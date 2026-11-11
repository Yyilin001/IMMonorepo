package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class OutboxWindowStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun command(n: Int)=MessageCommand.text(actor,room,"等待发送 $n",600000+n.toLong(),id(10000+n).value)
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private suspend fun seed(s: SqliteClientStore,count: Int=300) {
        s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(count.toLong()).setViewerMembershipRevision(1).build())
        database {db->db.beginTransaction();try {
            for(n in 1..count) insert(db,id(n),n.toLong())
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}}
    }
    private fun insert(db: SQLiteDatabase,message: MessageId,sequence: Long) {
        db.execSQL("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn) VALUES (?,?,?,?,?,1,?,?,0)",
            arrayOf<Any>(message.value,room.value,actor.value,"正式消息 $sequence",sequence,sequence,sequence))
    }
    private fun receipt(command: MessageSendOperation,message: MessageId?=null)=MessageSendOperationReceipt.newBuilder()
        .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(actor.value).setRoomId(room.value).setOperationId(command.clientMessageId))
        .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint)).setResolvedAtMs(100000)
        .apply {if(message!=null) setAccepted(MessageSendOperationAcceptance.newBuilder().setMessageId(message.value).setRoomSequence(301)) else setRejected(MessageSendOperationRejection.newBuilder().setReasonValue(2))}.build()
    @Test fun tailIsFiniteAndGlobalPublicationDoesNotDecodeUnrelatedHistoryOrCommands()=runBlocking<Unit> {
        val s=store();try {
            seed(s,2000);for(n in 1..120) s.enqueue(command(n))
            database {db->db.execSQL("UPDATE messages SET rich='malformed' WHERE id=?",arrayOf(id(1).value));db.execSQL("UPDATE outbox SET command=? WHERE id=?",arrayOf(byteArrayOf(0),command(1).clientMessageId))}
            val snapshot=s.appSnapshot();assertTrue(snapshot.messages.isEmpty());assertEquals("正式消息 2000",snapshot.conversations.single().preview)
            assertTrue(runCatching {s.snapshot()}.isFailure)
            val window=s.conversationTimeline(room,actor)
            assertEquals(120,window.messages.size);assertEquals((81..120).map {MessageId(command(it).clientMessageId)},window.outbox.map {it.id})
            assertTrue(window.outbox.all {it.revision==0L && it.roomSequence==0L && it.delivery==Delivery.Pending})
            val history=s.conversationTimeline(room,actor,TimelineSelection.Before(TimelineCursor(1500,id(1500))))
            assertTrue(history.outbox.isEmpty());assertNotNull(history.newerBoundary)
            val emptyHistory=s.conversationTimeline(room,actor,TimelineSelection.Before(TimelineCursor(1,id(1))))
            assertTrue(emptyHistory.messages.isEmpty());assertTrue(emptyHistory.outbox.isEmpty());assertFalse(emptyHistory.latest)
            assertTrue(s.conversationTimeline(room,UserId(UUID.randomUUID().toString())).outbox.isEmpty())
            database {db->db.rawQuery("EXPLAIN QUERY PLAN SELECT command FROM outbox WHERE room=? ORDER BY rowid DESC LIMIT 40",arrayOf(room.value)).use {rows->
                val plan=buildList {while(rows.moveToNext()) add(rows.getString(3))}.joinToString(" ");assertTrue(plan,plan.contains("outbox_room_tail"));assertFalse(plan,plan.contains("TEMP B-TREE"))
            }}
        } finally {s.close()}
    }
    @Test fun receiptsProjectionWithdrawalAndRevocationNeverResurrectOrDuplicateEchoes()=runBlocking<Unit> {
        val s=store();try {
            seed(s);val first=MessageCommand.text(actor,room,"回复回显",600001,command(1).clientMessageId,MessageRichContent(replyTo=id(1)));val second=command(2);s.enqueue(first);s.enqueue(second)
            val pending=s.conversationTimeline(room,actor);assertEquals("正式消息 1",pending.replySources[id(1)]?.text);s.complete(first.clientMessageId,receipt(first,id(5000)));s.complete(second.clientMessageId,receipt(second))
            val resolved=s.conversationTimeline(room,actor)
            assertEquals(listOf(id(5000),MessageId(second.clientMessageId)),resolved.outbox.map {it.id});assertEquals(listOf(Delivery.Accepted,Delivery.Failed),resolved.outbox.map {it.delivery})
            assertEquals(Delivery.Pending,pending.outbox.first().delivery)
            val location=s.locateTimelineMessage(room,actor,MessageId(second.clientMessageId)) as TimelineLocation.Found
            assertTrue(location.window.outbox.any {it.id.value==second.clientMessageId})
            database {insert(it,id(5000),301)}
            val projected=s.conversationTimeline(room,actor);assertEquals(1,projected.messages.count {it.id==id(5000)});assertEquals(1,projected.outbox.size)
            database {db->db.execSQL("DELETE FROM messages WHERE id=?",arrayOf(id(5000).value));db.execSQL("INSERT INTO message_tombstones(id,room,revision,redacted) VALUES (?,?,2,1)",arrayOf(id(5000).value,room.value))}
            assertTrue(s.conversationTimeline(room,actor).outbox.none {it.id==id(5000)});assertTrue(s.snapshot().messages.none {it.id==id(5000)})
            s.unavailable(room);assertTrue(s.conversationTimeline(room,actor).outbox.isEmpty());assertTrue(s.appSnapshot().conversations.isEmpty())
        } finally {s.close()}
    }
    @Test fun legacyOutboxMigrationPreservesOrderingReceiptsAndMetadataSnapshotParity()=runBlocking<Unit> {
        var s=store();try {
            seed(s,1);for(n in 1..60) s.enqueue(command(n))
            s.complete(command(60).clientMessageId,receipt(command(60),id(8000)))
            val expected=s.snapshot();assertEquals(expected.conversations,s.appSnapshot().conversations)
            s.close()
            database {db->db.execSQL("ALTER TABLE outbox RENAME TO old_outbox");db.execSQL("CREATE TABLE outbox(id TEXT PRIMARY KEY,command BLOB NOT NULL,receipt BLOB)");db.execSQL("INSERT INTO outbox SELECT id,command,receipt FROM old_outbox ORDER BY rowid");db.execSQL("DROP TABLE old_outbox")}
            s=store();val tail=s.conversationTimeline(room,actor).outbox
            assertEquals(40,tail.size);assertEquals(MessageId(command(21).clientMessageId),tail.first().id);assertEquals(id(8000),tail.last().id)
            assertEquals(Delivery.Accepted,tail.last().delivery);assertEquals(59,s.pending().size)
            assertEquals(expected.conversations,s.appSnapshot().conversations);assertTrue(s.appSnapshot().messages.isEmpty())
            assertTrue(runCatching {s.enqueue(command(61).toBuilder().setSenderUserId(UserId(UUID.randomUUID().toString()).value).build())}.isFailure)
        } finally {s.close()}
    }
}
