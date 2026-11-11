package com.xmtx.im.client

import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal fun mutationCommand(text: String? = "  编辑🙂\n") = MessageMutationCommand(actorId, personalRoom, personalMessage, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", 4, text, 596000)
internal fun mutationReceipt(command: MessageMutationCommand, conflict: Boolean = false) = buildJsonObject {
    put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", 3000)
    put("outcome", if(conflict) buildJsonObject { put("rejected", buildJsonObject { put("_0", buildJsonObject { put("revisionConflict", buildJsonObject { put("current", command.revision + 1) }) }) }) }
    else buildJsonObject { put("committed", buildJsonObject { put("_0", buildJsonObject { put("messageID", wireId(command.message.value)); put("messageRevision", command.revision + 1); put("roomSequence", 6); put("eventID", wireId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")) }) }) })
}
private class MemoryMutations : MessageMutationStore {
    val works = mutableListOf<MessageMutationWork>()
    override suspend fun mutationWorks() = works.toPersistentList()
    override suspend fun enqueueMutation(command: MessageMutationCommand) = MessageMutationWork.fresh(command).also(works::add)
    override suspend fun updateMutation(expected: MessageMutationWork, updated: MessageMutationWork) { check(expected.command == updated.command); val index = works.indexOf(expected); check(index >= 0); works[index] = updated }
}
class MessageMutationTests {
    @Test fun `cancelled edits and withdrawals retain retry history across manual rounds and serialization`() = runTest {
        val diagnostics=NetworkDiagnostics()
        withContext(NetworkDiagnosticsScope(diagnostics)) {
        for(text in listOf("changed", null)) {
            val store = MemoryMutations(); var now = 1000L
            val api = FakeEdge { _, _ -> assertCommandAttempt(false); throw CancellationException("fixture interruption") }
            fun service() = MessageMutationService(actorId, MessageMutationClient(api), store, { now })
            val command = service().enqueue(personalRoom, personalMessage, 4, text).command
            assertFailsWith<CancellationException> { service().flush() }
            assertEquals(0, store.works.single().attempts)
            val saved = Json.decodeFromString<MessageMutationWork>(Json.encodeToString(MessageMutationWork.serializer(), store.works.single()))
            assertEquals(true, saved.executionStarted)
            store.works[0] = saved.copy(status = MutationStatus.NeedsAttention)
            val resumed = service(); resumed.retry(command.operation)
            api.answer = { path, body ->
                assertCommandAttempt(true); assertTrue(path.endsWith("/recover")); assertEquals(command.recovery(false), body)
                EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
            }
            resumed.flush(); assertFalse(store.works.single().reconcile)
            now = store.works.single().nextAttempt
            store.works[0] = store.works.single().copy(status = MutationStatus.NeedsAttention)
            resumed.retry(command.operation)
            api.answer = { path, body ->
                assertCommandAttempt(true); assertTrue(path.endsWith(if(text == null) "/withdraw" else "/edit"))
                assertEquals(command.payload(), body); EdgeResponse(200, directResult("receipt", mutationReceipt(command)))
            }
            resumed.flush(); assertEquals(MutationStatus.Committed, store.works.single().status)
            assertEquals(command, store.works.single().command)
        }
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(6,samples.size)
        assertEquals(setOf(OperationKind.EditMessage,OperationKind.WithdrawMessage),samples.map {it.kind}.toSet())
        assertEquals(2,samples.count {it.completion==OperationStepMetric.Completion.Cancelled})
        assertEquals(2,samples.count {it.observation?.execution==OperationExecutionState.Committed})
        assertTrue(samples.filter {it.action==OperationWorkAction.Reconcile}.all {it.priority==NetworkWorkPriority.Recovery})
    }

    @Test fun `legacy mutation with reset counters queries conservatively`() = runTest {
        val store = MemoryMutations(); val command = mutationCommand()
        val encoded = Json.encodeToString(MessageMutationWork.serializer(), MessageMutationWork(command))
        assertFalse(encoded.contains("executionStarted"))
        store.works += Json.decodeFromString<MessageMutationWork>(encoded)
        val api = FakeEdge { path, body ->
            assertCommandAttempt(true); assertTrue(path.endsWith("/recover")); assertEquals(command.recovery(false), body)
            EdgeResponse(200, directResult("receipt", mutationReceipt(command)))
        }
        MessageMutationService(actorId, MessageMutationClient(api), store, {1000}).flush()
        assertEquals(MutationStatus.Committed, store.works.single().status)
    }
    @Test fun `edit and withdrawal match actual Swift command fingerprints receipts and close recovery`() {
        val lines = javaClass.getResourceAsStream("/message-mutations-swift.txt")!!.bufferedReader().readLines()
        listOf(mutationCommand(), mutationCommand(null)).forEachIndexed { index, command ->
            assertEquals(lines[index * 4], command.fingerprint)
            assertEquals(Json.parseToJsonElement(lines[index * 4 + 1]), command.payload())
            assertEquals(Json.parseToJsonElement(lines[index * 4 + 3]), command.recovery(true))
            val receipt = MessageMutationClient.decodeReceipt(command, Json.parseToJsonElement(lines[index * 4 + 2]).jsonObject)
            assertEquals(MutationStatus.Committed, receipt.status); assertEquals(5, receipt.commit!!.revision); assertEquals(6, receipt.commit.roomSequence)
        }
    }
    @Test fun `raw edit text preserves whitespace and Unicode while enforcing byte and revision limits`() {
        assertEquals("   ", mutationCommand("   ").text)
        assertFails { mutationCommand("") }; assertFails { mutationCommand("🙂".repeat(16385)) }
        assertEquals(65536, mutationCommand("🙂".repeat(16384)).text!!.toByteArray().size)
        assertFails { mutationCommand().copy(revision = 0) }; assertFails { mutationCommand().copy(revision = Long.MAX_VALUE) }
        assertNotEquals(mutationCommand("é").fingerprint, mutationCommand("é").fingerprint)
    }
    @Test fun `commit is bound to exact actor message kind fingerprint and next revision`() {
        val command = mutationCommand(); val receipt = mutationReceipt(command)
        assertFails { MessageMutationClient.decodeReceipt(command.copy(actor = targetId), receipt) }
        assertFails { MessageMutationClient.decodeReceipt(command.copy(text = null), receipt) }
        assertFails { MessageMutationClient.decodeReceipt(command.copy(message = MessageId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")), receipt) }
        listOf("\"messageRevision\":5" to "\"messageRevision\":6", "\"roomSequence\":6" to "\"roomSequence\":0", "\"resolvedAtMilliseconds\":3000" to "\"resolvedAtMilliseconds\":\"3000\"").forEach { (old,new) ->
            assertFails { MessageMutationClient.decodeReceipt(command, Json.parseToJsonElement(receipt.toString().replace(old,new)).jsonObject) }
        }
    }
    @Test fun `bound deferred takes maximum server floor and unrelated responses cannot schedule mutation`() = runTest {
        val command = mutationCommand()
        val hint = buildJsonObject { put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("reason", "rateLimited"); put("retryAfterMilliseconds", 5000) }
        val api = FakeEdge { path, body -> assertTrue(path.endsWith("/message-mutations/edit")); assertEquals(command.payload(), body); EdgeResponse(429, directResult("deferred", hint), "90") }
        val client = MessageMutationClient(api)
        assertEquals(90000, (client.execute(command, false, false) as MutationResult.Deferred).delayMilliseconds)
        api.answer = { _, _ -> EdgeResponse(503, directResult("receipt", mutationReceipt(command)), "90") }; assertFails { client.execute(command, true, false) }
        api.answer = { _, _ -> EdgeResponse(503, directResult("deferred", JsonObject(hint + ("fingerprint" to fingerprintPayload("foreign")))), "90") }; assertFails { client.execute(command, true, false) }
    }
    @Test fun `restart after possible submission recovers same command and never projects receipt content`() = runTest {
        val store = MemoryMutations(); var now = 1000L
        val api = FakeEdge { path, body -> assertCommandAttempt(false); assertTrue(path.endsWith("/edit")); assertTrue(store.works.single().reconcile); assertEquals(store.works.single().command.payload(), body); throw IOException("reply lost") }
        var service = MessageMutationService(actorId, MessageMutationClient(api), store, { now })
        service.enqueue(personalRoom, personalMessage, 4, "changed"); val command = store.works.single().command
        assertEquals(596000, command.deadline); service.flush()
        now = 4000; api.answer = { path, body -> assertCommandAttempt(true); assertTrue(path.endsWith("/operations/recover")); assertEquals(command.recovery(false), body); EdgeResponse(200, directResult("receipt", mutationReceipt(command))) }
        service = MessageMutationService(actorId, MessageMutationClient(api), store, { now }); service.flush()
        assertEquals(MutationStatus.Committed, store.works.single().status); assertEquals(command, store.works.single().command)
    }
    @Test fun `conflict is terminal while expiry closes original identity without extending deadline`() = runTest {
        val store = MemoryMutations(); val command = mutationCommand(null); store.works.add(MessageMutationWork(command))
        val api = FakeEdge { _, body -> assertEquals(command.recovery(true), body); EdgeResponse(200, directResult("receipt", mutationReceipt(command, true))) }
        val service = MessageMutationService(actorId, MessageMutationClient(api), store, { 600000 })
        service.flush(); assertEquals(MutationStatus.Conflicted, store.works.single().status)
        api.answer = { _, _ -> error("terminal retry") }; service.flush()
    }
    @Test fun `unknown head blocks later commands for same message while another message proceeds`() = runTest {
        val store = MemoryMutations(); val command = mutationCommand()
        store.works += MessageMutationWork(command, MutationStatus.NeedsAttention)
        store.works += MessageMutationWork(command.copy(operation = "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE", text = null))
        val other = command.copy(operation = "11111111-1111-1111-1111-111111111111", message = MessageId("22222222-2222-2222-2222-222222222222"))
        store.works += MessageMutationWork.fresh(other)
        val api = FakeEdge { _, body -> assertEquals(other.payload(), body); EdgeResponse(200, directResult("receipt", mutationReceipt(other))) }
        MessageMutationService(actorId, MessageMutationClient(api), store, { 1000 }).flush()
        assertEquals(MutationStatus.Pending, store.works[1].status); assertEquals(MutationStatus.Committed, store.works[2].status)
    }
}
