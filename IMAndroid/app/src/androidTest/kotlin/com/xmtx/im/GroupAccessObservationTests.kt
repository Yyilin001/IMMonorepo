package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Test

class GroupAccessObservationTests {
    private val room = RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val actor = UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB");private val target = UserId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private fun directory() = MembersState(room,4,MemberRole.Admin,persistentListOf(GroupMember(actor,MemberRole.Admin),GroupMember(target,MemberRole.Member)),
        policies = GroupPolicies(room,2,4,10,persistentSetOf(GroupPermission.Remove),persistentSetOf(GroupPermission.Send)),stale = false)
    @Test fun observedRoleAndEmptyPermissionsInvalidateAuthorityWhileKeepingBaselineVersions() {
        val snapshot = ClientSnapshot(memberAccess = persistentListOf(MemberAccessEffect("role",room,actor,5,MemberEffectAction.Role,MemberRole.Member,11,null,null)),
            rolePolicies = persistentListOf(RolePolicyEffect("policy",room,MemberRole.Member,3,persistentSetOf(),12,null,null)))
        val shown = directory().observeAccess(snapshot,actor)
        assertTrue(shown.stale);assertEquals(MemberRole.Member,shown.actorRole);assertTrue(shown.policies!!.member.isEmpty());assertFalse(shown.allows(GroupPermission.Remove))
        assertEquals(4L,shown.revision);assertEquals(2L,shown.policies!!.revision)
    }
    @Test fun olderEffectsCannotOverwriteFreshDirectoryAndUnknownRoleOnRejoinIsNotInvented() {
        val effect = MemberAccessEffect("remove",room,target,3,MemberEffectAction.Remove,null,11,null,null)
        assertEquals(directory(),directory().observeAccess(ClientSnapshot(memberAccess = persistentListOf(effect)),actor))
        val rejoin = effect.copy(source = "rejoin",revision = 5,action = MemberEffectAction.Add)
        val shown = directory().observeAccess(ClientSnapshot(memberAccess = persistentListOf(rejoin)),actor)
        assertTrue(shown.stale);assertFalse(shown.items.any { it.user == target });assertFalse(shown.allows(GroupPermission.Remove))
    }
    @Test fun incompletePolicyHistoryNeverGrantsAnUnobservedRoleAndRevocationInvalidatesAuthority() {
        val directory = directory().copy(policies = null)
        val effect = RolePolicyEffect("policy",room,MemberRole.Admin,3,persistentSetOf(GroupPermission.Remove),11,null,null)
        val shown = directory.observeAccess(ClientSnapshot(rolePolicies = persistentListOf(effect)),actor)
        assertNull(shown.policies);assertFalse(shown.allows(GroupPermission.Remove))
        assertTrue(directory().observeAccess(ClientSnapshot(revokedRooms = persistentSetOf(room)),actor).stale)
    }
}
