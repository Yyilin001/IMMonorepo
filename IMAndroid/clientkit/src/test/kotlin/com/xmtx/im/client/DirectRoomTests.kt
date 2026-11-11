package com.xmtx.im.client

import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal fun directCommand() = DirectRoomCommand(actorId, targetId, "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", 601000)
internal fun directProof(command: DirectRoomCommand) = buildJsonObject { put("identity", command.identity()); put("fingerprint", command.fingerprintPayload()) }
internal fun directReceipt(command: DirectRoomCommand) = buildJsonObject {
    directProof(command).forEach { (key, value) -> put(key, value) }
    put("resolvedAtMilliseconds", 2000)
    put("outcome", buildJsonObject { put("opened", buildJsonObject { put("roomID", wireId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")); put("createdAtMilliseconds", 1000) }) })
}
internal fun directResult(kind: String, value: JsonObject) = buildJsonObject { put(kind, buildJsonObject { put("_0", value) }) }
private class MemoryDirect : DirectRoomStore {
    val works = mutableListOf<DirectRoomWork>()
    override suspend fun prepareDirect(command: DirectRoomCommand): DirectRoomWork = works.firstOrNull { !it.terminal && it.command.target == command.target }
        ?: DirectRoomWork.fresh(command).also { works.add(it) }
    override suspend fun prepareDirect(command: DirectRoomCommand, identity: PublicIdentity): DirectRoomWork {
        require(identity.user == command.target)
        return works.firstOrNull { !it.terminal && it.command.target == command.target }
            ?: DirectRoomWork.fresh(command, identity).also { works.add(it) }
    }
    override suspend fun directWorks() = works.toPersistentList()
    override suspend fun updateDirect(expected: DirectRoomWork, updated: DirectRoomWork) { val index = works.indexOf(expected); check(index >= 0); works[index] = updated }
}
class DirectRoomTests {
    @Test fun `selected identity freezes before network and survives retry and serialization`() = runTest {
        val store = MemoryDirect()
        val identity = PublicIdentity(targetId, PublicHandle("friend"), "原始选择", AccountKind.CustomerSupport)
        val api = FakeEdge { _, _ ->
            assertEquals(identity, store.works.single().publicIdentity)
            throw CancellationException()
        }
        val service = DirectRoomService(actorId, DirectRoomClient(api), store, { 1000 }, { 0 })
        val first = service.prepare(identity)
        assertEquals(first, service.prepare(identity.copy(displayName = "稍后的查询")))
        assertFailsWith<CancellationException> { service.flush() }
        store.works[0] = Json.decodeFromString(Json.encodeToString(DirectRoomWork.serializer(), store.works.single()))
        assertEquals(identity, store.works.single().publicIdentity)
        api.answer = { path, _ ->
            assertTrue(path.endsWith("recover"))
            EdgeResponse(200, directResult("receipt", directReceipt(first.command)))
        }
        DirectRoomService(actorId, DirectRoomClient(api), store, { 1000 }, { 0 }).flush()
        assertEquals(identity, store.works.single().publicIdentity)
        assertEquals(DirectWorkStatus.Opened, store.works.single().status)
    }
    @Test fun `stored identity validates target handle and display name and has no lookup deadline`() {
        val identity = PublicIdentity(targetId, PublicHandle("friend"), "本地选择", AccountKind.Regular)
        val work = DirectRoomWork.fresh(directCommand(), identity)
        val json = Json.encodeToString(DirectRoomWork.serializer(), work)
        assertEquals(work, Json.decodeFromString<DirectRoomWork>(json))
        assertFalse(json.contains("deadlineNanos")); assertFalse(json.contains("lease"))
        assertFails { work.copy(publicIdentity = identity.copy(user = actorId)) }
        assertFails { Json.decodeFromString<DirectRoomWork>(json.replace("friend", "INVALID")) }
        assertFails { Json.decodeFromString<DirectRoomWork>(json.replace("本地选择", "")) }
        assertNull(Json.decodeFromString<DirectRoomWork>(Json.encodeToString(DirectRoomWork.serializer(), DirectRoomWork(directCommand()))).publicIdentity)
    }

    @Test fun `lost or cancelled submit queries after reopen and only unresolved permits exact resubmission`()=runTest {
        val diagnostics=NetworkDiagnostics()
        withContext(NetworkDiagnosticsScope(diagnostics)) {
        for(cancelled in listOf(false,true)) {
            val store=MemoryDirect();var now=1000L;val command=directCommand();store.prepareDirect(command)
            val api=FakeEdge {path,body->
                assertCommandAttempt(false);assertTrue(path.endsWith("submit"));assertEquals(command.payload(),body)
                assertEquals(true,store.works.single().executionStarted);assertEquals(true,store.works.single().reconcile)
                if(cancelled) throw CancellationException() else throw IOException()
            }
            fun service()=DirectRoomService(actorId,DirectRoomClient(api),store,{now},{now*1_000_000})
            if(cancelled) assertFailsWith<CancellationException> {service().flush()} else service().flush()
            store.works[0]=Json.decodeFromString<DirectRoomWork>(Json.encodeToString(DirectRoomWork.serializer(),store.works.single()))
            now=maxOf(now,store.works.single().nextAttemptMilliseconds);service().retry(command.operation)
            api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("recover"));assertEquals(command.recovery(false),body)
                EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})}
            service().flush();assertEquals(false,store.works.single().reconcile)
            now=store.works.single().nextAttemptMilliseconds;service().retry(command.operation)
            api.answer={path,body->assertCommandAttempt(true);assertTrue(path.endsWith("submit"));assertEquals(command.payload(),body)
                EdgeResponse(200,directResult("receipt",directReceipt(command)))}
            service().flush();assertEquals(DirectWorkStatus.Opened,store.works.single().status)
        }
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(6,samples.size);assertTrue(samples.all {it.kind==OperationKind.DirectRoom})
        assertEquals(2,samples.count {it.certainty==NetworkMetric.Certainty.ResponseReceived})
        assertEquals(1,samples.count {it.completion==OperationStepMetric.Completion.Cancelled})
    }

    @Test fun `legacy direct command with cleared counters is queried and charged as a retry`()=runTest {
        val store=MemoryDirect();val command=directCommand()
        store.works+=Json.decodeFromString<DirectRoomWork>(Json.encodeToString(DirectRoomWork.serializer(),DirectRoomWork(command)))
        val api=FakeEdge {path,body->assertCommandAttempt(true);assertTrue(path.endsWith("recover"));assertEquals(command.recovery(false),body)
            EdgeResponse(200,directResult("receipt",directReceipt(command)))}
        DirectRoomService(actorId,DirectRoomClient(api),store,{1000},{0}).flush()
        assertEquals(DirectWorkStatus.Opened,store.works.single().status)
    }
    @Test fun `Swift codable shape and canonical fingerprint fixture remain stable`() {
        val command = directCommand()
        assertEquals("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", command.payload().identifier("actorUserID"))
        assertEquals(command.target.value, command.identity().objectValue("scope").objectValue("userPair").identifier("_1"))
        assertEquals("closeIfAbsent", command.recovery(true).string("action"))
        assertEquals("6sYLBkMQmBe0s895nn3iikfBPNRan13YujdOZqTH5TQ=", command.fingerprint)
    }
    @Test fun `receipt binding rejects another operation and unknown terminal outcome`() = runTest {
        val command = directCommand()
        val api = FakeEdge { _, _ -> EdgeResponse(200, directResult("receipt", directReceipt(command))) }
        val receipt = DirectRoomClient(api).execute(command, false, false) as DirectRoomResult.Receipt
        assertEquals(RoomId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"), receipt.room)
        val other = command.copy(operation = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        assertFailsWith<ClientFailure.Protocol> { DirectRoomClient(api).execute(other, false, false) }
        api.answer = { _, _ -> EdgeResponse(200, directResult("receipt", JsonObject(directReceipt(command) + ("outcome" to buildJsonObject { put("invented", buildJsonObject {}) })))) }
        assertFailsWith<ClientFailure.Protocol> { DirectRoomClient(api).execute(command, false, false) }
    }
    @Test fun `uncertain submission survives restart coalesces target and closes after deadline`() = runTest {
        val store = MemoryDirect(); var now = 1000L; var clock = 0L
        var paths = mutableListOf<String>(); var bodies = mutableListOf<JsonObject>()
        val api = FakeEdge { path, body ->
            assertTrue(store.works.isNotEmpty()) // Write-ahead before networking.
            paths.add(path); bodies.add(body!!); throw IOException()
        }
        fun service() = DirectRoomService(actorId, DirectRoomClient(api), store, { now }, { clock })
        val first = service(); val work = first.prepare(targetId)
        first.flush()
        val restarted = service()
        assertEquals(work.command, restarted.prepare(targetId).command)
        now = 700000; clock = 699000000000
        api.answer = { path, body -> paths.add(path); bodies.add(body!!); EdgeResponse(200, directResult("receipt", directReceipt(work.command))) }
        restarted.flush()
        assertTrue(paths.first().endsWith("submit")); assertTrue(paths.last().endsWith("operations/recover"))
        assertEquals("closeIfAbsent", bodies.last().string("action"))
        assertEquals(work.command.identity(), bodies.last()["identity"])
        assertEquals(DirectWorkStatus.Opened, store.works.single().status)
    }
    @Test fun `processing proof prevents resubmission and bound retry floors are respected`() = runTest {
        val store = MemoryDirect(); var now = 1000L
        val command = directCommand(); store.prepareDirect(command)
        val api = FakeEdge { _, _ -> EdgeResponse(200, directResult("processing", directProof(command))) }
        val service = DirectRoomService(actorId, DirectRoomClient(api), store, { now }, { now * 1_000_000 })
        service.flush(); assertTrue(store.works.single().processing)
        now = 6000
        api.answer = { path, body ->
            assertTrue(path.endsWith("operations/recover")); assertEquals("query", body!!.string("action"))
            EdgeResponse(429, directResult("deferred", buildJsonObject {
                directProof(command).forEach { (k, v) -> put(k, v) }; put("reason", "rateLimited"); put("retryAfterMilliseconds", 1000)
            }), "20")
        }
        service.flush(); assertEquals(26000, store.works.single().nextAttemptMilliseconds)
        api.answer = { _, _ -> fail("retried before server floor") }
        now = 25999; service.flush()
    }
    @Test fun `wall clock rollback never extends the original submission window`() = runTest {
        val store = MemoryDirect(); val command = directCommand(); store.prepareDirect(command)
        var now = 1000L; var monotonic = 0L
        val api = FakeEdge { _, _ -> EdgeResponse(200, directResult("processing", directProof(command))) }
        val service = DirectRoomService(actorId, DirectRoomClient(api), store, { now }, { monotonic })
        service.flush()
        now = 6000; monotonic = 700_000_000_000
        api.answer = { _, body ->
            assertEquals("closeIfAbsent", body!!.string("action"))
            EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
        }
        service.flush()
        assertEquals(command, store.works.single().command)
        assertFalse(store.works.single().terminal)
    }
    @Test fun `malformed proof keeps original work for explicit reconciliation`() = runTest {
        val store = MemoryDirect(); store.prepareDirect(directCommand())
        val api = FakeEdge { _, _ -> EdgeResponse(200, directResult("receipt", buildJsonObject {})) }
        DirectRoomService(actorId, DirectRoomClient(api), store, { 1000 }, { 0 }).flush()
        assertEquals(DirectWorkStatus.NeedsAttention, store.works.single().status)
        assertNull(store.works.single().receipt); assertNull(store.works.single().room)
    }
}
