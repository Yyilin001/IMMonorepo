package com.xmtx.im.client

import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal class MemorySocial : SocialStore {
    val proposals = mutableListOf<SocialProposal>(); val works = mutableListOf<SocialWork>()
    override suspend fun socialProposals() = proposals.toPersistentList()
    override suspend fun socialWorks() = works.toPersistentList()
    override suspend fun saveSocialProposal(proposal: SocialProposal): SocialProposal {
        check(works.none { !it.terminal && it.command.target == proposal.target && it.command.action.kind == proposal.action.kind })
        return proposals.firstOrNull { it.target == proposal.target && it.action == proposal.action } ?: proposal.also { proposals.add(it) }
    }
    override suspend fun discardSocialProposal(id: String) { proposals.removeAll { it.id == id } }
    override suspend fun confirmSocial(proposal: SocialProposal, command: SocialCommand): SocialWork {
        check(proposals.remove(proposal)); return SocialWork.fresh(command).also { works.add(it) }
    }
    override suspend fun updateSocial(expected: SocialWork, updated: SocialWork) { val index = works.indexOf(expected); check(index >= 0); works[index] = updated }
}
internal fun socialBaseline(actor: UserId = actorId, target: UserId = targetId, revision: Long = 0) = buildJsonObject {
    put("actorUserID", wireId(actor.value)); put("targetUserID", wireId(target.value)); put("relationshipState", "none")
    put("relationshipRevision", revision); put("isBlocked", false); put("blockRevision", 0)
}
internal fun socialReceipt(command: SocialCommand, conflict: Boolean = false) = buildJsonObject {
    put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", 2000)
    put("outcome", if (conflict) buildJsonObject { put("rejected", buildJsonObject { put("_0", buildJsonObject {
        put("revisionConflict", buildJsonObject { put("currentRevision", command.expectedRevision + 1) })
    }) }) } else buildJsonObject { put("applied", buildJsonObject { put("_0", buildJsonObject { put(command.action.kind, buildJsonObject {
        if (command.action.kind == "relationship") put("state", when(command.action) { SocialAction.Request -> "pending"; SocialAction.Accept -> "accepted"; else -> "none" })
        else put("isBlocked", command.action == SocialAction.Block)
        put("revision", command.expectedRevision + 1)
    }) }) }) })
}
class SocialTests {
    @Test fun `cancelled relationship command persists query action across restart and manual continuation`()=runTest {
        val diagnostics=NetworkDiagnostics()
        withContext(NetworkDiagnosticsScope(diagnostics)) {
        val store=MemorySocial();var now=1000L
        val api=FakeEdge {_,_->EdgeResponse(200,socialBaseline())}
        fun service()=SocialService(actorId,SocialClient(api,actorId),store,{now},{now*1_000_000})
        val command=service().enqueue(targetId,SocialAction.Block).command
        api.answer={path,body->assertCommandAttempt(false);assertTrue(path.endsWith("submit"));assertEquals(command.payload(),body)
            assertEquals(true,store.works.single().executionStarted);throw CancellationException()}
        assertFailsWith<CancellationException> {service().flush()}
        store.works[0]=Json.decodeFromString<SocialWork>(Json.encodeToString(SocialWork.serializer(),store.works.single()))
        service().retry(command.operation);assertEquals(0,store.works.single().attempts)
        api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("recover"));assertEquals(command.recovery(false),body)
            EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})}
        service().flush();assertEquals(false,store.works.single().reconcile)
        now=store.works.single().nextAttemptMilliseconds;service().retry(command.operation)
        api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("submit"));assertEquals(command.payload(),body)
            EdgeResponse(200,directResult("receipt",socialReceipt(command)))}
        service().flush();assertEquals(SocialWorkStatus.Committed,store.works.single().status)
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(3,samples.size);assertTrue(samples.all {it.kind==OperationKind.UserBlock})
        assertEquals(OperationStepMetric.Completion.Cancelled,samples.first().completion)
        assertEquals(OperationWorkAction.Reconcile,samples[1].action)
        assertEquals(OperationExecutionState.Committed,samples.last().observation?.execution)
    }

    @Test fun `legacy relationship command without execution evidence is conservatively queried`()=runTest {
        val store=MemorySocial();val command=SocialCommand(actorId,targetId,"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",SocialAction.Block,0,116000)
        store.works+=Json.decodeFromString<SocialWork>(Json.encodeToString(SocialWork.serializer(),SocialWork(command)))
        val api=FakeEdge {path,body->assertCommandAttempt(true);assertTrue(path.endsWith("recover"));assertEquals(command.recovery(false),body)
            EdgeResponse(200,directResult("receipt",socialReceipt(command)))}
        val service=SocialService(actorId,SocialClient(api,actorId),store,{1000},{0});service.retry(command.operation);service.flush()
        assertEquals(SocialWorkStatus.Committed,store.works.single().status)
    }
    @Test fun `baseline is bound to actor target and pending requester`() = runTest {
        val api = FakeEdge { path, body -> assertEquals("/v2/social/targets/${targetId.value}/baseline", path); assertNull(body); EdgeResponse(200, socialBaseline()) }
        val client = SocialClient(api, actorId)
        assertEquals(0, client.baseline(targetId).relationshipRevision)
        api.answer = { _, _ -> EdgeResponse(200, socialBaseline(actor = targetId, target = actorId)) }
        assertFailsWith<ClientFailure.Protocol> { client.baseline(targetId) }
        api.answer = { _, _ -> EdgeResponse(200, JsonObject(socialBaseline() + ("relationshipState" to JsonPrimitive("pending")))) }
        assertFailsWith<IllegalArgumentException> { client.baseline(targetId) }
    }
    @Test fun `all actions encode exact Swift enum shape and bind receipts`() {
        for (action in SocialAction.entries) {
            val command = SocialCommand(actorId, targetId, "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", action, 4, 601000)
            assertEquals(action.wire, command.payload().objectValue("action").objectValue(action.kind).string("_0"))
            assertEquals(SocialWorkStatus.Committed, SocialClient.decodeReceipt(command, socialReceipt(command)).status)
            assertNotEquals(command.fingerprint, command.copy(expectedRevision = 5).fingerprint)
            assertFailsWith<ClientFailure.Protocol> { SocialClient.decodeReceipt(command.copy(expectedRevision = 5), socialReceipt(command)) }
            val wrongOutcome = socialReceipt(command).let { JsonObject(it + ("outcome" to socialReceipt(command.copy(expectedRevision = 5)).getValue("outcome"))) }
            assertFailsWith<ClientFailure.Protocol> { SocialClient.decodeReceipt(command, wrongOutcome) }
        }
    }
    @Test fun `proposal persists through baseline failure cancellation and expired confirmation`() = runTest {
        val store = MemorySocial(); var clock = 0L
        val api = FakeEdge { _, _ -> throw IOException() }
        val service = SocialService(actorId, SocialClient(api, actorId), store, { 1000 }, { clock })
        val proposal = service.propose(targetId, SocialAction.Block)
        assertFailsWith<IOException> { service.prepareConfirmation(proposal.id) }
        assertEquals(proposal, store.proposals.single()); assertTrue(store.works.isEmpty())
        api.answer = { _, _ -> EdgeResponse(200, socialBaseline()) }
        val confirmation = service.prepareConfirmation(proposal.id)
        clock = 30_000_000_000
        assertFailsWith<IllegalStateException> { service.confirm(confirmation) }
        assertTrue(store.works.isEmpty()); assertEquals(proposal, store.proposals.single())
        service.discard(proposal.id)
        assertFailsWith<IllegalStateException> { service.prepareConfirmation(proposal.id) }
    }
    @Test fun `enqueue baseline latency consumes original submission window`() = runTest {
        val store = MemorySocial(); var now = 1000L; var nanos = 0L
        val api = FakeEdge { _, _ -> now += 10_000; nanos += 10_000_000_000; EdgeResponse(200, socialBaseline()) }
        val service = SocialService(actorId, SocialClient(api, actorId), store, { now }, { nanos })
        val work = service.enqueue(targetId, SocialAction.Request)
        assertEquals(596000, work.command.deadlineMilliseconds)
        assertTrue(store.proposals.isEmpty()); assertEquals(work, store.works.single())
    }
    @Test fun `uncertain work survives restart then closes original operation after expiry`() = runTest {
        val store = MemorySocial(); var now = 1000L
        val api = FakeEdge { path, _ -> if (path.endsWith("baseline")) EdgeResponse(200, socialBaseline()) else {
            assertTrue(store.proposals.isEmpty()); assertTrue(store.works.isNotEmpty()); throw IOException()
        } }
        fun service() = SocialService(actorId, SocialClient(api, actorId), store, { now }, { now * 1_000_000 })
        val first = service(); val original = first.enqueue(targetId, SocialAction.Block)
        first.flush(); assertEquals(1, store.works.single().attempts)
        now = 122000
        api.answer = { path, body ->
            assertTrue(path.endsWith("recover")); assertEquals("closeIfAbsent", body!!.string("action"))
            assertEquals(original.command.identity(), body["identity"])
            EdgeResponse(200, directResult("receipt", socialReceipt(original.command)))
        }
        service().flush()
        assertEquals(original.command, store.works.single().command); assertEquals(SocialWorkStatus.Committed, store.works.single().status)
    }
    @Test fun `clock rollback during baseline cannot renew the frozen server deadline`() = runTest {
        val store = MemorySocial(); var now = 10_000L; var nanos = 0L
        val api = FakeEdge { _, _ -> now = 5_000; nanos = 10_000_000_000; EdgeResponse(200, socialBaseline()) }
        val service = SocialService(actorId, SocialClient(api, actorId), store, { now }, { nanos })
        val work = service.enqueue(targetId, SocialAction.Block)
        assertEquals(110_000, work.command.deadlineMilliseconds)
    }
    @Test fun `revision conflict is terminal and never silently rebased on retry`() = runTest {
        val store = MemorySocial()
        val api = FakeEdge { _, _ -> EdgeResponse(200, socialBaseline(revision = 4)) }
        val service = SocialService(actorId, SocialClient(api, actorId), store, { 1000 }, { 0 })
        val work = service.enqueue(targetId, SocialAction.Request)
        api.answer = { _, _ -> EdgeResponse(200, directResult("receipt", socialReceipt(work.command, conflict = true))) }
        service.flush(); assertEquals(SocialWorkStatus.Conflicted, store.works.single().status)
        api.answer = { _, _ -> fail("terminal conflict must not rebase or resubmit") }
        service.retry(work.command.operation); service.flush()
        assertEquals(work.command, store.works.single().command)
    }
    @Test fun `bound deferred delay and monotonic expiry survive explicit retry and wall rollback`() = runTest {
        val store = MemorySocial(); var now = 1000L; var nanos = 0L
        val api = FakeEdge { _, _ -> EdgeResponse(200, socialBaseline()) }
        val service = SocialService(actorId, SocialClient(api, actorId), store, { now }, { nanos })
        val work = service.enqueue(targetId, SocialAction.Block)
        api.answer = { _, _ -> EdgeResponse(429, directResult("deferred", buildJsonObject {
            put("identity", work.command.identity()); put("fingerprint", fingerprintPayload(work.command.fingerprint))
            put("reason", "rateLimited"); put("retryAfterMilliseconds", 1000)
        }), "20") }
        service.flush(); assertEquals(21000, store.works.single().nextAttemptMilliseconds)
        now = 20000; service.retry(work.command.operation)
        api.answer = { _, _ -> fail("retried before server floor") }; service.flush()
        now = 21000; nanos = 121_000_000_000
        api.answer = { path, body -> assertTrue(path.endsWith("recover")); assertEquals("closeIfAbsent", body!!.string("action")); EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) }) }
        service.flush(); assertEquals(work.command, store.works.single().command)
    }
    @Test fun `relationship receipt is observed under its own diagnostic kind`()=runTest {
        val command=SocialCommand(actorId,targetId,"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",SocialAction.Request,0,600000)
        val store=MemorySocial();store.works+=SocialWork.fresh(command);val diagnostics=NetworkDiagnostics()
        val api=FakeEdge {_,_->EdgeResponse(200,directResult("receipt",socialReceipt(command)))}
        withContext(NetworkDiagnosticsScope(diagnostics)) {SocialService(actorId,SocialClient(api,actorId),store,{1000},{0}).flush()}
        val sample=diagnostics.snapshot().operations.single()
        assertEquals(OperationKind.Relationship,sample.kind);assertEquals(OperationExecutionState.Committed,sample.observation?.execution)
    }

}
