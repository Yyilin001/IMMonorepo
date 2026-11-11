package com.xmtx.im.client

import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

internal fun reactionIntent(reaction: String = "👍", present: Boolean = true) = ReactionIntent(actorId, personalRoom, personalMessage, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", normalizedReaction(reaction), present, 596000)
internal fun reactionBaseline(intent: ReactionIntent, revision: Long = 0) = buildJsonObject {
    put("actorUserID", wireId(intent.actor.value)); put("roomID", wireId(intent.room.value)); put("messageID", wireId(intent.message.value))
    put("reaction", intent.reaction); put("targetState", if(revision > 0) "present" else "absent"); put("revision", revision)
}
internal fun reactionReceipt(command: ReactionCommand, conflict: Boolean = false, event: Boolean = true) = buildJsonObject {
    put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", 3000)
    put("outcome", if(conflict) buildJsonObject { put("rejected", buildJsonObject { put("_0", buildJsonObject { put("revisionConflict", buildJsonObject { put("current", command.revision + 1) }) }) }) }
    else buildJsonObject { put("committed", buildJsonObject { put("_0", buildJsonObject {
        put("targetState", if(command.intent.present) "present" else "absent"); put("revision", command.revision + 1)
        if(event) put("event", buildJsonObject { put("roomSequence", 6); put("eventID", wireId("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")) })
    }) }) })
}
private class MemoryReactions : MessageReactionStore {
    val works = mutableListOf<ReactionWork>()
    override suspend fun reactionWorks() = works.toPersistentList()
    override suspend fun enqueueReaction(intent: ReactionIntent) = ReactionWork(intent).also(works::add)
    override suspend fun updateReaction(expected: ReactionWork, updated: ReactionWork) {
        check(expected.intent == updated.intent); if(expected.command != null) check(expected.command == updated.command)
        val index = works.indexOf(expected); check(index >= 0); works[index] = updated
    }
}
class MessageReactionTests {
    @Test fun `canonical commands fingerprints receipts and close recovery match actual Swift`() {
        val lines = javaClass.getResourceAsStream("/message-reactions-swift.txt")!!.bufferedReader().readLines()
        listOf(ReactionCommand(reactionIntent("é"), 0), ReactionCommand(reactionIntent(present = false), 4), ReactionCommand(reactionIntent("❤️", false), 0)).forEachIndexed { index, command ->
            assertEquals(lines[index * 4], command.fingerprint); assertEquals(Json.parseToJsonElement(lines[index * 4 + 1]), command.payload())
            assertEquals(Json.parseToJsonElement(lines[index * 4 + 3]), command.recovery(true))
            val receipt = MessageReactionClient.decodeReceipt(command, Json.parseToJsonElement(lines[index * 4 + 2]).jsonObject)
            assertEquals(ReactionStatus.Committed, receipt.status); assertEquals(command.revision + 1, receipt.commit!!.revision)
            if(index == 2) assertNull(receipt.commit.event) else assertEquals(6, receipt.commit.event!!.sequence)
        }
    }
    @Test fun `public reaction effect requires typed key and room sequence independent of message revision`() {
        val value = buildJsonObject {
            put("event_type", "message.reaction_changed"); put("room_id", personalRoom.value); put("message_id", personalMessage.value); put("actor_user_id", actorId.value)
            put("reaction", "1"); put("action", "remove"); put("room_sequence", 9)
        }
        val effect = ReactionEffect.decode("event", value, 9); assertFalse(effect.present); assertEquals(9, effect.sequence)
        assertFails { ReactionEffect.decode("event", value, 8) }
        assertFails { ReactionEffect.decode("event", JsonObject(value + ("reaction" to JsonPrimitive(1))), 9) }
        assertFails { ReactionEffect.decode("event", JsonObject(value + ("room_sequence" to JsonPrimitive("9"))), 9) }
    }
    @Test fun `NFC key limits and control characters match Foundation contract`() {
        assertEquals("é", normalizedReaction("é")); assertEquals("👍".repeat(4), normalizedReaction("👍".repeat(4)))
        listOf("", "a b", "a\n", "a\u0085", "a\u00a0", "a\u200b", "a\u200d", "a\ufeff", "👍".repeat(5), "\ud800").forEach { assertFails(it) { normalizedReaction(it) } }
        assertEquals(ReactionCommand(reactionIntent("é"), 0).fingerprint, ReactionCommand(reactionIntent("é"), 0).fingerprint)
        assertFails { ReactionCommand(reactionIntent(), -1) }; assertFails { ReactionCommand(reactionIntent(), Long.MAX_VALUE) }
    }
    @Test fun `baseline binds actor and key with zero revision only absent`() = runTest {
        val intent = reactionIntent()
        val transport = object : AuthenticatedTransport {
            override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
                assertEquals("/v2/rooms/${intent.room.value}/message-reactions/${intent.message.value}", path); assertNull(payload)
                assertEquals("reaction" to "👍", query); assertEquals(65536, maximumBytes)
                return EdgeResponse(200, reactionBaseline(intent))
            }
        }
        assertEquals(0, MessageReactionClient(transport).baseline(intent).revision)
        val bad = FakeEdge { _, _ -> EdgeResponse(200, reactionBaseline(intent.copy(actor = targetId))) }
        assertFails { MessageReactionClient(bad).baseline(intent) }
        bad.answer = { _, _ -> EdgeResponse(200, JsonObject(reactionBaseline(intent) + ("targetState" to JsonPrimitive("present")))) }
        assertFails { MessageReactionClient(bad).baseline(intent) }
    }
    @Test fun `receipt rejects mismatched proof target version and invalid event but accepts no-op commit`() {
        val command = ReactionCommand(reactionIntent(), 0); val receipt = reactionReceipt(command)
        assertFails { MessageReactionClient.decodeReceipt(command.copy(intent = command.intent.copy(present = false)), receipt) }
        listOf("\"revision\":1" to "\"revision\":2", "\"targetState\":\"present\"" to "\"targetState\":\"absent\"", "\"roomSequence\":6" to "\"roomSequence\":0", "\"resolvedAtMilliseconds\":3000" to "\"resolvedAtMilliseconds\":\"3000\"").forEach { (old,new) ->
            assertFails { MessageReactionClient.decodeReceipt(command, Json.parseToJsonElement(receipt.toString().replace(old,new)).jsonObject) }
        }
        assertNull(MessageReactionClient.decodeReceipt(command, reactionReceipt(command, event = false)).commit!!.event)
    }
    @Test fun `durable preparation freezes fresh revision and restart recovers original command`() = runTest {
        val store = MemoryReactions(); var now = 1000L
        val api = FakeEdge { _, _ -> EdgeResponse(200, reactionBaseline(store.works.single().intent, 8)) }
        var service = MessageReactionService(actorId, MessageReactionClient(api), store, { now })
        service.enqueue(personalRoom, personalMessage, "é", true); service.flush()
        val command = store.works.single().command!!; assertEquals(8, command.revision); assertEquals(596000, command.intent.deadline)
        api.answer = { path, body -> assertTrue(path.endsWith("/change")); assertTrue(store.works.single().reconcile); assertEquals(command.payload(), body); assertCommandAttempt(false); throw IOException("reply lost") }
        service.flush(); now = 4000
        api.answer = { path, body -> assertCommandAttempt(true); assertTrue(path.endsWith("/operations/recover")); assertEquals(command.recovery(false), body); EdgeResponse(200, directResult("receipt", reactionReceipt(command))) }
        service = MessageReactionService(actorId, MessageReactionClient(api), store, { now }); service.flush()
        assertEquals(ReactionStatus.Committed, store.works.single().status); assertEquals(command, store.works.single().command)
    }
    @Test fun `baseline budget and retry floor survive explicit resume without renewing intent`() = runTest {
        val store = MemoryReactions(); var now = 1000L
        val api = FakeEdge { _, _ -> EdgeResponse(429, buildJsonObject {}, "90") }
        val service = MessageReactionService(actorId, MessageReactionClient(api, { now }), store, { now })
        service.enqueue(personalRoom, personalMessage, "👍", true); service.flush()
        val saved = store.works.single(); assertEquals(ReactionStatus.PreparationPaused, saved.status); assertEquals(91000, saved.nextAttempt)
        service.retry(saved.intent.operation); assertEquals(saved.intent, store.works.single().intent)
        api.answer = { _, _ -> error("called before server floor") }; service.flush()
        now = 92000; api.answer = { _, _ -> EdgeResponse(200, reactionBaseline(saved.intent)) }; service.flush()
        assertEquals(ReactionStatus.Pending, store.works.single().status)
    }
    @Test fun `frozen expiry closes exact identity while conflict never rebases and next key can progress`() = runTest {
        val store = MemoryReactions(); val intent = reactionIntent(); val command = ReactionCommand(intent, 0)
        store.works += ReactionWork(intent, command, ReactionStatus.Pending)
        val api = FakeEdge { _, body -> assertEquals(command.recovery(true), body); EdgeResponse(200, directResult("receipt", reactionReceipt(command, conflict = true))) }
        MessageReactionService(actorId, MessageReactionClient(api), store, { 600000 }).flush(); assertEquals(ReactionStatus.Conflicted, store.works.single().status)
        val draft = intent.copy(operation = "11111111-1111-1111-1111-111111111111")
        store.works += ReactionWork(draft); api.answer = { _, _ -> error("expired draft network") }
        MessageReactionService(actorId, MessageReactionClient(api), store, { 600000 }).flush(); assertEquals(ReactionStatus.Expired, store.works.last().status)
    }
    @Test fun `unknown head blocks only same actor reaction key and bound defer respects header floor`() = runTest {
        val store = MemoryReactions(); val intent = reactionIntent()
        store.works += ReactionWork(intent, ReactionCommand(intent, 0), ReactionStatus.NeedsAttention)
        store.works += ReactionWork(intent.copy(operation = "11111111-1111-1111-1111-111111111111", present = false))
        val other = intent.copy(operation = "22222222-2222-2222-2222-222222222222", reaction = "😂")
        val command = ReactionCommand(other, 0); store.works += ReactionWork(other, command, ReactionStatus.Pending,executionStarted=false)
        val hint = buildJsonObject { put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("reason", "rateLimited"); put("retryAfterMilliseconds", 5000) }
        val api = FakeEdge { _, body -> assertEquals(command.payload(), body); EdgeResponse(429, directResult("deferred", hint), "90") }
        MessageReactionService(actorId, MessageReactionClient(api), store, { 1000 }).flush()
        assertEquals(0, store.works[1].preparationAttempts); assertEquals(91000, store.works[2].nextAttempt)
        api.answer = { _, _ -> EdgeResponse(503, directResult("deferred", JsonObject(hint + ("fingerprint" to fingerprintPayload("foreign"))))) }
        assertFails { MessageReactionClient(api).execute(command, true, false) }
    }
    @Test fun `legacy frozen reaction queries before resubmitting and retains retry metadata`() = runTest {
        val intent=reactionIntent();val command=ReactionCommand(intent,0);var now=1000L
        val store=MemoryReactions();store.works+=ReactionWork(intent,command,ReactionStatus.Pending)
        val diagnostics=NetworkDiagnostics();var calls=0
        val api=FakeEdge {path,body->
            calls++;assertCommandAttempt(true)
            if(calls==1) {
                assertTrue(path.endsWith("/operations/recover"));assertEquals(command.recovery(false),body)
                EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})
            } else {
                assertEquals(command.payload(),body)
                EdgeResponse(200,directResult("receipt",reactionReceipt(command)))
            }
        }
        withContext(NetworkDiagnosticsScope(diagnostics)) {
            val service=MessageReactionService(actorId,MessageReactionClient(api),store,{now})
            service.flush();assertTrue(store.works.single().executionStarted==true);assertFalse(store.works.single().reconcile)
            now=store.works.single().nextAttempt;service.flush()
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(listOf(OperationWorkAction.Reconcile,OperationWorkAction.Submit),samples.map {it.action})
        assertTrue(samples.all {it.priority==NetworkWorkPriority.Recovery && it.kind==OperationKind.Reaction})
        assertEquals(NetworkMetric.Certainty.OutcomeUnknown,samples.first().certainty)
        assertEquals(NetworkMetric.Certainty.ResponseReceived,samples.last().certainty)
        assertEquals(command,store.works.single().command);assertEquals(2,calls)
    }

}
