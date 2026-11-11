package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal fun forwardCommand() = ForwardCommand(actorId, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", (1..21).map {
    ForwardSource(personalRoom, MessageId("00000000-0000-0000-0000-%012d".format(it)), it.toLong())
}.toPersistentList(), persistentListOf(RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"), RoomId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")), 596000)
private class MemoryForwards : ForwardPlanStore {
    val works = mutableListOf<ForwardWork>()
    override suspend fun forwardWorks() = works.toPersistentList()
    override suspend fun enqueueForward(command: ForwardCommand) = ForwardWork(command).also(works::add)
    override suspend fun updateForward(expected: ForwardWork, updated: ForwardWork) {
        check(expected.command == updated.command); val index = works.indexOf(expected); check(index >= 0)
        if(expected.progress != null && updated.progress != null && !updated.progress.advances(expected.progress)) throw ClientFailure.Protocol()
        works[index] = updated
    }
}
class ForwardPlanTests {
    private val lines get() = javaClass.getResourceAsStream("/forward-plans-swift.txt")!!.bufferedReader().readLines()
    private fun json(index: Int) = Json.parseToJsonElement(lines[index]).jsonObject
    @Test fun `cancelled forwarding remains retry after serialization manual rounds and unresolved query`() = runTest {
        val diagnostics=NetworkDiagnostics()
        withContext(NetworkDiagnosticsScope(diagnostics)) {
        val command = forwardCommand(); val store = MemoryForwards(); store.works += ForwardWork(command); var now = 1000L
        val api = FakeEdge { _, _ -> assertCommandAttempt(false); throw CancellationException("fixture interruption") }
        fun service() = ForwardPlanService(actorId, ForwardPlanClient(api), store, {now})
        assertFailsWith<CancellationException> { service().flush() }
        assertEquals(0, store.works.single().attempts)
        val saved = Json.decodeFromString<ForwardWork>(Json.encodeToString(ForwardWork.serializer(), store.works.single()))
        assertTrue(saved.submissionStarted)
        store.works[0] = saved.copy(status = ForwardStatus.NeedsAttention); service().retry(command.operation)
        api.answer = { _, body ->
            assertCommandAttempt(true); assertEquals(command.recovery("query"), body)
            EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
        }
        service().flush(); assertFalse(store.works.single().reconcile); now = store.works.single().nextAttempt
        store.works[0] = store.works.single().copy(status = ForwardStatus.NeedsAttention); service().retry(command.operation)
        api.answer = { path, body ->
            assertCommandAttempt(true); assertTrue(path.endsWith("/submit")); assertEquals(command.payload(), body)
            EdgeResponse(200, directResult("processing", json(3)))
        }
        service().flush(); now = store.works.single().nextAttempt; service().cancel(command.operation)
        api.answer = { _, body ->
            assertCommandAttempt(true); assertEquals(command.recovery("cancelRemaining"), body)
            EdgeResponse(200, directResult("receipt", json(4)))
        }
        service().flush(); assertEquals(ForwardStatus.Committed, store.works.single().status)
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(4,samples.size);assertTrue(samples.all {it.kind==OperationKind.ForwardMessage})
        assertEquals(OperationStepMetric.Completion.Cancelled,samples.first().completion)
        assertEquals(OperationExecutionState.Processing,samples[2].observation?.execution)
        assertEquals(OperationWorkAction.Reconcile,samples.last().action)
        assertEquals(NetworkMetric.Certainty.ResponseReceived,samples.last().certainty)
    }

    @Test fun `Swift manifest fingerprint chunk UUIDs mixed result digest and recovery match exactly`() {
        val command = forwardCommand()
        assertEquals(lines[0], command.fingerprint); assertEquals(json(1), command.payload()); assertEquals(json(5), command.recovery("cancelRemaining"))
        val ids = Json.parseToJsonElement(lines[2]).jsonArray.map { it.jsonPrimitive.content }
        assertEquals(ids, (0 until command.childCount).map(command::childOperation))
        val progress = ForwardPlanClient.decodeProgress(command, json(3))
        val result = ForwardPlanClient.decodeResolved(command, json(4))
        assertTrue(result.progress.advances(progress)); assertEquals(ForwardStatus.Committed, result.status)
        assertEquals(21, result.progress.succeeded); assertEquals(20, result.progress.rejected); assertEquals(1, result.progress.cancelled(command))
        assertEquals(0, ForwardWork(command, progress = result.progress).unresolved)
    }
    @Test fun `manifest keeps user order rejects duplicates and covers fifty deterministic children`() {
        val command = forwardCommand()
        assertEquals(20, command.childSources(0).size); assertEquals(1, command.childSources(2).size)
        assertEquals(command.targets[1], command.childTarget(3))
        assertNotEquals(command.fingerprint, command.copy(sources = command.sources.reversed().toPersistentList()).fingerprint)
        assertFails { command.copy(sources = command.sources.add(command.sources.first())) }; assertFails { command.copy(targets = command.targets.add(command.targets.first())) }
        assertFails { command.copy(sources = persistentListOf()) }; assertFails { ForwardSource(personalRoom, personalMessage, 0) }
        val maximum = command.copy(sources = (1..100).map { ForwardSource(personalRoom, MessageId("00000000-0000-0000-0000-%012d".format(it)), 1) }.toPersistentList(),
            targets = (1..10).map { RoomId("20000000-0000-0000-0000-%012d".format(it)) }.toPersistentList())
        assertEquals(50, maximum.childCount); assertEquals(50, (0..49).map(maximum::childOperation).distinct().size)
        assertTrue(maximum.recovery("cancelRemaining").toString().toByteArray().size < 65536)
        assertFails { maximum.childOperation(50) }; assertFails { maximum.copy(targets = maximum.targets.add(personalRoom)) }
    }
    @Test fun `proof binds parent child ordinal source order target and aggregate digest`() {
        val command = forwardCommand(); val original = json(4).toString()
        assertFails { ForwardPlanClient.decodeResolved(command.copy(actor = targetId), json(4)) }
        val id = command.childOperation(0)
        listOf(id to command.childOperation(1), "\"succeededItemCount\":21" to "\"succeededItemCount\":22", "\"sourceRevisionConflict\"" to "\"unknown\"", "\"roomSequence\":1" to "\"roomSequence\":0").forEach { (old,new) ->
            assertNotEquals(original, original.replace(old,new)); assertFails { ForwardPlanClient.decodeResolved(command, Json.parseToJsonElement(original.replace(old,new)).jsonObject) }
        }
        val progress = json(4).objectValue("progress").toString()
        assertFails { ForwardPlanClient.decodeProgress(command, Json.parseToJsonElement(progress.replace("10000000-0000-0000-0000-000000000002", "10000000-0000-0000-0000-000000000001")).jsonObject) }
        assertFails { ForwardPlanClient.decodeProgress(command, Json.parseToJsonElement(progress.replace("\"roomSequence\":2", "\"roomSequence\":1")).jsonObject) }
    }
    @Test fun `resolved children cannot change and processing cannot become unstarted or cancelled`() {
        val command = forwardCommand(); val progress = ForwardPlanClient.decodeProgress(command, json(3))
        val result = ForwardPlanClient.decodeResolved(command, json(4)).progress
        assertFalse(progress.advances(result))
        assertFails { ForwardPlanClient.summary(command.copy(operation = "11111111-1111-1111-1111-111111111111"), result) }
        assertFails { ForwardPlanClient.summary(command, result.copy(children = persistentListOf())) }
        assertFalse(result.copy(children = result.children.set(0, result.children[0].copy(resolvedAt = 999))).advances(progress))
        assertFalse(progress.copy(children = progress.children.set(1, progress.children[1].copy(state = ForwardChildState.Cancelled))).advances(progress))
        assertFalse(progress.copy(execution = "waitingToStart").advances(progress))
        assertFalse(progress.copy(execution = "processing").advances(progress.copy(execution = "cancelling")))
    }
    @Test fun `lost submission recovers same frozen manifest and preserves verified partial progress across restart`() = runTest {
        val command = forwardCommand(); val store = MemoryForwards(); store.works += ForwardWork(command); var now = 1000L
        val api = FakeEdge { path, body -> assertCommandAttempt(false); assertTrue(path.endsWith("/submit")); assertEquals(command.payload(), body); assertTrue(store.works.single().submissionStarted); throw IOException("lost reply") }
        var service = ForwardPlanService(actorId, ForwardPlanClient(api), store, { now }); service.flush()
        now = 4000; api.answer = { path, body -> assertCommandAttempt(true); assertTrue(path.endsWith("/operations/recover")); assertEquals(command.recovery("query"), body); EdgeResponse(200, directResult("processing", json(3))) }
        service = ForwardPlanService(actorId, ForwardPlanClient(api), store, { now }); service.flush(); assertEquals(20, store.works.single().succeeded)
        now = 10000; api.answer = { _, body -> assertCommandAttempt(true); assertEquals(command.recovery("query"), body); EdgeResponse(200, directResult("receipt", json(4))) }
        service.flush(); assertEquals(ForwardStatus.Committed, store.works.single().status); assertEquals(command, store.works.single().command)
    }
    @Test fun `unresolved after admitted progress never resubmits plan and cancellation preserves retry floor`() = runTest {
        val command = forwardCommand(); val store = MemoryForwards(); val progress = ForwardPlanClient.decodeProgress(command, json(3))
        store.works += ForwardWork(command, progress = progress, submissionStarted = true, reconcile = true); var now = 1000L
        val api = FakeEdge { _, body -> assertEquals(command.recovery("query"), body); EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) }) }
        val service = ForwardPlanService(actorId, ForwardPlanClient(api), store, { now }); service.flush(); assertTrue(store.works.single().reconcile)
        service.cancel(command.operation); assertTrue(store.works.single().cancelRequested)
        assertEquals(6000, store.works.single().nextAttempt)
        api.answer = { _, _ -> error("before server floor") }; service.flush()
        now = 7000; api.answer = { _, body -> assertEquals(command.recovery("cancelRemaining"), body); EdgeResponse(200, directResult("receipt", json(4))) }; service.flush()
        assertEquals(ForwardStatus.Committed, store.works.single().status)
    }
    @Test fun `never submitted cancellation and expiry avoid network while uncertain expiry closes original plan`() = runTest {
        val command = forwardCommand(); val store = MemoryForwards(); store.works += ForwardWork(command)
        val api = FakeEdge { _, _ -> error("no request") }
        var service = ForwardPlanService(actorId, ForwardPlanClient(api), store, { 1000 }); service.cancel(command.operation); service.flush()
        assertEquals(42, store.works.single().cancelled); assertEquals(ForwardStatus.Cancelled, store.works.single().status)
        store.works.clear(); store.works += ForwardWork(command); service = ForwardPlanService(actorId, ForwardPlanClient(api), store, { 600000 }); service.flush()
        assertEquals(ForwardStatus.Expired, store.works.single().status)
        store.works[0] = ForwardWork(command, submissionStarted = true, reconcile = true)
        api.answer = { _, body -> assertEquals(command.recovery("closeIfUnstarted"), body); EdgeResponse(200, directResult("receipt", json(4))) }
        service.flush(); assertEquals(ForwardStatus.Committed, store.works.single().status)
    }
    @Test fun `bound backpressure honors header floor and unbound hint cannot schedule work`() = runTest {
        val command = forwardCommand()
        val hint = buildJsonObject { put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("reason", "rateLimited"); put("retryAfterMilliseconds", 5000) }
        val api = FakeEdge { _, _ -> EdgeResponse(429, directResult("deferred", hint), "90") }
        assertEquals(90000, (ForwardPlanClient(api).execute(command) as ForwardResult.Deferred).delay)
        api.answer = { _, _ -> EdgeResponse(503, directResult("deferred", JsonObject(hint + ("fingerprint" to fingerprintPayload("foreign")))) ) }
        assertFails { ForwardPlanClient(api).execute(command) }
    }
}
