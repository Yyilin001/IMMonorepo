package com.xmtx.im.platform

import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64
import java.util.UUID

class PersonalPreferenceStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId(UUID.randomUUID().toString()); private val device = DeviceId(UUID.randomUUID().toString())
    private val room = RoomId(UUID.randomUUID().toString()); private val message = MessageId(UUID.randomUUID().toString())
    private fun store() = SqliteClientStore(context, actor, device)
    @Test fun cancelledRealtimePreferenceRecoversOverHttpAfterReopenAndRoundReset() = runBlocking {
        var store = store(); var command: PersonalCommand? = null; var submissions = 0; var queries = 0; var now = 1000L
        val tcp = object: EnvelopeTransport {
            override suspend fun request(body: Envelope.Builder): Envelope {
                submissions++; val intent = requireNotNull(currentCoroutineContext()[NetworkWorkIntent])
                assertEquals(submissions > 1, intent.isRetry)
                assertEquals(if(submissions == 1) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery, intent.priority)
                assertEquals(requireNotNull(command).envelope().build(), body.build())
                assertTrue(store.personalWorks().single().submissionStarted)
                throw CancellationException("fixture interruption")
            }
        }
        val api = object: AuthenticatedTransport {
            override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
                queries++; val intent = requireNotNull(currentCoroutineContext()[NetworkWorkIntent])
                assertTrue(intent.isRetry); assertEquals(NetworkWorkPriority.Recovery, intent.priority)
                assertTrue(path.endsWith("operations/recover")); assertEquals(requireNotNull(command).recovery(false), payload)
                return EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
            }
        }
        fun service() = PersonalPreferenceService(actor, PersonalPreferenceClient(tcp, api), store, {now})
        suspend fun retry() {
            val work = store.personalWorks().single(); store.updatePersonal(work, work.copy(status = PersonalStatus.NeedsAttention))
            service().retry(work.operation); assertEquals(0, store.personalWorks().single().attempts)
        }
        try {
            store.enqueueFavorite(room, message, true, now); store.preparePersonal(now); command = store.personalWorks().single().command
            try { service().flush(); fail("expected interruption") } catch(_: CancellationException) {}
            store.close(); store = store(); retry(); service().flush()
            now = store.personalWorks().single().nextAttempt; assertFalse(store.personalWorks().single().reconcile)
            store.close(); store = store(); retry()
            try { service().flush(); fail("expected interruption") } catch(_: CancellationException) {}
            assertEquals(2, submissions); assertEquals(1, queries); assertEquals(command, store.personalWorks().single().command)
        } finally { store.close() }
    }
    private fun receipt(command: PersonalCommand): String {
        val target = command.target as PersonalTarget.Conversation
        return PersonalPreferenceClient.decodeWire(command, PersonalPreferenceReceipt.newBuilder().setActorUserId(actor.value).setRoomId(room.value).setOperationId(command.operation)
            .setKind(PersonalPreferenceReceipt.Kind.CONVERSATION_STATE).setFingerprintVersion(1).setFingerprint(ByteString.copyFrom(Base64.getDecoder().decode(command.fingerprint))).setResolvedAtMs(10000)
            .setConversationState(ConversationStateSet.newBuilder().setRoomId(room.value).setIsPinned(target.pinned).setIsArchived(target.archived).setMuteUntilMs(target.muteUntil).setRevision(command.revision + 1).setUpdatedAtMs(10000)).build()).wire
    }
    @Test fun unfrozenTargetsCoalesceWithoutExtendingDeadlineAndFrozenHeadsSerializeAcrossReopen() = runBlocking {
        var store = store()
        val first = store.enqueueConversation(room, ConversationPatch(pinned = true), 1000)
        val coalesced = store.enqueueConversation(room, ConversationPatch(muteUntil = 50000), 2000)
        assertEquals(first.operation, coalesced.operation); assertEquals(first.deadline, coalesced.deadline)
        assertEquals(PersonalTarget.Conversation(room, true, false, 50000), coalesced.target)
        store.preparePersonal(3000); val frozen = store.personalWorks().single()
        val later = store.enqueueConversation(room, ConversationPatch(archived = true), 4000)
        assertNotEquals(first.operation, later.operation); assertEquals(PersonalTarget.Conversation(room, true, true, 50000), later.target)
        store.preparePersonal(5000); assertNull(store.personalWorks().last().command)
        store.close(); store = store(); assertEquals(frozen, store.personalWorks().first())
        assertEquals(frozen,store.personalWork(frozen.operation));assertNull(store.personalWork(UUID.randomUUID().toString()))
        try { store.updatePersonal(frozen, frozen.copy(command = frozen.command!!.copy(revision = 9))); fail("frozen identity rewritten") } catch (_: IllegalArgumentException) { }
        store.updatePersonal(frozen, frozen.copy(status = PersonalStatus.Committed, receipt = receipt(frozen.command!!)))
        store.preparePersonal(6000); val next = store.personalWorks().last()
        assertEquals(1L, next.command!!.revision); assertEquals(later.deadline, next.command!!.deadline)
        assertEquals(1L, store.snapshot().personalStates.single().revision)
        store.close()
    }
    @Test fun expiryAndUnknownSubmissionCannotBeDiscardedOrSilentlyReplaced() = runBlocking {
        val store = store()
        val expired = store.enqueueConversation(room, ConversationPatch(pinned = true), 1000)
        store.preparePersonal(expired.deadline); assertEquals(PersonalStatus.Expired, store.personalWorks().single().status)
        val favorite = store.enqueueFavorite(room, message, true, expired.deadline + 1)
        store.preparePersonal(expired.deadline + 2); val frozen = store.personalWorks().first { it.operation == favorite.operation }
        val unknown = frozen.copy(submissionStarted = true, reconcile = true, status = PersonalStatus.NeedsAttention)
        store.updatePersonal(frozen, unknown)
        try { store.updatePersonal(unknown, unknown.copy(status = PersonalStatus.Cancelled)); fail("unknown result discarded") } catch (_: IllegalArgumentException) { }
        val queued = store.enqueueFavorite(room, message, false, expired.deadline + 3)
        store.preparePersonal(expired.deadline + 4)
        assertNull(store.personalWorks().first { it.operation == queued.operation }.command)
        store.close()
    }
    @Test fun projectionConflictRollsBackAndOldSnapshotCannotRegressReceiptOrNextRevision() = runBlocking {
        var store = store()
        fun projection(revision: Int, pinned: Boolean) = buildJsonObject {
            put("room_id", room.value); put("is_pinned", pinned); put("is_archived", false); put("mute_until_ms", 0); put("revision", revision); put("updated_at_ms", 10000)
        }
        fun batch(sequence: Long, value: JsonObject) = SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base").setNextSyncToken("token-$sequence").setSyncReceipt("receipt-$sequence")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(sequence).setSourceEventId("personal-$sequence").setProjectionKind("conversation_state").setPayload(ByteString.copyFromUtf8(value.toString()))).build()
        store.commit(batch(1, projection(3, false)), store.cursor())
        store.enqueueConversation(room, ConversationPatch(pinned = true), 1000); store.preparePersonal(1001)
        val work = store.personalWorks().single(); assertEquals(3L, work.command!!.revision)
        store.updatePersonal(work, work.copy(status = PersonalStatus.Committed, receipt = receipt(work.command!!)))
        val cursor = store.cursor()
        try { store.commit(batch(2, projection(4, false)), cursor); fail("contradicted receipt") } catch (_: ClientFailure.Protocol) { }
        assertEquals(cursor, store.cursor())
        store.commit(batch(2, projection(4, true)), cursor)
        val old = persistentListOf(SnapshotItem("conversation_state", room.value, "old", 1, ByteString.copyFromUtf8(projection(2, false).toString())))
        store.activateFixture(SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(1).setNextSyncToken("snapshot").build(), old)
        store.close(); store = store()
        assertEquals(4L, store.snapshot().personalStates.single().revision)
        val next = store.enqueueConversation(room, ConversationPatch(archived = true), 3000)
        assertEquals(PersonalTarget.Conversation(room, true, true), next.target)
        store.preparePersonal(3001); assertEquals(4L, store.personalWorks().last().command!!.revision)
        store.close()
    }
}
