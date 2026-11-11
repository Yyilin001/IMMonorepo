package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

private class MemoryReads(var works: PersistentList<ReadWork>): ReadReceiptStore {
    var publication = true;var enqueued = 0
    override suspend fun enqueueRead(room: RoomId,sequence: Long): Boolean { enqueued++;return true }
    override suspend fun prepareReads(limit: Int) = Unit
    override suspend fun readWorks() = works
    override suspend fun updateRead(expected: ReadWork,updated: ReadWork) { val index = works.indexOf(expected);check(index >= 0);works = works.set(index,updated) }
    override suspend fun allowsReadPublication(room: RoomId) = publication
    override suspend fun archiveRead(operation: String,now: Long) = error("not used")
    override suspend fun restoreRead(operation: String,now: Long) = error("not used")
    override suspend fun admitReadResubmission(expected: ReadWork,updated: ReadWork) = updateRead(expected,updated)
}
private class ReadRemote: ReadReceiptTransport {
    val calls = mutableListOf<Pair<Boolean,ReadCommand>>()
    var answer: suspend (ReadCommand)->ReadResult = { throw IOException() }
    override suspend fun submit(command: ReadCommand): ReadResult.Confirmed { calls.add(false to command);return answer(command) as ReadResult.Confirmed }
    override suspend fun recover(command: ReadCommand): ReadResult { calls.add(true to command);return answer(command) }
}
class ReadReceiptTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val command = ReadCommand(actor,room,"10000000-0000-0000-0000-000000000001",7)
    private val lines get() = javaClass.getResourceAsStream("/read-receipts-swift.txt")!!.bufferedReader().readLines()
    private fun wire(i: Int) = Json.parseToJsonElement(lines[i]).jsonObject
    private fun confirmed() = ReadResult.Confirmed(ReadWatermark(room,actor,9,1700000000002),true)
    @Test fun `Swift command fingerprint recovery and both proof variants match`() = runTest {
        assertEquals(lines[0],command.fingerprint);assertEquals(wire(1),command.payload());assertEquals(wire(2),command.recovery())
        val tcp = object: EnvelopeTransport { override suspend fun request(body: Envelope.Builder): Envelope {
            assertEquals(7L,body.recordReadReceipt.readThroughRoomSequence);assertEquals(command.operation,body.recordReadReceipt.operationId)
            return Envelope.newBuilder().setReadReceiptRecorded(ReadReceiptRecorded.newBuilder().setRoomId(room.value).setUserId(actor.value).setReadThroughRoomSequence(9).setRecordedAtMs(1700000000002)).build()
        } }
        val edge = FakeEdge { path,body -> assertEquals("/v2/rooms/${room.value}/read-receipts/operations/recover",path);assertEquals(command.recovery(),body);EdgeResponse(200,wire(3)) }
        val client = ReadReceiptClient(tcp,edge);assertEquals(confirmed(),client.submit(command));assertEquals(confirmed(),client.recover(command))
        assertEquals(confirmed().copy(original = false),ReadReceiptClient.decode(command,wire(4)))
        assertEquals(ReadResult.Unresolved,ReadReceiptClient.decode(command,wire(5)));assertEquals(ReadResult.Conflict,ReadReceiptClient.decode(command,wire(6)))
        assertEquals(ReadResult.Unavailable("permissionDenied"),ReadReceiptClient.decode(command,wire(7)))
    }
    @Test fun `proofs bind original command identity user watermark and numeric types`() {
        for(i in 3..4) {
            val raw = wire(i).toString()
            assertFails { ReadReceiptClient.decode(command.copy(sequence = 6),wire(i)) }
            for(replacement in listOf("\"readThroughRoomSequence\":\"9\"","\"readThroughRoomSequence\":6","\"readThroughRoomSequence\":9223372036854775808"))
                assertFails { ReadReceiptClient.decode(command,Json.parseToJsonElement(raw.replace("\"readThroughRoomSequence\":9",replacement)).jsonObject) }
            assertFails { ReadReceiptClient.decode(command,Json.parseToJsonElement(raw.replace("\"version\":1","\"version\":\"1\"")).jsonObject) }
            assertFails { ReadReceiptClient.decode(command,Json.parseToJsonElement(raw.replace("\"userID\":{\"rawValue\":\"${actor.value}\"}","\"userID\":{\"rawValue\":\"${room.value}\"}")).jsonObject) }
        }
    }
    @Test fun `reader pages bind scope enforce opaque cursor and unique IDs`() = runTest {
        val message = MessageId(actor.value)
        var page = ReadReceiptReadersPage.newBuilder().setRoomId(room.value).setMessageId(message.value).addReaders(ReadReceiptReader.newBuilder().setUserId(actor.value)).setNextCursor("next")
        val tcp = object: EnvelopeTransport { override suspend fun request(body: Envelope.Builder) = Envelope.newBuilder().setReadReceiptReadersPage(page).build() }
        val client = ReadReceiptClient(tcp,FakeEdge { _,_->error("HTTP not used") })
        assertEquals(persistentListOf(actor),client.readers(room,message).readers)
        assertFails { client.readers(room,message,"next") }
        page.addReaders(ReadReceiptReader.newBuilder().setUserId(actor.value));assertFails { client.readers(room,message) }
        page.clearReaders();assertFails { client.readers(room,message) }
        assertFails { client.readers(room,message,limit = 0) };assertFails { client.readers(room,message,"x".repeat(513)) }
    }
    @Test fun `lost reply restarts with query then resubmits only the exact unresolved command`() = runTest {
        var now = 1000L;val store = MemoryReads(persistentListOf(ReadWork(command)));val remote = ReadRemote()
        ReadReceiptService(actor,remote,store,{now},{now}).flush();assertTrue(store.works.single().reconcile);assertTrue(store.works.single().submissionStarted)
        now += 1000;remote.answer = { ReadResult.Unresolved }
        val restarted = ReadReceiptService(actor,remote,store,{now},{now});restarted.flush();assertFalse(store.works.single().reconcile)
        now = store.works.single().nextAttempt;remote.answer = { confirmed() };restarted.flush()
        assertEquals(listOf(false,true,false),remote.calls.map { it.first });assertTrue(remote.calls.all { it.second == command });assertEquals(ReadStatus.Confirmed,store.works.single().status)
    }
    @Test fun `privacy blocks a fresh publication but permits recovery of uncertain work`() = runTest {
        val store = MemoryReads(persistentListOf(ReadWork(command)));store.publication = false;val remote = ReadRemote()
        val service = ReadReceiptService(actor,remote,store,{1000},{1000});service.flush();assertTrue(remote.calls.isEmpty());assertFalse(store.works.single().submissionStarted)
        assertEquals("privacyPaused",store.works.single().reason)
        store.works = persistentListOf(ReadWork(command,submissionStarted = true,reconcile = true));remote.answer = { confirmed().copy(original = false) }
        service.flush();assertEquals(true,remote.calls.single().first);assertEquals(false,store.works.single().originalReceipt)
    }
    @Test fun `retry floors bounded confirmation and cancellation preserve uncertainty`() = runTest {
        var now = 1000L;val store = MemoryReads(persistentListOf(ReadWork(command)));val remote = ReadRemote();remote.answer = { throw ReadBackpressure(90000) }
        val service = ReadReceiptService(actor,remote,store,{now},{now});service.flush();assertEquals(ReadStatus.NeedsAttention,store.works.single().status);assertEquals(91000L,store.works.single().nextAttempt)
        service.retry(command.operation);service.flush();assertEquals(1,remote.calls.size)
        now = 91000;remote.answer = { throw CancellationException() };assertFailsWith<CancellationException> { service.flush() }
        assertTrue(store.works.single().reconcile);assertEquals(1,store.works.single().attempts)
        now = 151001;service.flush();assertEquals(ReadStatus.NeedsAttention,store.works.single().status)
    }
    @Test fun `network work is bounded and reading can enqueue during a stalled transmission`() = runTest {
        val second = command.copy(room = RoomId(actor.value),operation = "10000000-0000-0000-0000-000000000002")
        val store = MemoryReads(persistentListOf(ReadWork(command),ReadWork(second)));val remote = ReadRemote()
        val entered = CompletableDeferred<Unit>();val release = CompletableDeferred<Unit>()
        remote.answer = { entered.complete(Unit);release.await();confirmed() }
        val service = ReadReceiptService(actor,remote,store,{1000},{1000},batchSize = 1)
        val running = launch { service.flush() };entered.await()
        withTimeout(1000) { assertTrue(service.enqueue(room,12)) };assertEquals(1,store.enqueued)
        release.complete(Unit);running.join();assertEquals(1,remote.calls.size);assertEquals(ReadStatus.Pending,store.works.last().status)
    }
    @Test fun `privacy tombstone revisions prevent old disclosure and reject crossed policy versions`() {
        val visible = DirectReadProjection(room,actor,8,100,true,2,3)
        val hidden = visible.copy(sequence = 0,visible = false,readerRevision = 3)
        assertEquals(hidden,visible.replacing(hidden));assertEquals(hidden,hidden.replacing(visible))
        assertFails { visible.copy(readerRevision = 4,viewerRevision = 2).replacing(hidden) }
        assertFails { hidden.copy(visible = true).replacing(hidden) }
        val restored = hidden.copy(visible = true,readerRevision = 4)
        assertEquals(restored,restored.replacing(hidden));assertEquals(restored.copy(sequence = 9),restored.copy(sequence = 9).replacing(restored))
    }
    @Test fun `read cancellation manual retry query and resubmit preserve admission facts and diagnostics`() = runTest {
        var now=1000L;val store=MemoryReads(persistentListOf(ReadWork(command)));val remote=ReadRemote()
        val diagnostics=NetworkDiagnostics();val service=ReadReceiptService(actor,remote,store,{now},{now})
        remote.answer={assertCommandAttempt(false);throw CancellationException()}
        withContext(NetworkDiagnosticsScope(diagnostics)) {
            assertFailsWith<CancellationException> {service.flush()}
            val saved=Json.decodeFromString<ReadWork>(Json.encodeToString(ReadWork.serializer(),store.works.single()))
            store.works=persistentListOf(saved.copy(status=ReadStatus.NeedsAttention));service.retry(command.operation)
            remote.answer={assertCommandAttempt(true);ReadResult.Unresolved};service.flush()
            now=store.works.single().nextAttempt
            remote.answer={assertCommandAttempt(true);confirmed()};service.flush()
        }
        assertEquals(listOf(false,true,false),remote.calls.map {it.first})
        assertTrue(remote.calls.all {it.second==command})
        val samples=diagnostics.snapshot().operations
        assertEquals(3,samples.size);assertTrue(samples.all {it.kind==OperationKind.ReadReceipt})
        assertEquals(OperationStepMetric.Completion.Cancelled,samples.first().completion)
        assertEquals(listOf(NetworkWorkPriority.Interactive,NetworkWorkPriority.Recovery,NetworkWorkPriority.Recovery),samples.map {it.priority})
        assertEquals(OperationExecutionState.Committed,samples.last().observation?.execution)
    }
    @Test fun `watermark proof satisfies read intent without claiming original request execution`() = runTest {
        val diagnostics=NetworkDiagnostics();val store=MemoryReads(persistentListOf(ReadWork(command,submissionStarted=true,reconcile=true)))
        val remote=ReadRemote();remote.answer={assertCommandAttempt(true);confirmed().copy(original=false)}
        withContext(NetworkDiagnosticsScope(diagnostics)) {ReadReceiptService(actor,remote,store,{1000},{1000}).flush()}
        assertEquals(false,store.works.single().originalReceipt)
        val sample=diagnostics.snapshot().operations.single()
        assertEquals(OperationExecutionState.Committed,sample.observation?.execution)
        assertEquals(NetworkMetric.Certainty.ResponseReceived,sample.certainty)
        val archived=ReadWork(command,ReadStatus.Archived,submissionStarted=true,reconcile=true,archivedAt=1000).operationObservation(2000)
        assertEquals(OperationSchedulingState.Suspended,archived.scheduling)
        assertEquals(OperationExecutionState.AwaitingConfirmation,archived.execution)
    }

}
