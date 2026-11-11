package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LocalProfileDisplayStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun id() = UUID.randomUUID().toString()
    private inner class Fixture {
        val actor = UserId(id()); val peer = UserId(id()); val device = DeviceId(id()); val room = RoomId(id())
        val contact = ProfileKey(peer, ProfileContext.Relationship); val direct = ProfileKey(peer, ProfileContext.DirectConversation)
        val group = ProfileKey(peer, ProfileContext.Room(room))
        val keys = persistentListOf(contact, direct, group)
        val file = accountDatabaseFile(context, actor, device)
        val binding = LocalInstallationBinding.create()
        val bootstrap = LocalStoreBootstrapper(context, object : InstallationBindingStore {
            override suspend fun load() = binding
            override suspend fun save(binding: LocalInstallationBinding) = error("unexpected binding mutation")
            override suspend fun delete() = error("unexpected binding mutation")
        })
        var store: SqliteClientStore? = null
        suspend fun open(): SqliteClientStore { store?.close(); return bootstrap.open(actor, device).also { store = it } }
        fun db(body: (SQLiteDatabase) -> Unit) = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use(body)
        fun value(key: ProfileKey = contact, revision: Long = 1, alias: String? = null, aliasRevision: Long? = null,
            nickname: String? = null, control: Long = revision, state: ProfileState = ProfileState.Active,
            owner: UserId = actor, deadline: Long = System.nanoTime() + 60_000_000_000): ProfileReadResult.Available {
            val scope = when (val c = key.context) { is ProfileContext.Room -> c.room; is ProfileContext.GroupJoinReview -> c.room; ProfileContext.DirectConversation -> room; else -> null }
            val membership = if (scope == null) 0L else 1L
            return ProfileReadResult.Available(AuthorizedProfile(ProfileView(peer,
                if (state == ProfileState.Active) PublicIdentity(peer, PublicHandle("friend"), "姓名$revision", AccountKind.Regular) else null,
                if (state == ProfileState.Active) id().uppercase() else null, state, revision, revision),
                ProfileLease(owner, device, key, revision, revision, membership, ProfileAuthority(control, scope, membership, 0), revision, revision + 60_000),
                nickname?.let { ProfileGroupName(room, peer, it, revision) }, aliasRevision?.let { ProfileAlias(owner, peer, alias, it) }), deadline)
        }
        suspend fun save(vararg values: ProfileReadResult, expected: ProfileFenceSnapshot? = null): Boolean {
            val s = requireNotNull(store); val batch = values.toList().toPersistentList()
            return s.saveLocalProfileDisplays(batch, expected ?: s.profileFences(batch.map { it.key }.toPersistentList()))
        }
        suspend fun snapshot(keys: PersistentList<ProfileKey> = this.keys) = requireNotNull(store).cachedLocalProfileDisplays(keys)
        suspend fun project(kind: String, payload: JsonObject) {
            val s = requireNotNull(store); val cursor = s.cursor()
            s.commit(SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("next")
                .addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setProjectionKind(kind).setUserSyncSequence(cursor.sequence + 1)
                    .setPayload(ByteString.copyFromUtf8(payload.toString()))).build(), cursor)
        }
        fun security(revision: Long) = buildJsonObject { put("user_id", peer.value); put("minimum_profile_revision", revision); put("profile_state", "hidden") }
        fun cleanup() { store?.close(); LocalDatabaseAccess.acquire(file, recovery = true).close(); SQLiteDatabase.deleteDatabase(file) }
    }

    @Test fun coldNamesShareOwnRemarksButNeverPersistAvatarOrLeaseAndNicknamesStayScoped() = runBlocking {
        val f = Fixture()
        try {
            f.open(); val profile = f.value(alias = "我的备注", aliasRevision = 1)
            assertTrue(f.save(profile, f.value(f.group, nickname = "群昵称")))
            f.open(); val snapshot = f.snapshot()
            assertEquals("我的备注", snapshot.value(f.contact)?.name); assertEquals("我的备注", snapshot.value(f.direct)?.name)
            assertEquals("群昵称", snapshot.value(f.group)?.name)
            val review = ProfileKey(f.peer, ProfileContext.GroupJoinReview(f.room))
            assertEquals("姓名1", f.snapshot(persistentListOf(review)).value(review)?.name)
            assertFalse(f.save(profile.copy(deadlineNanos = System.nanoTime() - 1)))
            assertEquals("我的备注", f.snapshot().value(f.contact)?.name)
            f.db { db -> db.rawQuery("SELECT value,authority FROM local_profile_displays", null).use { rows ->
                while (rows.moveToNext()) {
                    val raw = (if (rows.isNull(0)) "" else rows.getString(0)) + (if (rows.isNull(1)) "" else rows.getString(1))
                    for (secret in listOf("lease", "avatar", "validUntil", "deadline", "https://", profile.profile.view.avatarMediaId!!)) assertFalse(raw.contains(secret))
                }
            } }
        } finally { f.cleanup() }
    }

    @Test fun scopedDenialRetainsNewestSharedIdentityAndRemarkAcrossRestart() = runBlocking {
        val f = Fixture()
        try {
            f.open(); assertTrue(f.save(f.value(f.direct)))
            assertTrue(f.save(f.value(revision = 4, alias = "新备注", aliasRevision = 5)))
            assertTrue(f.save(ProfileReadResult.Unavailable(f.contact, ProfileAuthority(5, null, 0, 0))))
            f.open(); assertNull(f.snapshot().value(f.contact)); assertEquals("新备注", f.snapshot().value(f.direct)?.name)
            assertEquals("姓名4", f.snapshot().value(f.direct)?.identity?.displayName)
            assertFalse(f.save(f.value(revision = 2))); assertNull(f.snapshot().value(f.contact))
            assertTrue(f.save(f.value(revision = 6, aliasRevision = 6)))
            assertEquals("姓名6", f.snapshot().value(f.direct)?.name)
            assertNull(f.snapshot().basics[f.peer]?.alias?.name)
        } finally { f.cleanup() }
    }

    @Test fun globalHiddenDenialBlocksOldOtherContextAndNewerAuthorizationRestoresText() = runBlocking {
        val f = Fixture()
        try {
            f.open(); assertTrue(f.save(f.value(f.direct), f.value()))
            val hidden = f.value(revision = 3, state = ProfileState.Hidden)
            assertTrue(f.save(hidden)); assertTrue(f.save(hidden)); f.open()
            assertTrue(f.snapshot().records.isEmpty()); assertTrue(f.keys.all { f.snapshot().value(it) == null })
            assertFalse(f.save(f.value(f.direct, revision = 2, control = 9)))
            assertTrue(f.save(f.value(f.direct, revision = 4)))
            assertEquals("姓名4", f.snapshot().value(f.contact)?.name)
        } finally { f.cleanup() }
    }

    @Test fun liveSecurityFloorPurgesAtomicallyWhileLateOlderInvalidationKeepsNewerFacts() = runBlocking {
        val f = Fixture()
        try {
            f.open(); val old = f.value(); assertTrue(f.save(old))
            f.project("profile_invalidation", f.security(2))
            assertTrue(f.snapshot().basics.isEmpty()); assertFalse(f.save(old))
            assertTrue(f.save(f.value(revision = 4)))
            f.project("profile_invalidation", f.security(3)); f.open()
            assertEquals("姓名4", f.snapshot().value(f.contact)?.name)
            f.db { db -> db.rawQuery("SELECT COUNT(*) FROM local_profile_displays WHERE value IS NOT NULL AND revision<=3", null).use { it.moveToFirst(); assertEquals(0, it.getInt(0)) } }
        } finally { f.cleanup() }
    }

    @Test fun snapshotFloorAppliesAtActivationAndPreservesNewerConcurrentDisplay() = runBlocking {
        for (newer in listOf(false, true)) {
            val f = Fixture()
            try {
                val s = f.open(); assertTrue(f.save(f.value()))
                val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(30).setNextSyncToken("reset").build()
                val items = persistentListOf(SnapshotItem("profile_invalidation", f.peer.value, id().uppercase(), 1, ByteString.copyFromUtf8(f.security(2).toString())))
                s.stage(manifest); s.validateSnapshot(items)
                assertEquals("姓名1", f.snapshot().value(f.contact)?.name)
                if (newer) assertTrue(f.save(f.value(revision = 3)))
                s.activateFixture(manifest, items)
                assertEquals(if (newer) "姓名3" else null, f.snapshot().value(f.contact)?.name)
            } finally { f.cleanup() }
        }
    }

    @Test fun wrongOwnerExpiredAndChangedFenceBatchesHaveNoPartialCommit() = runBlocking {
        val f = Fixture()
        try {
            val s = f.open()
            assertFalse(f.save(f.value(), f.value(f.group, owner = UserId(id())))); assertTrue(f.snapshot().basics.isEmpty())
            assertFalse(f.save(f.value(), f.value(f.group, deadline = System.nanoTime() - 1))); assertTrue(f.snapshot().basics.isEmpty())
            val before = s.profileFences(persistentListOf(f.contact))
            f.project("contact_alias", buildJsonObject { put("target_user_id", f.peer.value); put("revision", 2) })
            assertFalse(f.save(f.value(alias = "备注", aliasRevision = 2), expected = before)); assertTrue(f.snapshot().basics.isEmpty())
            assertFalse(f.save(f.value(alias = "旧备注", aliasRevision = 1)))
            assertTrue(f.save(f.value(alias = "新备注", aliasRevision = 2)))
            s.clearLocalProfileDisplays(); assertTrue(f.snapshot().basics.isEmpty())
            assertEquals(2L, s.profileFences(persistentListOf(f.contact)).floors[f.contact]!!.aliasRevision)
        } finally { f.cleanup() }
    }

    @Test fun readonlyProjectionUsesCachedNamesAndSecurityDenialRemovesDirectEvidence() = runBlocking {
        val f = Fixture()
        try {
            f.open()
            f.project("direct_room_profile", buildJsonObject {
                put("room_id", f.room.value); put("target_user_id", f.peer.value); put("display_name", "不能展示的发现名称")
                put("public_handle", "friend"); put("account_kind", "regular"); put("revision", 1); put("updated_at_ms", 1); put("room_created_at_ms", 1)
            })
            assertTrue(f.save(f.value(f.direct, alias = "我的备注", aliasRevision = 1)))
            f.db { it.execSQL("INSERT INTO messages(id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn,rich) VALUES (?,?,?,?,?,1,1,1,1,0,'{}')",
                arrayOf(id(), f.room.value, f.peer.value, "正文", "正文")) }
            f.store!!.close(); val bytes = f.file.readBytes()
            SqliteLocalReadConnection.open(f.file).use { reader -> SqliteLocalReadConnection.snapshot(reader) {
                val projection = SqliteLocalProjection(reader, f.actor)
                assertEquals("我的备注", projection.conversations(null, 10).entries.single().title)
                assertEquals("姓名1", projection.messages(f.room, null, 10).entries.single().senderName)
            } }
            assertArrayEquals(bytes, f.file.readBytes())
            f.open(); f.project("profile_invalidation", f.security(1)); f.store!!.close()
            SqliteLocalReadConnection.open(f.file).use { reader -> SqliteLocalReadConnection.snapshot(reader) {
                val projection = SqliteLocalProjection(reader, f.actor)
                assertTrue(projection.conversations(null, 10).entries.isEmpty()); assertFalse(projection.messages(f.room, null, 10).available)
            } }
        } finally { f.cleanup() }
    }

    @Test fun oldReadonlyStoreDoesNotCreateCacheAndCorruptOwnedFactIsNotDisplayed() = runBlocking {
        val f = Fixture()
        try {
            f.open(); assertTrue(f.save(f.value())); f.store!!.close()
            f.db { it.execSQL("UPDATE local_profile_displays SET value='{}' WHERE value IS NOT NULL") }
            SqliteLocalReadConnection.open(f.file).use { reader ->
                try { SqliteLocalReadConnection.snapshot(reader) { SqliteLocalProfileDisplays(reader, f.actor).load(f.keys) }; fail("corrupt display accepted") } catch (_: kotlinx.serialization.SerializationException) { }
            }
            f.db { it.execSQL("DROP TABLE local_profile_displays") }; val bytes = f.file.readBytes()
            SqliteLocalReadConnection.open(f.file).use { reader ->
                assertTrue(SqliteLocalReadConnection.snapshot(reader) { SqliteLocalProfileDisplays(reader, f.actor).load(f.keys).basics.isEmpty() })
            }
            assertArrayEquals(bytes, f.file.readBytes())
        } finally { f.cleanup() }
    }
    @Test fun atomicPageReadsRequireExactFencesAndStoreSignalsCacheAndSecurityChanges() = runBlocking {
        val f = Fixture()
        try {
            val store = f.open(); val before = store.profileFences(f.keys)
            val initial = store.localDisplayChanges.value
            assertTrue(f.save(f.value())); assertTrue(store.localDisplayChanges.value > initial)
            assertEquals("姓名1", store.readLocalProfileDisplays(f.keys, before)?.value(f.direct)?.name)
            val saved = store.localDisplayChanges.value
            assertTrue(f.save(ProfileReadResult.Unavailable(f.contact, ProfileAuthority(2, null, 0, 0))))
            assertTrue(store.localDisplayChanges.value > saved)
            val scoped = store.readLocalProfileDisplays(f.keys, before)!!
            assertNull(scoped.value(f.contact)); assertEquals("姓名1", scoped.value(f.direct)?.name)
            val denied = store.localDisplayChanges.value
            f.project("profile_invalidation", f.security(2))
            assertTrue(store.localDisplayChanges.value > denied)
            assertNull(store.readLocalProfileDisplays(f.keys, before))
            val current = store.profileFences(f.keys)
            assertTrue(store.readLocalProfileDisplays(f.keys, current)!!.basics.isEmpty())
            assertTrue(f.save(f.value(revision = 3))); val restored = store.localDisplayChanges.value
            store.clearLocalProfileDisplays(); assertTrue(store.localDisplayChanges.value > restored)
            assertTrue(store.readLocalProfileDisplays(f.keys, current)!!.basics.isEmpty())
        } finally { f.cleanup() }
    }

    @Test fun ordinaryContentHintsKeepLocalTextButReadersMustCaptureNewGeneration() = runBlocking {
        val f = Fixture()
        try {
            val store = f.open(); assertTrue(f.save(f.value(alias = "保留的本地备注", aliasRevision = 1)))
            val before = store.profileFences(f.keys); val signal = store.localDisplayChanges.value
            f.project("contact_alias", buildJsonObject { put("target_user_id", f.peer.value); put("revision", 2) })
            assertTrue(store.localDisplayChanges.value > signal)
            assertNull(store.readLocalProfileDisplays(f.keys, before))
            val current = store.profileFences(f.keys)
            assertEquals("保留的本地备注", store.readLocalProfileDisplays(f.keys, current)?.value(f.contact)?.name)
            try { store.readLocalProfileDisplays(persistentListOf(f.contact), current); fail("mismatched key set accepted") }
            catch (_: IllegalArgumentException) { }
        } finally { f.cleanup() }
    }

}
