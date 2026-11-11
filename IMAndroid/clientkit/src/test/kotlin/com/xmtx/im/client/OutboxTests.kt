package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.*

class OutboxTests {
    private fun command(n: Int=1)=MessageCommand.text(UserId("user"),RoomId("room"),"text $n",100_000)
    private fun accepted(command: MessageSendOperation)=Envelope.newBuilder().setMessageSendOperationResult(MessageSendOperationResult.newBuilder()
        .setReceipt(MessageSendOperationReceipt.newBuilder().setIdentity(identity(command)).setFingerprint(fingerprint(command)).setResolvedAtMs(1)
            .setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(command.clientMessageId).setRoomSequence(1)))).build()
    private fun identity(command: MessageSendOperation)=MessageSendOperationIdentity.newBuilder().setAccountId(command.senderUserId).setRoomId(command.roomId).setOperationId(command.clientMessageId)
    private fun fingerprint(command: MessageSendOperation)=MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint)
    @Test fun `lost response queries original identity deadline and both fingerprints`() = runTest {
        val store=MemorySendStore();val requests=mutableListOf<Envelope>();var now=0L
        val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {requests+=body.build();throw IOException()}}
        val outbox=MessageOutbox(transport,store,AccountRetryAdmission(monotonicMillis={now})) {now}
        assertFailsWith<IOException> {outbox.send(UserId("user"),RoomId("room"),"exact text")}
        val original=store.commands.single();now=1000
        assertFailsWith<IOException> {outbox.flush()}
        assertEquals(original,requests.first().messageSendOperation)
        val recovery=requests.last().messageSendOperationRecover
        assertEquals(MessageSendOperationRecover.Action.QUERY,recovery.action)
        assertEquals(original.clientMessageId,recovery.identity.operationId);assertEquals(original.fingerprint,recovery.fingerprint.digest)
        assertEquals(original.domainFingerprint,recovery.domainFingerprint.digest);assertEquals(original,store.commands.single());assertTrue(store.receipts.isEmpty())
    }
    @Test fun `proven unsubmitted expiry stays local while legacy uncertainty closes original identity`() = runTest {
        val store=MemorySendStore();val fresh=MessageCommand.text(UserId("user"),RoomId("room"),"expired",1);store.seed(fresh)
        var calls=0
        val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
            calls++;val request=body.build().messageSendOperationRecover
            assertEquals(MessageSendOperationRecover.Action.CLOSE_IF_ABSENT,request.action)
            assertEquals(fresh.fingerprint,request.fingerprint.digest);throw IOException()
        }}
        MessageOutbox(transport,store) {2}.flush();assertEquals(0,calls)
        assertEquals(SendRecoveryStatus.ExpiredUnsubmitted,store.recovery(fresh.clientMessageId).status)
        val legacy=MemorySendStore().also {it.seed(fresh,SendRecovery.Legacy)}
        assertFailsWith<IOException> {MessageOutbox(transport,legacy) {2}.flush()};assertEquals(1,calls);assertEquals(fresh,legacy.commands.single())
    }
    @Test fun `mismatched receipt pauses without completing an outbox entry`() = runTest {
        val store=MemorySendStore();val command=command();store.seed(command)
        val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder)=accepted(command).toBuilder().setMessageSendOperationResult(
            MessageSendOperationResult.newBuilder().setReceipt(accepted(command).messageSendOperationResult.receipt.toBuilder().setIdentity(identity(command).setRoomId("wrong-room")))).build()}
        assertFailsWith<ClientFailure.Protocol> {MessageOutbox(transport,store) {0}.flush()}
        assertEquals(1,store.commands.size);assertTrue(store.receipts.isEmpty());assertEquals(SendRecoveryStatus.NeedsAttention,store.recovery(command.clientMessageId).status)
    }
    @Test fun `each flush has at most four network actions even with a large due queue`() = runTest {
        val store=MemorySendStore();repeat(9) {store.seed(command(it))};var calls=0
        val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {calls++;return accepted(body.build().messageSendOperation)}}
        val outbox=MessageOutbox(transport,store) {0}
        outbox.flush();assertEquals(4,calls);assertEquals(4,store.receipts.size)
        outbox.flush();assertEquals(8,calls);outbox.flush();assertEquals(9,calls);assertTrue(store.pending().isEmpty())
    }
    @Test fun `server cooldown is mandatory for every outbox adapter`() = runTest {
        val store=MemorySendStore();val command=command();store.seed(command);var now=0L;var calls=0
        val transport=object:EnvelopeTransport {override suspend fun request(body: Envelope.Builder):Envelope {
            calls++;assertEquals(command,body.build().messageSendOperation)
            return if(calls==1) Envelope.newBuilder().setMessageSendOperationResult(MessageSendOperationResult.newBuilder().setDeferred(
                MessageSendOperationRetryHint.newBuilder().setIdentity(identity(command)).setFingerprint(fingerprint(command)).setReasonValue(1).setRetryAfterMs(5000))).build() else accepted(command)
        }}
        val outbox=MessageOutbox(transport,store,AccountRetryAdmission(monotonicMillis={now})) {now};outbox.flush();assertEquals(1,calls)
        now=4999;outbox.flush();assertEquals(1,calls)
        now=store.recovery(command.clientMessageId).nextAt;outbox.flush();assertEquals(2,calls);assertEquals(1,store.receipts.size)
    }
}
