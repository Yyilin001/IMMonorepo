package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class MessageOperationAdmissionStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture(var limits: OperationAdmissionLimits = OperationAdmissionLimits()) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val device = DeviceId(id()); val room = RoomId(id())
        val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device, operationLimits = limits)
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device, operationLimits = limits) }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
        fun reaction() = ReactionIntent(actor, room, MessageId(id()), id(), "👍", true, 601_000)
        fun mutation(text: String?) = MessageMutationCommand(actor, room, MessageId(id()), id(), 1, text, 601_000)
    }
    private suspend fun capacity(body: suspend () -> Unit) {
        try { body(); fail("over-capacity operation admitted") } catch (_: OperationCapacityExceeded) { }
    }
    private suspend fun invalid(body: suspend () -> Unit) {
        try { body(); fail("invalid transition accepted") } catch (_: IllegalArgumentException) { }
    }

    @Test fun draftFreezeTransfersFullQuotaAndPreservesOriginalIdentityAndDeadline() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(2, 1_000_000))
        try {
            val personal = f.store.enqueueConversation(f.room, ConversationPatch(pinned = true), 1_000)
            val reaction = f.store.enqueueReaction(f.reaction())
            val before = f.store.operationAdmissionUsage()
            capacity { f.store.enqueueMutation(f.mutation("edit")) }
            f.store.preparePersonal(2_000)
            val frozenPersonal = requireNotNull(f.store.personalWork(personal.operation))
            val command = ReactionCommand(reaction.intent, Long.MAX_VALUE - 1)
            val frozenReaction = reaction.copy(command = command, status = ReactionStatus.Pending)
            f.store.updateReaction(reaction, frozenReaction)
            val after = f.store.operationAdmissionUsage()
            assertEquals(2L, after.activeCount); assertTrue(after.reservedBytes <= before.reservedBytes)
            assertEquals(personal.deadline, frozenPersonal.command?.deadline)
            assertEquals(personal.operation, frozenPersonal.command?.operation)
            assertEquals(reaction.intent, frozenReaction.command?.intent)
            f.reopen(); assertEquals(after, f.store.operationAdmissionUsage())
            assertEquals(frozenPersonal, f.store.personalWork(personal.operation))
            assertEquals(frozenReaction, f.store.reactionWork(reaction.intent.operation))
        } finally { f.close() }
    }

    @Test fun unknownFrozenPreferenceAndReactionCannotReleaseCreditThroughLocalCancellation() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(2, 1_000_000))
        try {
            val personal = f.store.enqueueFavorite(f.room, MessageId(id()), true, 1_000); f.store.preparePersonal(2_000)
            val frozen = requireNotNull(f.store.personalWork(personal.operation))
            val unknownPersonal = frozen.copy(status = PersonalStatus.NeedsAttention, submissionStarted = true, reconcile = true)
            f.store.updatePersonal(frozen, unknownPersonal)
            val reaction = f.store.enqueueReaction(f.reaction())
            val unknownReaction = reaction.copy(command = ReactionCommand(reaction.intent, 1), status = ReactionStatus.NeedsAttention, executionStarted = true, reconcile = true)
            f.store.updateReaction(reaction, unknownReaction)
            val before = f.store.operationAdmissionUsage(); f.reopen()
            invalid { f.store.updatePersonal(unknownPersonal, unknownPersonal.copy(status = PersonalStatus.Cancelled)) }
            invalid { f.store.updateReaction(unknownReaction, unknownReaction.copy(status = ReactionStatus.Cancelled)) }
            capacity { f.store.enqueueMutation(f.mutation(null)) }
            assertEquals(before, f.store.operationAdmissionUsage())
            assertEquals(unknownPersonal, f.store.personalWork(personal.operation))
            assertEquals(unknownReaction, f.store.reactionWork(reaction.intent.operation))
        } finally { f.close() }
    }

    @Test fun largerCoalescedDraftMustAcquireBytesOrLeaveOriginalDraftUntouched() = runBlocking {
        val f = Fixture()
        try {
            val original = f.store.enqueueConversation(f.room, ConversationPatch(pinned = false), 1_000)
            val before = f.store.operationAdmissionUsage()
            f.limits = OperationAdmissionLimits(10, before.reservedBytes); f.reopen()
            capacity { f.store.enqueueConversation(f.room, ConversationPatch(pinned = true), 2_000) }
            assertEquals(original, f.store.personalWork(original.operation))
            assertEquals(before, f.store.operationAdmissionUsage())
            f.store.updatePersonal(original, original.copy(status = PersonalStatus.Cancelled))
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun editingReservesUtf8PayloadAndVerifiedTerminalReceiptReleasesIt() = runBlocking {
        val f = Fixture()
        try {
            val command = f.mutation("汉字")
            val expected = Json.encodeToString(command).toByteArray(Charsets.UTF_8).size.toLong()
            assertEquals(4, Json.encodeToString(command).toByteArray().size - Json.encodeToString(command.copy(text = "ab")).toByteArray().size)
            f.limits = OperationAdmissionLimits(10, expected); f.reopen()
            val work = f.store.enqueueMutation(command)
            assertEquals(expected, f.store.operationAdmissionUsage().reservedBytes)
            val other = f.mutation(null); capacity { f.store.enqueueMutation(other) }
            assertNull(f.store.mutationWork(other.operation))
            val receipt = buildJsonObject {
                put("identity", command.identity()); put("fingerprint", buildJsonObject { put("version", 1); put("digest", command.fingerprint) })
                put("resolvedAtMilliseconds", 2_000); put("outcome", buildJsonObject { put("closed", buildJsonObject {}) })
            }.toString()
            f.store.updateMutation(work, work.copy(status = MutationStatus.Closed, receipt = receipt))
            assertEquals(0L, f.store.operationAdmissionUsage().reservedBytes)
            f.store.enqueueMutation(other); f.reopen(); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun sharedLimitReplacesOldPerDomainCeilingAndSurvivesReopen() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(257, 1_000_000))
        try {
            repeat(257) { f.store.enqueueFavorite(f.room, MessageId(id()), true, 1_000) }
            assertEquals(257L, f.store.operationAdmissionUsage().activeCount)
            capacity { f.store.enqueueReaction(f.reaction()) }
            assertTrue(f.store.reactionWorks().isEmpty())
            f.reopen(); assertEquals(257, f.store.personalWorks().size)
            assertEquals(257L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }
}
