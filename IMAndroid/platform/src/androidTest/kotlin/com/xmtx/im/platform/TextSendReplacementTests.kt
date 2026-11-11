package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class TextSendReplacementTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun command()=MessageCommand.text(actor,room,"原始正文",600000,rich=MessageRichContent(
        mentions=persistentListOf(MentionTarget.Everyone),entities=persistentListOf(RichTextEntity(0,2,RichTextKind.bold)),replyTo=MessageId(UUID.randomUUID().toString())))
    private fun receipt(c: MessageSendOperation,accepted: Boolean=false)=MessageSendOperationReceipt.newBuilder()
        .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(c.clientMessageId))
        .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(c.fingerprintVersion).setDigest(c.fingerprint)).setResolvedAtMs(1000)
        .apply {if(accepted) setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(UUID.randomUUID().toString().uppercase()).setRoomSequence(1))
            else setRejected(MessageSendOperationRejection.newBuilder().setReasonValue(6))}.build()
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    @Test fun permanentRejectionCreatesOneReplacementWithFrozenRichContentAndSurvivesReopen()=runBlocking<Unit> {
        var s=store();try {
            s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(0).setViewerMembershipRevision(1).build())
            val original=command();s.enqueue(original);s.complete(original.clientMessageId,receipt(original))
            assertTrue(s.sendHistory(room,actor).items.single().canReplaceText)
            val ids=coroutineScope {(1..8).map {async {s.replaceUnsentText(room,actor,original.clientMessageId,10000)}}.awaitAll()}
            assertEquals(1,ids.toSet().size);assertNotEquals(original.clientMessageId,ids.first())
            val next=s.pending().single();assertEquals(ids.first(),next.clientMessageId)
            assertEquals(original.text,next.text);assertEquals(MessageRichContent.fromCommand(original),MessageRichContent.fromCommand(next))
            assertNotEquals(original.fingerprint,next.fingerprint);assertEquals(10000+ClientSubmissionWindow.COMMAND_MILLISECONDS,next.firstSubmissionDeadlineMs)
            val records=s.sendHistory(room,actor).items;assertEquals(2,records.size)
            assertEquals(next.clientMessageId,records.last().replacement);assertFalse(records.last().canReplaceText)
            assertFalse(records.first().canReplaceText)
            database {db->db.rawQuery("SELECT command FROM outbox WHERE id=?",arrayOf(original.clientMessageId)).use {assertTrue(it.moveToFirst());assertEquals(original,MessageSendOperation.parseFrom(it.getBlob(0)))}}
            assertEquals(listOf(next.clientMessageId),s.conversationTimeline(room,actor).outbox.map {it.id.value})
            s.close();s=store();assertEquals(ids.first(),s.replaceUnsentText(room,actor,original.clientMessageId,20000))
            assertEquals(2,s.sendHistory(room,actor).items.size)
            assertTrue(runCatching {s.replaceUnsentText(room,UserId(UUID.randomUUID().toString()),original.clientMessageId,20000)}.isFailure)
            assertTrue(runCatching {s.replaceUnsentText(RoomId(UUID.randomUUID().toString()),actor,original.clientMessageId,20000)}.isFailure)
            s.unavailable(room);assertTrue(runCatching {s.replaceUnsentText(room,actor,original.clientMessageId,20000)}.isFailure)
        } finally {s.close()}
    }
    @Test fun unknownAcceptedMediaAndUnboundReceiptsCannotCreateNewIdentity()=runBlocking<Unit> {
        val s=store();try {
            val original=command();s.enqueue(original)
            assertTrue(runCatching {s.replaceUnsentText(room,actor,original.clientMessageId,1000)}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(room,actor,original.clientMessageId)}.isFailure)
            val attempt=s.claimSend(1000)!!;s.deferSend(attempt,attempt.state.copy(status=SendRecoveryStatus.NeedsAttention))
            assertFalse(s.sendHistory(room,actor).items.single().canReplaceText)
            assertTrue(runCatching {s.replaceUnsentText(room,actor,original.clientMessageId,700000)}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(room,actor,original.clientMessageId)}.isFailure)
            s.complete(original.clientMessageId,receipt(original,true))
            assertTrue(runCatching {s.replaceUnsentText(room,actor,original.clientMessageId,700000)}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(room,actor,original.clientMessageId)}.isFailure)
            val media=MessageCommand.withMedia(actor,room,"附件",persistentListOf(UUID.randomUUID().toString()),600000)
            s.enqueue(media);s.complete(media.clientMessageId,receipt(media))
            assertFalse(s.sendHistory(room,actor).items.first().canReplaceText)
            assertTrue(runCatching {s.replaceUnsentText(room,actor,media.clientMessageId,700000)}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(room,actor,media.clientMessageId)}.isFailure)
            val wrong=command();s.enqueue(wrong)
            try { s.complete(wrong.clientMessageId,receipt(original)); fail("Unbound receipt persisted") }
            catch (_: ClientFailure.Protocol) { }
            assertEquals(wrong,s.pending().single())
            assertTrue(runCatching {s.replaceUnsentText(room,actor,wrong.clientMessageId,700000)}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(room,actor,wrong.clientMessageId)}.isFailure)
            database {db->db.rawQuery("SELECT COUNT(*) FROM text_send_replacements",null).use {it.moveToFirst();assertEquals(0,it.getInt(0))}}
        } finally {s.close()}
    }
    @Test fun intentOwnedTextRetainsItsExistingReplacementOwner()=runBlocking<Unit> {
        val s=store();try {
            val service=SendIntentService(actor,s) {1000}
            val intent=service.enqueue(room,"由准备任务持有的文本",persistentListOf())
            service.prepareNext();val frozen=s.pending().single()
            s.complete(frozen.clientMessageId,receipt(frozen))
            assertFalse(s.sendHistory(room,actor).items.single().canReplaceText)
            assertTrue(runCatching {s.replaceUnsentText(room,actor,frozen.clientMessageId,2000)}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(room,actor,frozen.clientMessageId)}.isFailure)
            val next=service.resumeOrReapply(intent.id)
            assertNotEquals(intent.operation,next.operation)
        } finally {s.close()}
    }
    @Test fun localExpiryRequiresUnsubmittedEvidenceAndReplacementRollsBackAtomically()=runBlocking<Unit> {
        val s=store();try {
            val original=command();s.enqueue(original);assertNull(s.claimSend(600001))
            assertTrue(s.sendHistory(room,actor).items.single().canReplaceText)
            database {it.execSQL("CREATE TRIGGER fail_replacement BEFORE INSERT ON text_send_replacements BEGIN SELECT RAISE(ABORT,'test rollback'); END")}
            assertTrue(runCatching {s.replaceUnsentText(room,actor,original.clientMessageId,700000)}.isFailure)
            assertEquals(listOf(original),s.pending());assertNull(s.sendHistory(room,actor).items.single().replacement)
            database {it.execSQL("DROP TRIGGER fail_replacement")}
            val replacement=s.replaceUnsentText(room,actor,original.clientMessageId,700000)
            assertEquals(replacement,s.claimSend(700000)!!.command.clientMessageId)
            val legacy=command();s.enqueue(legacy)
            database {it.execSQL("UPDATE outbox SET send_work=NULL WHERE id=?",arrayOf(legacy.clientMessageId))}
            assertTrue(runCatching {s.replaceUnsentText(room,actor,legacy.clientMessageId,800000)}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(room,actor,legacy.clientMessageId)}.isFailure)
        } finally {s.close()}
    }
}
