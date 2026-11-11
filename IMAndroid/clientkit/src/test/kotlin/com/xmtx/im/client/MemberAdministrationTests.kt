package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal class MemoryAdministration: AdministrationStore {
    var works = persistentListOf<AdministrationWork>()
    override suspend fun administrationWorks() = works
    override suspend fun prepareAdministration(intent: AdministrationIntent,activation: String) = AdministrationWork(intent,activation).also { works = works.add(it) }
    override suspend fun replaceAdministrationDraft(expected: AdministrationWork,intent: AdministrationIntent,activation: String): AdministrationWork {
        works = works.set(works.indexOf(expected),expected.copy(status = AdministrationStatus.DraftCancelled))
        return AdministrationWork(intent,activation,nextAttempt = expected.nextAttempt).also { works = works.add(it) }
    }
    override suspend fun updateAdministration(expected: AdministrationWork,updated: AdministrationWork) { val index = works.indexOf(expected);check(index >= 0);works = works.set(index,updated) }
}
class MemberAdministrationTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB");private val target = UserId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val lines get() = javaClass.getResourceAsStream("/member-administration-swift.txt")!!.bufferedReader().readLines()
    private fun wire(index: Int,offset: Int) = Json.parseToJsonElement(lines[index*7+offset]).jsonObject
    private fun intent(index: Int = 0) = AdministrationIntent(actor,room,"10000000-0000-0000-0000-%012d".format(index+1),target,if(index == 1) AdministrationAction.Remove else AdministrationAction.Mute(200000),"ADMIN_ACTION",7,116000)
    private fun admission(intent: AdministrationIntent) = AdministrationAdmission("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",intent.fingerprint,7,3,2000,110000)
    private fun admitted(intent: AdministrationIntent) = EdgeResponse(200,buildJsonObject { put("admitted",buildJsonObject { put("_0",admission(intent).payload(intent)) }) })
    private fun closed(command: AdministrationCommand) = EdgeResponse(200,buildJsonObject { put("receipt",buildJsonObject { put("_0",buildJsonObject {
        put("identity",command.intent.identity());put("fingerprint",fingerprintPayload(command.fingerprint));put("resolvedAtMilliseconds",3000);put("outcome",buildJsonObject { put("closed",buildJsonObject {}) })
    }) }) })
    @Test fun `Swift mute removal and already satisfied fingerprints and wire contracts match`() = runTest {
        for(i in 0..2) {
            val intent = intent(i);assertEquals(lines[i*7],intent.fingerprint);assertEquals(wire(i,1),intent.payload())
            val edge = FakeEdge { _,_ -> EdgeResponse(200,wire(i,2)) };val client = AdministrationClient(edge)
            val admitted = (client.admit(intent) as AdministrationAdmissionResult.Admitted).value;assertEquals(admission(intent),admitted)
            val command = AdministrationCommand(intent,admitted);assertEquals(lines[i*7+3],command.fingerprint);assertEquals(wire(i,4),command.payload());assertEquals(wire(i,6),command.recovery(true))
            edge.answer = { _,_ -> EdgeResponse(200,wire(i,5)) }
            val receipt = client.execute(command) as AdministrationResult.Receipt;assertEquals(AdministrationStatus.Committed,receipt.status)
            assertEquals(if(i == 1) 8L else 7L,receipt.revision);assertEquals(if(i == 0) 200000L else if(i == 2) 300000L else null,receipt.until)
        }
    }
    @Test fun `receipts bind exact mute expiry membership version and frozen admission`() = runTest {
        for(i in 0..2) {
            val command = AdministrationCommand(intent(i),admission(intent(i)))
            val valid = wire(i,5).objectValue("receipt").objectValue("_0")
            for((before,after) in listOf("\"membershipRevision\":${if(i == 1) 8 else 7}" to "\"membershipRevision\":9", "200000" to "199999", "300000" to "199999")) {
                if(!valid.toString().contains(before)) continue
                assertFails { AdministrationClient.decodeReceipt(command,Json.parseToJsonElement(valid.toString().replace(before,after)).jsonObject) }
            }
            assertFails { AdministrationClient.decodeReceipt(command,Json.parseToJsonElement(valid.toString().replace("\"membershipRevision\":${if(i == 1) 8 else 7}","\"membershipRevision\":\"${if(i == 1) 8 else 7}\"")).jsonObject) }
            assertFails { AdministrationClient.decodeReceipt(command.copy(admission = command.admission.copy(joined = 4)),valid) }
            val safe = AdministrationClient.decodeReceipt(command,JsonObject(valid+mapOf("auditText" to JsonPrimitive("private-report"))))
            assertFalse(safe.wire.contains("private-report"))
        }
        assertEquals("ADMIN_ACTION",moderationReason("\u200b ADMIN_ACTION\n"));assertFails { moderationReason("report body") };assertFails { intent().copy(target = actor) }
    }
    @Test fun `lost submission reply queries original command after restart`() = runTest {
        var now = 1000L;val store = MemoryAdministration();var admittedIntent: AdministrationIntent? = null;var queries = 0
        val edge = FakeEdge { path,_ -> if(path.endsWith("admissions")) admitted(requireNotNull(admittedIntent)) else {assertCommandAttempt(false);throw IOException()} }
        val service = AdministrationService(actor,AdministrationClient(edge),store,{ now },{ 0 })
        val confirmation = service.confirmation(room,target,AdministrationAction.Mute(200000),"ADMIN_ACTION",7);admittedIntent = confirmation.intent
        service.enqueue(confirmation);service.flush();service.flush()
        val frozen = store.works.single();assertTrue(frozen.reconcile);assertTrue(frozen.submissionStarted)
        now += 3000
        edge.answer = { path,body -> assertCommandAttempt(true); assertTrue(path.endsWith("operations/recover"));assertEquals(frozen.command().recovery(false),body);queries++;closed(frozen.command()) }
        AdministrationService(actor,AdministrationClient(edge),store,{ now },{ 0 }).flush()
        assertEquals(1,queries);assertEquals(AdministrationStatus.Closed,store.works.single().status)
    }
    @Test fun `unadmitted restart requires explicit reconfirmation and preserves expiry and backpressure`() = runTest {
        var now = 1000L;val store = MemoryAdministration();var calls = 0
        val edge = FakeEdge { _,_ -> calls++;EdgeResponse(429,buildJsonObject {},"90") }
        val service = AdministrationService(actor,AdministrationClient(edge,{now}),store,{now},{0})
        service.enqueue(service.confirmation(room,target,AdministrationAction.Mute(200000),"ADMIN_ACTION",7));service.flush()
        val paused = store.works.single();assertEquals(AdministrationStatus.DraftPaused,paused.status);assertEquals(91000L,paused.nextAttempt)
        val reopened = AdministrationService(actor,AdministrationClient(edge,{now}),store,{now},{0});reopened.flush();assertEquals(1,calls)
        val renewed = reopened.reconfirm(paused.intent.key,reopened.confirmation(room,target,paused.intent.action,"ADMIN_ACTION",8))
        assertEquals(paused.intent.action,renewed.intent.action);assertEquals(91000L,renewed.nextAttempt);reopened.flush();assertEquals(1,calls)
        now = 200001;assertFails { reopened.confirmation(room,target,paused.intent.action,"ADMIN_ACTION",8) }
    }
    @Test fun `monotonic expiry cannot reopen with wall clock rollback and retry keeps server floor`() = runTest {
        var now = 1000L;var nanos = 0L;val store = MemoryAdministration();var observed: AdministrationIntent? = null
        val edge = FakeEdge { _,_ -> admitted(requireNotNull(observed)) };val service = AdministrationService(actor,AdministrationClient(edge),store,{now},{nanos})
        val confirmation = service.confirmation(room,target,AdministrationAction.Mute(200000),"ADMIN_ACTION",7);observed = confirmation.intent
        assertFails { service.enqueue(confirmation.copy(intent = confirmation.intent.copy(deadline = 500000),deadlineNanos = 500000000000)) }
        service.enqueue(confirmation);service.flush();nanos = 120000000000;now = 500
        edge.answer = { path,body -> assertTrue(path.endsWith("operations/recover"));assertEquals("closeIfAbsent",body!!.getValue("action").jsonPrimitive.content);closed(store.works.single().command()) }
        service.flush();assertEquals(AdministrationStatus.NeedsAttention,store.works.single().status)
        service.retry(confirmation.intent.key);service.flush();assertEquals(AdministrationStatus.Closed,store.works.single().status)
    }
    @Test fun `frozen retry stops after bounded recovery round without reobtaining admission`() = runTest {
        var now = 1000L;val store = MemoryAdministration();var observed: AdministrationIntent? = null
        val edge = FakeEdge { path,_ -> if(path.endsWith("admissions")) admitted(requireNotNull(observed)) else EdgeResponse(503,buildJsonObject {},"90") }
        val service = AdministrationService(actor,AdministrationClient(edge,{now}),store,{now},{0})
        val confirmation = service.confirmation(room,target,AdministrationAction.Mute(200000),"ADMIN_ACTION",7);observed = confirmation.intent
        service.enqueue(confirmation);service.flush();service.flush();val frozen = store.works.single().command()
        assertEquals(91000L,store.works.single().nextAttempt)
        now = 62000;service.flush();assertEquals(AdministrationStatus.NeedsAttention,store.works.single().status)
        service.retry(confirmation.intent.key);assertEquals(91000L,store.works.single().nextAttempt);assertEquals(frozen,store.works.single().command())
    }
}
