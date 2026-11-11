package com.xmtx.im.platform

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

class ProfileFenceStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun id() = UUID.randomUUID().toString().uppercase()
    private val actor = UserId(id());private val peer = UserId(id());private val device = DeviceId(id());private val room = RoomId(id())
    private val key = ProfileKey(peer,ProfileContext.Room(room))
    private fun store() = SqliteClientStore(context,actor,device)
    private suspend fun project(store: SqliteClientStore,kind: String,payload: JsonObject) {
        val old = store.cursor()
        store.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("next").addRecords(SyncRecord.newBuilder().setUserSyncSequence(old.sequence+1).setSourceEventId(id()).setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(payload.toString()))).build(),old)
    }
    private fun security(revision: Long) = buildJsonObject { put("user_id",peer.value);put("minimum_profile_revision",revision);put("profile_state","hidden") }
    @Test fun securityAndAliasFloorsSurviveReopenAndSnapshotReplacement() = runBlocking {
        var store = store();try {
            project(store,"profile_invalidation",security(8));project(store,"profile_invalidation",security(4))
            project(store,"contact_alias",buildJsonObject { put("target_user_id",peer.value);put("revision",12) })
            val first = store.profileFences(persistentListOf(key));assertEquals(ProfileFence(8,12),first.floors[key]);assertEquals(first.generation,store.snapshot().presentationGeneration)
            store.close();store = store();assertEquals(first,store.profileFences(persistentListOf(key)))
            val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(30).setNextSyncToken("reset").build()
            store.stage(manifest);store.validateSnapshot(persistentListOf());assertEquals(first,store.profileFences(persistentListOf(key)))
            store.activateFixture(manifest,persistentListOf());val restored = store.profileFences(persistentListOf(key))
            assertEquals(first.floors,restored.floors);assertNotEquals(first.generation,restored.generation)
        } finally { store.close() }
    }
    @Test fun invalidPayloadRollsBackCursorAndPresentationGeneration() = runBlocking {
        val store = store();try {
            val before = store.profileFences(persistentListOf(key));val cursor = store.cursor()
            try { project(store,"contact_alias",buildJsonObject { put("target_user_id",peer.value);put("revision",2);put("remark_name","must not persist") });fail("private payload accepted") } catch(_: IllegalArgumentException) { }
            assertEquals(cursor,store.cursor());assertEquals(before,store.profileFences(persistentListOf(key)))
            try { project(store,"profile_invalidation",buildJsonObject { put("user_id",peer.value);put("minimum_profile_revision","8");put("profile_state","active") });fail("bad invalidation accepted") } catch(_: Exception) { }
            assertEquals(before,store.profileFences(persistentListOf(key)))
        } finally { store.close() }
    }
    @Test fun nicknameEffectsAreRoomScopedConflictCheckedAndPurgedOnRevocation() = runBlocking {
        val store = store();try {
            store.reconcileDirectory(persistentMapOf(room to RoomKind.Group));store.acceptState(room,RoomSyncState.newBuilder().setHead(20).setViewerMembershipRevision(1).build())
            suspend fun nickname(source: String,revision: Long,position: Long) {
                val payload = buildJsonObject { put("event_type","group.nickname_changed");put("room_id",room.value);put("target_user_id",peer.value);put("revision",revision);put("room_sequence",position);put("server_created_at_ms",1000) }
                store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(position).addEvents(GroupEvent.newBuilder().setSourceEventId(source).setRoomSequence(position).setProjectionKind("group_capability").setPayload(ByteString.copyFromUtf8(payload.toString()))).build(),store.roomCursor(room))
            }
            nickname(id(),3,1);val before = store.profileFences(persistentListOf(key));assertEquals(3L,before.floors[key]!!.nicknameRevision)
            try { nickname(id(),3,2);fail("revision reused") } catch(_: IllegalArgumentException) { }
            assertEquals(1L,store.roomCursor(room).sequence);assertEquals(before,store.profileFences(persistentListOf(key)))
            val review = ProfileKey(peer,ProfileContext.GroupJoinReview(room));assertEquals(0L,store.profileFences(persistentListOf(review)).floors[review]!!.nicknameRevision)
            store.unavailable(room);assertEquals(0L,store.profileFences(persistentListOf(key)).floors[key]!!.nicknameRevision)
        } finally { store.close() }
    }
}
