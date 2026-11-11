package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class DirectIdentityStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val peer = UserId(id()); val device = DeviceId(id()); val room = RoomId(id())
        val identity = PublicIdentity(peer, PublicHandle("friend"), "创建时选择", AccountKind.CustomerSupport)
        val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device)
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device) }
        suspend fun prepare(identity: PublicIdentity = this.identity) = store.prepareDirect(DirectRoomCommand.create(actor, identity.user, 1000), identity)
        fun opened(work: DirectRoomWork, room: RoomId = this.room, created: Long = 1000): DirectRoomWork {
            val c = work.command
            val receipt = buildJsonObject {
                put("identity", c.identity()); put("fingerprint", c.fingerprintPayload()); put("resolvedAtMilliseconds", 3000)
                put("outcome", buildJsonObject { put("opened", buildJsonObject {
                    put("roomID", buildJsonObject { put("rawValue", room.value) }); put("createdAtMilliseconds", created)
                }) })
            }
            return work.copy(status = DirectWorkStatus.Opened, receipt = receipt.toString(), room = room)
        }
        suspend fun complete(): DirectRoomWork { val work = prepare(); val done = opened(work); store.updateDirect(work, done); return done }
        suspend fun project(kind: String, value: JsonObject) {
            val cursor = store.cursor()
            store.commit(SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("next")
                .addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setProjectionKind(kind).setUserSyncSequence(cursor.sequence + 1)
                    .setPayload(ByteString.copyFromUtf8(value.toString()))).build(), cursor)
        }
        fun profile(created: Long = 1000, target: UserId = peer) = buildJsonObject {
            put("room_id", room.value); put("target_user_id", target.value); put("public_handle", "friend")
            put("display_name", "服务端发现名称"); put("account_kind", "system"); put("revision", 4); put("updated_at_ms", 2000); put("room_created_at_ms", created)
        }
        fun security(revision: Long) = buildJsonObject { put("user_id", peer.value); put("minimum_profile_revision", revision); put("profile_state", "hidden") }
        suspend fun reset(items: PersistentList<SnapshotItem> = persistentListOf()) {
            val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(30).setNextSyncToken("reset").build()
            store.stage(manifest); store.validateSnapshot(items); store.activateFixture(manifest, items)
        }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
    }
    private suspend fun rejected(body: suspend () -> Unit) {
        try { body(); fail("invalid transition accepted") } catch (_: IllegalArgumentException) { } catch (_: IllegalStateException) { }
    }

    @Test fun selectionFreezesWithOperationAcrossCoalescingRestartAndLostResponse() = runBlocking {
        val f = Fixture()
        try {
            val first = f.prepare(); assertEquals(first, f.prepare(f.identity.copy(displayName = "后来查询")))
            rejected { f.store.prepareDirect(first.command, f.identity.copy(user = UserId(id()))) }
            rejected { f.store.updateDirect(first, first.copy(publicIdentity = f.identity.copy(displayName = "不能替换"))) }
            val started = first.copy(executionStarted = true, reconcile = true)
            f.store.updateDirect(first, started); f.reopen(); assertEquals(started, f.store.directWorks().single())
            f.store.updateDirect(started, f.opened(started)); f.reopen()
            assertEquals(f.identity, f.store.localDirectRoomIdentities().single().publicIdentity)
            assertEquals(1000L, f.store.localDirectRoomIdentities().single().roomCreatedAt)
        } finally { f.close() }
    }
    @Test fun receiptContextDoesNotGrantDisplayRoomReadSendingClassificationOrSyncEnrollment() = runBlocking {
        val f = Fixture()
        try {
            f.complete(); val conversation = f.store.appSnapshot().conversations.single()
            assertEquals(f.peer, conversation.peer); assertEquals(1000L, conversation.updatedAt); assertEquals("会话", conversation.title)
            assertNull(f.store.conversationSendingPolicy(f.room, f.actor).accountKind)
            assertNull(f.store.directSendingCapability(f.room, f.actor))
            assertTrue(f.store.cachedLocalProfileDisplays(persistentListOf(ProfileKey(f.peer, ProfileContext.DirectConversation))).basics.isEmpty())
            f.store.close()
            SqliteLocalReadConnection.open(f.file).use { db -> SqliteLocalReadConnection.snapshot(db) {
                assertFalse(SqliteLocalProjection(db, f.actor).allows(f.room))
                assertTrue(SqliteLocalProjection(db, f.actor).conversations(null, 10).entries.isEmpty())
                for (table in listOf("room_cursors", "rooms", "direct_profile_bindings", "direct_account_kinds"))
                    db.rawQuery("SELECT COUNT(*) FROM $table", null).use { it.moveToFirst(); assertEquals(0, it.getInt(0)) }
            } }
        } finally { f.close() }
    }
    @Test fun conflictingReceiptAndProjectionRollbackWithoutLosingFrozenWork() = runBlocking {
        val f = Fixture()
        try {
            f.complete(); val old = f.store.localDirectRoomIdentities()
            val second = f.prepare()
            rejected { f.store.updateDirect(second, f.opened(second, created = 1001)) }
            assertEquals(second, f.store.directWorks().first()); assertEquals(old, f.store.localDirectRoomIdentities())
            val foreign = f.prepare(f.identity.copy(user = UserId(id())))
            rejected { f.store.updateDirect(foreign, f.opened(foreign)) }
            val cursor = f.store.cursor()
            rejected { f.project("direct_room_profile", f.profile(created = 1001)) }
            rejected { f.project("direct_room_profile", f.profile(target = UserId(id()))) }
            assertEquals(cursor, f.store.cursor()); assertEquals(old, f.store.localDirectRoomIdentities())
        } finally { f.close() }
    }
    @Test fun snapshotPreservesDeviceContextAndUsesAuthoritativeClassificationSeparately() = runBlocking {
        val f = Fixture()
        try {
            f.complete(); val original = f.store.localDirectRoomIdentities()
            f.project("direct_room_profile", f.profile())
            assertEquals(AccountKind.System, f.store.conversationSendingPolicy(f.room, f.actor).accountKind)
            assertEquals(original, f.store.localDirectRoomIdentities())
            f.reset(); f.reopen()
            assertEquals(original, f.store.localDirectRoomIdentities())
            assertEquals(f.peer, f.store.appSnapshot().conversations.single().peer)
            assertNull(f.store.conversationSendingPolicy(f.room, f.actor).accountKind)
            f.store.close(); SqliteLocalReadConnection.open(f.file).use { db ->
                SqliteLocalReadConnection.snapshot(db) { assertFalse(SqliteLocalProjection(db, f.actor).allows(f.room)) }
            }
        } finally { f.close() }
    }
    @Test fun securityRemovalIsAtomicAndDuplicateTerminalCallbackCannotRepublishIdentity() = runBlocking {
        val f = Fixture()
        try {
            val done = f.complete(); f.project("profile_invalidation", f.security(2)); f.reopen()
            assertTrue(f.store.localDirectRoomIdentities().isEmpty())
            assertTrue(f.store.appSnapshot().conversations.isEmpty())
            rejected { f.store.updateDirect(done, done) }
            assertTrue(f.store.localDirectRoomIdentities().isEmpty())
            assertEquals(f.identity, f.store.directWorks().single().publicIdentity) // Original intent is not a display grant.
        } finally { f.close() }
    }
    @Test fun newerAuthorizedTextPreservesContextUntilSecurityCatchesUpAndSnapshotPreflightRollsBack() = runBlocking {
        val f = Fixture()
        try {
            f.complete(); val key = ProfileKey(f.peer, ProfileContext.Relationship)
            val available = ProfileReadResult.Available(AuthorizedProfile(
                ProfileView(f.peer, f.identity, null, ProfileState.Active, 5, 5),
                ProfileLease(f.actor, f.device, key, 5, 5, 0, ProfileAuthority(5, null, 0, 0), 0, 60_000)), System.nanoTime() + 60_000_000_000)
            assertTrue(f.store.saveLocalProfileDisplays(persistentListOf(available), f.store.profileFences(persistentListOf(key))))
            f.project("profile_invalidation", f.security(3)); assertEquals(1, f.store.localDirectRoomIdentities().size)
            val items = persistentListOf(SnapshotItem("profile_invalidation", f.peer.value, id(), 1, ByteString.copyFromUtf8(f.security(5).toString())))
            val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(30).setNextSyncToken("reset").build()
            f.store.stage(manifest); f.store.validateSnapshot(items)
            assertEquals(1, f.store.localDirectRoomIdentities().size)
            f.store.activateFixture(manifest, items); assertTrue(f.store.localDirectRoomIdentities().isEmpty())
        } finally { f.close() }
    }
    @Test fun legacyWorkAndOldReadonlyDatabaseDoNotInventIdentityOrMigrate() = runBlocking {
        val f = Fixture()
        try {
            val old = f.store.prepareDirect(DirectRoomCommand.create(f.actor, f.peer, 1000))
            assertNull(old.publicIdentity); f.store.updateDirect(old, f.opened(old)); assertTrue(f.store.localDirectRoomIdentities().isEmpty())
            f.store.close()
            SQLiteDatabase.openDatabase(f.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { it.execSQL("DROP TABLE local_direct_room_identities") }
            val before = f.file.readBytes()
            SqliteLocalReadConnection.open(f.file).use { db -> assertTrue(SqliteDirectRoomIdentities(db, f.actor).all().isEmpty()) }
            assertArrayEquals(before, f.file.readBytes())
        } finally { f.close() }
    }
}
