package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

/** An observed role policy is partial room history, not a complete current authorization baseline. */
@Serializable data class RolePolicyEffect(val source: String,val room: RoomId,val role: MemberRole,val revision: Long,
    @Serializable(with = ImmutablePermissions::class) val permissions: PersistentSet<GroupPermission>,val sequence: Long,val actor: UserId?,val created: Long?) {
    init { require(canonicalId(source) == source && uuidId(room.value) == room.value && role != MemberRole.Owner && revision > 0 && sequence > 0 && (created == null || created >= 0));actor?.let { require(uuidId(it.value) == it.value) } }
    companion object {
        fun decode(source: String,value: JsonObject,room: RoomId,sequence: Long): RolePolicyEffect = accessPayload {
            val header = accessHeader(value,room,sequence)
            require(value.accessText("event_type") == "group.role_permissions_changed")
            val permissions = value.getValue("permissions").jsonArray.map { raw ->
                val name = raw.jsonPrimitive.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
                GroupPermission.entries.firstOrNull { it.wire == name } ?: throw ClientFailure.Protocol()
            }
            require(permissions.distinct().size == permissions.size)
            RolePolicyEffect(canonicalId(source),room,accessRole(value.accessText("role")),value.accessNumber("revision"),permissions.toPersistentSet(),requireNotNull(header.sequence),header.actor,header.created)
        }
    }
}
@Serializable enum class MemberEffectAction { Add,Remove,Role }
/** Per-target history includes removals: absence of a visible role cannot erase its revision fence. */
@Serializable data class MemberAccessEffect(val source: String,val room: RoomId,val user: UserId,val revision: Long,val action: MemberEffectAction,
    val role: MemberRole?,val sequence: Long?,val actor: UserId?,val created: Long?) {
    init {
        require(canonicalId(source) == source && uuidId(room.value) == room.value && uuidId(user.value) == user.value && revision > 0 && (sequence == null || sequence > 0))
        require((action == MemberEffectAction.Role) == (role != null) && (created == null || created >= 0));actor?.let { require(uuidId(it.value) == it.value) }
    }
    fun sameMeaning(other: MemberAccessEffect) = copy(sequence = null) == other.copy(sequence = null)
    companion object {
        fun decode(source: String,kind: String,value: JsonObject,room: RoomId,sequence: Long? = null): PersistentList<MemberAccessEffect> = accessPayload {
            val header = accessHeader(value,room,sequence);val revision = value.accessNumber("membership_revision");val source = canonicalId(source)
            fun effect(user: UserId,action: MemberEffectAction,role: MemberRole? = null) = MemberAccessEffect(source,room,user,revision,action,role,header.sequence,header.actor,header.created)
            when(value.accessText("event_type")) {
                "group.member_role_changed" -> {
                    require(kind == "group_capability")
                    persistentListOf(effect(UserId(uuidId(value.accessText("target_user_id"))),MemberEffectAction.Role,accessRole(value.accessText("role"))))
                }
                "membership_changed" -> {
                    require(kind == "membership")
                    val action = when(value.accessText("action")) { "add" -> MemberEffectAction.Add;"remove" -> MemberEffectAction.Remove;else -> throw ClientFailure.Protocol() }
                    persistentListOf(effect(UserId(uuidId(value.accessText("target_user_id"))),action))
                }
                "group.ownership_transferred" -> {
                    require(kind == "membership" && value.accessText("action") == "transfer")
                    val old = UserId(uuidId(value.accessText("previous_owner_user_id")));val new = UserId(uuidId(value.accessText("owner_user_id")))
                    require(old != new && header.actor == old)
                    persistentListOf(effect(old,MemberEffectAction.Role,MemberRole.Member),effect(new,MemberEffectAction.Role,MemberRole.Owner))
                }
                else -> throw ClientFailure.Protocol()
            }
        }
    }
}
private data class AccessHeader(val sequence: Long?,val actor: UserId?,val created: Long?)
private fun accessHeader(value: JsonObject,expectedRoom: RoomId,expectedSequence: Long?): AccessHeader {
    require(RoomId(uuidId(value.accessText("room_id"))) == expectedRoom && (expectedSequence == null || expectedSequence > 0))
    val sequence = value.accessOptionalNumber("room_sequence");require(sequence == null || sequence > 0)
    require(expectedSequence == null || sequence == null || expectedSequence == sequence)
    val actor = value["actor_user_id"]?.takeUnless { it is JsonNull }?.let { UserId(uuidId(value.accessText("actor_user_id"))) }
    val created = value.accessOptionalNumber("server_created_at_ms");require(created == null || created >= 0)
    return AccessHeader(expectedSequence ?: sequence,actor,created)
}
private fun accessRole(value: String) = when(value) { "admin" -> MemberRole.Admin;"member" -> MemberRole.Member;else -> throw ClientFailure.Protocol() }
private fun JsonObject.accessText(key: String) = get(key)?.jsonPrimitive?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
private fun JsonObject.accessNumber(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
private fun JsonObject.accessOptionalNumber(key: String) = get(key)?.takeUnless { it is JsonNull }?.let { accessNumber(key) }
private inline fun <T> accessPayload(block: () -> T): T = try { block() } catch(_: IllegalArgumentException) { throw ClientFailure.Protocol() } catch(_: NoSuchElementException) { throw ClientFailure.Protocol() }
