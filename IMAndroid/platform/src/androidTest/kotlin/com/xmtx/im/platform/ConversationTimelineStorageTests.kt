package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class ConversationTimelineStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private suspend fun ready(s: SqliteClientStore) = s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(10000).setViewerMembershipRevision(1).build())
    // A large persisted projection fixture isolates index/window behavior from network recovery costs.
    private fun seed(count: Int, sequence: (Int)->Long = {it.toLong()}) = database { db ->
        db.beginTransaction()
        try {
            db.compileStatement("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn,rich) VALUES (?,?,?,?,?,1,?,?,0,?)").use { insert ->
                for(n in 1..count) {
                    insert.bindString(1,id(n).value);insert.bindString(2,room.value);insert.bindString(3,actor.value)
                    insert.bindString(4,"本地消息 $n");insert.bindLong(5,n.toLong());insert.bindLong(6,sequence(n));insert.bindLong(7,n.toLong())
                    insert.bindString(8,(if(n==count) MessageRichContent(replyTo=id(1)) else MessageRichContent.Empty).payload().toString())
                    insert.executeInsert();insert.clearBindings()
                }
            }
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}
    }
    @Test fun deepHistoryUsesBoundedIndexedPagesAndReopensWithoutOffset() = runBlocking<Unit> {
        var s=store();try {
            ready(s);seed(1800)
            val latest=s.conversationTimeline(room,actor);assertEquals((1681..1800).map(::id),latest.messages.map {it.id})
            val deep=s.locateTimelineMessage(room,actor,id(8),before=3,after=4) as TimelineLocation.Found
            assertEquals((5..12).map(::id),deep.window.messages.map {it.id});assertEquals(id(13),deep.window.newerBoundary?.message)
            val ids=mutableListOf<MessageId>();var selection: TimelineSelection=TimelineSelection.Latest
            while(true) {
                val page=s.conversationTimeline(room,actor,selection,100);assertTrue(page.messages.size<=100)
                ids+=page.messages.map {it.id};selection=TimelineSelection.Before(page.olderCursor ?: break)
            }
            assertEquals(1800,ids.size);assertEquals(1800,ids.toSet().size)
            s.close();s=store();assertEquals(deep,s.locateTimelineMessage(room,actor,id(8),3,4))
            database {db -> db.rawQuery("EXPLAIN QUERY PLAN SELECT id,sequence FROM messages WHERE room=? AND (sequence,id)<(?,?) ORDER BY sequence DESC,id DESC LIMIT 120",
                arrayOf(room.value,"1000",id(1000).value)).use {rows ->
                val plan=buildList {while(rows.moveToNext()) add(rows.getString(3))}.joinToString(" ")
                assertTrue(plan,plan.contains("messages_timeline"));assertFalse(plan,plan.contains("TEMP B-TREE"))
            }}
        } finally {s.close()}
    }
    @Test fun equalSequencesUseIdentityTieBreakerAndDeletedBoundaryRemainsUsable() = runBlocking<Unit> {
        val s=store();try {
            ready(s);seed(9) {Long.MAX_VALUE-1}
            val middle=(s.locateTimelineMessage(room,actor,id(5),1,1) as TimelineLocation.Found).window
            assertEquals(listOf(id(4),id(5),id(6)),middle.messages.map {it.id});assertEquals(id(7),middle.newerBoundary?.message)
            database {it.execSQL("DELETE FROM messages WHERE id=?",arrayOf(id(7).value))}
            val refreshed=s.conversationTimeline(room,actor,TimelineSelection.Before(requireNotNull(middle.newerBoundary)),3)
            assertEquals(middle.messages,refreshed.messages)
            val newer=s.conversationTimeline(room,actor,TimelineSelection.After(middle.messages.last().timelineCursor()),2)
            assertEquals(listOf(id(8),id(9)),newer.messages.map {it.id});assertNull(newer.newerBoundary)
            val ids=mutableListOf<MessageId>();var selection: TimelineSelection=TimelineSelection.Latest
            while(true) {val page=s.conversationTimeline(room,actor,selection,2);ids+=page.messages.map {it.id};selection=TimelineSelection.Before(page.olderCursor ?: break)}
            assertEquals((1..9).filter {it!=7}.map(::id).toSet(),ids.toSet());assertEquals(8,ids.size)
        } finally {s.close()}
    }
    @Test fun accountRoomAndRevokedAccessNeverExposeTargetExistence() = runBlocking<Unit> {
        val s=store();try {
            ready(s);seed(5)
            val other=UserId(UUID.randomUUID().toString());val otherRoom=RoomId(UUID.randomUUID().toString())
            assertEquals(TimelineLocation.Unavailable,s.locateTimelineMessage(room,other,id(1)))
            assertTrue(s.conversationTimeline(room,other).messages.isEmpty())
            assertEquals(TimelineLocation.Unavailable,s.locateTimelineMessage(otherRoom,actor,id(1)))
            database {it.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id(1).value))}
            assertEquals(TimelineLocation.Withdrawn,s.locateTimelineMessage(room,actor,id(1)))
            s.unavailable(room)
            assertEquals(TimelineLocation.Unavailable,s.locateTimelineMessage(room,actor,id(1)))
            assertTrue(s.conversationTimeline(room,actor).messages.isEmpty())
        } finally {s.close()}
    }
    @Test fun offWindowReplyDecorationsAndReceiptEvidenceAreFiniteImmutableSnapshots() = runBlocking<Unit> {
        val s=store();try {
            ready(s);seed(240)
            val pin=GroupMetadataEffect.Pin(room,UUID.randomUUID().toString(),241,actor,1,id(240),true)
            database {db ->
                db.execSQL("INSERT INTO reaction_versions VALUES (?,?,?,?,?,?)",arrayOf<Any>(id(240).value,actor.value,"👍",room.value,1,"{}"))
                db.execSQL("INSERT INTO group_pins VALUES (?,?,?)",arrayOf(room.value,id(240).value,Json.encodeToString(pin)))
                db.execSQL("UPDATE room_cursors SET sequence=240 WHERE room=?",arrayOf(room.value))
                db.execSQL("INSERT OR REPLACE INTO room_kinds VALUES (?,'Direct')",arrayOf(room.value))
                db.execSQL("INSERT OR REPLACE INTO direct_read_projections VALUES (?,?)",arrayOf(room.value,Json.encodeToString(DirectReadProjection(room,UserId(UUID.randomUUID().toString()),200,1,true,1,1))))
            }
            val before=s.conversationTimeline(room,actor,limit=12)
            assertEquals(12,before.messages.size);assertEquals(setOf(id(1)),before.replySources.keys)
            assertFalse(before.messages.any {it.id==id(1)});assertEquals(id(240),before.reactions.single().message)
            assertTrue(before.reactions.single().own);assertEquals(setOf(id(240)),before.pinned)
            assertEquals(240L,before.checkpoint?.applied);assertEquals(200L,before.directRead?.sequence)
            database {db -> db.execSQL("UPDATE messages SET withdrawn=1,text='已撤回' WHERE id IN (?,?)",arrayOf(id(1).value,id(240).value))}
            val after=s.conversationTimeline(room,actor,limit=12)
            assertTrue(after.replySources.isEmpty());assertTrue(after.reactions.isEmpty());assertTrue(after.pinned.isEmpty())
            assertEquals("本地消息 1",before.replySources[id(1)]?.text);assertFalse(before.messages.last().withdrawn)
        } finally {s.close()}
    }
    @Test fun realProjectionEditAndWithdrawalRefreshAStableHistoryWindow() = runBlocking<Unit> {
        val s=store();try {
            ready(s)
            suspend fun apply(payload: String) {
                val cursor=s.roomCursor(room);val sequence=cursor.sequence+1
                val event=GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(payload))
                s.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence).addEvents(event).build(),cursor)
            }
            apply("""{"event_type":"message.accepted","message_id":"${id(1).value}","room_id":"${room.value}","sender_user_id":"${actor.value}","text":"original","room_sequence":1,"timeline_sequence":1,"message_revision":1,"server_created_at_ms":1}""")
            val first=s.conversationTimeline(room,actor).messages.single()
            apply("""{"event_type":"message.edited","message_id":"${id(1).value}","room_id":"${room.value}","message_revision":2,"text":"edited"}""")
            val refreshed=s.conversationTimeline(room,actor,TimelineSelection.Through(first.timelineCursor()))
            assertEquals("edited",refreshed.messages.single().text);assertEquals(first.timelineCursor(),refreshed.messages.single().timelineCursor())
            apply("""{"event_type":"message.withdrawn","message_id":"${id(1).value}","room_id":"${room.value}","message_revision":3}""")
            assertEquals(TimelineLocation.Withdrawn,s.locateTimelineMessage(room,actor,id(1)))
            assertTrue(s.conversationTimeline(room,actor).messages.single().withdrawn)
        } finally {s.close()}
    }
    @Test fun invalidWindowSizesFailBeforeAnyUnboundedRead() = runBlocking<Unit> {
        val s=store();try {
            for(limit in listOf(0,-1,201,Int.MAX_VALUE)) assertTrue(runCatching {s.conversationTimeline(room,actor,limit=limit)}.exceptionOrNull() is IllegalArgumentException)
            for((before,after) in listOf(-1 to 1,1 to -1,100 to 100,Int.MAX_VALUE to 0))
                assertTrue(runCatching {s.locateTimelineMessage(room,actor,id(1),before,after)}.exceptionOrNull() is IllegalArgumentException)
        } finally {s.close()}
    }
}
