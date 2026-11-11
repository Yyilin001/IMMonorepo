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

class SendHistoryStorageTests {
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
    @Test fun bidirectionalKeysetsAreBoundedAndRejectCrossRoomAccountAndReopenedCursors()=runBlocking<Unit> {
        var s=store();try {
            seed(s,1);for(n in 1..125) s.enqueue(command(n))
            val first=s.sendHistory(room,actor);assertEquals((125 downTo 76).map {command(it).clientMessageId},first.items.map {it.operation});assertNull(first.previous)
            val second=s.sendHistory(room,actor,SendHistorySelection.Before(first.next!!))
            assertEquals((75 downTo 26).map {command(it).clientMessageId},second.items.map {it.operation})
            val third=s.sendHistory(room,actor,SendHistorySelection.Before(second.next!!));assertEquals(25,third.items.size);assertNull(third.next)
            assertEquals(second,s.sendHistory(room,actor,SendHistorySelection.After(third.previous!!)))
            assertEquals(first,s.sendHistory(room,actor,SendHistorySelection.After(second.previous!!)))
            assertTrue(s.sendHistory(room,UserId(UUID.randomUUID().toString())).items.isEmpty())
            assertTrue(runCatching {s.sendHistory(RoomId(UUID.randomUUID().toString()),actor,SendHistorySelection.Before(first.next!!))}.isFailure)
            assertTrue(runCatching {s.sendHistory(room,actor,limit=101)}.isFailure)
            database {it.execSQL("UPDATE outbox SET command=? WHERE id=?",arrayOf(byteArrayOf(0),command(1).clientMessageId))}
            assertEquals(first,s.sendHistory(room,actor))
            s.close();s=store();assertTrue(runCatching {s.sendHistory(room,actor,SendHistorySelection.Before(first.next!!))}.isFailure)
            assertEquals(50,s.sendHistory(room,actor).items.size)
        } finally {s.close()}
    }
    @Test fun currentSourcesReplaceFrozenTextAndRemovedOrMissingSourcesNeverResurrectIt()=runBlocking<Unit> {
        val s=store();try {
            seed(s,1);for(n in 1..3) s.enqueue(command(n))
            val pending=s.sendHistory(room,actor);assertEquals(Delivery.Pending,pending.items.last().delivery)
            s.complete(command(1).clientMessageId,receipt(command(1),id(9001)))
            s.complete(command(2).clientMessageId,receipt(command(2)))
            var records=s.sendHistory(room,actor)
            assertEquals("消息正文暂不可用",records.items.last().text);assertNull(records.items.last().message)
            assertEquals(Delivery.Failed,records.items[1].delivery);assertEquals("等待发送 2",records.items[1].text)
            database {db->insert(db,id(9001),2);db.execSQL("UPDATE messages SET text='编辑后的正文',revision=2 WHERE id=?",arrayOf(id(9001).value))}
            records=s.sendHistory(room,actor);assertEquals("编辑后的正文",records.items.last().text);assertEquals(id(9001),records.items.last().message)
            database {db->db.execSQL("DELETE FROM messages WHERE id=?",arrayOf(id(9001).value));db.execSQL("INSERT INTO message_tombstones(id,room,revision,redacted) VALUES (?,?,3,1)",arrayOf(id(9001).value,room.value))}
            val removed=s.sendHistory(room,actor);assertEquals("消息已撤回或移除",removed.items.last().text);assertNull(removed.items.last().message)
            assertEquals("编辑后的正文",records.items.last().text);assertEquals("等待发送 1",pending.items.last().text)
            assertEquals(pending.items.map {it.operation},removed.items.map {it.operation})
            s.unavailable(room);assertTrue(s.sendHistory(room,actor).items.isEmpty())
        } finally {s.close()}
    }
    @Test fun migrationExposesOlderRecordsWithoutChangingFrozenCommands()=runBlocking<Unit> {
        var s=store();try {
            seed(s,1);for(n in 1..60) s.enqueue(command(n));s.close()
            database {db->db.execSQL("ALTER TABLE outbox RENAME TO old_outbox");db.execSQL("CREATE TABLE outbox(id TEXT PRIMARY KEY,command BLOB NOT NULL,receipt BLOB)");db.execSQL("INSERT INTO outbox SELECT id,command,receipt FROM old_outbox ORDER BY rowid");db.execSQL("DROP TABLE old_outbox")}
            s=store();val first=s.sendHistory(room,actor);val old=s.sendHistory(room,actor,SendHistorySelection.Before(first.next!!))
            assertEquals((10 downTo 1).map {command(it).clientMessageId},old.items.map {it.operation})
            assertEquals((1..60).map {command(it)},s.pending())
        } finally {s.close()}
    }
}
