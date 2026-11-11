package com.xmtx.im.client

import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.io.IOException

class ResourceDownloadPolicyTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val room=RoomId(id())
    private fun work(attempts:Int=1)=ResourceDownloadWork(id(),ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id()),1,"file.txt","text/plain",8,ResourceChecksum("a".repeat(64)),ResourceState.Ready),MediaMessageLocation(room,MessageId(id())),0,attempts=attempts)
    @Test fun automaticRetriesUseJitterWithoutResettingServerFloorAndWaitingWorkAges() {
        val automatic=work().copy(automatic=true)
        assertEquals(1750L,resourceDownloadFailure(IOException(),automatic,1000,{0.0}).retryAt)
        assertEquals(2250L,resourceDownloadFailure(IOException(),automatic,1000,{1.0}).retryAt)
        assertEquals(61000L,resourceDownloadFailure(IOException(),automatic.copy(serverRetryAt=61000),1000,{1.0}).retryAt)
        assertTrue(resourceDownloadSchedulingPriority(automatic,0)>resourceDownloadSchedulingPriority(work(),0))
        assertTrue(resourceDownloadSchedulingPriority(automatic,15_000_000_000L)<resourceDownloadSchedulingPriority(work(),0))
    }
    @Test fun networkPolicyRestrictionDoesNotSpendAutomaticRetriesOrLoseServerFloor() {
        val result=resourceDownloadFailure(ResourceDownloadPolicyRestricted(),work().copy(serverRetryAt=61000),1000)
        assertEquals(ResourceDownloadIssue.Policy,result.issue);assertNull(result.retryAt);assertEquals(61000L,result.serverRetryAt)
    }
    @Test fun serverFloorSurvivesBackoffAndExhaustedRounds() {
        val first=resourceDownloadFailure(MediaReadFailure(MediaReadFailureReason.Unavailable,429,"60"),work(),1000)
        assertEquals(61000L,first.serverRetryAt);assertEquals(62000L,first.retryAt)
        val last=resourceDownloadFailure(IOException(),work(5).copy(serverRetryAt=61000),2000)
        assertNull(last.retryAt);assertEquals(61000L,last.serverRetryAt)
    }
    @Test fun authorizationIntegrityAndStorageErrorsRequireExplicitAttention() {
        for(error in listOf(MediaReadFailure(MediaReadFailureReason.Denied),MediaReadFailure(MediaReadFailureReason.AuthorizationUnavailable),MediaFileFailure(MediaFileFailureReason.Integrity),IllegalStateException("space"))) {
            assertNull(resourceDownloadFailure(error,work(),1000).retryAt)
        }
        assertEquals(ResourceDownloadIssue.Unavailable,resourceDownloadFailure(ResourceCatalogConflict(),work(),1000).issue)
    }
    @Test fun expiredOrChangedReadEvidenceGetsFreshBoundedAuthorizationAttempts() {
        for(reason in listOf(MediaReadFailureReason.Expired,MediaReadFailureReason.SourceChanged)) {
            assertEquals(5000L,resourceDownloadFailure(MediaReadFailure(reason),work(3),1000).retryAt)
        }
        assertNull(resourceDownloadFailure(MediaReadFailure(MediaReadFailureReason.Expired),work(5),1000).retryAt)
    }
    @Test fun invalidRetryHintsAreConservativeAndCannotOverflowTime() {
        val bad=resourceDownloadFailure(MediaReadFailure(MediaReadFailureReason.Unavailable,503,"not-a-date"),work(),1000)
        assertEquals(86401000L,bad.serverRetryAt)
        val late=resourceDownloadFailure(IOException(),work().copy(serverRetryAt=Long.MAX_VALUE),Long.MAX_VALUE-10)
        assertEquals(Long.MAX_VALUE,late.retryAt)
    }
}
