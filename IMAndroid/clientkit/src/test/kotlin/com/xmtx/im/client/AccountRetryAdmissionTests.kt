package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*

@OptIn(ExperimentalCoroutinesApi::class)
class AccountRetryAdmissionTests {
    @Test fun refillIsImmutableBoundedAndDoesNotRewardClockRollback() {
        val empty=NetworkRetryBucket(0,0)
        assertEquals(empty,empty.refill(1999));assertEquals(NetworkRetryBucket(1,2000),empty.refill(2500))
        assertEquals(NetworkRetryBucket(5,200000),empty.refill(200001))
        val later=NetworkRetryBucket(0,5000);assertEquals(later,later.refill(4000));assertEquals(0,empty.tokens)
    }
    @Test fun retriesUseFifoRefillWithoutBlockingInitialRequestsOrOtherServices()=runTest {
        val gate=AccountRetryAdmission(monotonicMillis={testScheduler.currentTime})
        repeat(20) {gate.await("send",false)};repeat(5) {gate.await("send",true)}
        val order=mutableListOf<Pair<Int,Long>>()
        val jobs=(1..3).map {n->launch {gate.await("send",true);order+=n to testScheduler.currentTime}}
        runCurrent();assertTrue(order.isEmpty());gate.await("sync",true);gate.await("send",false)
        advanceTimeBy(1999);runCurrent();assertTrue(order.isEmpty())
        advanceTimeBy(1);runCurrent();assertEquals(listOf(1 to 2000L),order)
        advanceTimeBy(4000);runCurrent();jobs.joinAll()
        assertEquals(listOf(1 to 2000L,2 to 4000L,3 to 6000L),order)
    }
    @Test fun boundedWaitersCancelAndCloseWithoutLeakingQueueEntries()=runTest {
        val gate=AccountRetryAdmission(monotonicMillis={testScheduler.currentTime},maximumWaiters=1,maximumServices=2)
        repeat(5) {gate.await("send",true)}
        val first=launch {gate.await("send",true)};runCurrent()
        assertFailsWith<RetryAdmissionUnavailable> {gate.await("send",true)};first.cancelAndJoin()
        val second=async {runCatching {gate.await("send",true)}};runCurrent()
        gate.await("other",false);assertFailsWith<RetryAdmissionUnavailable> {gate.await("third",false)}
        gate.close();runCurrent();assertIs<RetryAdmissionUnavailable>(second.await().exceptionOrNull())
        assertFailsWith<RetryAdmissionUnavailable> {gate.await("send",false)}
        val fresh=AccountRetryAdmission(monotonicMillis={testScheduler.currentTime});repeat(5) {fresh.await("send",true)}
    }
    @Test fun cooldownCoversInitialRequestsAndCannotBeShortened()=runTest {
        val gate=AccountRetryAdmission(monotonicMillis={testScheduler.currentTime});gate.coolDown("send",7000)
        val first=async {gate.await("send",false);testScheduler.currentTime}
        val retry=async {gate.await("send",true);testScheduler.currentTime}
        runCurrent();gate.await("other",false)
        advanceTimeBy(4000);gate.coolDown("send",2000);gate.coolDown("send",5000)
        advanceTimeBy(4999);runCurrent();assertFalse(first.isCompleted);assertFalse(retry.isCompleted)
        advanceTimeBy(1);runCurrent();assertEquals(9000L,first.await());assertEquals(9000L,retry.await())
    }
    @Test fun ownTimeoutIsAdmissionFailureAndParentCancellationStillCancels()=runTest {
        val gate=AccountRetryAdmission(monotonicMillis={testScheduler.currentTime},maximumWaiters=1);gate.coolDown("send",60000)
        val timeout=async {runCatching {gate.await("send",false,100)}}
        advanceTimeBy(100);runCurrent();assertIs<RetryAdmissionUnavailable>(timeout.await().exceptionOrNull())
        val cancelled=launch {gate.await("send",false)};runCurrent();cancelled.cancelAndJoin()
        assertTrue(cancelled.isCancelled);gate.await("other",false)
    }
    @Test fun admissionTimeoutParksFrozenWorkWithoutTransportOrConnectionFailure()=runTest {
        val store=MemorySendStore();val command=MessageCommand.text(UserId("actor"),RoomId("room"),"original",100000);store.seed(command)
        val gate=AccountRetryAdmission(monotonicMillis={testScheduler.currentTime});gate.coolDown("durableOperations",60000)
        var calls=0
        val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {calls++;error("Unexpected network")}}
        MessageOutbox(transport,store,gate) {testScheduler.currentTime}.flush()
        assertEquals(15000L,testScheduler.currentTime);assertEquals(0,calls);assertEquals(listOf(command),store.commands)
        val state=store.recovery(command.clientMessageId)
        assertEquals(SendAction.Submit,state.action);assertEquals(SendRecoveryStatus.Confirming,state.status);assertTrue(state.nextAt>=17000)
    }
    @Test fun recreatedOutboxAndManualResumeShareTheSameRetryQuota()=runTest {
        val actor=UserId("actor");val store=MemorySendStore()
        val commands=(1..6).map {MessageCommand.text(actor,RoomId("room$it"),"body $it",100000)}
        commands.forEach {store.seed(it,SendRecovery.Legacy.copy(status=SendRecoveryStatus.NeedsAttention))}
        commands.forEach {store.resumeSend(RoomId(it.roomId),actor,it.clientMessageId,0)}
        val gate=AccountRetryAdmission(monotonicMillis={testScheduler.currentTime});val sent=mutableListOf<String>()
        val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder): Envelope {
            val request=body.build();assertTrue(request.hasMessageSendOperationRecover())
            val command=commands.single {it.clientMessageId==request.messageSendOperationRecover.identity.operationId};sent+=command.clientMessageId
            return Envelope.newBuilder().setMessageSendOperationResult(MessageSendOperationResult.newBuilder().setReceipt(
                MessageSendOperationReceipt.newBuilder().setIdentity(request.messageSendOperationRecover.identity).setFingerprint(request.messageSendOperationRecover.fingerprint)
                    .setResolvedAtMs(1).setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(command.clientMessageId).setRoomSequence(1)))).build()
        }}
        MessageOutbox(transport,store,gate) {testScheduler.currentTime}.flush();assertEquals(4,sent.size)
        val next=launch {MessageOutbox(transport,store,gate) {testScheduler.currentTime}.flush()}
        runCurrent();assertEquals(5,sent.size);advanceTimeBy(1999);runCurrent();assertEquals(5,sent.size)
        advanceTimeBy(1);runCurrent();next.join();assertEquals(6,sent.size);assertEquals(6,store.receipts.size);assertEquals(commands,store.commands)
    }
}
