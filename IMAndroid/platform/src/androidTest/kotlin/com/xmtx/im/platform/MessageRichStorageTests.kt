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
import java.security.MessageDigest
import java.util.UUID

class MessageRichStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id());private val message=MessageId(id())
    private val body=" A😀e\u0301 中文 "
    private val rich=MessageRichContent(persistentListOf(MentionTarget.User(actor),MentionTarget.Everyone),persistentListOf(RichTextEntity(2,2,RichTextKind.bold),RichTextEntity(5,1,RichTextKind.italic)),MessageId(id()))
    private fun store()=SqliteClientStore(context,actor,device)
    private suspend fun ready(s:SqliteClientStore)=s.acceptState(room,RoomSyncState.newBuilder().setHead(100).setViewerMembershipRevision(1).build())
    private fun accepted(revision:Long=1,text:String=body,content:MessageRichContent=rich)=buildJsonObject {
        put("event_type","message.accepted");put("message_id",message.value);put("room_id",room.value);put("sender_user_id",actor.value)
        put("message_revision",revision);put("room_sequence",1);put("timeline_sequence",1);put("server_created_at_ms",1000);put("text",text)
        MessageMedia.Empty.payload().forEach {(k,v)->put(k,v)};content.payload().forEach {(k,v)->put(k,v)}
    }
    private fun edit(revision:Long,text:String="plain",replacement:JsonObject?=null)=buildJsonObject {
        put("event_type","message.edited");put("message_id",message.value);put("room_id",room.value);put("message_revision",revision);put("text",text)
        replacement?.let {put("replacement",buildJsonObject {put("schema_version",1);put("accepted_membership_revision",1);put("accepted_event_id",id());put("state",it)})}
    }
    private suspend fun apply(s:SqliteClientStore,value:JsonObject) {
        val c=s.roomCursor(room);val n=c.sequence+1
        s.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(n).addEvents(GroupEvent.newBuilder().setRoomSequence(n).setSourceEventId(id()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(value.toString()))).build(),c)
    }
    private fun database(block:(SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(block)
    }
    private fun legacy()=database {db->
        db.execSQL("ALTER TABLE messages RENAME TO new_messages")
        db.execSQL("CREATE TABLE messages AS SELECT id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn,forwarded_message,forwarded_sender,media FROM new_messages")
        db.execSQL("DROP TABLE new_messages");db.execSQL("CREATE UNIQUE INDEX legacy_rich_id ON messages(id)")
    }
    @Test fun completeAndLegacyEditsPreserveReferencesAndClearOnlyOldFormats()=runBlocking {
        var s=store();try {
            ready(s);apply(s,accepted());s.close();s=store();assertEquals(rich,s.snapshot().messages.single().rich)
            apply(s,edit(2));assertEquals(rich.copy(entities=persistentListOf()),s.snapshot().messages.single().rich)
            apply(s,edit(3,replacement=accepted(3)));assertEquals(rich,s.snapshot().messages.single().rich)
            val cursor=s.roomCursor(room)
            assertTrue(runCatching {apply(s,edit(3,replacement=accepted(3,content=rich.copy(replyTo=MessageId(id())))))}.exceptionOrNull() is ClientFailure.Protocol)
            assertEquals(cursor,s.roomCursor(room));assertEquals(rich,s.snapshot().messages.single().rich)
            apply(s,edit(2));assertEquals(rich,s.snapshot().messages.single().rich)
        } finally {s.close()}
    }
    @Test fun malformedRangesDuplicatesAndIncompleteReplacementRollbackCursor()=runBlocking {
        val s=store();try {
            ready(s)
            val good=accepted();val invalid=rich.copy(entities=persistentListOf(RichTextEntity(2,1,RichTextKind.bold)))
            for(value in listOf(accepted(content=invalid),JsonObject(good+("mention_user_ids" to JsonArray(listOf(JsonPrimitive(actor.value),JsonPrimitive(actor.value.lowercase()))))))) {
                assertTrue(runCatching {apply(s,value)}.exceptionOrNull() is ClientFailure.Protocol);assertEquals(0L,s.roomCursor(room).sequence);assertTrue(s.snapshot().messages.isEmpty())
            }
            apply(s,good)
            for(key in listOf("mention_user_ids","mentions_everyone","entities","reply_to_message_id")) {
                assertTrue(runCatching {apply(s,edit(2,replacement=JsonObject(accepted(2)-key)))}.exceptionOrNull() is ClientFailure.Protocol)
                assertEquals(1L,s.snapshot().messages.single().revision)
            }
        } finally {s.close()}
    }
    @Test fun tombstoneClearsRichContentAcrossReopenAndLateProjection()=runBlocking {
        var s=store();try {
            ready(s);apply(s,accepted());apply(s,JsonObject(edit(2)+("event_type" to JsonPrimitive("message.redacted"))))
            s.close();s=store();assertEquals(MessageRichContent.Empty,s.snapshot().messages.single().rich)
            apply(s,edit(1,replacement=accepted()));assertEquals(MessageRichContent.Empty,s.snapshot().messages.single().rich)
            s.unavailable(room);assertTrue(s.snapshot().messages.isEmpty())
        } finally {s.close()}
    }
    @Test fun legacyMigrationRequiresContinuousEvidenceAndRecoversCompleteReplacement()=runBlocking {
        var s=store();try {
            ready(s);apply(s,accepted());apply(s,edit(2));apply(s,edit(3));s.close();legacy();s=store()
            assertEquals(rich.copy(entities=persistentListOf()),s.snapshot().messages.single().rich)
            s.close();legacy();database {db->db.rawQuery("SELECT event,payload FROM records WHERE kind='message'",null).use {r->while(r.moveToNext()) {
                val v=Json.parseToJsonElement(r.getBlob(1).toString(Charsets.UTF_8)).jsonObject
                if(v["message_revision"]?.jsonPrimitive?.longOrNull==2L) db.execSQL("DELETE FROM records WHERE event=?",arrayOf(r.getString(0)))
            }}}
            s=store();assertNull(s.snapshot().messages.single().rich)
            apply(s,edit(4,replacement=accepted(4)));assertEquals(rich,s.snapshot().messages.single().rich)
        } finally {s.close()}
    }
    @Test fun durableDraftFreezesExactOffsetsAndRetryCannotConsumeTheNextDraft()=runBlocking {
        var s=store();try {
            val now=System.currentTimeMillis();val before=s.conversationDraft(room)
            val draft=s.saveConversationContent(before,body,rich,now)
            assertTrue(runCatching {s.saveConversationContent(before,"old",MessageRichContent.Empty,now)}.exceptionOrNull() is ConversationDraftConflict)
            s.close();s=store();assertEquals(draft,s.conversationDraft(room))
            val intent=SendIntentService(actor,s) {now}.prepare(room,draft.sendText,draft.attachments,draft.rich)
            assertTrue(runCatching {s.submitConversationDraft(draft,intent.copy(rich=MessageRichContent.Empty),now)}.isFailure)
            s.submitConversationDraft(draft,intent,now);val next=s.saveConversationText(s.conversationDraft(room),"next",now)
            s.advanceSendIntents(now);val command=s.pending().single();assertEquals(body,command.text);assertEquals(rich,MessageRichContent.fromCommand(command))
            s.close();s=store();assertEquals(command,s.pending().single());assertEquals(rich,s.snapshot().messages.single().rich)
            s.submitConversationDraft(draft,intent,now);assertEquals(next,s.conversationDraft(room))
            val richDraft=s.saveConversationContent(next,body,rich,now);val edited=s.saveConversationText(richDraft,"x",now)
            assertEquals(rich.copy(entities=persistentListOf()),edited.rich)
        } finally {s.close()}
    }
}
