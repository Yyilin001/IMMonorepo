package com.xmtx.im.client

import kotlin.test.*

class SendRecoveryPolicyTests {
    @Test fun reservationRecordsUncertaintyBeforeTransportAndSeparatesProvenExpiryFromLegacyData() {
        val original=SendRecovery()
        val ready=assertIs<SendClaimDecision.Ready>(SendRecoveryPolicy.claim(original,1000,2000))
        assertEquals(SendAction.Submit,ready.action);assertTrue(ready.state.submitted);assertEquals(SendAction.Recover,ready.state.action)
        assertFalse(original.submitted);assertEquals(0,original.submitAttempts)
        val expired=assertIs<SendClaimDecision.Stop>(SendRecoveryPolicy.claim(original,2000,2000))
        assertEquals(SendRecoveryStatus.ExpiredUnsubmitted,expired.state.status)
        assertEquals(SendAction.Recover,assertIs<SendClaimDecision.Ready>(SendRecoveryPolicy.claim(SendRecovery.Legacy,2000,2000)).action)
    }
    @Test fun exhaustedSubmissionCannotSuppressTheFirstOriginalIdentityRecoveryRound() {
        val exhausted=SendRecovery(submitted=true,submitAttempts=5,submitStarted=0)
        assertEquals(SendRecoveryStatus.NeedsAttention,assertIs<SendClaimDecision.Stop>(SendRecoveryPolicy.claim(exhausted,61000,100000)).state.status)
        val recover=assertIs<SendClaimDecision.Ready>(SendRecoveryPolicy.claim(exhausted.copy(action=SendAction.Recover),61000,100000))
        assertEquals(1,recover.state.recoveryAttempts);assertEquals(61000,recover.state.recoveryStarted)
        assertIs<SendClaimDecision.Stop>(SendRecoveryPolicy.claim(recover.state.copy(recoveryAttempts=5),62000,100000))
        assertIs<SendClaimDecision.Stop>(SendRecoveryPolicy.claim(recover.state,121000,200000))
    }
    @Test fun explicitContinuationPreservesCooldownAndCannotReviveKnownUnsubmittedExpiry() {
        val paused=SendRecovery.Legacy.copy(status=SendRecoveryStatus.NeedsAttention,recoveryAttempts=5,nextAt=50000)
        assertEquals(SendClaimDecision.Wait,SendRecoveryPolicy.claim(paused,1000,100000))
        val resumed=SendRecoveryPolicy.resume(paused,2000)
        assertEquals(50000,resumed.nextAt);assertEquals(0,resumed.recoveryAttempts);assertEquals(SendAction.Recover,resumed.action)
        assertEquals(SendClaimDecision.Wait,SendRecoveryPolicy.claim(resumed,49999,100000))
        assertIs<SendClaimDecision.Ready>(SendRecoveryPolicy.claim(resumed,50000,100000))
        val expired=SendRecovery(status=SendRecoveryStatus.ExpiredUnsubmitted)
        assertEquals(expired,SendRecoveryPolicy.resume(expired,1000))
    }
}
