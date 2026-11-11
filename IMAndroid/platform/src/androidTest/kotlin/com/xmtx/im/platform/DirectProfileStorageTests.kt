package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import android.database.sqlite.SQLiteDatabase
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.io.File
import java.security.MessageDigest

class DirectProfileStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun id() = UUID.randomUUID().toString().uppercase()
    private val actor = UserId(id());private val peer = UserId(id());private val device = DeviceId(id());private val room = RoomId(id())
    private fun store() = SqliteClientStore(context,actor,device)
    private fun database(): SQLiteDatabase {
        val hash = MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
        return SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$hash.db").path,null,SQLiteDatabase.OPEN_READWRITE)
    }
    private fun value(revision: Long = 2,name: String = "旧展示名称",target: UserId = peer,created: Long = 1000,accountKind:String="regular") = buildJsonObject {
        put("room_id",room.value);put("target_user_id",target.value);put("display_name",name);put("public_handle","friend");put("account_kind",accountKind)
        put("revision",revision);put("updated_at_ms",1234);put("room_created_at_ms",created)
    }
    private suspend fun project(store: SqliteClientStore,kind: String = "direct_room_profile",payload: JsonObject = value()) {
        val cursor = store.cursor()
        store.commit(SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("next").addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setProjectionKind(kind).setUserSyncSequence(cursor.sequence+1).setPayload(ByteString.copyFromUtf8(payload.toString()))).build(),cursor)
    }
    private fun available(kind:AccountKind,revision:Long=2,viewer:UserId=actor,owner:DeviceId=device,deadline:Long=System.nanoTime()+60_000_000_000)=ProfileReadResult.Available(
        AuthorizedProfile(ProfileView(peer,PublicIdentity(peer,PublicHandle("friend"),"仅授权展示",kind),null,ProfileState.Active,revision,1),
            ProfileLease(viewer,owner,ProfileKey(peer,ProfileContext.DirectConversation),revision,1,1,ProfileAuthority(1,room,1,0),0,60_000)),deadline)
    @Test fun systemClassificationBlocksNewDraftBeforeCapabilityButSupportAndGroupsRemainWritable()=runBlocking {
        val store=store();try {
            project(store,payload=value(accountKind="system"));assertNull(store.directSendingCapability(room,actor))
            var draft=store.saveConversationText(store.conversationDraft(room),"保留正文",System.currentTimeMillis())
            val frozen=SendIntentService(actor,store).prepareDraft(draft)
            assertEquals("此系统账号仅用于发送通知",store.conversationSendingPolicy(room,actor).restriction)
            assertTrue(runCatching {store.submitConversationDraft(draft,frozen,System.currentTimeMillis())}.exceptionOrNull() is ConversationDraftSubmissionRejected)
            assertEquals(draft,store.conversationDraft(room));assertTrue(store.sendIntents().isEmpty())
            assertNull(store.conversationSendingPolicy(room,UserId(id())).accountKind)
            database().use {it.execSQL("INSERT INTO room_kinds VALUES (?,?)",arrayOf(room.value,RoomKind.Group.name))}
            assertTrue(store.conversationSendingPolicy(room,actor).allowsNewContent)
            database().use {it.execSQL("DELETE FROM room_kinds")}
            project(store,payload=value(3,accountKind="customer_support"));assertTrue(store.conversationSendingPolicy(room,actor).allowsNewContent)
            store.submitConversationDraft(draft,frozen,System.currentTimeMillis());assertTrue(store.conversationDraft(room).empty)
            val next=store.saveConversationText(store.conversationDraft(room),"下一条",System.currentTimeMillis())
            project(store,payload=value(4,accountKind="system"));store.submitConversationDraft(draft,frozen,System.currentTimeMillis());assertEquals(next,store.conversationDraft(room))
        } finally {store.close()}
    }
    @Test fun legacyClassificationCanBackfillOnIdenticalProjectionAndSnapshotReplacesIt()=runBlocking {
        var store=store();try {
            project(store,payload=value(accountKind="system"));store.close()
            database().use {it.execSQL("DROP TABLE direct_account_kinds")};store=store()
            assertNull(store.conversationSendingPolicy(room,actor).accountKind)
            project(store,payload=value(accountKind="system"));assertEquals(AccountKind.System,store.conversationSendingPolicy(room,actor).accountKind)
            val manifest=SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(30).setNextSyncToken("reset").build()
            store.stage(manifest);store.validateSnapshot(persistentListOf());assertEquals(AccountKind.System,store.conversationSendingPolicy(room,actor).accountKind)
            store.activateFixture(manifest,persistentListOf());assertNull(store.conversationSendingPolicy(room,actor).accountKind)
        } finally {store.close()}
    }
    @Test fun authorizedKindBackfillRejectsExpiredWrongOwnerStaleFencesAndCannotDowngrade()=runBlocking {
        var store=store();try {
            project(store,payload=value(accountKind="system"));database().use {it.execSQL("DELETE FROM direct_account_kinds")}
            val keys=persistentListOf(ProfileKey(peer,ProfileContext.DirectConversation));val fence=store.profileFences(keys)
            for(result in listOf(available(AccountKind.System,viewer=UserId(id())),available(AccountKind.System,owner=DeviceId(id())),available(AccountKind.System,deadline=System.nanoTime()-1)))
                assertFalse(store.adoptDirectAccountKind(room,result,fence))
            assertFalse(store.adoptDirectAccountKind(RoomId(id()),available(AccountKind.System),fence))
            assertTrue(store.adoptDirectAccountKind(room,available(AccountKind.System),fence));store.close();store=store()
            assertEquals(AccountKind.System,store.conversationSendingPolicy(room,actor).accountKind)
            assertTrue(store.adoptDirectAccountKind(room,available(AccountKind.CustomerSupport,3),store.profileFences(keys)))
            project(store,payload=value(accountKind="system"));assertEquals(AccountKind.CustomerSupport,store.conversationSendingPolicy(room,actor).accountKind)
            assertNotNull(runCatching {store.adoptDirectAccountKind(room,available(AccountKind.System,3),store.profileFences(keys))}.exceptionOrNull())
            project(store,"profile_invalidation",buildJsonObject {put("user_id",peer.value);put("minimum_profile_revision",3);put("profile_state","hidden")})
            assertFalse(store.adoptDirectAccountKind(room,available(AccountKind.System),fence));assertNull(store.conversationSendingPolicy(room,actor).accountKind)
            store.unavailable(room)
            database().use {db->db.rawQuery("SELECT COUNT(*) FROM direct_account_kinds",null).use {it.moveToFirst();assertEquals(0,it.getInt(0))}}
        } finally {store.close()}
    }
    @Test fun discoveryNeverBecomesTitleAndSecurityFloorPreventsStaleRediscovery() = runBlocking {
        var store = store();try {
            project(store);val conversation = store.snapshot().conversations.single();assertEquals(peer,conversation.peer);assertEquals("会话",conversation.title)
            assertEquals(2L,store.profileFences(persistentListOf(ProfileKey(peer,ProfileContext.DirectConversation))).floors.values.single().minimumProfileRevision)
            project(store,"profile_invalidation",buildJsonObject { put("user_id",peer.value);put("minimum_profile_revision",2);put("profile_state","hidden") })
            assertNull(store.snapshot().conversations.single().peer);project(store);assertNull(store.snapshot().conversations.single().peer)
            project(store,payload = value(3));assertEquals(peer,store.snapshot().conversations.single().peer)
            store.close();store = store();assertEquals(peer,store.snapshot().conversations.single().peer)
            database().use { db ->
                db.rawQuery("SELECT COUNT(*) FROM records WHERE kind='direct_room_profile'",null).use { assertTrue(it.moveToFirst());assertEquals(0,it.getInt(0)) }
                db.rawQuery("SELECT title FROM rooms",null).use { assertTrue(it.moveToFirst());assertFalse(it.getString(0).contains("旧展示名称")) }
            }
        } finally { store.close() }
    }
    @Test fun sameVersionConflictRoomRetargetAndCreationTimeChangeRollback() = runBlocking {
        val store = store();try {
            project(store);val cursor = store.cursor();val before = store.snapshot()
            for(payload in listOf(value(name = "different"),value(3,target = UserId(id())),value(3,created = 999),value(3,target = actor))) {
                try { project(store,payload = payload);fail("invalid discovery accepted") } catch(_: IllegalArgumentException) { }
                assertEquals(cursor,store.cursor());assertEquals(before,store.snapshot())
            }
            project(store,payload = value(1));assertEquals(peer,store.snapshot().conversations.single().peer)
            store.unavailable(room);assertTrue(store.snapshot().conversations.isEmpty())
        } finally { store.close() }
    }
    @Test fun legacyTitleMigrationAndPersonalSnapshotReplacementPreserveOnlyNewLookupFacts() = runBlocking {
        var store = store();try {
            project(store);store.close()
            database().use { db ->
                db.execSQL("DELETE FROM projection_migrations WHERE name='direct_lookup_v1'");db.execSQL("DELETE FROM direct_profile_bindings")
                db.execSQL("UPDATE rooms SET title='旧展示名称'")
                db.execSQL("INSERT INTO records VALUES (?,?,?,?)",arrayOf(id(),"direct_room_profile",value().toString().toByteArray(),room.value))
            }
            store = store();assertEquals("会话",store.snapshot().conversations.single().title);assertEquals(peer,store.snapshot().conversations.single().peer)
            val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(30).setNextSyncToken("reset").build()
            store.stage(manifest);store.validateSnapshot(persistentListOf());assertEquals(peer,store.snapshot().conversations.single().peer)
            store.activateFixture(manifest,persistentListOf());assertTrue(store.snapshot().conversations.isEmpty())
            assertEquals(2L,store.profileFences(persistentListOf(ProfileKey(peer,ProfileContext.DirectConversation))).floors.values.single().minimumProfileRevision)
            project(store);assertEquals(peer,store.snapshot().conversations.single().peer)
        } finally { store.close() }
    }
}
