package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class PolicyRecoveryUiTests {
    @get:Rule val compose = createComposeRule()
    private val room = RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    @Test fun cachedPoliciesRemainReadOnlyAndPausedRecoveryHasExplicitResume() {
        var retries = 0
        val state = GroupPolicyState(room,persistentListOf(LocalRolePolicy(room,MemberRole.Admin,persistentSetOf(GroupPermission.Mute),4),LocalRolePolicy(room,MemberRole.Member,persistentSetOf(),4)),PolicyRecoveryStatus.Paused)
        compose.setContent { MaterialTheme { PolicyRecoveryPanel(state,false) { retries++ } } }
        compose.onNodeWithText("管理员：管理成员禁言").assertIsDisplayed();compose.onNodeWithText("成员：无").assertIsDisplayed()
        compose.onNodeWithText("本机保存的权限仅供查看，操作前需要刷新。").assertIsDisplayed();compose.onNodeWithText("保存权限").assertDoesNotExist()
        compose.onNodeWithText("重新读取完整权限").performClick();compose.runOnIdle { assertEquals(1,retries) }
    }
    @Test fun recoveredNewerBaselineInvalidatesOldDirectoryEvenWithoutRoleEvents() {
        val actor = UserId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        val directory = MembersState(room,3,MemberRole.Admin,policies = GroupPolicies(room,2,3,5,persistentSetOf(GroupPermission.Remove),persistentSetOf()),stale = false)
        val cached = GroupPolicyState(room,persistentListOf(LocalRolePolicy(room,MemberRole.Admin,persistentSetOf(),4)),PolicyRecoveryStatus.Ready,membershipRevision = 5)
        val updated = directory.observeAccess(ClientSnapshot(groupPolicyStates = persistentListOf(cached)),actor)
        assertTrue(updated.stale);assertTrue(updated.policies!!.admin.isEmpty());assertEquals(2L,updated.policies!!.revision);assertFalse(updated.allows(GroupPermission.Remove))
        val denied = directory.observeAccess(ClientSnapshot(groupPolicyStates = persistentListOf(cached.copy(policies = persistentListOf(),status = PolicyRecoveryStatus.Unavailable))),actor)
        assertTrue(denied.stale);assertNull(denied.policies);assertNull(denied.actorRole);assertTrue(denied.items.isEmpty())
    }
}
