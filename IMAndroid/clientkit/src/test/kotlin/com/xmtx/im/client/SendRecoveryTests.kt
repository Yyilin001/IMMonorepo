package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*
import java.io.IOException

class SendRecoveryTests {
    private val command=MessageCommand.text(UserId("actor"),RoomId("room"),"original",100_000)
    private fun claim(action: SendAction=SendAction.Submit,state: SendRecovery=SendRecovery(submitted=true,submitAttempts=1,submitStarted=0))=SendAttempt(command,"token",action,state)
    private class Store(var attempt: SendAttempt?): SendRecoveryStore {
        var deferred: SendRecovery?=null;var receipt: MessageSendOperationReceipt?=null
        override suspend fun claimSend(now: Long)=attempt.also {attempt=null}
        override suspend fun deferSend(attempt: SendAttempt,state: SendRecovery) {deferred=state}
        override suspend fun completeSend(attempt: SendAttempt,receipt: MessageSendOperationReceipt) {this.receipt=receipt}
        override suspend fun resumeSend(room: RoomId,viewer: UserId,operation: String,now: Long) {}
        override suspend fun resumeNetworkWaitingSends(viewer: UserId,now: Long) {}
    }
    private fun transport(block: suspend (Envelope)->Envelope)=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder)=block(body.build())}
    private fun result(value: MessageSendOperationResult.Builder)=Envelope.newBuilder().setMessageSendOperationResult(value).build()
    private fun identity()=MessageSendOperationIdentity.newBuilder().setAccountId(command.senderUserId).setRoomId(command.roomId).setOperationId(command.clientMessageId)
    private fun fingerprint()=MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint)
    private fun accepted()=result(MessageSendOperationResult.newBuilder().setReceipt(MessageSendOperationReceipt.newBuilder()
        .setIdentity(identity()).setFingerprint(fingerprint()).setResolvedAtMs(1001)
        .setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId("accepted").setRoomSequence(1))))
    private fun javax.net.ssl.SSLSocket.reply(request:Envelope,response:Envelope) {
        outputStream.write(FrameCodec.encode(response.toBuilder().setRequestId(request.requestId).setProtocolVersion(FrameCodec.VERSION).build()))
        outputStream.flush()
    }
    private suspend fun waiting(scheduler:AccountWorkScheduler)=withTimeout(3000) {
        while(scheduler.snapshot().waiting!=1) delay(5)
    }
    @Test fun `scheduled sends charge one shared retry bucket and proven first sends bypass it`()=runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use {peer->
            val clock=java.util.concurrent.atomic.AtomicLong(0)
            val scheduler=AccountWorkScheduler(nowMillis=clock::get)
            // A closed legacy pool proves the scheduled path never consults a second admission owner.
            val legacy=AccountRetryAdmission().also {it.close()}
            val count=java.util.concurrent.atomic.AtomicInteger()
            val server=async(Dispatchers.IO) {peer.accept().use {socket->repeat(8) {
                val frame=FrameCodec.read(socket.inputStream);count.incrementAndGet()
                socket.reply(frame,if(frame.hasHeartbeat()) Envelope.newBuilder().setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000)).build() else accepted())
            }}}
            suspend fun send(retry:Boolean) {
                val store=Store(claim(if(retry) SendAction.Recover else SendAction.Submit,SendRecovery(submitted=true,submitAttempts=if(retry) 0 else 1,recoveryAttempts=if(retry) 1 else 0)).copy(isRetry=retry))
                val foreign=NetworkDiagnostics()
                withContext(NetworkDiagnosticsScope(foreign)) {SendRecoveryRunner(peer.connection,store,{1000},admission=legacy).flush()}
                assertEquals(0,foreign.snapshot().operationRecorded)
                assertNotNull(store.receipt)
                val diagnostic=scheduler.networkDiagnostics.snapshot().operations.last()
                assertEquals(OperationKind.SendMessage,diagnostic.kind)
                assertEquals(if(retry) NetworkWorkPriority.Recovery else NetworkWorkPriority.Interactive,diagnostic.priority)
                // This minimal fixture has no journal observation API; callback success is not proof.
                assertEquals(NetworkMetric.Certainty.OutcomeUnknown,diagnostic.certainty)
            }
            try {
                peer.connection.connect(peer.credentials,scheduler)
                repeat(5) {send(true)}
                val queued=async {send(true)};waiting(scheduler);assertEquals(5,count.get())
                send(false)
                assertTrue(peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance())).hasHeartbeatAck())
                assertEquals(7,count.get());assertFalse(queued.isCompleted)
                clock.set(2000);scheduler.setDegraded(false);queued.await();server.await()
                assertEquals(0,scheduler.snapshot().active)
            } finally {peer.connection.close();server.cancelAndJoin();scheduler.closeAndDrain()}
        }
    }
    @Test fun `deferred and gateway hints apply cooldown to ordinary realtime requests`()=runBlocking<Unit> {
        for(gateway in listOf(false,true)) RealtimeReceiveTests.Peer().use {peer->
            val clock=java.util.concurrent.atomic.AtomicLong(0);val scheduler=AccountWorkScheduler(nowMillis=clock::get)
            val server=async(Dispatchers.IO) {peer.accept().use {socket->
                val send=FrameCodec.read(socket.inputStream)
                val response=if(gateway) Envelope.newBuilder().setError(com.xmtx.imclientkit.generated.im.realtime.v2.Error.newBuilder()
                    .setCode("UNAVAILABLE").setRetryable(true).setRetryAfterSeconds(10)).build() else
                    result(MessageSendOperationResult.newBuilder().setDeferred(MessageSendOperationRetryHint.newBuilder()
                        .setIdentity(identity()).setFingerprint(fingerprint()).setReasonValue(1).setRetryAfterMs(10_000)))
                socket.reply(send,response)
                val control=FrameCodec.read(socket.inputStream);assertTrue(control.hasHeartbeat())
                socket.reply(control,Envelope.newBuilder().setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000)).build())
                val read=FrameCodec.read(socket.inputStream);assertTrue(read.hasSyncPull())
                socket.reply(read,Envelope.newBuilder().setSyncBatch(SyncBatch.getDefaultInstance()).build())
            }}
            try {
                peer.connection.connect(peer.credentials,scheduler)
                val store=Store(claim().copy(isRetry=false))
                val runner=SendRecoveryRunner(peer.connection,store,{1000},{0.0})
                if(gateway) assertFailsWith<GatewayFailure> {runner.flush()} else runner.flush()
                assertEquals(11_000,store.deferred!!.nextAt)
                val read=async {peer.connection.request(Envelope.newBuilder().setSyncPull(SyncPull.getDefaultInstance()))}
                waiting(scheduler);assertFalse(read.isCompleted)
                assertTrue(peer.connection.request(Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance())).hasHeartbeatAck())
                clock.set(10_000);scheduler.setDegraded(false);assertTrue(read.await().hasSyncBatch());server.await()
            } finally {peer.connection.close();server.cancelAndJoin();scheduler.closeAndDrain()}
        }
    }
    @Test fun lostResponseSwitchesToOriginalIdentityQueryAndCancellationAlsoPersistsRecovery()=runTest {
        val store=Store(claim())
        assertFailsWith<IOException> {SendRecoveryRunner(transport {assertEquals(command,it.messageSendOperation);throw IOException()},store,{1000},{0.0}).flush()}
        assertEquals(SendAction.Recover,store.deferred!!.action);assertEquals(SendRecoveryStatus.Confirming,store.deferred!!.status)
        store.attempt=claim(SendAction.Recover,store.deferred!!)
        SendRecoveryRunner(transport {
            val query=it.messageSendOperationRecover;assertEquals(MessageSendOperationRecover.Action.QUERY,query.action)
            assertEquals(command.clientMessageId,query.identity.operationId);assertEquals(command.fingerprint,query.fingerprint.digest);assertEquals(command.domainFingerprint,query.domainFingerprint.digest)
            result(MessageSendOperationResult.newBuilder().setReceipt(MessageSendOperationReceipt.newBuilder().setIdentity(identity()).setFingerprint(fingerprint()).setResolvedAtMs(1001)
                .setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId("accepted").setRoomSequence(1))))
        },store,{1000}).flush();assertTrue(store.receipt!!.hasAccepted())
        val cancelled=Store(claim())
        assertFailsWith<CancellationException> {SendRecoveryRunner(transport {throw CancellationException()},cancelled,{1000},{0.0}).flush()}
        assertEquals(SendAction.Recover,cancelled.deferred!!.action)
    }
    @Test fun deferredRetainsItsActionAndServerFloorEvenWhenBudgetIsExhausted()=runTest {
        val store=Store(claim())
        val response=result(MessageSendOperationResult.newBuilder().setDeferred(MessageSendOperationRetryHint.newBuilder().setIdentity(identity()).setFingerprint(fingerprint()).setReasonValue(1).setRetryAfterMs(90_000)))
        SendRecoveryRunner(transport {response},store,{1000},{0.0}).flush()
        assertEquals(SendAction.Submit,store.deferred!!.action);assertEquals(91_000,store.deferred!!.nextAt);assertEquals(SendRecoveryStatus.NeedsAttention,store.deferred!!.status)
        val next=Store(claim(SendAction.Recover,SendRecovery.Legacy.copy(recoveryAttempts=1,recoveryStarted=1000)))
        SendRecoveryRunner(transport {result(MessageSendOperationResult.newBuilder().setDeferred(MessageSendOperationRetryHint.newBuilder().setIdentity(identity()).setFingerprint(fingerprint()).setReasonValue(2).setRetryAfterMs(1000)))},next,{2000},{0.5}).flush()
        assertTrue(next.deferred!!.nextAt>3000);assertEquals(SendAction.Recover,next.deferred!!.action)
    }
    @Test fun unresolvedResubmitsOnlyBeforeDeadlineAndCloseRecoveryDoesNotInventFailureReceipt()=runTest {
        val first=Store(claim(SendAction.Recover,SendRecovery.Legacy))
        SendRecoveryRunner(transport {result(MessageSendOperationResult.newBuilder().setUnresolved(true))},first,{1000},{0.0}).flush()
        assertEquals(SendAction.Submit,first.deferred!!.action);assertNull(first.receipt)
        val expired=Store(claim(SendAction.Recover,SendRecovery.Legacy))
        SendRecoveryRunner(transport {assertEquals(MessageSendOperationRecover.Action.CLOSE_IF_ABSENT,it.messageSendOperationRecover.action);result(MessageSendOperationResult.newBuilder().setUnresolved(true))},expired,{100_001},{0.0}).flush()
        assertEquals(SendRecoveryStatus.NeedsAttention,expired.deferred!!.status);assertNull(expired.receipt)
    }
    @Test fun malformedResponseAndFingerprintConflictPauseWithoutCompletingIdentity()=runTest {
        for(response in listOf(result(MessageSendOperationResult.newBuilder().setUnresolved(false)),result(MessageSendOperationResult.newBuilder().setDeferred(MessageSendOperationRetryHint.newBuilder().setIdentity(identity()).setFingerprint(fingerprint()).setReasonValue(0))))) {
            val store=Store(claim());assertFailsWith<ClientFailure.Protocol> {SendRecoveryRunner(transport {response},store,{1000}).flush()}
            assertEquals(SendRecoveryStatus.NeedsAttention,store.deferred!!.status);assertNull(store.receipt)
        }
        val store=Store(claim());SendRecoveryRunner(transport {result(MessageSendOperationResult.newBuilder().setFingerprintConflict(true))},store,{1000}).flush()
        assertEquals(SendRecoveryStatus.NeedsAttention,store.deferred!!.status);assertNull(store.receipt)
    }
    @Test fun `send diagnostic follows persisted recovery and receipt rather than handler return`()=runTest {
        val store=MemorySendStore();store.seed(command);var now=1000L;var fail=true
        val diagnostics=NetworkDiagnostics()
        val runner=SendRecoveryRunner(transport {
            if(fail) throw IOException()
            accepted()
        },store,{now},{0.0})
        withContext(NetworkDiagnosticsScope(diagnostics)) {
            assertFailsWith<IOException> {runner.flush()}
            val pending=diagnostics.snapshot().operations.single()
            assertEquals(OperationWorkAction.Submit,pending.action);assertEquals(OperationStepMetric.Completion.Threw,pending.completion)
            assertEquals(OperationExecutionState.AwaitingConfirmation,pending.observation?.execution)
            fail=false;now=store.recovery(command.clientMessageId).nextAt;runner.flush()
        }
        val final=diagnostics.snapshot().operations.last()
        assertEquals(OperationWorkAction.Reconcile,final.action);assertEquals(OperationExecutionState.Committed,final.observation?.execution)
        assertEquals(NetworkMetric.Certainty.ResponseReceived,final.certainty)
        assertEquals(2,diagnostics.snapshot().operationRecorded)
    }

}
