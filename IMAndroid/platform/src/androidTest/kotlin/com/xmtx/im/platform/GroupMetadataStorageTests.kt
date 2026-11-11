package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class GroupMetadataStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val account = UserId(UUID.randomUUID().toString())
    private val device = DeviceId(UUID.randomUUID().toString())
    private val room = RoomId(UUID.randomUUID().toString())
    private val message = MessageId(UUID.randomUUID().toString())
    private fun store() = SqliteClientStore(context, account, device)
    private fun announcement(body: String, revision: Int) = buildJsonObject {
        put("event_type", "group.announcement_changed"); put("room_id", room.value); put("body", body); put("revision", revision); put("server_created_at_ms", 1000)
    }
    private fun pin(value: Boolean) = buildJsonObject {
        put("event_type", "message.pinned_changed"); put("room_id", room.value); put("message_id", message.value); put("is_pinned", value); put("server_created_at_ms", 1000)
    }
    private fun messagePayload() = buildJsonObject {
        put("event_type", "message.accepted"); put("room_id", room.value); put("message_id", message.value); put("sender_user_id", account.value)
        put("text", "hello"); put("server_created_at_ms", 1000); put("room_sequence", 1); put("message_revision", 1)
    }
    private suspend fun apply(store: SqliteClientStore, sequence: Long, source: String, value: JsonObject, kind: String = "group_capability") {
        val current = store.roomCursor(room)
        val page = GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence).addEvents(GroupEvent.newBuilder()
            .setRoomSequence(sequence).setSourceEventId(source).setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(value.toString()))).build()
        store.commitRoom(page, current)
    }
    @Test fun metadataReopenConflictsRollbackAndWithdrawalHidesPins() = runBlocking {
        var store = store()
        store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
        apply(store, 1, "message", messagePayload(), "message")
        apply(store, 2, "announcement", announcement("new", 2)); apply(store, 3, "pin", pin(true))
        store.close(); store = store()
        assertEquals("new", store.snapshot().announcements.single().body); assertEquals(message, store.snapshot().pins.single().message)
        try { apply(store, 4, "changed-source", announcement("tampered", 2)); fail("same revision changed") } catch (_: ClientFailure.Protocol) { }
        assertEquals(3L, store.roomCursor(room).sequence); assertEquals("new", store.snapshot().announcements.single().body)
        try { apply(store, 4, "announcement", announcement("new", 2)); fail("source moved") } catch (_: ClientFailure.Protocol) { }
        assertEquals(3L, store.roomCursor(room).sequence)
        apply(store, 4, "old-announcement", announcement("old", 1)); assertEquals("new", store.snapshot().announcements.single().body)
        apply(store, 5, "unpin", pin(false)); assertTrue(store.snapshot().pins.isEmpty())
        apply(store, 6, "clear-announcement", announcement("", 3)); assertEquals(3L, store.snapshot().announcements.single().revision)
        apply(store, 7, "repin", pin(true))
        apply(store, 8, "withdraw", JsonObject(messagePayload() + mapOf("event_type" to JsonPrimitive("message.withdrawn"), "room_sequence" to JsonPrimitive(8), "message_revision" to JsonPrimitive(2))), "message")
        assertTrue(store.snapshot().messages.single().withdrawn); assertTrue(store.snapshot().pins.isEmpty())
        store.unavailable(room); assertTrue(store.snapshot().announcements.isEmpty())
        try { apply(store, 9, "late", announcement("late", 4)); fail("revoked metadata accepted") } catch (_: ClientFailure.Protocol) { }
        store.close()
    }
    @Test fun personalSnapshotRetainsMetadataOnlyForTheSameAuthorizedMembership() = runBlocking {
        val store = store(); store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(10).build())
        apply(store, 1, "announcement", announcement("retained", 1))
        fun items(revision: Int) = persistentListOf(SnapshotItem("room", "room:${room.value}", "snapshot", 1, ByteString.copyFromUtf8(buildJsonObject {
            put("event_type", "room.created"); put("room_id", room.value); put("membership_revision", revision); put("title", "group")
            put("viewer_membership_revision", revision); put("viewer_is_member", true); put("viewer_membership_source_event_id", "grant-$revision")
        }.toString())))
        val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(1).setNextSyncToken("token").build()
        store.validateSnapshot(items(1)); assertEquals("retained", store.snapshot().announcements.single().body)
        store.activateFixture(manifest, items(1)); assertEquals("retained", store.snapshot().announcements.single().body)
        store.reconcileDirectory(kotlinx.collections.immutable.persistentMapOf())
        assertTrue(store.snapshot().announcements.isEmpty()); assertTrue(room in store.snapshot().revokedRooms)
        store.activateFixture(manifest, items(2)); assertTrue(store.snapshot().announcements.isEmpty())
        store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(2).setHead(10).build())
        apply(store, 1, "new-announcement", announcement("new", 2))
        store.activateFixture(manifest, persistentListOf()); assertTrue(store.snapshot().announcements.isEmpty())
        store.close()
    }
}
