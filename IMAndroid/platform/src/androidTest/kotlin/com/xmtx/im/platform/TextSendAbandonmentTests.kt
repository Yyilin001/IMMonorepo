package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class TextSendAbandonmentTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun command()=MessageCommand.text(actor,room,"确定未发送",600000)
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private suspend fun expired(s: SqliteClientStore): MessageSendOperation {
        val c=command();s.enqueue(c);assertNull(s.claimSend(600001));return c
    }
    @Test fun abandonmentIsDurableIdempotentAndNeverResurrectsOrBlocksLaterSends()=runBlocking<Unit> {
        var s=store();try {
            s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setViewerMembershipRevision(0).build())
            val c=expired(s);val before=s.sendHistory(room,actor).items.single()
            coroutineScope {(1..8).map {async {s.abandonUnsentText(room,actor,c.clientMessageId)}}.awaitAll()}
            s.close();s=store();s.abandonUnsentText(room,actor,c.clientMessageId)
            val after=s.sendHistory(room,actor).items.single()
            assertEquals(before.copy(canReplaceText=false,abandoned=true),after)
            assertFalse(after.canAbandonText);assertTrue(s.conversationTimeline(room,actor).outbox.isEmpty())
            s.resumeSend(room,actor,c.clientMessageId,700000);assertNull(s.claimSend(700000))
            assertTrue(runCatching {s.replaceUnsentText(room,actor,c.clientMessageId,700000)}.isFailure)
            val next=MessageCommand.text(actor,room,"新的独立发送",1300000);s.enqueue(next)
            assertEquals(next,s.claimSend(700000)!!.command)
            database {db->db.rawQuery("SELECT command,receipt FROM outbox WHERE id=?",arrayOf(c.clientMessageId)).use {
                assertTrue(it.moveToFirst());assertEquals(c,MessageSendOperation.parseFrom(it.getBlob(0)));assertTrue(it.isNull(1))
            }}
        } finally {s.close()}
    }
    @Test fun replacementAndAbandonmentAreMutuallyExclusiveUnderConcurrentRequests()=runBlocking<Unit> {
        val s=store();try {
            val c=expired(s)
            val results=coroutineScope {
                val abandon=async {runCatching {s.abandonUnsentText(room,actor,c.clientMessageId)}}
                val replace=async {runCatching {s.replaceUnsentText(room,actor,c.clientMessageId,700000)}}
                abandon.await().isSuccess to replace.await().isSuccess
            }
            assertTrue(results.first.xor(results.second))
            val row=s.sendHistory(room,actor).items.first {it.operation==c.clientMessageId}
            assertTrue(row.abandoned.xor(row.replacement!=null));assertFalse(row.canReplaceText)
            if(row.abandoned) assertEquals(1,s.sendHistory(room,actor).items.size)
            else {
                assertEquals(2,s.sendHistory(room,actor).items.size)
                assertTrue(runCatching {s.abandonUnsentText(room,actor,c.clientMessageId)}.isFailure)
            }
        } finally {s.close()}
    }
    @Test fun failedWriteRollsBackAndAccountRoomAndRevocationRemainMandatory()=runBlocking<Unit> {
        var s=store();try {
            val c=expired(s)
            database {it.execSQL("CREATE TRIGGER fail_abandon BEFORE INSERT ON abandoned_text_sends BEGIN SELECT RAISE(ABORT,'test rollback'); END")}
            assertTrue(runCatching {s.abandonUnsentText(room,actor,c.clientMessageId)}.isFailure)
            assertTrue(s.sendHistory(room,actor).items.single().canAbandonText)
            database {it.execSQL("DROP TRIGGER fail_abandon")}
            assertTrue(runCatching {s.abandonUnsentText(room,UserId(UUID.randomUUID().toString()),c.clientMessageId)}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(RoomId(UUID.randomUUID().toString()),actor,c.clientMessageId)}.isFailure)
            s.unavailable(room);assertTrue(runCatching {s.abandonUnsentText(room,actor,c.clientMessageId)}.isFailure)
            database {db->db.rawQuery("SELECT COUNT(*) FROM abandoned_text_sends",null).use {it.moveToFirst();assertEquals(0,it.getInt(0))}}
            s.close();s=store();assertTrue(room in s.appSnapshot().revokedRooms)
            assertTrue(runCatching {s.enqueue(command())}.isFailure)
            assertTrue(runCatching {s.abandonUnsentText(room,actor,c.clientMessageId)}.isFailure)
            s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setViewerMembershipRevision(0).build())
            s.abandonUnsentText(room,actor,c.clientMessageId)
            assertTrue(s.sendHistory(room,actor).items.single().abandoned)
        } finally {s.close()}
    }
}
