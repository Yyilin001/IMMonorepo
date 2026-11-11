package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

class FavoriteMessageStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString())
    private fun id(n: Int)=MessageId(UUID(0,n.toLong()).toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database(body: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
    }
    private suspend fun seed(store: SqliteClientStore,count: Int) {
        store.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(count.toLong()).setViewerMembershipRevision(1).build())
        database {db->db.beginTransaction();try {
            for(n in 1..count) db.execSQL("INSERT OR REPLACE INTO messages(id,room,sender,text,time,revision,sequence,accepted_sequence,withdrawn,rich) VALUES (?,?,?,?,?,1,?,0,0,'malformed-unrelated-rich')",
                arrayOf<Any>(id(n).value,room.value,actor.value,"收藏正文 $n",n,n))
            db.setTransactionSuccessful()
        } finally {db.endTransaction()}}
    }
    private fun value(n: Int,revision: Long=1,favorited: Boolean=true,time: Long=n.toLong()/3)=buildJsonObject {
        put("room_id",room.value);put("message_id",id(n).value);put("revision",revision);put("is_favorited",favorited);put("updated_at_ms",time)
    }
    private suspend fun project(store: SqliteClientStore,values: List<JsonObject>) {
        val cursor=store.cursor();val batch=SyncBatch.newBuilder().setGeneration(if(cursor.generation==0L) 1 else cursor.generation).setCapabilityProfile("base")
            .setNextSyncToken("token-${cursor.sequence+values.size}").setSyncReceipt("receipt-${cursor.sequence+values.size}")
        values.forEachIndexed {index,value->batch.addRecords(SyncRecord.newBuilder().setUserSyncSequence(cursor.sequence+index+1).setSourceEventId("favorite-${cursor.sequence+index+1}")
            .setProjectionKind("message_favorite").setPayload(ByteString.copyFromUtf8(value.toString())))}
        store.commit(batch.build(),cursor)
    }
    @Test fun keysetPagesCoverTiesInBothDirectionsWithoutDecodingGlobalHistory()=runBlocking<Unit> {
        var store=store();try {
            seed(store,2000);project(store,(1..125).map {value(it)})
            val first=store.favoriteMessages(actor);assertEquals((125 downTo 76).map(::id),first.items.map {it.message});assertNull(first.previous)
            val next=store.favoriteMessages(actor,FavoriteMessageSelection.Before(first.next!!))
            assertEquals((75 downTo 26).map(::id),next.items.map {it.message})
            val last=store.favoriteMessages(actor,FavoriteMessageSelection.Before(next.next!!));assertEquals((25 downTo 1).map(::id),last.items.map {it.message});assertNull(last.next)
            assertEquals(first,store.favoriteMessages(actor,FavoriteMessageSelection.After(next.previous!!)))
            assertTrue(store.favoriteMessages(UserId(UUID.randomUUID().toString())).items.isEmpty())
            assertTrue(runCatching {store.favoriteMessages(actor,limit=101)}.isFailure)
            // A captured page stays immutable while current rows change.
            project(store,listOf(value(125,2,false,1000)));assertEquals(id(124),store.favoriteMessages(actor).items.first().message);assertEquals(id(125),first.items.first().message)
            store.close();store=store();assertEquals(50,store.favoriteMessages(actor).items.size)
            assertTrue(runCatching {store.favoriteMessages(actor,FavoriteMessageSelection.Before(first.next!!))}.isFailure)
        } finally {store.close()}
    }
    @Test fun unavailableWithdrawnTombstonedAndUnacceptedMessagesNeverAppear()=runBlocking<Unit> {
        val store=store();try {
            seed(store,6);project(store,(1..7).map {value(it)})
            database {db->
                db.execSQL("UPDATE messages SET withdrawn=1 WHERE id=?",arrayOf(id(2).value))
                db.execSQL("UPDATE messages SET revision=0 WHERE id=?",arrayOf(id(3).value))
                db.execSQL("INSERT INTO message_tombstones(id,room,revision,redacted) VALUES (?,?,2,1)",arrayOf(id(4).value,room.value))
            }
            assertEquals(listOf(id(6),id(5),id(1)),store.favoriteMessages(actor).items.map {it.message})
            store.unavailable(room);assertTrue(store.favoriteMessages(actor).items.isEmpty())
        } finally {store.close()}
    }
    @Test fun receiptProjectionMigrationAndSnapshotReplacementKeepTheLatestAuthority()=runBlocking<Unit> {
        var store=store();try {
            seed(store,3);project(store,listOf(value(1,3,false,10000),value(2,1,true,10000)))
            store.enqueueFavorite(room,id(1),true,1000);store.preparePersonal(1001)
            val work=store.personalWorks().single();val command=work.command!!
            val receipt=PersonalPreferenceClient.decodeWire(command,PersonalPreferenceReceipt.newBuilder().setActorUserId(actor.value).setRoomId(room.value).setMessageId(id(1).value)
                .setOperationId(command.operation).setKind(PersonalPreferenceReceipt.Kind.MESSAGE_FAVORITE).setFingerprintVersion(1)
                .setFingerprint(ByteString.copyFrom(Base64.getDecoder().decode(command.fingerprint))).setResolvedAtMs(10000)
                .setMessageFavorite(MessageFavoriteChanged.newBuilder().setRoomId(room.value).setMessageId(id(1).value).setRevision(4).setUpdatedAtMs(10000).setIsFavorited(true)).build())
            store.updatePersonal(work,work.copy(status=PersonalStatus.Committed,receipt=receipt.wire))
            assertEquals(setOf(id(1),id(2)),store.favoriteMessages(actor).items.map {it.message}.toSet())
            val before=store.cursor();assertTrue(runCatching {project(store,listOf(value(1,4,false,10000)))}.isFailure);assertEquals(before,store.cursor())
            project(store,listOf(value(1,4,true,10000)));assertEquals(2,store.favoriteMessages(actor).items.size)
            // Simulate an older database: migration backfills both streams, including false higher revisions.
            database {it.execSQL("DELETE FROM projection_migrations WHERE name='favorite_sources_v1'");it.execSQL("DROP TABLE favorite_sources")}
            store.close();store=store();assertEquals(2,store.favoriteMessages(actor).items.size)
            store.activateFixture(SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(1).setNextSyncToken("snapshot").build(),
                persistentListOf(SnapshotItem("message_favorite",room.value,"old",1,ByteString.copyFromUtf8(value(1,2,false,10000).toString()))))
            seed(store,3)
            assertEquals(listOf(id(1)),store.favoriteMessages(actor).items.map {it.message})
            project(store,listOf(value(1,5,false,11000)));assertTrue(store.favoriteMessages(actor).items.isEmpty())
        } finally {store.close()}
    }
}
