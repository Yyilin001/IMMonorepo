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

class MessageMediaStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id());private val message=MessageId(id())
    private val first=id();private val second=id()
    private fun store()=SqliteClientStore(context,actor,device)
    private suspend fun ready(store: SqliteClientStore)=store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(100).build())
    private fun media(vararg ids: String)=MessageMedia(ids.toList().toPersistentList(),ids.map {
        val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),it),1,"附件.png","image/png",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready,20,20)
        MessageMediaPresentation(it,MessageMediaKind.Image,"image/png",100,descriptor)
    }.toPersistentList())
    private fun accepted(revision: Long=1,content: MessageMedia=media(first,second),text: String="")=buildJsonObject {
        MessageRichContent.Empty.payload().forEach { (k,v)->put(k,v) }
        put("event_type","message.accepted");put("message_id",message.value);put("room_id",room.value);put("sender_user_id",actor.value)
        put("message_revision",revision);put("room_sequence",1);put("timeline_sequence",1);put("server_created_at_ms",1000);put("text",text)
        content.payload().forEach { (key,value)->put(key,value) }
    }
    private fun edit(revision: Long)=buildJsonObject {
        put("event_type","message.edited");put("message_id",message.value);put("room_id",room.value);put("message_revision",revision);put("text","edited-$revision")
    }
    private fun replacement(revision: Long,content: MessageMedia)=buildJsonObject {
        edit(revision).forEach { (key,value)->put(key,value) }
        put("replacement",buildJsonObject {
            put("schema_version",1);put("accepted_membership_revision",1);put("accepted_event_id",id());put("state",accepted(revision,content,"replacement"))
        })
    }
    private suspend fun apply(store: SqliteClientStore,value: JsonObject) {
        val cursor=store.roomCursor(room);val sequence=cursor.sequence+1
        store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence).addEvents(GroupEvent.newBuilder()
            .setRoomSequence(sequence).setSourceEventId(id()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(value.toString()))).build(),cursor)
    }
    private fun database(block: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(block)
    }
    private fun legacy()=database { db ->
        db.execSQL("ALTER TABLE messages RENAME TO current_messages")
        db.execSQL("CREATE TABLE messages AS SELECT id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn,forwarded_message,forwarded_sender FROM current_messages")
        db.execSQL("DROP TABLE current_messages");db.execSQL("CREATE UNIQUE INDEX legacy_message_id ON messages(id)")
    }
    @Test fun orderedDescriptorsSurviveReopenTextEditAndCompleteReplacement()=runBlocking {
        var store=store();try {
            ready(store);apply(store,accepted());assertEquals(media(first,second),store.snapshot().messages.single().media)
            store.close();store=store();apply(store,edit(2));assertEquals(media(first,second),store.snapshot().messages.single().media)
            apply(store,replacement(3,media(second)));assertEquals(media(second),store.snapshot().messages.single().media)
            val cursor=store.roomCursor(room)
            try { apply(store,replacement(3,media(first)));fail("same revision changed attachment") } catch(_: ClientFailure.Protocol) { }
            assertEquals(cursor,store.roomCursor(room));assertEquals(media(second),store.snapshot().messages.single().media)
            // An older complete state cannot put removed attachments back.
            apply(store,replacement(2,media(first,second)));assertEquals(media(second),store.snapshot().messages.single().media)
        } finally { store.close() }
    }
    @Test fun malformedAttachmentFactsRollbackWholePageAndCursor()=runBlocking {
        val store=store();try {
            ready(store)
            val good=accepted();val p=media(first,second).presentations!!.first().payload()
            val wrongKind=JsonObject(p+("kind" to JsonPrimitive("audio")))
            val invalid=listOf(JsonObject(good-"media_presentations"),
                JsonObject(good+("media_ids" to JsonArray(listOf(JsonPrimitive(first),JsonPrimitive(first.lowercase()))))),
                JsonObject(good+("media_presentations" to JsonArray(listOf(p,p)))),
                JsonObject(good+("media_presentations" to JsonArray(listOf(wrongKind)))))
            for(value in invalid) {
                try { apply(store,value);fail("invalid media published") } catch(_: ClientFailure.Protocol) { }
                assertEquals(0L,store.roomCursor(room).sequence);assertTrue(store.snapshot().messages.isEmpty())
            }
            apply(store,good);assertEquals(media(first,second),store.snapshot().messages.single().media)
            val changed=JsonObject(replacement(2,media(second)))
            val envelope=changed.getValue("replacement").jsonObject
            val altered=JsonObject(changed+("replacement" to JsonObject(envelope+("state" to JsonObject(envelope.getValue("state").jsonObject+("sender_user_id" to JsonPrimitive(id())))))))
            try { apply(store,altered);fail("replacement changed original sender") } catch(_: ClientFailure.Protocol) { }
            val incomplete=JsonObject(changed+("replacement" to JsonObject(envelope+("state" to JsonObject(envelope.getValue("state").jsonObject-"media_ids"-"media_presentations")))))
            try { apply(store,incomplete);fail("incomplete replacement cleared attachments") } catch(_: ClientFailure.Protocol) { }
            assertEquals(1L,store.snapshot().messages.single().revision)
        } finally { store.close() }
    }
    @Test fun removalClearsPersistentMediaAndLateStateCannotRestoreIt()=runBlocking {
        var store=store();try {
            ready(store);apply(store,accepted())
            apply(store,buildJsonObject { edit(2).forEach { (k,v)->put(k,v) };put("event_type","message.redacted") })
            assertEquals(MessageMedia.Empty,store.snapshot().messages.single().media)
            store.close();store=store();apply(store,replacement(1,media(first,second)))
            assertTrue(store.snapshot().messages.single().redacted);assertEquals(MessageMedia.Empty,store.snapshot().messages.single().media)
            store.unavailable(room);assertTrue(store.snapshot().messages.isEmpty())
            try { apply(store,replacement(3,media(first)));fail("revoked room media restored") } catch(_: ClientFailure.Protocol) { }
        } finally { store.close() }
    }
    @Test fun legacyRecoveryRequiresCompleteDescriptorsAndContiguousTextEditEvidence()=runBlocking {
        var store=store();try {
            ready(store);apply(store,accepted());apply(store,edit(2));apply(store,edit(3));store.close();legacy()
            store=store();assertEquals(media(first,second),store.snapshot().messages.single().media)
            store.close();legacy();database { db ->
                db.rawQuery("SELECT event,payload FROM records WHERE kind='message'",null).use { rows -> while(rows.moveToNext()) {
                    val value=Json.parseToJsonElement(rows.getBlob(1).toString(Charsets.UTF_8)).jsonObject
                    if(value["message_revision"]?.jsonPrimitive?.longOrNull==2L) db.execSQL("DELETE FROM records WHERE event=?",arrayOf(rows.getString(0)))
                } }
            }
            store=store();assertNull(store.snapshot().messages.single().media)
            // A complete replacement restores known facts at the current version without inferring the gap.
            apply(store,replacement(4,media(second)));assertEquals(media(second),store.snapshot().messages.single().media)
        } finally { store.close() }
    }
    @Test fun legacyMissingOrInvalidDescriptorStaysUnknownAndTombstoneStaysEmpty()=runBlocking {
        var store=store();try {
            ready(store);apply(store,accepted());store.close();legacy()
            database { db ->
                val malformed=JsonObject(accepted()-"media_presentations").toString().toByteArray()
                db.execSQL("UPDATE records SET payload=? WHERE kind='message'",arrayOf(malformed))
            }
            store=store();assertNull(store.snapshot().messages.single().media)
            apply(store,replacement(2,media(first)));assertEquals(media(first),store.snapshot().messages.single().media)
            apply(store,buildJsonObject { edit(3).forEach { (k,v)->put(k,v) };put("event_type","message.withdrawn") })
            store.close();legacy();store=store();assertEquals(MessageMedia.Empty,store.snapshot().messages.single().media)
        } finally { store.close() }
    }
    @Test fun pendingMediaIdentitiesAreVisibleButCarryNoTrustedDescriptor()=runBlocking {
        var store=store();try {
            val command=MessageCommand.withMedia(actor,room,"",persistentListOf(first,second),System.currentTimeMillis()+60000)
            store.enqueue(command);store.close();store=store()
            val pending=store.snapshot().messages.single();assertEquals("[附件]",pending.text);assertEquals(0L,pending.revision)
            assertEquals(persistentListOf(first,second),pending.media!!.ids);assertNull(pending.media!!.presentations)
        } finally { store.close() }
    }
}
