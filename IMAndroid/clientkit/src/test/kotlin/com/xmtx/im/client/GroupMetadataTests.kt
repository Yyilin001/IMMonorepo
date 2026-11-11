package com.xmtx.im.client

import kotlinx.serialization.json.*
import kotlin.test.*

class GroupMetadataTests {
    private val room = RoomId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val message = "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    private fun announcement(body: String = "公告", revision: Long = 1) = buildJsonObject {
        put("event_type", "group.announcement_changed"); put("room_id", room.value); put("body", body); put("revision", revision); put("server_created_at_ms", 0)
    }
    private fun pin(pinned: Boolean = true) = buildJsonObject {
        put("event_type", "message.pinned_changed"); put("room_id", room.value); put("message_id", message); put("is_pinned", pinned); put("server_created_at_ms", 1000)
    }
    @Test fun `outer room log position binds metadata with optional repeated position`() {
        val decoded = GroupMetadataEffect.decode("event", announcement(), room, 5) as GroupMetadataEffect.Announcement
        assertEquals(5, decoded.sequence); assertEquals(1, decoded.revision); assertEquals("公告", decoded.body)
        assertEquals(decoded, GroupMetadataEffect.decode("event", JsonObject(announcement() + ("room_sequence" to JsonPrimitive(5))), room, 5))
        assertFails { GroupMetadataEffect.decode("event", JsonObject(announcement() + ("room_sequence" to JsonPrimitive(4))), room, 5) }
        assertFails { GroupMetadataEffect.decode("event", announcement(), RoomId(message), 5) }
        assertFails { GroupMetadataEffect.decode("event", announcement(), room, 0) }
    }
    @Test fun `semantic identity ignores unknown fields and normalizes actor and room identifiers`() {
        val wire = JsonObject(pin() + mapOf("room_id" to JsonPrimitive(room.value.lowercase()), "actor_user_id" to JsonPrimitive(actorId.value.lowercase()), "extension" to JsonPrimitive(1)))
        val actual = GroupMetadataEffect.decode("event", wire, room, 2) as GroupMetadataEffect.Pin
        assertEquals(actorId, actual.actor); assertEquals(room, actual.room); assertEquals(MessageId(message), actual.message)
        assertEquals(actual, GroupMetadataEffect.decode("event", JsonObject(wire - "extension"), room, 2))
    }
    @Test fun `cleared announcements retain their positive revision and strict type limits`() {
        assertEquals("", (GroupMetadataEffect.decode("event", announcement(""), room, 1) as GroupMetadataEffect.Announcement).body)
        assertFails { GroupMetadataEffect.decode("event", announcement(revision = 0), room, 1) }
        assertFails { GroupMetadataEffect.decode("event", announcement("猫".repeat(1366)), room, 1) }
        assertFails { GroupMetadataEffect.decode("event", JsonObject(announcement() + ("body" to JsonNull)), room, 1) }
        assertFails { GroupMetadataEffect.decode("event", JsonObject(announcement() + ("revision" to JsonPrimitive("1"))), room, 1) }
        assertFails { GroupMetadataEffect.decode("event", JsonObject(announcement() + ("server_created_at_ms" to JsonPrimitive(-1))), room, 1) }
    }
    @Test fun `pin effects require boolean values UUID messages and valid optional actors`() {
        assertFalse((GroupMetadataEffect.decode("event", pin(false), room, 2) as GroupMetadataEffect.Pin).pinned)
        assertFails { GroupMetadataEffect.decode("event", JsonObject(pin() + ("is_pinned" to JsonPrimitive("true"))), room, 2) }
        assertFails { GroupMetadataEffect.decode("event", JsonObject(pin() + ("message_id" to JsonPrimitive("message"))), room, 2) }
        assertFails { GroupMetadataEffect.decode("event", JsonObject(pin() + ("actor_user_id" to JsonPrimitive("actor"))), room, 2) }
    }
}
