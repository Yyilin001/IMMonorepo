package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ForwardStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val device = DeviceId(UUID.randomUUID().toString())
    private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val message = MessageId("00000000-0000-0000-0000-000000000001")
    private fun store() = SqliteClientStore(context, actor, device)
    private fun command() = ForwardCommand(actor, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", (1..21).map {
        ForwardSource(room, MessageId("00000000-0000-0000-0000-%012d".format(it)), it.toLong())
    }.toPersistentList(), persistentListOf(RoomId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"), RoomId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")), 596000)
    private fun fixture(index: Int) = InstrumentationRegistry.getInstrumentation().context.assets.open("forward-plans-swift.txt").bufferedReader().use { Json.parseToJsonElement(it.readLines()[index]).jsonObject }
    private fun id() = UUID.randomUUID().toString().uppercase()
    @Test fun cancelledForwardResumesAsRetryAndProcessingQueryKeepsItsHistory() = runBlocking {
        val diagnostics=NetworkDiagnostics()
        kotlinx.coroutines.withContext(NetworkDiagnosticsScope(diagnostics)) {
        var store = store(); var now = 1000L; var calls = 0; val command = command()
        val api = object: AuthenticatedTransport {
            override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
                calls++; val intent = requireNotNull(currentCoroutineContext()[NetworkWorkIntent])
                assertEquals(calls > 1, intent.isRetry)
                assertEquals(if(calls == 1) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery, intent.priority)
                assertTrue(store.forwardWorks().single().submissionStarted)
                if(calls == 1) { assertEquals(command.payload(), payload); throw CancellationException("fixture interruption") }
                assertEquals(command.recovery("query"), payload)
                return EdgeResponse(200, buildJsonObject { put(if(calls == 2) "processing" else "receipt", buildJsonObject { put("_0", fixture(if(calls == 2) 3 else 4)) }) })
            }
        }
        fun service() = ForwardPlanService(actor, ForwardPlanClient(api), store, {now})
        try {
            store.enqueueForward(command)
            try { service().flush(); fail("expected interruption") } catch(_: CancellationException) {}
            store.close(); store = store()
            val saved = store.forwardWorks().single(); assertEquals(0, saved.attempts)
            store.updateForward(saved, saved.copy(status = ForwardStatus.NeedsAttention))
            service().retry(command.operation); service().flush()
            now = store.forwardWorks().single().nextAttempt; store.close(); store = store(); service().flush()
            assertEquals(3, calls); assertEquals(ForwardStatus.Committed, store.forwardWorks().single().status)
        } finally { store.close() }
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(3,samples.size)
        assertEquals(OperationStepMetric.Completion.Cancelled,samples.first().completion)
        assertEquals(OperationExecutionState.Processing,samples[1].observation?.execution)
        assertEquals(OperationExecutionState.Committed,samples.last().observation?.execution)
        assertEquals(NetworkMetric.Certainty.ResponseReceived,samples.last().certainty)
    }

    @Test fun duplicateCoalescingAndOverlapFenceSurviveReopenWithoutChangingFrozenPlan() = runBlocking {
        var store = store(); val command = command(); val work = store.enqueueForward(command)
        assertEquals(work, store.enqueueForward(command.copy(operation = id(), deadline = 700000)))
        try { store.enqueueForward(command.copy(operation = id(), sources = persistentListOf(command.sources.first()))); fail("overlap allowed") } catch (_: IllegalStateException) { }
        try { store.updateForward(work, work.copy(command = command.copy(deadline = 700000))); fail("deadline renewed") } catch (_: IllegalArgumentException) { }
        store.close(); store = store(); assertEquals(work, store.forwardWorks().single())
        assertEquals(work,store.forwardWork(command.operation));assertNull(store.forwardWork(id()))
        store.updateForward(work, work.copy(status = ForwardStatus.Cancelled, cancelRequested = true))
        assertEquals(42, store.snapshot().forwardOperations.single().cancelled)
        assertNotEquals(work.command.operation, store.enqueueForward(command.copy(operation = id())).command.operation)
        store.close()
    }
    @Test fun verifiedPartialResultsPersistAndCannotRegressOrCreateMessageProjection() = runBlocking {
        var store = store(); val command = command(); val work = store.enqueueForward(command)
        val progress = ForwardPlanClient.decodeProgress(command, fixture(3)); val active = work.copy(submissionStarted = true, reconcile = true, progress = progress)
        store.updateForward(work, active); store.close(); store = store()
        assertEquals(20, store.forwardWorks().single().succeeded); assertTrue(store.snapshot().messages.isEmpty())
        try { store.updateForward(active, active.copy(progress = null)); fail("progress erased") } catch (_: IllegalArgumentException) { }
        try { store.updateForward(active, active.copy(status = ForwardStatus.Cancelled)); fail("uncertain plan cancelled locally") } catch (_: IllegalArgumentException) { }
        val completed = ForwardPlanClient.decodeResolved(command, fixture(4))
        val changed = completed.progress.copy(children = completed.progress.children.set(0, completed.progress.children[0].copy(resolvedAt = 999)))
        try { store.updateForward(active, active.copy(progress = changed)); fail("verified child replaced") } catch (_: IllegalArgumentException) { }
        store.updateForward(active, active.copy(status = completed.status, progress = completed.progress, receipt = completed.wire))
        assertTrue(store.snapshot().messages.isEmpty()); assertEquals(21, store.forwardWorks().single().succeeded); assertEquals(20, store.forwardWorks().single().rejected)
        store.close()
    }
    @Test fun forwardedAttributionComesFromRoomProjectionSurvivesReopenAndDisappearsOnWithdrawal() = runBlocking {
        var store = store(); store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
        val origin = id(); val originActor = id()
        fun body(type: String, revision: Long, originSender: String? = originActor) = buildJsonObject {
            put("event_type", type); put("message_id", message.value); put("room_id", room.value); put("message_revision", revision); put("sender_user_id", actor.value)
            put("text", "forwarded"); put("timeline_sequence", 1); put("server_created_at_ms", 1000); put("forwarded_from_message_id", origin)
            originSender?.let { put("forwarded_from_user_id", it) }
        }
        suspend fun apply(sequence: Long, value: JsonObject) = store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence)
            .addEvents(GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId(id()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(value.toString()))).build(), store.roomCursor(room))
        try { apply(1, body("message.accepted", 1, null)); fail("partial attribution accepted") } catch (_: ClientFailure.Protocol) { }
        apply(1, body("message.accepted", 1)); store.close(); store = store()
        assertEquals(ForwardAttribution(MessageId(origin), UserId(originActor)), store.snapshot().messages.single().forwardedFrom)
        try { apply(2, body("message.accepted", 1, id())); fail("same revision changed origin") } catch (_: ClientFailure.Protocol) { }
        apply(2, body("message.edited", 2)); assertNotNull(store.snapshot().messages.single().forwardedFrom)
        apply(3, body("message.withdrawn", 3)); assertNull(store.snapshot().messages.single().forwardedFrom)
        store.close()
    }
}
