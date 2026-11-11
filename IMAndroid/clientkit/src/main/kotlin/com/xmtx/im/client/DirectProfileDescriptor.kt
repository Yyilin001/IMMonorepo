package com.xmtx.im.client

import kotlinx.serialization.json.*
import java.security.MessageDigest
import java.text.Normalizer

/** Sync discovery selects a future authorized lookup; it never grants access to profile text. */
data class DirectProfileDescriptor(val room: RoomId,val peer: UserId,val revision: Long,val createdAt: Long,val contentDigest: String,val accountKind: AccountKind?=null) {
    init { uuidId(room.value);uuidId(peer.value);require(revision > 0 && createdAt >= 0 && contentDigest.matches(Regex("[a-f0-9]{64}"))) }
    companion object {
        fun decode(value: JsonObject): DirectProfileDescriptor {
            fun text(key: String) = (value[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
            fun number(key: String) = (value[key] as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
            val room = RoomId(uuidId(text("room_id")));val peer = UserId(uuidId(text("target_user_id")))
            val identity = PublicIdentity(peer,PublicHandle(text("public_handle")),Normalizer.normalize(text("display_name"),Normalizer.Form.NFC).trim { it.isWhitespace() },
                when(text("account_kind")) { "regular" -> AccountKind.Regular;"system" -> AccountKind.System;"customer_support" -> AccountKind.CustomerSupport;else -> throw ClientFailure.Protocol() })
            val revision = number("revision");val updated = number("updated_at_ms");val created = number("room_created_at_ms")
            require(revision > 0 && updated >= 0 && created >= 0)
            val canonical = buildJsonObject {
                put("room",room.value);put("peer",peer.value);put("revision",revision);put("created",created);put("updated",updated)
                put("handle",identity.handle.value);put("name",identity.displayName);put("kind",identity.kind.name)
            }.toString()
            return DirectProfileDescriptor(room,peer,revision,created,MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) },identity.kind)
        }
    }
}
