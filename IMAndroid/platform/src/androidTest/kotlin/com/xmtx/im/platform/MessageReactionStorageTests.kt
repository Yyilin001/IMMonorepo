package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class MessageReactionStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId(UUID.randomUUID().toString()); private val peer = UserId(UUID.randomUUID().toString())
    private val device = DeviceId(UUID.randomUUID().toString()); private val room = RoomId(UUID.randomUUID().toString()); private val message = MessageId(UUID.randomUUID().toString())
    private fun id() = UUID.randomUUID().toString().uppercase()
    private fun store() = SqliteClientStore(context, actor, device)
    private fun intent(present: Boolean = true) = ReactionIntent(actor, room, message, id(), "👍", present, 596000)
    private fun messagePayload(withdrawn: Boolean = false) = buildJsonObject {
        put("event_type", if(withdrawn) "message.withdrawn" else "message.accepted"); put("message_id", message.value); put("room_id", room.value)
        put("message_revision", if(withdrawn) 2 else 1); put("sender_user_id", actor.value); put("text", "original"); put("timeline_sequence", 1); put("server_created_at_ms", 1000)
    }
    private fun reaction(sequence: Long, actor: UserId = this.actor, present: Boolean = true, key: String = "👍") = buildJsonObject {
        put("event_type", "message.reaction_changed"); put("room_id", room.value); put("message_id", message.value); put("actor_user_id", actor.value)
        put("reaction", key); put("action", if(present) "add" else "remove"); put("room_sequence", sequence)
    }
    private suspend fun apply(store: SqliteClientStore, sequence: Long, value: JsonObject, source: String = id(), kind: String = "message_reaction") {
        store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence).addEvents(GroupEvent.newBuilder().setRoomSequence(sequence)
            .setSourceEventId(source).setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(value.toString()))).build(), store.roomCursor(room))
    }
    private fun receipt(command: ReactionCommand) = buildJsonObject {
        put("identity", command.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) }); put("resolvedAtMilliseconds", 3000)
        put("outcome", buildJsonObject { put("committed", buildJsonObject { put("_0", buildJsonObject { put("targetState", if(command.intent.present) "present" else "absent"); put("revision", command.revision + 1) }) }) })
    }.toString()
    @Test fun unfrozenTargetsCoalesceWithoutRenewingBudgetAndFrozenCommandsSurviveReopen() = runBlocking {
        var store = store(); val initial = store.enqueueReaction(intent())
        val paused = initial.copy(status = ReactionStatus.PreparationPaused, preparationAttempts = 3, preparationStarted = 1000, nextAttempt = 90000)
        store.updateReaction(initial, paused)
        val merged = store.enqueueReaction(intent(false).copy(deadline = 999999))
        assertEquals(paused.copy(intent = paused.intent.copy(present = false)), merged)
        val command = ReactionCommand(merged.intent, 7); val frozen = merged.copy(executionStarted = true,command = command, status = ReactionStatus.Pending)
        store.updateReaction(merged, frozen)
        try { store.updateReaction(frozen, frozen.copy(executionStarted = false)); fail("erased execution evidence") } catch (_: IllegalArgumentException) { }
        val next = store.enqueueReaction(intent()); assertNotEquals(frozen.intent.operation, next.intent.operation)
        try { store.updateReaction(frozen, frozen.copy(command = command.copy(revision = 8))); fail("frozen command rebased") } catch (_: IllegalArgumentException) { }
        store.close(); store = store(); assertEquals(listOf(frozen, next), store.reactionWorks())
        assertEquals(frozen,store.reactionWork(frozen.intent.operation));assertNull(store.reactionWork(id()))
        store.updateReaction(frozen, frozen.copy(status = ReactionStatus.Committed, receipt = receipt(command)))
        assertTrue(store.snapshot().reactions.isEmpty())
        store.close()
    }
    @Test fun independentActorKeysAggregateAndSourceConflictsRollbackBeforeWithdrawAndRevocationHideCounts() = runBlocking {
        var store = store(); store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
        apply(store, 1, messagePayload(), kind = "message")
        val source = id(); apply(store, 2, reaction(2), source); apply(store, 3, reaction(3, peer))
        var summary = store.snapshot().reactions.single(); assertEquals(2, summary.count); assertTrue(summary.own)
        try { apply(store, 4, reaction(4, present = false), source); fail("reused source accepted") } catch (_: ClientFailure.Protocol) { }
        assertEquals(3L, store.roomCursor(room).sequence); assertEquals(2, store.snapshot().reactions.single().count)
        apply(store, 4, reaction(4, present = false)); summary = store.snapshot().reactions.single(); assertEquals(1, summary.count); assertFalse(summary.own)
        apply(store, 5, reaction(5, key = "❤️")); store.close(); store = store()
        assertEquals(2, store.snapshot().reactions.size)
        apply(store, 6, messagePayload(true), kind = "message"); assertTrue(store.snapshot().reactions.isEmpty())
        apply(store, 7, reaction(7)); assertTrue(store.snapshot().reactions.isEmpty())
        store.unavailable(room); assertTrue(store.snapshot().reactions.isEmpty())
        try { store.enqueueReaction(intent()); fail("revoked room accepted intent") } catch (_: IllegalStateException) { }
        store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(2).setHead(20).build())
        apply(store, 1, messagePayload(), kind = "message"); assertTrue(store.snapshot().reactions.isEmpty())
        store.close()
    }
    @Test fun missingContentNeverDisplaysCountsAndMalformedSequenceLeavesCursorUnchanged() = runBlocking {
        val store = store(); store.acceptState(room, RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
        apply(store, 1, reaction(1)); assertTrue(store.snapshot().reactions.isEmpty())
        try { apply(store, 2, JsonObject(reaction(2) + ("room_sequence" to JsonPrimitive("2")))); fail("string sequence accepted") } catch (_: ClientFailure.Protocol) { }
        assertEquals(1L, store.roomCursor(room).sequence)
        apply(store, 2, messagePayload(true), kind = "message")
        apply(store, 3, messagePayload(), kind = "message"); assertTrue(store.snapshot().reactions.isEmpty()); assertTrue(store.snapshot().messages.isEmpty())
        store.close()
    }
    @Test fun legacyFrozenReactionQueriesBeforeReplayAfterDatabaseReopen() = runBlocking {
        var store=store();var now=1000L;var calls=0;val diagnostics=NetworkDiagnostics()
        try {
            val draft=store.enqueueReaction(intent());val command=ReactionCommand(draft.intent,7)
            store.updateReaction(draft,draft.copy(command=command,status=ReactionStatus.Pending))
            store.close();store=store();assertNull(store.reactionWork(command.intent.operation)!!.executionStarted)
            val transport=object:AuthenticatedTransport {
                override suspend fun request(path:String,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse {
                    calls++;assertTrue(kotlinx.coroutines.currentCoroutineContext()[NetworkWorkIntent]!!.isRetry)
                    if(calls==1) {
                        assertEquals(command.recovery(false),payload);assertTrue(path.endsWith("/operations/recover"))
                        return EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})
                    }
                    assertEquals(command.payload(),payload)
                    return EdgeResponse(200,buildJsonObject {put("receipt",buildJsonObject {put("_0",Json.parseToJsonElement(receipt(command)))})})
                }
            }
            kotlinx.coroutines.withContext(NetworkDiagnosticsScope(diagnostics)) {
                val service=MessageReactionService(actor,MessageReactionClient(transport),store,{now})
                service.flush();now=store.reactionWork(command.intent.operation)!!.nextAttempt;service.flush()
            }
            assertEquals(2,calls);assertEquals(ReactionStatus.Committed,store.reactionWork(command.intent.operation)!!.status)
            assertEquals(listOf(OperationWorkAction.Reconcile,OperationWorkAction.Submit),diagnostics.snapshot().operations.map {it.action})
            assertEquals(OperationExecutionState.Committed,diagnostics.snapshot().operations.last().observation!!.execution)
        } finally {store.close()}
    }

}
