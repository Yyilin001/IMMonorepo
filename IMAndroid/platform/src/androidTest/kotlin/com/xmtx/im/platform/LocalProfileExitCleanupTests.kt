package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class LocalProfileExitCleanupTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun id() = UUID.randomUUID().toString()
    private inner class Fixture {
        val actor = UserId(id()); val peer = UserId(id()); val device = DeviceId(id()); val room = RoomId(id())
        val account = LocalExitAccount(actor, device); val key = ProfileKey(peer, ProfileContext.Relationship)
        val keys = persistentListOf(key); val file = accountDatabaseFile(context, actor, device)
        val marker = FileLocalExitMarker(context, "profile-exit-${id()}")
        var binding: LocalInstallationBinding? = LocalInstallationBinding.create()
        var reads = 0; var onLoad: suspend (Int) -> Unit = {}
        val bindings = object : InstallationBindingStore {
            override suspend fun load(): LocalInstallationBinding? { onLoad(++reads); return binding }
            override suspend fun save(binding: LocalInstallationBinding) = error("exit created binding")
            override suspend fun delete() = error("exit removed binding")
        }
        val bootstrap = LocalStoreBootstrapper(context, bindings)
        suspend fun seed() {
            bootstrap.open(actor, device).use { s ->
                val value = ProfileReadResult.Available(AuthorizedProfile(ProfileView(peer,
                    PublicIdentity(peer, PublicHandle("friend"), "只清除此姓名", AccountKind.Regular), null, ProfileState.Active, 1, 1),
                    ProfileLease(actor, device, key, 1, 1, 0, ProfileAuthority(1, null, 0, 0), 0, 60_000)), System.nanoTime() + 60_000_000_000)
                assertTrue(s.saveLocalProfileDisplays(persistentListOf(value), s.profileFences(keys)))
                s.saveConversationText(s.conversationDraft(room), "保留草稿", 1)
                db { it.execSQL("CREATE TABLE cleanup_sentinel(value TEXT NOT NULL)"); it.execSQL("INSERT INTO cleanup_sentinel VALUES('保留业务恢复记录')") }
            }
            marker.markPending(); reads = 0
        }
        fun db(body: (SQLiteDatabase) -> Unit) = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use(body)
        suspend fun clear() = bootstrap.clearLocalProfileDisplaysForExit(account, marker)
        fun count(): Long = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            db.rawQuery("SELECT COUNT(*) FROM local_profile_displays", null).use { it.moveToFirst(); it.getLong(0) }
        }
        suspend fun rejected() {
            try { clear(); fail("unsafe cleanup accepted") } catch (_: LocalStoreFailure) { }
            LocalDatabaseAccess.acquire(file, recovery = true).close()
        }
        fun cleanup() {
            for (suffix in listOf("", ".bak", ".new")) File(marker.path.path + suffix).delete()
            LocalDatabaseAccess.acquire(file, recovery = true).close(); SQLiteDatabase.deleteDatabase(file)
        }
    }

    @Test fun coldCleanupPreservesDraftOtherTablesAndOtherAccountAndIsIdempotent() = runBlocking {
        val f = Fixture(); val other = Fixture()
        try {
            f.seed(); other.seed(); val otherBytes = other.file.readBytes()
            f.clear(); assertEquals(0L, f.count()); assertTrue(f.marker.isPending())
            assertArrayEquals(otherBytes, other.file.readBytes()); assertEquals(2L, other.count())
            f.bootstrap.open(f.actor, f.device).use { assertEquals("保留草稿", it.conversationDraft(f.room).text) }
            f.db { db -> db.rawQuery("SELECT value FROM cleanup_sentinel", null).use { it.moveToFirst(); assertEquals("保留业务恢复记录", it.getString(0)) } }
            val cleared = f.file.readBytes(); f.clear(); assertArrayEquals(cleared, f.file.readBytes())
        } finally { f.cleanup(); other.cleanup() }
    }

    @Test fun missingDatabaseLegacyStoreAndUnknownIdentityNeverCreateMigrateOrScan() = runBlocking {
        val f = Fixture(); val other = Fixture()
        try {
            f.marker.markPending(); f.binding = null; f.clear(); assertFalse(f.file.exists()); assertEquals(0, f.reads)
            SQLiteDatabase.openOrCreateDatabase(f.file, null).use { it.execSQL("CREATE TABLE legacy(value TEXT)"); it.execSQL("INSERT INTO legacy VALUES('retain')") }
            val bytes = f.file.readBytes(); f.clear(); assertArrayEquals(bytes, f.file.readBytes()); assertEquals(0, f.reads)
            other.seed(); val otherBytes = other.file.readBytes()
            f.bootstrap.clearLocalProfileDisplaysForExit(null, f.marker)
            assertArrayEquals(otherBytes, other.file.readBytes())
        } finally { f.cleanup(); other.cleanup() }
    }

    @Test fun noPendingExitAndMalformedMarkerCannotDeleteFacts() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); val bytes = f.file.readBytes(); f.marker.clearPending(); f.rejected(); assertArrayEquals(bytes, f.file.readBytes())
            f.marker.path.writeText("interrupted"); f.rejected(); assertArrayEquals(bytes, f.file.readBytes())
        } finally { f.cleanup() }
    }

    @Test fun liveOwnerMustDrainBeforeColdCleanupCanAcquireTheDatabase() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); f.bootstrap.open(f.actor, f.device).use {
                try { f.clear(); fail("live store was cleared") } catch (_: LocalStoreFailure) { }
                assertEquals("只清除此姓名", it.cachedLocalProfileDisplays(f.keys).value(f.key)?.name)
            }
            f.clear(); assertEquals(0L, f.count())
        } finally { f.cleanup() }
    }

    @Test fun changedInstallationBindingOrDatabaseUuidBeforeWriteNeverClearsFacts() = runBlocking {
        for (replaceBinding in listOf(true, false)) {
            val f = Fixture()
            try {
                f.seed()
                f.onLoad = { if (it == 2) {
                    if (replaceBinding) f.binding = LocalInstallationBinding.create()
                    else f.db { db -> db.execSQL("UPDATE im_database_identity SET identity=?", arrayOf(LocalDatabaseIdentity.create().value)) }
                } }
                f.rejected(); assertEquals(2L, f.count()); assertTrue(f.marker.isPending())
            } finally { f.cleanup() }
        }
    }

    @Test fun cancellationAndExitMarkerChangeDuringValidationPreventMutation() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); val bytes = f.file.readBytes(); val entered = CompletableDeferred<Unit>()
            f.onLoad = { if (it == 2) { entered.complete(Unit); awaitCancellation() } }
            val work = launch(Dispatchers.Default) { f.clear() }
            withTimeout(10_000) { entered.await() }; work.cancelAndJoin()
            LocalDatabaseAccess.acquire(f.file, recovery = true).close(); assertArrayEquals(bytes, f.file.readBytes())
            f.reads = 0; f.onLoad = { if (it == 2) f.marker.clearPending() }
            f.rejected(); assertArrayEquals(bytes, f.file.readBytes())
        } finally { f.cleanup() }
    }

    @Test fun silentPartialDeleteRollsBackAndCanBeRetriedAfterStorageRepair() = runBlocking {
        val f = Fixture()
        try {
            f.seed()
            f.db { it.execSQL("CREATE TRIGGER reject_display_delete BEFORE DELETE ON local_profile_displays WHEN OLD.key LIKE 'basic|%' BEGIN SELECT RAISE(IGNORE); END") }
            f.rejected(); assertEquals(2L, f.count()); assertTrue(f.marker.isPending())
            f.db { it.execSQL("DROP TRIGGER reject_display_delete") }
            f.clear(); assertEquals(0L, f.count())
        } finally { f.cleanup() }
    }

    @Test fun foreignOwnershipAndOrphanSidecarsArePreservedWithoutAdoption() = runBlocking {
        val f = Fixture(); val absent = Fixture()
        try {
            f.seed(); f.db { it.execSQL("UPDATE im_installation SET user_id=?", arrayOf(UserId(id()).value)) }
            val bytes = f.file.readBytes(); f.rejected(); assertArrayEquals(bytes, f.file.readBytes())
            absent.marker.markPending(); val wal = File(absent.file.path + "-wal").apply { writeText("orphan") }
            absent.rejected(); assertFalse(absent.file.exists()); assertEquals("orphan", wal.readText())
        } finally { f.cleanup(); absent.cleanup() }
    }

    @Test fun corruptDatabaseAndSymlinkAreNeverDeletedOrFollowedByCleanup() = runBlocking {
        val f = Fixture(); val other = Fixture()
        try {
            f.seed(); other.seed(); val original = f.file.readBytes(); val otherBytes = other.file.readBytes()
            f.file.writeText("corrupt database fixture"); val corrupt = f.file.readBytes()
            f.rejected(); assertArrayEquals(corrupt, f.file.readBytes())
            f.file.delete(); Os.symlink(other.file.path, f.file.path)
            f.rejected(); assertArrayEquals(otherBytes, other.file.readBytes())
            f.file.delete(); f.file.writeBytes(original)
            val wal = File(f.file.path + "-wal"); Os.symlink(other.file.path, wal.path)
            try { f.rejected(); assertArrayEquals(otherBytes, other.file.readBytes()); assertArrayEquals(original, f.file.readBytes()) }
            finally { wal.delete() }
        } finally { f.cleanup(); other.cleanup() }
    }
}
