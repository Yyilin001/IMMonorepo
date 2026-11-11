package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal class MemoryModeration: ModerationStore {
    var works = persistentListOf<ModerationWork>()
    override suspend fun moderationWorks() = works
    override suspend fun enqueueModeration(work: ModerationWork) = work.also { works = works.add(it) }
    override suspend fun updateModeration(expected: ModerationWork,updated: ModerationWork) { val index = works.indexOf(expected);check(index >= 0);works = works.set(index,updated) }
}
class MessageModerationTests {
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB");private val message = MessageId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val lines get() = javaClass.getResourceAsStream("/message-moderation-swift.txt")!!.bufferedReader().readLines()
    private fun wire(index: Int,offset: Int) = Json.parseToJsonElement(lines[index*7+offset]).jsonObject
    private fun intent(index: Int = 0) = ModerationIntent(actor,room,"10000000-0000-0000-0000-%012d".format(index+1),message,"ADMIN_ACTION",3,7,116000)
    private fun baseline() = ModerationBaseline(room,message,3,7,false)
    private fun admission(intent: ModerationIntent) = ModerationAdmission("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",intent.fingerprint,1,2000,110000)
    private fun admitted(intent: ModerationIntent) = EdgeResponse(200,buildJsonObject { put("admitted",buildJsonObject { put("_0",admission(intent).payload(intent)) }) })
    private fun closed(intent: ModerationIntent) = EdgeResponse(200,buildJsonObject { put("receipt",buildJsonObject { put("_0",buildJsonObject {
        put("identity",intent.identity());put("fingerprint",fingerprintPayload(intent.fingerprint));put("resolvedAtMilliseconds",3000);put("outcome",buildJsonObject { put("closed",buildJsonObject {}) })
    }) }) })
    @Test fun `cancelled admission retains execution history when a restarted confirmation must close`() = runTest {
        val store = MemoryModeration()
        val edge = FakeEdge { path, _ -> assertTrue(path.endsWith("admissions")); assertCommandAttempt(false); throw CancellationException("fixture interruption") }
        val original = MessageModerationService(actor, MessageModerationClient(edge), store, {1000}, {0})
        val confirmation = original.confirmation(baseline(), "ADMIN_ACTION")
        original.enqueue(confirmation)
        assertFailsWith<CancellationException> { original.flush() }
        val saved = Json.decodeFromString<ModerationWork>(Json.encodeToString(ModerationWork.serializer(), store.works.single()))
        assertEquals(true, saved.executionStarted); assertFalse(saved.submissionStarted)
        store.works = persistentListOf(saved)
        val resumed = MessageModerationService(actor, MessageModerationClient(edge), store, {1000}, {0})
        resumed.retry(confirmation.intent.key); assertEquals(0, store.works.single().attempts)
        edge.answer = { path, body ->
            assertCommandAttempt(true); assertTrue(path.endsWith("operations/recover")); assertEquals(confirmation.intent.recovery(true), body)
            closed(confirmation.intent)
        }
        resumed.flush(); assertEquals(ModerationStatus.Closed, store.works.single().status)
    }
    @Test fun `legacy admitted work queries as retry even after round reset`() = runTest {
        val store = MemoryModeration(); val intent = intent()
        val old = ModerationWork(intent, "old", admission = admission(intent), roundEnd = 61000)
        val encoded = Json.encodeToString(ModerationWork.serializer(), old); assertFalse(encoded.contains("executionStarted"))
        store.works = persistentListOf(Json.decodeFromString<ModerationWork>(encoded))
        val edge = FakeEdge { path, body ->
            assertCommandAttempt(true); assertTrue(path.endsWith("operations/recover")); assertEquals(intent.recovery(false), body); closed(intent)
        }
        val service = MessageModerationService(actor, MessageModerationClient(edge), store, {1000}, {0})
        service.retry(intent.key); service.flush(); assertEquals(ModerationStatus.Closed, store.works.single().status)
    }
    @Test fun `Swift redaction already satisfied baseline admission and recovery match`() = runTest {
        for(i in 0..1) {
            val intent = intent(i);assertEquals(lines[i*7],intent.fingerprint);assertEquals(wire(i,1),intent.payload())
            val edge = FakeEdge { _,_ -> EdgeResponse(200,wire(i,2)) };val client = MessageModerationClient(edge)
            val admitted = (client.admit(intent) as ModerationAdmissionResult.Admitted).value;assertEquals(admission(intent),admitted)
            val command = ModerationCommand(intent,admitted);assertEquals(intent.fingerprint,command.fingerprint);assertEquals(wire(i,3),command.payload());assertEquals(wire(i,5),intent.recovery(true))
            edge.answer = { path,body -> assertTrue(path.endsWith("submit"));assertEquals(command.payload(),body);EdgeResponse(200,wire(i,4)) }
            val receipt = client.execute(intent,command,recover = false) as ModerationResult.Receipt
            assertEquals(ModerationStatus.Committed,receipt.status);assertEquals(if(i == 0) 4L else 3L,receipt.revision)
            edge.answer = { _,_ -> EdgeResponse(200,wire(i,6)) };assertEquals(baseline().copy(redacted = i == 1),client.baseline(room,message))
        }
    }
    @Test fun `receipts bind message revision and operation but admission does not alter semantic identity`() = runTest {
        for(i in 0..1) {
            val intent = intent(i);val valid = wire(i,4).objectValue("receipt").objectValue("_0")
            val revision = if(i == 0) 4 else 3
            for(after in listOf("9","\"$revision\"")) assertFails { MessageModerationClient.decodeReceipt(intent,Json.parseToJsonElement(valid.toString().replace("\"messageRevision\":$revision","\"messageRevision\":$after")).jsonObject) }
            assertFails { MessageModerationClient.decodeReceipt(intent.copy(message = MessageId(actor.value)),valid) }
            val safe = MessageModerationClient.decodeReceipt(intent,JsonObject(valid+mapOf("auditText" to JsonPrimitive("private-report"))))
            assertFalse(safe.wire.contains("private-report"))
            assertEquals(intent.fingerprint,ModerationCommand(intent,admission(intent).copy(actorJoined = 2)).fingerprint)
            assertFails { ModerationCommand(intent,admission(intent).copy(actorJoined = 8)) }
            assertFails { ModerationCommand(intent,admission(intent).copy(expires = 117000)) }
        }
    }
    @Test fun `lost submission reply queries frozen intent after restart without resubmitting`() = runTest {
        var now = 1000L;val store = MemoryModeration();var observed: ModerationIntent? = null;var calls = 0
        val edge = FakeEdge { path,_ -> if(path.endsWith("admissions")) { assertCommandAttempt(false); admitted(requireNotNull(observed)) } else { assertCommandAttempt(true); throw IOException() } }
        val service = MessageModerationService(actor,MessageModerationClient(edge),store,{now},{0})
        val confirmation = service.confirmation(baseline(),"ADMIN_ACTION");observed = confirmation.intent
        service.enqueue(confirmation);service.flush();service.flush();val frozen = store.works.single();assertTrue(frozen.submissionStarted);assertTrue(frozen.reconcile)
        now += 5000
        edge.answer = { path,body -> calls++;assertCommandAttempt(true);assertTrue(path.endsWith("operations/recover"));assertEquals(frozen.intent.recovery(false),body);closed(frozen.intent) }
        MessageModerationService(actor,MessageModerationClient(edge),store,{now},{0}).flush()
        assertEquals(1,calls);assertEquals(ModerationStatus.Closed,store.works.single().status);assertEquals(frozen.intent,store.works.single().intent)
    }
    @Test fun `unadmitted restart closes original intent without acquiring new authority`() = runTest {
        val store = MemoryModeration();val edge = FakeEdge { _,_ -> error("must not admit") }
        val original = MessageModerationService(actor,MessageModerationClient(edge),store,{1000},{0})
        original.enqueue(original.confirmation(baseline(),"ADMIN_ACTION"));val intent = store.works.single().intent
        edge.answer = { path,body -> assertTrue(path.endsWith("operations/recover"));assertEquals(intent.recovery(true),body);closed(intent) }
        MessageModerationService(actor,MessageModerationClient(edge),store,{1000},{0}).flush()
        assertTrue(store.works.single().recoveryOnly);assertFalse(store.works.single().submissionStarted);assertEquals(ModerationStatus.Closed,store.works.single().status)
    }
    @Test fun `terminal admission receipt may finalize without inventing an admission`() = runTest {
        val store = MemoryModeration();val edge = FakeEdge { _,_ -> error("configured below") }
        val service = MessageModerationService(actor,MessageModerationClient(edge),store,{1000},{0})
        val confirmation = service.confirmation(baseline(),"ADMIN_ACTION")
        edge.answer = { _,_ -> EdgeResponse(200,buildJsonObject { put("terminal",closed(confirmation.intent).body.getValue("receipt")) }) }
        service.enqueue(confirmation);service.flush();assertEquals(ModerationStatus.Closed,store.works.single().status);assertNull(store.works.single().admission)
    }
    @Test fun `monotonic expiry and server floor survive explicit retry and clock rollback`() = runTest {
        var now = 1000L;var nanos = 0L;val store = MemoryModeration();var observed: ModerationIntent? = null
        val edge = FakeEdge { path,_ -> if(path.endsWith("admissions")) admitted(requireNotNull(observed)) else EdgeResponse(503,buildJsonObject {},"90") }
        val service = MessageModerationService(actor,MessageModerationClient(edge,{now}),store,{now},{nanos})
        val confirmation = service.confirmation(baseline(),"ADMIN_ACTION");observed = confirmation.intent
        service.enqueue(confirmation);service.flush();service.flush();assertEquals(91000L,store.works.single().nextAttempt)
        now = 62000;service.flush();assertEquals(ModerationStatus.NeedsAttention,store.works.single().status)
        service.retry(confirmation.intent.key);assertEquals(91000L,store.works.single().nextAttempt)
        now = 91000;nanos = 120000000000;service.flush();assertEquals(ModerationStatus.NeedsAttention,store.works.single().status)
        service.retry(confirmation.intent.key);now = 92000
        edge.answer = { path,body -> assertTrue(path.endsWith("operations/recover"));assertEquals(confirmation.intent.recovery(true),body);EdgeResponse(200,buildJsonObject { put("unresolved",buildJsonObject {}) }) }
        service.flush();assertTrue(store.works.single().recoveryOnly)
        now = 500;service.retry(confirmation.intent.key);assertEquals(97000L,store.works.single().nextAttempt)
        now = 97000;service.retry(confirmation.intent.key)
        edge.answer = { path,body -> assertTrue(path.endsWith("operations/recover"));assertEquals(confirmation.intent.recovery(true),body);closed(confirmation.intent) }
        service.flush();assertEquals(ModerationStatus.Closed,store.works.single().status)
    }
    @Test fun `five physical attempts exhaust a round and never rebase intent`() = runTest {
        var now = 1000L;val store = MemoryModeration();var count = 0
        val edge = FakeEdge { _,_ -> count++;throw IOException() }
        val service = MessageModerationService(actor,MessageModerationClient(edge),store,{now},{0});val confirmation = service.confirmation(baseline(),"ADMIN_ACTION")
        service.enqueue(confirmation)
        repeat(5) { service.flush();now = store.works.single().nextAttempt }
        assertEquals(5,count);assertEquals(ModerationStatus.NeedsAttention,store.works.single().status);assertEquals(confirmation.intent,store.works.single().intent)
        service.flush();assertEquals(5,count)
    }
}
