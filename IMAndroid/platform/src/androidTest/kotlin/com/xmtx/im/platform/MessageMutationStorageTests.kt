package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class MessageMutationStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId(UUID.randomUUID().toString()); private val device = DeviceId(UUID.randomUUID().toString())
    private val room = RoomId(UUID.randomUUID().toString()); private val message = MessageId(UUID.randomUUID().toString())
    private fun id() = UUID.randomUUID().toString().uppercase()
    private fun store() = SqliteClientStore(context, actor, device)
    private fun payload(type: String, revision: Long, body: String = "original") = buildJsonObject {
        MessageRichContent.Empty.payload().forEach { (k,v)->put(k,v) }
        put("event_type", type); put("message_id", message.value); put("room_id", room.value); put("message_revision", revision)
        put("sender_user_id", actor.value); put("text", body); put("timeline_sequence", 1); put("server_created_at_ms", 1000)
    }
    private suspend fun apply(store: SqliteClientStore, sequence: Long, value: JsonObject) {
        val page = GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence).addEvents(GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId("mutation-$sequence").setProjectionKind("message").setPayload(ByteString.copyFromUtf8(value.toString()))).build()
        store.commitRoom(page, store.roomCursor(room))
    }
    private fun receipt(command: MessageMutationCommand) = buildJsonObject {
        put("identity", command.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) }); put("resolvedAtMilliseconds", 3000)
        put("outcome", buildJsonObject { put("committed", buildJsonObject { put("_0", buildJsonObject {
            put("messageID", buildJsonObject { put("rawValue", message.value) }); put("messageRevision", command.revision + 1); put("roomSequence", 2); put("eventID", buildJsonObject { put("rawValue", id()) })
        }) }) })
    }.toString()
    @Test fun cancelledMutationRetainsRetryEvidenceAndOriginalCommandAcrossReopen() = runBlocking {
        val diagnostics=NetworkDiagnostics()
        kotlinx.coroutines.withContext(NetworkDiagnosticsScope(diagnostics)) {
        for(text in listOf("changed", null)) {
            var store = store(); var now = 1000L; var calls = 0
            val command = MessageMutationCommand(actor, room, MessageId(id()), id(), 1, text, 596000)
            val transport = object: AuthenticatedTransport {
                override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
                    calls++; val intent = requireNotNull(currentCoroutineContext()[NetworkWorkIntent])
                    assertEquals(calls > 1, intent.isRetry)
                    assertEquals(if(calls == 1) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery, intent.priority)
                    assertEquals(true, store.mutationWorks().first { it.command == command }.executionStarted)
                    if(calls == 2) {
                        assertTrue(path.endsWith("/recover")); assertEquals(command.recovery(false), payload)
                        return EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
                    }
                    assertTrue(path.endsWith(if(text == null) "/withdraw" else "/edit")); assertEquals(command.payload(), payload)
                    throw CancellationException("fixture interruption")
                }
            }
            fun service() = MessageMutationService(actor, MessageMutationClient(transport), store, {now})
            suspend fun work() = store.mutationWorks().first { it.command == command }
            suspend fun manualRetry() {
                val current = work(); store.updateMutation(current, current.copy(status = MutationStatus.NeedsAttention))
                service().retry(command.operation); assertEquals(0, work().attempts)
            }
            try {
                assertEquals(false, store.enqueueMutation(command).executionStarted)
                try { service().flush(); fail("expected interruption") } catch(_: CancellationException) {}
                store.close(); store = store()
                val saved = work(); assertEquals(true, saved.executionStarted); assertEquals(0, saved.attempts)
                try { store.updateMutation(saved, saved.copy(executionStarted = false)); fail("erased execution history") } catch(_: IllegalArgumentException) {}
                manualRetry(); service().flush(); assertFalse(work().reconcile)
                now = work().nextAttempt; store.close(); store = store(); manualRetry()
                try { service().flush(); fail("expected interruption") } catch(_: CancellationException) {}
                assertEquals(3, calls); assertEquals(command, work().command)
                // Keep this unresolved fixture from executing during the next loop iteration.
                val pending = work(); store.updateMutation(pending, pending.copy(status = MutationStatus.NeedsAttention))
            } finally { store.close() }
        }
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(6,samples.size)
        assertEquals(4,samples.count {it.completion==OperationStepMetric.Completion.Cancelled})
        assertTrue(samples.all {it.certainty==NetworkMetric.Certainty.OutcomeUnknown})
    }

    @Test fun originalCommandCoalescesAcrossReopenAndCommitNeverProjectsUnobservedContent() = runBlocking {
        var store = store(); store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
        apply(store, 1, payload("message.accepted", 1))
        val command = MessageMutationCommand(actor, room, message, id(), 1, "changed", 596000)
        val original = store.enqueueMutation(command)
        val same = store.enqueueMutation(command.copy(operation = id(), deadline = 700000))
        assertEquals(original, same)
        try { store.enqueueMutation(command.copy(operation = id(), text = "different")); fail("replaced unknown edit") } catch (_: IllegalStateException) { }
        try { store.updateMutation(original, original.copy(command = command.copy(revision = 2))); fail("rebased command") } catch (_: IllegalArgumentException) { }
        store.close(); store = store(); assertEquals(original, store.mutationWorks().single())
        assertEquals(original,store.mutationWork(command.operation));assertNull(store.mutationWork(id()))
        store.updateMutation(original, original.copy(status = MutationStatus.Committed, receipt = receipt(command)))
        assertEquals("original", store.snapshot().messages.single().text); assertEquals(1L, store.snapshot().messages.single().revision)
        apply(store, 2, payload("message.edited", 2, "changed"))
        assertEquals("changed", store.snapshot().messages.single().text); assertEquals(2L, store.snapshot().messages.single().revision)
        store.close()
    }
    @Test fun editsValidateVersionsAndWithdrawalTombstoneCannotBeResurrected() = runBlocking {
        var store = store(); store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
        apply(store, 1, payload("message.accepted", 1)); apply(store, 2, payload("message.edited", 2, "edited"))
        try { apply(store, 3, payload("message.edited", 2, "conflicting")); fail("same revision changed") } catch (_: ClientFailure.Protocol) { }
        assertEquals(2L, store.roomCursor(room).sequence)
        try { apply(store, 3, payload("message.edited", 4, "gap")); fail("missing baseline") } catch (_: ClientFailure.Protocol) { }
        apply(store, 3, payload("message.withdrawn", 3))
        store.close(); store = store()
        apply(store, 4, payload("message.accepted", 1)); apply(store, 5, payload("message.edited", 2, "late"))
        assertTrue(store.snapshot().messages.single().withdrawn); assertEquals("消息已撤回", store.snapshot().messages.single().text)
        try { apply(store, 6, payload("message.accepted", 4, "resurrection")); fail("resurrected message") } catch (_: ClientFailure.Protocol) { }
        assertEquals(5L, store.roomCursor(room).sequence); store.close()
    }
    @Test fun withdrawalBeforeAcceptedAndSelfContainedReplacementRespectIdentityAndTombstone() = runBlocking {
        val store = store(); store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
        fun replacement(revision: Long, roomValue: String = room.value) = buildJsonObject {
            put("event_type", "message.edited"); put("room_id", room.value); put("message_id", message.value); put("message_revision", revision)
            put("replacement", buildJsonObject { put("schema_version", 1); put("accepted_membership_revision", 1); put("accepted_event_id", "accepted-origin")
                put("state", JsonObject(payload("message.accepted", revision, "replacement") + mapOf("room_id" to JsonPrimitive(roomValue),"room_sequence" to JsonPrimitive(1),"media_ids" to JsonArray(emptyList()),"media_presentations" to JsonArray(emptyList())))) })
        }
        try { apply(store, 1, replacement(5, id())); fail("foreign replacement") } catch (_: ClientFailure.Protocol) { }
        apply(store, 1, replacement(5)); assertEquals(5L, store.snapshot().messages.single().revision)
        store.unavailable(room); store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(2).setHead(20).build())
        apply(store, 1, payload("message.withdrawn", 2)); apply(store, 2, payload("message.accepted", 1))
        assertTrue(store.snapshot().messages.isEmpty())
        try { apply(store, 3, replacement(3)); fail("replacement bypassed tombstone") } catch (_: ClientFailure.Protocol) { }
        assertEquals(2L, store.roomCursor(room).sequence); store.close()
    }
}
