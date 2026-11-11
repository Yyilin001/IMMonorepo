package com.xmtx.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

/** Room-log effects retain semantic identity; JSON key order and unknown extension fields are immaterial. */
@Serializable sealed interface GroupMetadataEffect {
    val room: RoomId
    val source: String
    val sequence: Long
    val actor: UserId?
    val updatedAt: Long
    @Serializable data class Announcement(override val room: RoomId, override val source: String, override val sequence: Long,
        override val actor: UserId?, override val updatedAt: Long, val body: String, val revision: Long) : GroupMetadataEffect
    @Serializable data class Pin(override val room: RoomId, override val source: String, override val sequence: Long,
        override val actor: UserId?, override val updatedAt: Long, val message: MessageId, val pinned: Boolean) : GroupMetadataEffect
    companion object {
        fun decode(source: String, payload: JsonObject, expectedRoom: RoomId, expectedSequence: Long): GroupMetadataEffect {
            try {
                val room = RoomId(payload.strictText("room_id")); require(uuidId(room.value) == room.value && room == expectedRoom)
                val normalizedSource = canonicalId(source); require(expectedSequence > 0)
                val rawSequence = payload["room_sequence"]?.takeUnless { it is JsonNull }
                if(rawSequence != null) require(payload.strictLong("room_sequence") == expectedSequence)
                val rawActor = payload["actor_user_id"]?.takeUnless { it is JsonNull }
                val actor = if(rawActor != null) UserId(uuidId(payload.strictText("actor_user_id"))) else null
                val time = payload.strictLong("server_created_at_ms"); require(time >= 0)
                return when(payload.strictText("event_type")) {
                    "group.announcement_changed" -> {
                        val revision = payload.strictLong("revision"); val body = payload.strictText("body")
                        require(revision > 0 && body.toByteArray().size <= 4096)
                        Announcement(room, normalizedSource, expectedSequence, actor, time, body, revision)
                    }
                    "message.pinned_changed" -> {
                        val message = MessageId(uuidId(payload.strictText("message_id")))
                        val pinned = payload["is_pinned"]?.jsonPrimitive?.takeUnless { it.isString }?.booleanOrNull ?: throw ClientFailure.Protocol()
                        Pin(room, normalizedSource, expectedSequence, actor, time, message, pinned)
                    }
                    else -> throw ClientFailure.Protocol()
                }
            } catch(_: IllegalArgumentException) { throw ClientFailure.Protocol() }
        }
    }
}
private fun JsonObject.strictText(key: String) = get(key)?.jsonPrimitive?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
private fun JsonObject.strictLong(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()

data class GroupAnnouncement(val room: RoomId, val body: String, val revision: Long, val updatedAt: Long)
data class GroupPin(val room: RoomId, val message: MessageId, val sequence: Long)
