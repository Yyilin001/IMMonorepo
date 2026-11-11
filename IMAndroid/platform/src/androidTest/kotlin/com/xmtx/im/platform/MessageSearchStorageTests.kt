package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import com.xmtx.imclientkit.generated.im.realtime.v2.GroupEvent
import com.xmtx.imclientkit.generated.im.realtime.v2.GroupEventPage
import com.google.protobuf.ByteString
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MessageSearchStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val other=UserId(UUID.randomUUID().toString())
    private val device=DeviceId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString());private val second=RoomId(UUID.randomUUID().toString())
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private suspend fun ready(s: SqliteClientStore) {for(r in listOf(room,second)) s.acceptState(r,RoomSyncState.newBuilder().setRoomId(r.value).setHead(2000).setViewerMembershipRevision(1).build())}
    private fun insert(db: SQLiteDatabase,n: Int,text: String="query $n",time: Long=n.toLong(),r: RoomId=room,sender: UserId=actor,source: String?=text,media: MessageMedia=MessageMedia.Empty) {
        db.execSQL("INSERT INTO messages(id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn,media,rich) VALUES (?,?,?,?,?,?,1,?,?,0,?,?)",
            arrayOf<Any?>(id(n).value,r.value,sender.value,text,source,time,n.toLong()+1000,n.toLong(),media.payload().toString(),MessageRichContent.Empty.payload().toString()))
    }
    private suspend fun drain(s: SqliteClientStore,limit: Int=32) {repeat(1000) {val p=s.processMessageSearchIndex(limit);if(p.ready && p.pending==0) return};error("index did not finish")}
    @Test fun normalizedGraphemePhrasesKeepPunctuationWhitespaceAndUtf16Ranges() {
        for((query,source) in listOf("abc" to "ＡＢＣ", "é" to "e\u0301", "ffi" to "ﬃ", "가" to "ㄱㅏ", "中文" to "前中文后", "👩‍👩‍👧‍👦" to "家庭👩‍👩‍👧‍👦好", "👍🏽" to "👍🏽", "İ" to "i\u0307", "a\r\nb" to "A\r\nB")) {
            val match=MessageSearchText(query).preview(source)
            assertNotNull("$query / $source",match);assertTrue(match!!.ranges.isNotEmpty())
            match.ranges.forEach {assertTrue(it.offset+it.length<=match.text.length)}
        }
        assertNull(MessageSearchText("👩").preview("👩‍👩‍👧‍👦"));assertNull(MessageSearchText("a b").preview("ab"))
        assertNull(MessageSearchText("e").preview("é"));assertNull(MessageSearchText("a\nb").preview("a\r\nb"))
        val preview=MessageSearchText("😀é").preview("前".repeat(200)+"😀e\u0301"+"后".repeat(200))!!
        assertTrue(preview.text.startsWith("…😀e\u0301"));assertEquals(MessageSearchRange(1,4),preview.ranges.single())
        assertTrue(preview.text.length<140)
    }
    @Test fun ftsMatchesLiteralOperatorTextAndFinitePagesAcrossLargeHistory()=runBlocking<Unit> {
        val s=store();try {
            ready(s);database {db ->db.beginTransaction();try {
                (1..700).forEach {insert(db,it,"查询 ＡＢＣ $it")};insert(db,701,"% OR \" ' * - 查询");db.setTransactionSuccessful()
            } finally {db.endTransaction()}}
            assertTrue(runCatching {s.searchMessages(actor,MessageSearchRequest("abc"))}.exceptionOrNull() is MessageSearchFailure.Building)
            drain(s)
            val seen=mutableSetOf<MessageId>();var request=MessageSearchRequest("abc",limit=37)
            while(true) {val page=s.searchMessages(actor,request);assertTrue(page.hits.size<=37);page.hits.forEach {assertTrue(seen.add(it.message))};request=request.copy(cursor=page.next ?: break)}
            assertEquals(700,seen.size)
            assertEquals(id(701),s.searchMessages(actor,MessageSearchRequest("% OR \" ' * -")).hits.single().message)
            assertTrue(s.searchMessages(actor,MessageSearchRequest("' OR 1=1 --")).hits.isEmpty())
        } finally {s.close()}
    }
    @Test fun staleCandidatesNeverExposeEditedWithdrawnOrRevokedBodiesBeforeWorkerRuns()=runBlocking<Unit> {
        val s=store();try {
            ready(s);database {insert(it,1,"old secret")};drain(s)
            database {it.execSQL("UPDATE messages SET text='new body',source_text='new body',revision=2 WHERE id=?",arrayOf(id(1).value))}
            assertTrue(s.searchMessages(actor,MessageSearchRequest("old")).hits.isEmpty())
            assertTrue(s.searchMessages(actor,MessageSearchRequest("new")).hits.isEmpty());assertTrue(s.messageSearchProgress().pending>0)
            drain(s);assertEquals(id(1),s.searchMessages(actor,MessageSearchRequest("new")).hits.single().message)
            database {it.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id(1).value))}
            assertTrue(s.searchMessages(actor,MessageSearchRequest("new")).hits.isEmpty())
            database {insert(it,2,"other secret")};drain(s);s.unavailable(room)
            assertTrue(s.searchMessages(actor,MessageSearchRequest("secret")).hits.isEmpty())
        } finally {s.close()}
    }
    @Test fun cursorPinsPublicationAndScopeAndCannotCrossReopenOrSnapshotGeneration()=runBlocking<Unit> {
        var s=store();try {
            ready(s);database {db->(1..5).forEach {insert(db,it,"needle",time=10)}};drain(s)
            val first=s.searchMessages(actor,MessageSearchRequest("needle",limit=2));val cursor=first.next!!
            database {db->insert(db,6,"needle",time=0);db.execSQL("UPDATE messages SET revision=2 WHERE id=?",arrayOf(id(3).value))};drain(s)
            val rest=s.searchMessages(actor,MessageSearchRequest("needle",limit=100,cursor=cursor))
            assertEquals(listOf(id(2),id(1)),rest.hits.map {it.message})
            for(request in listOf(MessageSearchRequest("changed",cursor=cursor),MessageSearchRequest("needle",scope=MessageSearchScope.Room(room),cursor=cursor),MessageSearchRequest("needle",sender=other,cursor=cursor)))
                assertTrue(runCatching {s.searchMessages(actor,request)}.exceptionOrNull() is MessageSearchFailure.InvalidContinuation)
            assertTrue(runCatching {s.searchMessages(other,MessageSearchRequest("needle",cursor=cursor))}.exceptionOrNull() is ClientFailure.SignedOut)
            database {it.execSQL("UPDATE cursor SET generation=generation+1")}
            assertTrue(runCatching {s.searchMessages(actor,MessageSearchRequest("needle",cursor=cursor))}.exceptionOrNull() is MessageSearchFailure.InvalidContinuation)
            val fresh=s.searchMessages(actor,MessageSearchRequest("needle",limit=2)).next!!
            s.close();s=store();assertTrue(s.messageSearchProgress().ready)
            assertTrue(runCatching {s.searchMessages(actor,MessageSearchRequest("needle",cursor=fresh))}.exceptionOrNull() is MessageSearchFailure.InvalidContinuation)
        } finally {s.close()}
    }
    @Test fun roomOrderingUsesAcceptedPositionsAndSenderAndMediaFiltersUseVerifiedFacts()=runBlocking<Unit> {
        val s=store();try {
            ready(s);val mediaId=UUID.randomUUID().toString().uppercase()
            val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),mediaId),1,"image.png","image/png",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready,20,20)
            val image=MessageMedia(persistentListOf(mediaId),persistentListOf(MessageMediaPresentation(mediaId,MessageMediaKind.Image,"image/png",100,descriptor)))
            database {db->insert(db,1,"[附件]",time=100,source="",media=image);insert(db,2,"[附件]",time=90,source="[附件]");insert(db,3,"文字",time=80,sender=other);insert(db,4,"文字",r=second)}
            drain(s)
            assertEquals(listOf(id(2)),s.searchMessages(actor,MessageSearchRequest("附件")).hits.map {it.message})
            assertEquals(id(1),s.searchMessages(actor,MessageSearchRequest("",content=MessageSearchContent.Image)).hits.single().message)
            assertTrue(s.searchMessages(actor,MessageSearchRequest("",content=MessageSearchContent.File)).hits.isEmpty())
            assertEquals(listOf(id(2),id(1)),s.searchMessages(actor,MessageSearchRequest("",scope=MessageSearchScope.Room(room),sender=actor)).hits.map {it.message})
            assertEquals(listOf(id(1),id(2),id(4)),s.searchMessages(actor,MessageSearchRequest("",sender=actor)).hits.map {it.message})
            assertEquals(id(3),s.searchMessages(actor,MessageSearchRequest("",scope=MessageSearchScope.Sender(other))).hits.single().message)
            assertEquals(listOf(id(3)),s.searchMessages(actor,MessageSearchRequest("文字",scope=MessageSearchScope.Room(room))).hits.map {it.message})
        } finally {s.close()}
    }
    @Test fun boundedBootstrapResumesAndFailedIndexTransactionDoesNotAdvancePublication()=runBlocking<Unit> {
        var s=store();try {
            ready(s);database {db->(1..8).forEach {insert(db,it)}}
            val partial=s.processMessageSearchIndex(2);assertFalse(partial.ready)
            s.close();s=store();assertFalse(s.messageSearchProgress().ready)
            database {it.execSQL("CREATE TRIGGER fail_search BEFORE INSERT ON message_search_documents BEGIN SELECT RAISE(ABORT,'test'); END")}
            val before=s.messageSearchProgress();assertTrue(runCatching {s.processMessageSearchIndex(2)}.isFailure);assertEquals(before,s.messageSearchProgress())
            database {it.execSQL("DROP TRIGGER fail_search")};drain(s,2)
            val first=s.searchMessages(actor,MessageSearchRequest("query",limit=2));assertNotNull(first.next)
            s.rebuildMessageSearchIndex();assertFalse(s.messageSearchProgress().ready);drain(s,2)
            assertTrue(runCatching {s.searchMessages(actor,MessageSearchRequest("query",cursor=first.next))}.exceptionOrNull() is MessageSearchFailure.InvalidContinuation)
            assertEquals(8,s.searchMessages(actor,MessageSearchRequest("query")).hits.size)
        } finally {s.close()}
    }
    @Test fun legacyPlaceholderRecoveryUsesOnlyTheCurrentRecordedBodyRevision()=runBlocking<Unit> {
        var s=store();try {
            ready(s)
            database {db ->
                insert(db,1,"[附件]",source=null);insert(db,2,"[附件]",source=null);insert(db,3,"[附件]",source=null)
                for((n,text,revision) in listOf(Triple(1,"[附件]",1),Triple(2,"",1),Triple(3,"[附件]",2))) {
                    val payload="""{"event_type":"message.accepted","message_id":"${id(n).value}","room_id":"${room.value}","message_revision":$revision,"text":"$text"}""".toByteArray()
                    db.execSQL("INSERT INTO records VALUES (?,'message',?,?)",arrayOf(UUID.randomUUID().toString(),payload,room.value))
                }
            }
            s.processMessageSearchIndex(1);s.close();s=store();drain(s,1)
            assertEquals(listOf(id(1)),s.searchMessages(actor,MessageSearchRequest("附件")).hits.map {it.message})
            database {db -> db.rawQuery("SELECT source_text FROM messages WHERE id=?",arrayOf(id(2).value)).use {assertTrue(it.moveToFirst());assertEquals("",it.getString(0))}}
            database {db -> db.rawQuery("SELECT source_text FROM messages WHERE id=?",arrayOf(id(3).value)).use {assertTrue(it.moveToFirst());assertTrue(it.isNull(0))}}
        } finally {s.close()}
    }
    @Test fun actualProjectionDistinguishesEmptyAttachmentBodyFromLiteralPlaceholderAtSameRevision()=runBlocking<Unit> {
        val s=store();try {
            ready(s)
            val mediaId=UUID.randomUUID().toString().uppercase()
            val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),mediaId),1,"image.png","image/png",100,ResourceChecksum("a".repeat(64)),ResourceState.Ready,20,20)
            val media=MessageMedia(persistentListOf(mediaId),persistentListOf(MessageMediaPresentation(mediaId,MessageMediaKind.Image,"image/png",100,descriptor)))
            fun accepted(text: String)=buildJsonObject {
                put("event_type","message.accepted");put("message_id",id(1).value);put("room_id",room.value);put("sender_user_id",actor.value)
                put("text",text);put("room_sequence",1);put("timeline_sequence",1);put("message_revision",1);put("server_created_at_ms",1)
                media.payload().forEach {(k,v)->put(k,v)};MessageRichContent.Empty.payload().forEach {(k,v)->put(k,v)}
            }
            suspend fun apply(value: JsonObject,position: Long?=null) {
                val cursor=s.roomCursor(room);val next=position ?: cursor.sequence+1
                s.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(next).addEvents(GroupEvent.newBuilder()
                    .setRoomSequence(next).setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(value.toString()))).build(),cursor)
            }
            apply(accepted(""));drain(s)
            assertTrue(s.searchMessages(actor,MessageSearchRequest("附件")).hits.isEmpty())
            assertEquals(id(1),s.searchMessages(actor,MessageSearchRequest("",content=MessageSearchContent.Image)).hits.single().message)
            val before=s.roomCursor(room)
            // A complete edit replacement delegates to the accepted-state comparison without changing its room position.
            val conflicting=buildJsonObject {
                put("event_type","message.edited");put("message_id",id(1).value);put("room_id",room.value);put("message_revision",1)
                put("replacement",buildJsonObject {put("schema_version",1);put("accepted_membership_revision",1);put("accepted_event_id",UUID.randomUUID().toString());put("state",accepted("[附件]"))})
            }
            assertTrue(runCatching {apply(conflicting)}.exceptionOrNull() is ClientFailure.Protocol);assertEquals(before,s.roomCursor(room))
            val edited=buildJsonObject {put("event_type","message.edited");put("message_id",id(1).value);put("room_id",room.value);put("message_revision",2);put("text","[附件]")}
            apply(edited);drain(s);assertEquals(id(1),s.searchMessages(actor,MessageSearchRequest("附件")).hits.single().message)
            val withdrawn=buildJsonObject {put("event_type","message.withdrawn");put("message_id",id(1).value);put("room_id",room.value);put("message_revision",3)}
            apply(withdrawn);assertTrue(s.searchMessages(actor,MessageSearchRequest("附件")).hits.isEmpty())
            database {db->db.rawQuery("SELECT source_text FROM messages WHERE id=?",arrayOf(id(1).value)).use {it.moveToFirst();assertEquals("",it.getString(0))}}
        } finally {s.close()}
    }
}
