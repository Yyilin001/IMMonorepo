package com.xmtx.im.client

import kotlinx.serialization.json.*
import java.security.MessageDigest

/** Durable invalidation fact. It contains no media identity, URL or display permission. */
data class GroupAvatarEffect(val source: String,val room: RoomId,val revision: Long,val sequence: Long,val updatedAt: Long) {
    init { require(canonicalId(source)==source);uuidId(room.value);require(revision>0 && sequence>0 && updatedAt>=0) }
    val digest: String get() {
        // Swift's sorted-key canonical payload (source identity is compared independently).
        val payload=buildJsonObject { put("revision",revision);put("room",room.value);put("sequence",sequence);put("updatedAt",updatedAt);put("version",1) }
        return MessageDigest.getInstance("SHA-256").digest(payload.toString().toByteArray()).joinToString("") { "%02x".format(it) }
    }
    companion object {
        fun decode(source: String,value: JsonObject,expectedRoom: RoomId?=null,expectedSequence: Long?=null): GroupAvatarEffect {
            require(value.keys==setOf("event_type","room_id","revision","room_sequence","server_created_at_ms"))
            require(value.resourceString("event_type")=="group.avatar_changed")
            return GroupAvatarEffect(canonicalId(source),RoomId(value.resourceString("room_id")),value.resourceNumber("revision"),
                value.resourceNumber("room_sequence"),value.resourceNumber("server_created_at_ms")).also {
                require((expectedRoom==null || it.room==expectedRoom) && (expectedSequence==null || it.sequence==expectedSequence))
            }
        }
    }
}
/** Local membership/permission epoch plus the independent avatar revision floor. */
data class GroupAvatarFence(val generation: String,val revision: Long,val membershipRevision: Long,val authorized: Boolean) {
    init { require(revision>=0 && membershipRevision>=0) }
}
