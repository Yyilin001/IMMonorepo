package com.xmtx.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

/** Historical room-log fact, never a substitute for current membership or send authorization. */
@Serializable data class MemberMuteFact(val source: String,val room: RoomId,val sequence: Long,val actor: UserId,val target: UserId,val until: Long,val created: Long) {
    init {
        listOf(source,room.value,actor.value,target.value).forEach { require(uuidId(it) == it) }
        require(sequence > 0 && created >= 0 && until > created)
    }
    companion object {
        fun decode(source: String,payload: JsonObject,room: RoomId,sequence: Long): MemberMuteFact {
            fun text(key: String) = payload[key]?.jsonPrimitive?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
            fun number(key: String) = payload[key]?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
            try {
                require(text("event_type") == "member.muted" && RoomId(text("room_id")) == room && number("room_sequence") == sequence)
                return MemberMuteFact(uuidId(source),room,sequence,UserId(text("actor_user_id")),UserId(text("target_user_id")),number("mute_until_ms"),number("server_created_at_ms"))
            } catch(_: IllegalArgumentException) { throw ClientFailure.Protocol() }
        }
    }
}
