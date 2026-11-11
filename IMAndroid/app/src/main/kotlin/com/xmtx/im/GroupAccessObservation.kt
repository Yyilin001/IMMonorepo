package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.toPersistentList
import kotlinx.collections.immutable.persistentListOf

/** Observations invalidate a baseline; they never manufacture authority from incomplete history. */
internal fun MembersState.observeAccess(snapshot: ClientSnapshot,actor: UserId): MembersState {
    val baselineRevision = revision ?: return this
    val members = snapshot.memberAccess.filter { it.room == room && it.revision > baselineRevision }
    val cached = snapshot.groupPolicyStates.firstOrNull { it.room == room }
    if(cached?.status == PolicyRecoveryStatus.Unavailable || room in snapshot.revokedRooms)
        return copy(items = persistentListOf(),actorRole = null,policies = null,stale = true,error = "群权限当前不可访问")
    val policies = buildMap<MemberRole,LocalRolePolicy> {
        snapshot.rolePolicies.filter { it.room == room && it.revision > (this@observeAccess.policies?.revision ?: 0) }.forEach {
            put(it.role,LocalRolePolicy(room,it.role,it.permissions,it.revision))
        }
        cached?.policies?.filter { it.revision > (this@observeAccess.policies?.revision ?: 0) }?.forEach { value ->
            if((get(value.role)?.revision ?: 0) <= value.revision) put(value.role,value)
        }
    }.values
    val invalid = cached?.status in setOf(PolicyRecoveryStatus.Unavailable,PolicyRecoveryStatus.WaitingForSync) || (cached?.membershipRevision ?: 0) > baselineRevision
    if(!invalid && members.isEmpty() && policies.isEmpty() && room !in snapshot.revokedRooms) return this
    val byUser = members.associateBy { it.user }
    val visible = items.mapNotNull { item -> when(val effect = byUser[item.user]) {
        null -> item
        else -> when(effect.action) { MemberEffectAction.Remove -> null;MemberEffectAction.Role -> item.copy(role = requireNotNull(effect.role));MemberEffectAction.Add -> null }
    } }.toPersistentList()
    var displayedPolicies = this.policies
    policies.forEach { effect -> displayedPolicies = displayedPolicies?.let { policy ->
        if(effect.role == MemberRole.Admin) policy.copy(admin = effect.permissions) else policy.copy(member = effect.permissions)
    } }
    val own = byUser[actor]
    val role = if(own == null) actorRole else own.role
    return copy(items = visible,actorRole = role,policies = displayedPolicies,stale = true)
}
