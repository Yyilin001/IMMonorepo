package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

class SendConnectionWaitingTests {
    private val actor=UserId("actor");private val room=RoomId("room")
    private val command=MessageCommand.text(actor,room,"frozen",100000)
    @Test fun capacityWaitReschedulesWithoutRequiringANewConnection()=runTest {
        for(reason in listOf(AccountWorkScheduler.Rejection.Overloaded,AccountWorkScheduler.Rejection.DeadlineExceeded)) {
            val store=MemorySendStore();store.seed(command)
            val transport=object:EnvelopeTransport {override suspend fun request(body:Envelope.Builder):Envelope {throw RealtimeUnavailableBeforeAdmission(reason)}}
            SendRecoveryRunner(transport,store,{1000},{0.0}).flush()
            val deferred=store.recovery(command.clientMessageId)
            assertEquals(SendRecoveryStatus.Confirming,deferred.status);assertEquals(SendAction.Submit,deferred.action)
            assertEquals(3000,deferred.nextAt);assertNull(store.claimSend(2999))
            assertNotNull(store.claimSend(3000))
        }
    }
    @Test fun disconnectedTransportParksWithoutAutomaticOrManualPollingAndConnectionResumesOriginalAction()=runTest {
        val store=MemorySendStore();store.seed(command);var now=1000L
        val socket=RealtimeConnection("localhost",1)
        val outbox=MessageOutbox(socket,store) {now}
        assertFailsWith<RealtimeUnavailableBeforeAdmission> {outbox.flush()}
        val parked=store.recovery(command.clientMessageId)
        assertEquals(SendRecoveryStatus.WaitingForNetwork,parked.status);assertEquals(SendAction.Submit,parked.action)
        now=200000;outbox.flush();store.resumeSend(room,actor,command.clientMessageId,now)
        assertEquals(parked,store.recovery(command.clientMessageId));assertFailsWith<IllegalArgumentException> {store.resumeNetworkWaitingSends(UserId("other"),now)}
        store.resumeNetworkWaitingSends(actor,now)
        val resumed=store.claimSend(now)!!
        assertEquals(command,resumed.command);assertEquals(SendAction.Recover,resumed.action);assertTrue(resumed.isRetry)
        // The deadline elapsed while waiting; the first following request must close/query this identity.
        socket.close()
    }
    @Test fun unavailableDuringOriginalIdentityRecoveryPreservesRecoveryAction()=runTest {
        val store=MemorySendStore();store.seed(command,SendRecovery.Legacy)
        val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {assertTrue(body.hasMessageSendOperationRecover());throw RealtimeUnavailableBeforeAdmission()}}
        assertFailsWith<RealtimeUnavailableBeforeAdmission> {MessageOutbox(transport,store) {1000}.flush()}
        assertEquals(SendAction.Recover,store.recovery(command.clientMessageId).action)
        store.resumeNetworkWaitingSends(actor,2000);val resumed=store.claimSend(2000)!!
        assertEquals(SendAction.Recover,resumed.action);assertEquals(command,resumed.command)
    }
    @Test fun onlyExplicitAuthenticationFailureParksAndOtherFailuresStayUnknown()=runTest {
        for(error in listOf(GatewayFailure("UNAUTHENTICATED",false,0),GatewayFailure("UNAUTHENTICATED",true,0),GatewayFailure("UNAUTHENTICATED",false,5),
            GatewayFailure("UNAVAILABLE",false,0),IOException("after write"),RetryAdmissionUnavailable("transport failed"))) {
            val store=MemorySendStore();store.seed(command)
            val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {throw error}}
            assertSame(error,runCatching {MessageOutbox(transport,store) {1000}.flush()}.exceptionOrNull())
            val parked=store.recovery(command.clientMessageId)
            val auth=error is GatewayFailure && error.code=="UNAUTHENTICATED" && !error.retryable && error.retryAfterSeconds==0
            assertEquals(if(auth) SendRecoveryStatus.WaitingForAuthentication else SendRecoveryStatus.Confirming,parked.status)
            assertEquals(if(auth) SendAction.Submit else SendAction.Recover,parked.action)
        }
    }
    @Test fun authenticatedWakeResetsOnlyConnectionWaitRoundsAndPreservesCooldownAndUncertainty() {
        for(action in SendAction.entries) for(status in listOf(SendRecoveryStatus.WaitingForNetwork,SendRecoveryStatus.WaitingForAuthentication)) {
            val original=SendRecovery(action,true,status,5,5,1,2,90000)
            val resumed=SendRecoveryPolicy.connected(original,1000)
            assertEquals(action,resumed.action);assertTrue(resumed.submitted);assertEquals(90000,resumed.nextAt)
            assertEquals(0,resumed.submitAttempts);assertEquals(0,resumed.recoveryAttempts);assertNull(resumed.submitStarted);assertNull(resumed.recoveryStarted)
            assertEquals(SendClaimDecision.Wait,SendRecoveryPolicy.claim(original,100000,200000))
            assertEquals(5,original.submitAttempts)
        }
        for(status in listOf(SendRecoveryStatus.NeedsAttention,SendRecoveryStatus.ExpiredUnsubmitted,SendRecoveryStatus.Queued,SendRecoveryStatus.Confirming)) {
            val old=SendRecovery.Legacy.copy(status=status,nextAt=90000,recoveryAttempts=5)
            assertEquals(old,SendRecoveryPolicy.connected(old,100000))
        }
    }
}
