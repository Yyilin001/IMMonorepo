package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import com.xmtx.imclientkit.generated.im.realtime.v2.ListRoomMembers
import com.xmtx.imclientkit.generated.im.realtime.v2.GetGroupRolePolicyBaseline
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.PersistentSet
import kotlinx.collections.immutable.toPersistentList
import kotlinx.collections.immutable.toPersistentSet

@kotlinx.serialization.Serializable enum class MemberRole { Owner, Admin, Member }
data class GroupMember(val user: UserId, val role: MemberRole)
data class MemberPage(val room: RoomId, val revision: Long, val actorRole: MemberRole,
    val members: PersistentList<GroupMember>, val nextCursor: String?)
@kotlinx.serialization.Serializable enum class GroupPermission(val wire: String) {
    Send("send_messages"), Invite("invite_members"), Remove("remove_members"), ChangeRoles("change_member_roles"),
    Pin("pin_messages"), Announce("manage_announcements"), Moderate("moderate_messages"), Mute("mute_members")
}
@kotlinx.serialization.Serializable data class GroupPolicies(val room: RoomId, val revision: Long, val membershipRevision: Long, val roomSequence: Long,
    @kotlinx.serialization.Serializable(with = ImmutablePermissions::class) val admin: PersistentSet<GroupPermission>,
    @kotlinx.serialization.Serializable(with = ImmutablePermissions::class) val member: PersistentSet<GroupPermission>) {
    init { require(revision > 0 && membershipRevision >= 0 && roomSequence >= 0) }
    fun allows(role: MemberRole, permission: GroupPermission) = when(role) { MemberRole.Owner -> true; MemberRole.Admin -> permission in admin; MemberRole.Member -> permission in member }
}
class MemberDirectory(private val transport: EnvelopeTransport) {
    suspend fun policies(room: RoomId): GroupPolicies {
        uuidId(room.value)
        val result = transport.request(Envelope.newBuilder().setGetGroupRolePolicyBaseline(GetGroupRolePolicyBaseline.newBuilder().setRoomId(room.value)))
        if (!result.hasGroupRolePolicyBaseline()) throw ClientFailure.Protocol()
        val baseline = result.groupRolePolicyBaseline
        if (RoomId(baseline.roomId) != room || baseline.permissionRevision <= 0 || baseline.membershipRevision < 0 || baseline.roomSequence < 0 ||
            baseline.policiesCount != 2 || baseline.policiesList.map { it.role }.toSet() != setOf("admin", "member")) throw ClientFailure.Protocol()
        val policies = baseline.policiesList.associate { policy ->
            val permissions = policy.permissionsList.map { value -> GroupPermission.entries.firstOrNull { it.wire == value.permission } ?: throw ClientFailure.Protocol() }
            if (permissions.distinct().size != permissions.size) throw ClientFailure.Protocol()
            policy.role to permissions.toPersistentSet()
        }
        return GroupPolicies(room, baseline.permissionRevision, baseline.membershipRevision, baseline.roomSequence, policies.getValue("admin"), policies.getValue("member"))
    }
    suspend fun page(room: RoomId, cursor: String? = null, limit: Int = 100): MemberPage {
        require(limit in 1..100 && (cursor == null || cursor.isNotEmpty() && cursor.toByteArray().size <= 512))
        val result = transport.request(Envelope.newBuilder().setListRoomMembers(ListRoomMembers.newBuilder()
            .setRoomId(room.value).setCursor(cursor.orEmpty()).setPageSize(limit)))
        if (!result.hasRoomMembersPage()) throw ClientFailure.Protocol()
        val page = result.roomMembersPage
        if (RoomId(page.roomId) != room || page.membershipRevision < 0 || page.membersCount > limit || page.nextCursor.toByteArray().size > 512) throw ClientFailure.Protocol()
        val members = page.membersList.map { GroupMember(UserId(it.userId), role(it.roleValue)) }.toPersistentList()
        if (members.map { it.user }.distinct().size != members.size || page.nextCursor.isNotEmpty() && (page.nextCursor == cursor || members.isEmpty())) throw ClientFailure.Protocol()
        return MemberPage(room, page.membershipRevision, role(page.actorRoleValue), members, page.nextCursor.takeIf { it.isNotEmpty() })
    }
    private fun role(value: Int) = when(value) { 1 -> MemberRole.Owner; 2 -> MemberRole.Admin; 3 -> MemberRole.Member; else -> throw ClientFailure.Protocol() }
}
