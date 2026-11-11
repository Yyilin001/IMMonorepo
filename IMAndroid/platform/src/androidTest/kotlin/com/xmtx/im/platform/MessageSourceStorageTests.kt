package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MessageSourceStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private suspend fun seed(store: SqliteClientStore,count: Int=2000) {
        store.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(count.toLong()).setViewerMembershipRevision(1).build())
        database {db->db.beginTransaction();try {
            db.compileStatement("INSERT INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn,rich) VALUES (?,?,?,?,?,1,?,?,0,?)").use {insert->
                for(n in 1..count) {
                    insert.bindString(1,id(n).value);insert.bindString(2,room.value);insert.bindString(3,actor.value)
                    insert.bindString(4,"来源 $n");insert.bindLong(5,n.toLong());insert.bindLong(6,n.toLong());insert.bindLong(7,n.toLong())
                    insert.bindString(8,MessageRichContent(replyTo=if(n==2) id(1) else null).payload().toString());insert.executeInsert();insert.clearBindings()
                }
            };db.setTransactionSuccessful()
        } finally {db.endTransaction()}}
    }
    @Test fun exactFiniteSourcesDoNotDecodeOtherHistoryOrExpandReplies()=runBlocking<Unit> {
        val s=store();try {
            seed(s)
            // Malformed data outside the selection would make a global snapshot fail.
            database {it.execSQL("UPDATE messages SET rich='malformed' WHERE id=?",arrayOf(id(1000).value))}
            val selected=s.messageSources(room,actor,persistentSetOf(id(2),id(2000),id(3000)))
            assertEquals(setOf(id(2),id(2000)),selected.keys);assertEquals(id(1),selected[id(2)]!!.rich?.replyTo)
            assertFalse(selected.containsKey(id(1)));assertEquals("来源 2000",selected[id(2000)]!!.text)
            assertTrue(s.messageSources(room,actor,persistentSetOf()).isEmpty())
            assertEquals(100,s.messageSources(room,actor,(1..100).map(::id).toPersistentSet()).size)
            assertTrue(runCatching {s.messageSources(room,actor,(1..101).map(::id).toPersistentSet())}.exceptionOrNull() is IllegalArgumentException)
            database {db->db.rawQuery("EXPLAIN QUERY PLAN SELECT id FROM messages WHERE room=? AND id IN (?,?)",arrayOf(room.value,id(2).value,id(2000).value)).use {rows->
                val plan=buildList {while(rows.moveToNext()) add(rows.getString(3))}.joinToString(" ")
                assertTrue(plan,plan.contains("INDEX"));assertFalse(plan,plan.contains("SCAN messages"))
            }}
        } finally {s.close()}
    }
    @Test fun inaccessibleWithdrawnAndTombstonedSourcesAreOmittedButUnknownLegacyPositionIsReadable()=runBlocking<Unit> {
        val s=store();try {
            seed(s,6)
            database {db->
                db.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id(2).value))
                db.execSQL("UPDATE messages SET accepted_sequence=0 WHERE id=?",arrayOf(id(3).value))
                db.execSQL("INSERT INTO message_tombstones(id,room,revision,redacted) VALUES (?,?,2,1)",arrayOf(id(4).value,room.value))
                db.execSQL("UPDATE messages SET revision=0 WHERE id=?",arrayOf(id(5).value))
            }
            val ids=(1..6).map(::id).toPersistentSet()
            assertEquals(setOf(id(1),id(3),id(6)),s.messageSources(room,actor,ids).keys)
            assertEquals(0L,s.messageSource(room,actor,id(3))!!.roomSequence)
            assertTrue(s.messageSources(room,UserId(UUID.randomUUID().toString()),ids).isEmpty())
            assertTrue(s.messageSources(RoomId(UUID.randomUUID().toString()),actor,ids).isEmpty())
            s.unavailable(room);assertTrue(s.messageSources(room,actor,ids).isEmpty())
        } finally {s.close()}
    }
    @Test fun newerReadAndDatabaseReopenCannotMutatePreviouslyPublishedSource()=runBlocking<Unit> {
        var s=store();try {
            seed(s,3);val before=s.messageSources(room,actor,persistentSetOf(id(2)))
            database {it.execSQL("UPDATE messages SET text='新版',revision=2,rich=NULL WHERE id=?",arrayOf(id(2).value))}
            val after=s.messageSource(room,actor,id(2))!!
            assertEquals(2L,after.revision);assertEquals("新版",after.text)
            assertEquals(1L,before[id(2)]!!.revision);assertEquals("来源 2",before[id(2)]!!.text)
            s.close();s=store();assertEquals(after,s.messageSource(room,actor,id(2)))
            database {it.execSQL("DELETE FROM messages WHERE id=?",arrayOf(id(2).value))}
            assertNull(s.messageSource(room,actor,id(2)));assertEquals(1,before.size)
        } finally {s.close()}
    }
}
