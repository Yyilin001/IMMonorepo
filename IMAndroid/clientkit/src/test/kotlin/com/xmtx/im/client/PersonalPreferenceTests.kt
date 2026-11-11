package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.IOException
import java.util.Base64
import kotlin.test.*

internal val personalRoom = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
internal val personalMessage = MessageId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
internal fun personalCommand(target: PersonalTarget = PersonalTarget.Conversation(personalRoom, true)) = PersonalCommand(actorId, "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", target, 7, 1700604795000)
internal fun personalWire(command: PersonalCommand): PersonalPreferenceReceipt = PersonalPreferenceReceipt.newBuilder().setActorUserId(command.actor.value).setRoomId(command.target.room.value).setOperationId(command.operation)
    .setFingerprintVersion(1).setFingerprint(ByteString.copyFrom(Base64.getDecoder().decode(command.fingerprint))).setResolvedAtMs(1700000000330).apply {
        when(val target = command.target) {
            is PersonalTarget.Conversation -> setKind(PersonalPreferenceReceipt.Kind.CONVERSATION_STATE).setConversationState(ConversationStateSet.newBuilder().setRoomId(target.room.value).setIsPinned(target.pinned).setIsArchived(target.archived).setMuteUntilMs(target.muteUntil).setRevision(command.revision + 1).setUpdatedAtMs(1700000000330))
            is PersonalTarget.Favorite -> setKind(PersonalPreferenceReceipt.Kind.MESSAGE_FAVORITE).setMessageId(target.message.value).setMessageFavorite(MessageFavoriteChanged.newBuilder().setRoomId(target.room.value).setMessageId(target.message.value).setIsFavorited(target.favorited).setRevision(command.revision + 1).setUpdatedAtMs(1700000000330))
        }
    }.build()
private class FrozenPersonalStore(var work: PersonalWork) : PersonalPreferenceStore {
    override suspend fun personalWorks() = persistentListOf(work)
    override suspend fun enqueueConversation(room: RoomId, patch: ConversationPatch, now: Long): PersonalWork = error("not used")
    override suspend fun enqueueFavorite(room: RoomId, message: MessageId, favorite: Boolean, now: Long): PersonalWork = error("not used")
    override suspend fun preparePersonal(now: Long) { }
    override suspend fun updatePersonal(expected: PersonalWork, updated: PersonalWork) { check(expected == work); check(expected.command == updated.command); work = updated }
}
class PersonalPreferenceTests {
    @Test fun `cancelled realtime preferences retain retry across HTTP recovery and exact realtime replay`() = runTest {
        val diagnostics=NetworkDiagnostics()
        withContext(NetworkDiagnosticsScope(diagnostics)) {
        for(target in listOf(PersonalTarget.Conversation(personalRoom, true), PersonalTarget.Favorite(personalRoom, personalMessage, true))) {
            val command = personalCommand(target); var now = 1700000000000L; var submissions = 0
            val store = FrozenPersonalStore(PersonalWork(actorId, command.operation, target, command.deadline, PersonalStatus.Pending, command))
            val tcp = object: EnvelopeTransport {
                override suspend fun request(body: Envelope.Builder): Envelope {
                    submissions++; assertCommandAttempt(submissions > 1); assertEquals(command.envelope().build(), body.build())
                    throw CancellationException("fixture interruption")
                }
            }
            val api = FakeEdge { _, body ->
                assertCommandAttempt(true); assertEquals(command.recovery(false), body)
                EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
            }
            fun service() = PersonalPreferenceService(actorId, PersonalPreferenceClient(tcp, api), store, {now})
            assertFailsWith<CancellationException> { service().flush() }
            assertEquals(0, store.work.attempts)
            store.work = Json.decodeFromString<PersonalWork>(Json.encodeToString(PersonalWork.serializer(), store.work))
            assertTrue(store.work.submissionStarted)
            store.work = store.work.copy(status = PersonalStatus.NeedsAttention); service().retry(command.operation)
            service().flush(); assertFalse(store.work.reconcile); now = store.work.nextAttempt
            store.work = store.work.copy(status = PersonalStatus.NeedsAttention); service().retry(command.operation)
            assertFailsWith<CancellationException> { service().flush() }
            assertEquals(2, submissions); assertEquals(command, store.work.command)
        }
        }
        val samples=diagnostics.snapshot().operations
        assertEquals(6,samples.size)
        assertEquals(setOf(OperationKind.ConversationPreference,OperationKind.MessageFavorite),samples.map {it.kind}.toSet())
        assertEquals(4,samples.count {it.completion==OperationStepMetric.Completion.Cancelled})
        assertTrue(samples.all {it.certainty==NetworkMetric.Certainty.OutcomeUnknown})
    }

    @Test fun `Swift fingerprints recovery and receipts match for mute absence precision and favorite`() {
        val lines = javaClass.getResourceAsStream("/personal-preferences-swift.txt")!!.bufferedReader().readLines()
        val targets = listOf(PersonalTarget.Conversation(personalRoom, true), PersonalTarget.Conversation(personalRoom, true, false, 1700003600330), PersonalTarget.Favorite(personalRoom, personalMessage, true))
        targets.forEachIndexed { index, target ->
            val command = personalCommand(target)
            assertEquals(lines[index * 3], command.fingerprint)
            assertEquals(Json.parseToJsonElement(lines[index * 3 + 2]), command.recovery(false))
            val http = PersonalPreferenceClient.decodeReceipt(command, Json.parseToJsonElement(lines[index * 3 + 1]).jsonObject)
            val tcp = PersonalPreferenceClient.decodeWire(command, personalWire(command))
            assertEquals(PersonalState(target, 8, 1700000000330), http.state); assertEquals(http.state, tcp.state)
            assertEquals(PersonalStatus.Committed, tcp.status)
            val envelope = command.envelope().setProtocolVersion(55).setRequestId(1).build()
            assertEquals(envelope, FrameCodec.read(FrameCodec.encode(envelope).inputStream()))
        }
    }
    @Test fun `integer wire milliseconds never lose a millisecond during receipt persistence`() {
        val command = personalCommand(); val wire = personalWire(command)
        for(offset in 0L..999L) {
            val time = 1700000000000L + offset
            val changed = wire.toBuilder().setConversationState(wire.conversationState.toBuilder().setUpdatedAtMs(time)).build()
            assertEquals(time, PersonalPreferenceClient.decodeWire(command, changed).state!!.updatedAt, "offset $offset")
        }
    }
    @Test fun `protobuf proof rejects foreign actor scope kind value revision and malformed rejection`() {
        val command = personalCommand(); val wire = personalWire(command)
        listOf(wire.toBuilder().setActorUserId(targetId.value), wire.toBuilder().setMessageId(personalMessage.value), wire.toBuilder().setKind(PersonalPreferenceReceipt.Kind.MESSAGE_FAVORITE),
            wire.toBuilder().setConversationState(wire.conversationState.toBuilder().setIsArchived(true)), wire.toBuilder().setConversationState(wire.conversationState.toBuilder().setRevision(9)),
            wire.toBuilder().setClosed(false), wire.toBuilder().setRejected(PersonalPreferenceRejection.newBuilder().setReason(PersonalPreferenceRejection.Reason.REVISION_CONFLICT)),
            wire.toBuilder().setRejected(PersonalPreferenceRejection.newBuilder().setReason(PersonalPreferenceRejection.Reason.NOT_FOUND).setCurrentRevision(0))
        ).forEach { assertFails { PersonalPreferenceClient.decodeWire(command, it.build()) } }
        assertEquals(PersonalStatus.Conflicted, PersonalPreferenceClient.decodeWire(command, wire.toBuilder().setRejected(PersonalPreferenceRejection.newBuilder().setReason(PersonalPreferenceRejection.Reason.REVISION_CONFLICT).setCurrentRevision(0)).build()).status)
    }
    @Test fun `recovery binding and projection reject quoted booleans and fractional milliseconds`() {
        val command = personalCommand()
        val receipt = PersonalPreferenceClient.decodeWire(command, personalWire(command)).wire
        assertFails { PersonalPreferenceClient.decodeReceipt(command.copy(actor = targetId), Json.parseToJsonElement(receipt).jsonObject) }
        assertEquals(1700000000330, PersonalPreferenceClient.decodeReceipt(command, Json.parseToJsonElement(receipt.replace("721692800.330", "721692800.330789")).jsonObject).state!!.updatedAt)
        val muted = personalCommand(PersonalTarget.Conversation(personalRoom, true, false, 1700003600330))
        val mutedReceipt = PersonalPreferenceClient.decodeWire(muted, personalWire(muted)).wire
        assertFails { PersonalPreferenceClient.decodeReceipt(muted, Json.parseToJsonElement(mutedReceipt.replace("721696400.330", "721696400.3305")).jsonObject) }
        val projection = buildJsonObject { put("room_id", personalRoom.value); put("is_pinned", true); put("is_archived", false); put("mute_until_ms", 0); put("revision", 1); put("updated_at_ms", 100) }
        assertEquals(1, PersonalState.projection("conversation_state", projection).revision)
        assertFails { PersonalState.projection("conversation_state", JsonObject(projection + ("is_pinned" to JsonPrimitive("true")))) }
        assertFails { PersonalState.projection("conversation_state", JsonObject(projection + ("revision" to JsonPrimitive(0)))) }
    }
    @Test fun `lost submit response persists uncertainty and restart recovers original command`() = runTest {
        val command = personalCommand(); var now = 1700000000000L
        val store = FrozenPersonalStore(PersonalWork(actorId, command.operation, command.target, command.deadline, PersonalStatus.Pending, command))
        val tcp = object : EnvelopeTransport { override suspend fun request(body: Envelope.Builder): Envelope {
            assertCommandAttempt(false); assertTrue(store.work.submissionStarted && store.work.reconcile); assertEquals(command.envelope().build(), body.build()); throw IOException("lost reply")
        } }
        val api = FakeEdge { path, body -> assertCommandAttempt(true); assertTrue(path.endsWith("/personal-preferences/operations/recover")); assertEquals(command.recovery(false), body)
            EdgeResponse(200, directResult("receipt", Json.parseToJsonElement(PersonalPreferenceClient.decodeWire(command, personalWire(command)).wire).jsonObject)) }
        PersonalPreferenceService(actorId, PersonalPreferenceClient(tcp, api), store, { now }).flush()
        assertTrue(store.work.reconcile); assertEquals(PersonalStatus.Pending, store.work.status)
        now += 3000
        PersonalPreferenceService(actorId, PersonalPreferenceClient(tcp, api), store, { now }).flush()
        assertEquals(PersonalStatus.Committed, store.work.status)
    }
    @Test fun `expired commands only close original identity and rejected versions never rebase`() = runTest {
        val command = personalCommand(); val store = FrozenPersonalStore(PersonalWork(actorId, command.operation, command.target, command.deadline, PersonalStatus.Pending, command))
        val tcp = object : EnvelopeTransport { override suspend fun request(body: Envelope.Builder): Envelope = error("expired submit") }
        val api = FakeEdge { _, body -> assertEquals(command.recovery(true), body)
            val rejected = personalWire(command).toBuilder().setRejected(PersonalPreferenceRejection.newBuilder().setReason(PersonalPreferenceRejection.Reason.REVISION_CONFLICT).setCurrentRevision(8)).build()
            EdgeResponse(200, directResult("receipt", Json.parseToJsonElement(PersonalPreferenceClient.decodeWire(command, rejected).wire).jsonObject)) }
        val service = PersonalPreferenceService(actorId, PersonalPreferenceClient(tcp, api), store, { command.deadline + 1 })
        service.flush(); assertEquals(PersonalStatus.Conflicted, store.work.status)
        api.answer = { _, _ -> error("terminal replay") }; service.flush()
    }
    @Test fun `Retry After floor survives explicit retry and missing recovery remains same identity`() = runTest {
        val command = personalCommand(); var now = 1700000000000L
        val store = FrozenPersonalStore(PersonalWork(actorId, command.operation, command.target, command.deadline, PersonalStatus.Pending, command, reconcile = true, submissionStarted = true))
        val tcp = object : EnvelopeTransport { override suspend fun request(body: Envelope.Builder): Envelope = error("submit before recovery") }
        val api = FakeEdge { _, _ -> EdgeResponse(503, buildJsonObject {}, "90") }
        val service = PersonalPreferenceService(actorId, PersonalPreferenceClient(tcp, api), store, { now })
        service.flush(); val floor = store.work.nextAttempt; assertEquals(now + 90000, floor)
        store.work = store.work.copy(status = PersonalStatus.NeedsAttention); service.retry(command.operation)
        service.flush(); assertEquals(floor, store.work.nextAttempt)
        now = floor; api.answer = { _, _ -> EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) }) }
        service.flush(); assertFalse(store.work.reconcile); assertEquals(command, store.work.command)
        assertFails { service.discard(command.operation) }
    }
}
