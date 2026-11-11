package com.xmtx.im

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ResourceManagedQuotaUiTests {
    @get:Rule val compose=createComposeRule()
    private val snapshot=ResourceStorageSnapshot(ResourceOriginalPolicy(retainedWarningBytes=8192),4096,8192,0,0,4096,8192,0,0,1,12288)
    private suspend fun until(body:()->Boolean)=withTimeout(5000) {while(!body()) delay(10)}
    @Test fun nullableManagedPreferenceIsSerializedWithCacheActionsAndKeepsIndependentSettings()=runBlocking {
        var current=snapshot;var cacheWrites=0;val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>()
        val owner=ResourceStorageController(this,{current},{cacheWrites++;error("must be serialized")},{},writeManaged={value->
            entered.complete(Unit);finish.await();current=current.copy(policy=current.policy.copy(maximumManagedBytes=value));ResourceStoragePolicyResult(current,current.managedOverageBytes>0)
        })
        try {
            owner.foreground(true);until {!owner.state.working};owner.managedLimit(1);entered.await();owner.cacheLimit(1);assertEquals(0,cacheWrites)
            finish.complete(Unit);until {!owner.state.working};assertEquals(1L,owner.state.snapshot!!.policy.maximumManagedBytes)
            assertTrue(owner.state.feedback!!.contains("受保护"));assertEquals(snapshot.policy.maximumCacheBytes,owner.state.snapshot!!.policy.maximumCacheBytes)
            owner.managedLimit(null);until {!owner.state.working};assertNull(owner.state.snapshot!!.policy.maximumManagedBytes);assertEquals(8192L,owner.state.snapshot!!.policy.retainedWarningBytes)
        } finally {finish.complete(Unit);owner.close()}
    }
    @Test fun screenExposesSoftWarningManagedOverageAndAnExplicitUnlimitedChoice() {
        var selected:Long?=7;val limited=snapshot.copy(policy=snapshot.policy.copy(maximumManagedBytes=1024))
        compose.setContent {MaterialTheme {ResourceStorageScreen(ResourceStorageState(true,snapshot=limited),true,false,{},{},{},{},managedLimit={selected=it})}}
        compose.onNodeWithTag("storage-retained-warning").performScrollTo().assertTextContains("这仅为提醒",substring=true)
        compose.onNodeWithTag("storage-managed-overage").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("storage-managed-limit").performScrollTo().performClick();compose.onNodeWithTag("storage-managed-1024").performClick()
        compose.runOnIdle {assertEquals(1024L*1024*1024,selected)}
        compose.onNodeWithTag("storage-managed-limit").performScrollTo().performClick();compose.onNodeWithTag("storage-managed-unlimited").performClick();compose.runOnIdle {assertNull(selected)}
    }
}
