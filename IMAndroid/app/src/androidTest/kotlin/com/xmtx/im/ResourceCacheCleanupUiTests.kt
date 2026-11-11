package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ResourceCacheCleanupUiTests {
    @get:Rule val compose=createComposeRule()
    private val snapshot=ResourceStorageSnapshot(ResourceOriginalPolicy(),4096,8192,4096,0,4096,8192,4096,0,1,16384)
    private val plan=ResourceCleanupPlan("preview",2,4096,1)
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun previewDoesNotDeleteAndRepeatedConfirmOnlyCommitsOnce()=runBlocking {
        var commits=0;val gate=CompletableDeferred<Unit>();val result=ResourceCleanupResult(1,2048,2,0)
        val owner=ResourceStorageController(this,{snapshot},{error("no quota change")},{},preview={plan},commit={commits++;gate.await();result})
        try {
            owner.foreground(true);until {!owner.state.working};owner.prepareCleanup();until {owner.state.cleanupPlan!=null}
            assertEquals(0,commits);owner.confirmCleanup();owner.confirmCleanup();until {commits==1};gate.complete(Unit);until {!owner.state.working}
            assertNull(owner.state.cleanupPlan);assertEquals(result,owner.state.cleanupResult);assertEquals(snapshot,owner.state.snapshot)
        } finally {gate.complete(Unit);owner.close()}
    }
    @Test fun dismissAndBackgroundDiscardPreviewWithoutCommittingOrResumingIt()=runBlocking {
        var commits=0;val owner=ResourceStorageController(this,{snapshot},{error("no quota change")},{},preview={plan},commit={commits++;error("must not commit")})
        try {
            owner.foreground(true);until {!owner.state.working};owner.prepareCleanup();until {owner.state.cleanupPlan!=null};owner.dismissCleanup();owner.confirmCleanup()
            assertNull(owner.state.cleanupPlan);owner.prepareCleanup();until {owner.state.cleanupPlan!=null};owner.foreground(false);owner.foreground(true);until {!owner.state.working}
            owner.confirmCleanup();assertNull(owner.state.cleanupPlan);assertEquals(0,commits)
        } finally {owner.close()}
    }
    @Test fun latePreviewAfterBackgroundCannotShowAnOldConfirmation()=runBlocking {
        val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
        val owner=ResourceStorageController(this,{snapshot},{error("no quota change")},{},preview={entered.complete(Unit);withContext(NonCancellable) {finish.await()};plan})
        try {
            owner.foreground(true);until {!owner.state.working};owner.prepareCleanup();entered.await();owner.foreground(false);finish.complete(Unit);delay(50)
            assertEquals(ResourceStorageState(),owner.state);owner.foreground(true);until {!owner.state.working};assertNull(owner.state.cleanupPlan)
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun expiredPreviewRequiresExplicitRefreshAndAnotherPreview()=runBlocking {
        var commits=0;val owner=ResourceStorageController(this,{snapshot},{error("no quota change")},{},preview={plan},commit={commits++;error("expired")})
        try {
            owner.foreground(true);until {!owner.state.working};owner.prepareCleanup();until {owner.state.cleanupPlan!=null};owner.confirmCleanup();until {!owner.state.working}
            assertNull(owner.state.cleanupPlan);assertNull(owner.state.snapshot);assertTrue(owner.state.feedback!!.contains("预览已失效"));owner.confirmCleanup();assertEquals(1,commits)
            owner.refresh();until {!owner.state.working};assertNull(owner.state.cleanupPlan);owner.prepareCleanup();until {owner.state.cleanupPlan!=null};assertEquals(1,commits)
        } finally {owner.close()}
    }
    @Test fun completedCleanupKeepsItsResultWhenTheFollowingUsageReadFails()=runBlocking {
        var reads=0;val result=ResourceCleanupResult(1,2048,1,1)
        val owner=ResourceStorageController(this,{if(++reads>1) error("unavailable");snapshot},{error("no quota change")},{},preview={plan},commit={result})
        try {
            owner.foreground(true);until {!owner.state.working};owner.prepareCleanup();until {owner.state.cleanupPlan!=null};owner.confirmCleanup();until {!owner.state.working}
            assertEquals(result,owner.state.cleanupResult);assertNull(owner.state.snapshot);assertTrue(owner.state.feedback!!.startsWith("清理已执行"))
        } finally {owner.close()}
    }
    @Test fun screenExplainsPreviewAndRequiresAnExplicitConfirmation() {
        val state=mutableStateOf(ResourceStorageState(true,snapshot=snapshot));var commits=0
        compose.setContent {MaterialTheme {ResourceStorageScreen(state.value,true,false,{},{},{},{},
            preview={state.value=state.value.copy(cleanupPlan=plan)},confirm={commits++;state.value=state.value.copy(cleanupPlan=null,cleanupResult=ResourceCleanupResult(1,2048,2,0))},dismiss={state.value=state.value.copy(cleanupPlan=null)})}}
        compose.onNodeWithTag("storage-cleanup-preview").performScrollTo().performClick();compose.onNodeWithText("清理本机缓存？").assertIsDisplayed()
        compose.onNodeWithText("预览有效期为 30 秒。",substring=true).assertIsDisplayed();compose.runOnIdle {assertEquals(0,commits)}
        compose.onNodeWithTag("storage-cleanup-dismiss").performClick();compose.runOnIdle {assertEquals(0,commits)}
        compose.onNodeWithTag("storage-cleanup-preview").performScrollTo().performClick();compose.onNodeWithTag("storage-cleanup-confirm").performClick()
        compose.onNodeWithTag("storage-cleanup-result").performScrollTo().assertTextContains("已清理 1 个文件",substring=true);compose.runOnIdle {assertEquals(1,commits)}
    }
}
