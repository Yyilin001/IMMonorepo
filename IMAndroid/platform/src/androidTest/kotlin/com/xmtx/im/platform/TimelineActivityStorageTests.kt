package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class TimelineActivityStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString());private val room=RoomId(UUID.randomUUID().toString())
    private fun id(n:Int)=UUID(0,n.toLong()).toString().uppercase()
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database(block:(SQLiteDatabase)->Unit) {
        val hash=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$hash.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(block)
    }
    private fun payload(sequence:Long,kind:String="direct_message_restricted")="""{"room_id":"${room.value}","event_type":"$kind","timeline_sequence":$sequence,"server_created_at_ms":5}"""
    private suspend fun project(s:SqliteClientStore,n:Int,sequence:Long=n.toLong(),kind:String="direct_message_restricted") {
        val cursor=s.cursor()
        s.commit(SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("next").setSyncReceipt("receipt")
            .addRecords(SyncRecord.newBuilder().setSourceEventId(id(n)).setProjectionKind("timeline_activity").setUserSyncSequence(cursor.sequence+1).setPayload(ByteString.copyFromUtf8(payload(sequence,kind)))).build(),cursor)
    }
    private fun message(n:Int,sequence:Long=n.toLong())=database {db->db.execSQL("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,1,?,?,0)",arrayOf(id(n),room.value,actor.value,"message $n",5,sequence,n))}
    @Test fun sameMessageAndActivityIdentityUseTypedCursorInBothDirectionsWithoutDuplicates()=runBlocking {
        val s=store()
        try {
            for(n in 1..6) {project(s,n);message(n)}
            val keys=mutableListOf<String>();var selection:TimelineSelection=TimelineSelection.Latest
            while(true) {val page=s.conversationTimeline(room,actor,selection,3);assertTrue(page.entries.size<=3);keys+=page.entries.map {it.key};selection=TimelineSelection.Before(page.olderCursor ?: break)}
            assertEquals(12,keys.size);assertEquals(12,keys.toSet().size)
            val cursor=TimelineCursor(3,MessageId(id(3)))
            val after=s.conversationTimeline(room,actor,TimelineSelection.After(cursor),3)
            assertEquals(listOf("activity:${id(3)}",id(4),"activity:${id(4)}"),after.entries.map {it.key})
            val before=s.conversationTimeline(room,actor,TimelineSelection.Before(cursor.copy(kind=TimelineItemKind.Activity)),1)
            assertEquals(listOf(id(3)),before.entries.map {it.key})
            val located=(s.locateTimelineMessage(room,actor,MessageId(id(3)),1,1) as TimelineLocation.Found).window
            assertEquals(listOf("activity:${id(2)}",id(3),"activity:${id(3)}"),located.entries.map {it.key})
        } finally {s.close()}
    }
    @Test fun activityOnlyWindowsReopenRemainBoundedAndNeverBecomeMessageSourcesOrReadEvidence()=runBlocking {
        var s=store()
        try {
            for(n in 1..12) project(s,n)
            s.close();s=store()
            val page=s.conversationTimeline(room,actor,limit=4)
            assertEquals(listOf(9L,10,11,12),page.activities.map {it.sequence});assertTrue(page.messages.isEmpty());assertNull(page.checkpoint)
            assertTrue(s.snapshot().messages.isEmpty());assertEquals(TimelineLocation.Unavailable,s.locateTimelineMessage(room,actor,MessageId(id(10))))
            val located=(s.locateTimelineActivity(room,actor,id(5),1,1) as TimelineLocation.Found).window
            assertEquals(listOf(4L,5,6),located.activities.map {it.sequence});assertEquals(7L,located.newerBoundary?.sequence)
            assertTrue(s.conversationTimeline(room,UserId("another")).activities.isEmpty())
            s.unavailable(room);assertFalse(s.conversationTimeline(room,actor).available)
            assertEquals(TimelineLocation.Unavailable,s.locateTimelineActivity(room,actor,id(5)))
        } finally {s.close()}
    }
    @Test fun immutableEventAndRoomSequenceConflictsRollBackPersonalCursor()=runBlocking {
        val s=store()
        try {
            project(s,1);project(s,1);val before=s.cursor()
            for(action in listOf<suspend ()->Unit>({project(s,1,2)},{project(s,2,1)},{project(s,1,1,"system_account_read_only")},{project(s,3,3,"peer_blocked_you")})) {
                try {action();fail()} catch(expected:Exception) {}
                assertEquals(before,s.cursor());assertEquals(1,s.conversationTimeline(room,actor).activities.size)
            }
        } finally {s.close()}
    }
    @Test fun oldRawProjectionMigratesOnceWithoutPreservingExtraPrivateFields()=runBlocking {
        var s=store();s.close()
        database {db->db.execSQL("INSERT INTO records VALUES (?,?,?,?)",arrayOf(id(1),"timeline_activity",payload(1).dropLast(1).plus(",\"internal_reason\":\"not-displayable\"}").toByteArray(),room.value))}
        s=store()
        try {
            assertEquals(1,s.conversationTimeline(room,actor).activities.size)
            database {db->db.rawQuery("SELECT COUNT(*) FROM records WHERE kind='timeline_activity'",null).use {it.moveToFirst();assertEquals(0,it.getInt(0))}}
            s.close();s=store();assertEquals(1,s.conversationTimeline(room,actor).activities.size)
        } finally {s.close()}
    }
    @Test fun snapshotRetainsPrivateHistoryOnlyForRoomsInTheNewAuthorizedBaseline()=runBlocking {
        val s=store()
        try {
            project(s,1)
            val roomPayload="""{"room_id":"${room.value}","event_type":"room.created","title":"room","membership_revision":1}"""
            val fixture=snapshotFixture(listOf(listOf(SnapshotItem("room",room.value,id(99),1,ByteString.copyFromUtf8(roomPayload)))))
            s.stage(fixture.manifest);fixture.pages.forEach {s.importSnapshotPage(fixture.manifest,it)}
            s.prepareSnapshotActivation(fixture.manifest);assertEquals(1,s.conversationTimeline(room,actor).activities.size)
            s.activateAcknowledgedSnapshot(fixture.manifest);assertEquals(1,s.conversationTimeline(room,actor).activities.size)
            val empty=snapshotFixture(emptyList()).manifest.toBuilder().setGeneration(3).build()
            s.stage(empty);s.prepareSnapshotActivation(empty);s.activateAcknowledgedSnapshot(empty)
            assertTrue(s.conversationTimeline(room,actor).activities.isEmpty())
        } finally {s.close()}
    }
}
