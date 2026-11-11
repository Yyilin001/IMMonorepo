package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class SendAdmissionStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture(var limits: OperationAdmissionLimits = OperationAdmissionLimits()) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val device = DeviceId(id()); val room = RoomId(id())
        val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device, operationLimits = limits)
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device, operationLimits = limits) }
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
        fun database(body: (SQLiteDatabase) -> Unit) = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use(body)
        fun command(deadline: Long = 601_000) = MessageCommand.text(actor, room, "等待发送的正文", deadline)
        fun receipt(command: MessageSendOperation, message: String = id(), sequence: Long = 1, reject: Boolean = false) = MessageSendOperationReceipt.newBuilder()
            .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(command.clientMessageId))
            .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint))
            .setResolvedAtMs(2_000).apply {
                if (reject) setRejected(MessageSendOperationRejection.newBuilder().setReasonValue(2))
                else setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(message).setRoomSequence(sequence))
            }.build()
        suspend fun project(message: String, sequence: Long = 1, removed: Boolean = false) {
            store.acceptState(room, RoomSyncState.newBuilder().setRoomId(room.value).setHead(100).setViewerMembershipRevision(1).build())
            val payload = buildJsonObject {
                MessageRichContent.Empty.payload().forEach { (key, value) -> put(key, value) }
                put("event_type", if (removed) "message.withdrawn" else "message.accepted")
                put("message_id", message); put("room_id", room.value); put("message_revision", if (removed) 2 else 1)
                put("sender_user_id", actor.value); put("text", "等待发送的正文")
                put("timeline_sequence", sequence); put("server_created_at_ms", 1_000)
            }
            val page = GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence)
                .addEvents(GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId(id()).setProjectionKind("message")
                    .setPayload(ByteString.copyFromUtf8(payload.toString()))).build()
            store.commitRoom(page, store.roomCursor(room))
        }
    }
    private suspend fun capacity(body: suspend () -> Unit) {
        try { body(); fail("over-capacity send admitted") } catch (_: OperationCapacityExceeded) { }
    }

    @Test fun preparationTransfersItsFullReservationToOneFrozenCommand() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 1_000_000))
        try {
            val service = SendIntentService(f.actor, f.store) { 1_000 }
            val intent = service.prepare(f.room, "保留原身份", persistentListOf())
            f.store.enqueueSendIntent(intent, 1_000)
            val before = f.store.operationAdmissionUsage()
            f.limits = OperationAdmissionLimits(1, before.reservedBytes); f.reopen()
            assertEquals(intent, f.store.enqueueSendIntent(intent, 1_000))
            capacity { f.store.enqueue(f.command()) }
            f.store.advanceSendIntents(2_000)
            val command = f.store.pending().single()
            assertEquals(intent.operation, command.clientMessageId)
            assertEquals(2_000L + ClientSubmissionWindow.COMMAND_MILLISECONDS, command.firstSubmissionDeadlineMs)
            val after = f.store.operationAdmissionUsage()
            assertEquals(1L, after.activeCount); assertEquals(command.serializedSize.toLong() + 256, after.reservedBytes)
            assertTrue(after.reservedBytes <= before.reservedBytes)
            f.reopen(); assertEquals(after, f.store.operationAdmissionUsage()); assertEquals(command, f.store.pending().single())
            capacity { f.store.enqueueConversation(f.room, ConversationPatch(pinned = true), 3_000) }
        } finally { f.close() }
    }

    @Test fun byteCapacityFailureRollsBackAttachmentAdoptionAndUploadPreparation() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(100, 1))
        val files = ManagedResourceFiles(f.context, f.store)
        val resourceRoot = File(f.context.noBackupFilesDir, "resources-${f.store.resourceScope}")
        val original = File.createTempFile("send-admission-", ".txt", f.context.cacheDir)
        try {
            original.writeText("附件原件")
            val asset = files.importFile(original, "附件.txt", "text/plain", ResourceUsage.Attachment(f.room), 1_024)
            val source = SendAttachment(id(), asset.id, asset.displayName, asset.contentType, asset.byteCount)
            val intent = SendIntentService(f.actor, f.store) { 1_000 }.prepare(f.room, "未取得额度", persistentListOf(source))
            capacity { f.store.enqueueSendIntent(intent, 1_000) }
            assertTrue(f.store.sendIntents().isEmpty()); assertTrue(f.store.resourceUploads().isEmpty())
            assertEquals(listOf(asset.id), files.selected(ResourceUsage.Attachment(f.room)).map { it.id })
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            capacity { f.store.enqueue(f.command()) }; assertTrue(f.store.pending().isEmpty())
        } finally {
            files.close(); f.close(); original.delete(); resourceRoot.deleteRecursively()
        }
    }

    @Test fun acceptedSendHoldsCreditUntilMatchingProjectionAndNeverReacquiresAfterPurge() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 1_000_000))
        try {
            val command = f.command(); val message = id(); f.store.enqueue(command)
            f.store.complete(command.clientMessageId, f.receipt(command, message))
            f.reopen(); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            capacity { f.store.enqueue(f.command()) }
            f.project(message)
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            f.database { it.execSQL("DELETE FROM messages WHERE id=?", arrayOf(message)) }
            f.reopen(); assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            // Receipt replay and unrelated writes cannot recharge a settled identity.
            f.store.complete(command.clientMessageId, f.receipt(command, message))
            f.store.enqueue(f.command()); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun projectionBeforeReceiptMustMatchAcceptedSequenceAndTombstoneCanSettleIt() = runBlocking {
        val f = Fixture()
        try {
            val command = f.command(); val message = id(); f.store.enqueue(command); f.project(message)
            val receipt = f.receipt(command, message, sequence = 2)
            f.store.complete(command.clientMessageId, receipt)
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            f.project(message, sequence = 2, removed = true)
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            val other = f.command(); val otherMessage = id(); f.store.enqueue(other); f.project(otherMessage, sequence = 3)
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            f.store.complete(other.clientMessageId, f.receipt(other, otherMessage, sequence = 3))
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount); f.reopen()
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun unknownSubmissionKeepsCreditButProvenUnsubmittedExpiryAndRejectionReleaseIt() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 1_000_000))
        try {
            val command = f.command(); f.store.enqueue(command)
            val attempt = requireNotNull(f.store.claimSend(1_000))
            f.store.deferSend(attempt, attempt.state.copy(status = SendRecoveryStatus.NeedsAttention))
            f.reopen(); capacity { f.store.enqueue(f.command()) }
            assertEquals(command, f.store.pending().single())
            f.store.complete(command.clientMessageId, f.receipt(command, reject = true))
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            val expired = f.command(deadline = 1_000); f.store.enqueue(expired)
            assertNull(f.store.claimSend(2_000)); assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
            f.store.enqueue(f.command()); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun invalidOrReplacedReceiptCannotReleaseReservationAndPreparationOverflowRollsBack() = runBlocking {
        val f = Fixture(OperationAdmissionLimits(1, 1_000_000))
        try {
            val command = f.command(); f.store.enqueue(command)
            val service = SendIntentService(f.actor, f.store) { 1_000 }
            capacity { f.store.enqueueSendIntent(service.prepare(f.room, "不得保存", persistentListOf()), 1_000) }
            assertTrue(f.store.sendIntents().isEmpty())
            val receipt = f.receipt(command)
            try { f.store.complete(command.clientMessageId, receipt.toBuilder().setFingerprint(MessageSendOperationFingerprint.getDefaultInstance()).build()); fail("invalid receipt") }
            catch (_: ClientFailure.Protocol) { }
            assertEquals(command, f.store.pending().single())
            f.store.complete(command.clientMessageId, receipt)
            try { f.store.complete(command.clientMessageId, f.receipt(command, reject = true)); fail("receipt replaced") }
            catch (_: IllegalArgumentException) { }
            assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            f.reopen(); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }

    @Test fun migrationRetainsOverLimitSendsAndProjectionEvidenceRollsBackWithFailedTransaction() = runBlocking {
        val f = Fixture()
        try {
            val command = f.command(); val other = f.command(); val message = id()
            f.store.enqueue(command); f.store.enqueue(other)
            f.store.complete(command.clientMessageId, f.receipt(command, message))
            f.database {
                it.execSQL("DELETE FROM operation_reservations WHERE source='outbox'")
                it.execSQL("DELETE FROM operation_reservation_versions WHERE source='outbox'")
            }
            f.limits = OperationAdmissionLimits(1, 1); f.reopen()
            assertEquals(2L, f.store.operationAdmissionUsage().activeCount)
            capacity { f.store.enqueue(f.command()) }
            // Fail after the monotonic marker write, proving both projection and marker roll back.
            f.database { it.execSQL("CREATE TRIGGER fail_send_evidence AFTER UPDATE OF accepted_projection_observed ON outbox WHEN NEW.accepted_projection_observed=1 BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            try { f.project(message); fail("projection committed despite SQL failure") }
            catch (_: android.database.sqlite.SQLiteException) { }
            assertEquals(2L, f.store.operationAdmissionUsage().activeCount)
            f.database { db ->
                db.rawQuery("SELECT accepted_projection_observed,(SELECT COUNT(*) FROM messages) FROM outbox WHERE id=?", arrayOf(command.clientMessageId)).use {
                    assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0)); assertEquals(0, it.getInt(1))
                }
                db.execSQL("DROP TRIGGER fail_send_evidence")
            }
            f.project(message); assertEquals(1L, f.store.operationAdmissionUsage().activeCount)
            f.store.complete(other.clientMessageId, f.receipt(other, reject = true))
            assertEquals(0L, f.store.operationAdmissionUsage().activeCount)
        } finally { f.close() }
    }
}
