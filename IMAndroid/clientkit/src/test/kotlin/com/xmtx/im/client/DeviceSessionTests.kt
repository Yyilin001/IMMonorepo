package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

private class DeviceSecrets : SecretStore {
    var value: String? = null
    override suspend fun read() = value
    override suspend fun write(value: String) { this.value = value }
    override suspend fun delete() { value = null }
}
class DeviceSessionTests {
    private val lines get() = javaClass.getResourceAsStream("/device-revocation-swift.txt")!!.bufferedReader().readLines()
    private fun wire(index: Int) = Json.parseToJsonElement(lines[index]).jsonObject
    private fun command(single: Boolean = false) = DeviceRevocationCommand.decode(wire(if(single) 6 else 2))
    private fun baseline() = command().baseline
    @Test fun `Swift canonical fingerprints commands receipts and recoveries match for both selections`() = runTest {
        for(single in listOf(false,true)) {
            val offset = if(single) 5 else 1; val command = command(single)
            assertEquals(lines[offset], command.fingerprint); assertEquals(wire(offset + 1), command.payload()); assertEquals(wire(offset + 3), command.recovery())
            val client = DeviceSessionClient(FakeEdge { _, body -> assertEquals(command.payload(), body); EdgeResponse(200, wire(offset + 2)) }, baseline().current)
            val receipt = (client.execute(command, false) as DeviceRevocationResult.Receipt).receipt
            assertEquals(DeviceRevocationOutcome.Revoked, receipt.outcome)
            assertFails { DeviceRevocationReceipt.decode(command.copy(operation = "11111111-1111-1111-1111-111111111111"), Json.parseToJsonElement(receipt.wire).jsonObject) }
        }
        assertFails { baseline().copy(targets = baseline().targets.reversed().toPersistentList()) }
        assertFails { baseline().copy(targets = persistentListOf(baseline().current)) }
        assertFails { baseline().copy(actor = UserId("non-uuid")) }
        assertFails { baseline().copy(expiresAt = 121001) }
    }
    @Test fun `submit uncertainty is persisted before request and lost reply recovers without resubmitting`() = runTest {
        val command = command(); val secret = DeviceSecrets(); val journal = DeviceRevocationJournal(secret, baseline().actor, baseline().current)
        var now = 1000L; var requests = 0
        val api = FakeEdge { path, body ->
            if(path.endsWith("revocation-baseline")) EdgeResponse(200, wire(0)) else {
                requests++; assertTrue(journal.read().single().unknown); assertEquals(1, journal.read().single().attempts)
                assertEquals(command.payload(), body); throw IOException("lost reply")
            }
        }
        val client = DeviceSessionClient(api, baseline().current)
        val first = DeviceRevocationService(baseline().actor, baseline().current, client, journal, { now }, { now * 1000000 })
        first.baseline(); first.enqueue(command); first.flush(); first.close(); assertEquals(1, requests)
        now = 4000
        api.answer = { path, body -> assertTrue(path.endsWith("operations/recover")); assertEquals(command.recovery(), body); EdgeResponse(200, wire(3)) }
        val reopened = DeviceRevocationService(baseline().actor, baseline().current, client, journal, { now }, { now * 1000000 })
        reopened.flush(); assertEquals(DeviceRevocationOutcome.Revoked, journal.read().single().receipt?.outcome)
    }
    @Test fun `restart never restores submit permission even if persisted operation was never attempted`() = runTest {
        val secret = DeviceSecrets(); val journal = DeviceRevocationJournal(secret, baseline().actor, baseline().current)
        val api = FakeEdge { path, _ -> assertTrue(path.endsWith("revocation-baseline")); EdgeResponse(200, wire(0)) }
        val client = DeviceSessionClient(api, baseline().current)
        val service = DeviceRevocationService(baseline().actor, baseline().current, client, journal, { 1000 }, { 0 })
        service.baseline(); service.enqueue(command()); service.close(); assertFalse(journal.read().single().unknown)
        api.answer = { path, body -> assertTrue(path.endsWith("operations/recover")); assertEquals(command().recovery(), body); EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) }) }
        DeviceRevocationService(baseline().actor, baseline().current, client, journal, { 1000 }, { 0 }).flush()
        assertTrue(journal.read().single().unknown)
    }
    @Test fun `monotonic expiry fences clock rollback and explicit resume keeps server retry floor`() = runTest {
        val secret = DeviceSecrets(); val journal = DeviceRevocationJournal(secret, baseline().actor, baseline().current)
        var now = 1000L; var mono = 0L
        val api = FakeEdge { _, _ -> EdgeResponse(200, wire(0)) }; val client = DeviceSessionClient(api, baseline().current, { now })
        val service = DeviceRevocationService(baseline().actor, baseline().current, client, journal, { now }, { mono })
        service.baseline(); mono = 121000000000; assertFails { service.enqueue(command()) }
        mono = 0; service.baseline(); service.enqueue(command())
        api.answer = { _, _ -> EdgeResponse(429, buildJsonObject {}, "90") }; service.flush()
        assertEquals(91000, journal.read().single().nextActionAt)
        service.resume(command().operation); assertEquals(91000, journal.read().single().nextActionAt)
        api.answer = { _, _ -> error("retry floor") }; service.flush()
        mono = 61000000000; service.flush(); assertTrue(journal.read().single().needsAttention)
        now = 92000; service.resume(command().operation)
        api.answer = { path, body -> assertTrue(path.endsWith("recover")); assertEquals(command().recovery(), body); EdgeResponse(200, wire(3)) }; service.flush()
        assertNotNull(journal.read().single().receipt)
    }
    @Test fun `journal binds owner full proof and immutable scope and rejects overlapping pending targets`() = runTest {
        val secret = DeviceSecrets(); val journal = DeviceRevocationJournal(secret, baseline().actor, baseline().current)
        val api = FakeEdge { _, _ -> EdgeResponse(200, wire(0)) }; val client = DeviceSessionClient(api, baseline().current)
        val service = DeviceRevocationService(baseline().actor, baseline().current, client, journal, { 1000 }, { 0 })
        service.baseline(); service.enqueue(command()); service.baseline()
        assertFails { service.enqueue(command(true).copy(operation = "11111111-1111-1111-1111-111111111111")) }
        assertFails { DeviceRevocationJournal(secret, UserId("11111111-1111-1111-1111-111111111111"), baseline().current).read() }
        val record = journal.read().single()
        assertFails { journal.write(persistentListOf(record.copy(attempts = 6))) }
        val receipt = DeviceRevocationReceipt.decode(command(), wire(3).getValue("receipt").jsonObject.getValue("_0").jsonObject)
        assertFails { journal.write(persistentListOf(record.copy(unknown = true, receipt = receipt.copy(resolvedAt = 4000)))) }
    }
    @Test fun `one shot transport never replays physical submit after unauthorized response`() = runTest {
        val account = FakeAccount(); val auth = AuthSession(MemorySecrets(), account) { 0 }
        val credentials = auth.login("account", "password123456")
        var calls = 0
        val edge = object : EdgeTransport {
            override suspend fun request(path: String, credentials: Credentials, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
                calls++; return EdgeResponse(401, buildJsonObject {})
            }
        }
        assertEquals(401, AuthenticatedApi(auth, edge, credentials.userId, credentials.deviceId).requestWithoutReplay("/v2/test", buildJsonObject {}).status)
        assertEquals(1, calls); assertEquals(0, account.requests.count { it.first.endsWith("refresh") })
    }
    private fun page(created: Long = 500, cursor: String? = null) = buildJsonObject {
        put("sessions", JsonArray((persistentListOf(baseline().current) + baseline().targets).map { id -> buildJsonObject {
            put("deviceID", id.value); put("deviceName", "device"); put("platform", "Android")
            put("createdAtMilliseconds", created); put("lastActiveAtMilliseconds", 1000); put("isCurrentDevice", id == baseline().current)
        } })); cursor?.let { put("nextCursor", it) }
    }
    @Test fun `pagination carries page size and opaque cursor separately and current identity must match`() = runTest {
        val transport = object : AuthenticatedTransport {
            override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse = error("multi-query path")
            override suspend fun requestWithQuery(path: String, query: Map<String,String>, maximumBytes: Long): EdgeResponse {
                assertEquals(mapOf("page_size" to "50", "cursor" to "opaque/+=&"), query); assertEquals(1048576, maximumBytes)
                return EdgeResponse(200, page())
            }
        }
        assertEquals(3, DeviceSessionClient(transport, baseline().current).list("opaque/+=&").sessions.size)
        assertFails { DeviceSessionClient(transport, baseline().targets.first()).list("opaque/+=&") }
    }
    @Test fun `confirmed revocation hides only older sessions and refresh clears proposed scope`() = runTest {
        val secret = DeviceSecrets(); val journal = DeviceRevocationJournal(secret, baseline().actor, baseline().current)
        var created = 500L
        val api = FakeEdge { path, _ -> EdgeResponse(200, if(path.endsWith("baseline")) wire(0) else page(created)) }
        val client = DeviceSessionClient(api, baseline().current)
        val service = DeviceRevocationService(baseline().actor, baseline().current, client, journal, { 1000 }, { 0 })
        val management = DeviceManagement(client, service, { 1000 }, { 0 })
        management.refresh(); management.propose(null); assertEquals(baseline().targets, management.state.value.prompt?.command?.targets)
        management.refresh(); assertNull(management.state.value.prompt); management.tick()
        val receipt = DeviceRevocationReceipt.decode(command(), wire(3).getValue("receipt").jsonObject.getValue("_0").jsonObject)
        journal.write(persistentListOf(DeviceRevocationWork(command(), receipt, true, roundEndsAt = 61000, nextActionAt = 1000)))
        management.tick(); assertEquals(listOf(baseline().current), management.state.value.sessions.map { it.device }); assertNull(management.state.value.baseline)
        created = 3000; management.refresh(); assertEquals(3, management.state.value.sessions.size)
        management.close(); assertTrue(management.state.value.sessions.isEmpty())
    }
    @Test fun `previous terminal history loaded during first refresh does not discard device list`() = runTest {
        val secret = DeviceSecrets(); val journal = DeviceRevocationJournal(secret, baseline().actor, baseline().current)
        val receipt = DeviceRevocationReceipt.decode(command(), wire(3).getValue("receipt").jsonObject.getValue("_0").jsonObject)
        journal.write(persistentListOf(DeviceRevocationWork(command(), receipt, true, roundEndsAt = 61000, nextActionAt = 1000)))
        val gate = CompletableDeferred<Unit>()
        val api = FakeEdge { path, _ -> if(path == "/v2/devices") { gate.await(); EdgeResponse(200, page(3000)) } else EdgeResponse(200, wire(0)) }
        val client = DeviceSessionClient(api, baseline().current)
        val management = DeviceManagement(client, DeviceRevocationService(baseline().actor, baseline().current, client, journal, { 1000 }, { 0 }), { 1000 }, { 0 })
        val refresh = launch { management.refresh() }; yield(); management.tick(); gate.complete(Unit); refresh.join()
        assertEquals(3, management.state.value.sessions.size); assertNotNull(management.state.value.baseline)
    }
    @Test fun `late refresh response cannot repopulate closed page`() = runTest {
        val gate = CompletableDeferred<Unit>(); val api = FakeEdge { _, _ -> gate.await(); EdgeResponse(200, page()) }
        val client = DeviceSessionClient(api, baseline().current)
        val management = DeviceManagement(client, DeviceRevocationService(baseline().actor, baseline().current, client,
            DeviceRevocationJournal(DeviceSecrets(), baseline().actor, baseline().current)))
        val job = launch { management.refresh() }; yield(); management.close(); gate.complete(Unit); job.join()
        assertTrue(management.state.value.sessions.isEmpty()); assertNull(management.state.value.baseline)
    }
}
