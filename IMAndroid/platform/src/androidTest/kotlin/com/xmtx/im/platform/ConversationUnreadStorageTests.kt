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
import java.util.UUID

class ConversationUnreadStorageTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private suspend fun fixture(body:suspend (UserId,DeviceId,SqliteClientStore)->Unit) {
        val actor=UserId(id());val device=DeviceId(id());val store=SqliteClientStore(context,actor,device)
        try {body(actor,device,store)} finally {store.close();SQLiteDatabase.deleteDatabase(accountDatabaseFile(context,actor,device))}
    }
    private suspend fun ready(store:SqliteClientStore,rooms:List<RoomId>) {
        store.reconcileDirectory(rooms.associateWith {RoomKind.Direct}.toPersistentMap())
        for(page in rooms.chunked(100)) store.acceptStates(page.associateWith {
            RoomSyncState.newBuilder().setRoomId(it.value).setHead(20).setUnreadCount(14).setReadThrough(4).setLatestOwnMessageSequence(6).setViewerMembershipRevision(1).build()
        }.toPersistentMap())
    }
    private suspend fun project(store:SqliteClientStore,room:RoomId,sequence:Long) {
        val cursor=store.cursor();val next=cursor.sequence+1
        val payload=buildJsonObject {put("room_id",room.value);put("read_through_room_sequence",sequence);put("recorded_at_ms",1000)}
        store.commit(SyncBatch.newBuilder().setGeneration(maxOf(1,cursor.generation)).setNextSyncToken("$next").setSyncReceipt("$next")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(next).setSourceEventId(id()).setProjectionKind("own_read_watermark").setPayload(ByteString.copyFromUtf8(payload.toString()))).build(),cursor)
    }
    @Test fun batchCombinesLocalConfirmedAndProjectedPositionsWithoutClaimingServerReceipt()=runBlocking {
        fixture {actor,device,store->
            val first=RoomId(id());val second=RoomId(id());val missing=RoomId(id());ready(store,listOf(first,second))
            assertTrue(store.roomReadWatermarks(persistentListOf(first,second)).isEmpty())
            store.enqueueRead(first,12);val frozen=store.roomReadWatermarks(persistentListOf(first,second,first,missing))
            assertEquals(mapOf(first to 12L),frozen);assertEquals(12L,store.roomReadWatermark(first));assertNull(store.roomReadWatermark(missing))
            store.prepareReads();val initial=store.readWorks().single()
            val pending=initial.copy(submissionStarted=true,reconcile=true,status=ReadStatus.NeedsAttention,reason="currentUnavailable:permissionDenied")
            store.updateRead(initial,pending);store.archiveRead(initial.command.operation,1000)
            project(store,first,9);project(store,second,18)
            store.enqueueRead(first,16);store.prepareReads();val successor=store.readWorks().single {it.active}
            store.updateRead(successor,successor.copy(submissionStarted=true,status=ReadStatus.Confirmed,watermark=ReadWatermark(first,actor,17,1000),originalReceipt=false))
            assertEquals(mapOf(first to 17L,second to 18L),store.roomReadWatermarks(persistentListOf(first,second)))
            assertEquals(mapOf(first to 3,second to 2),store.appSnapshot().conversations.associate {it.id to it.unread})
            assertEquals(mapOf(first to 12L),frozen)
            store.close();SqliteClientStore(context,actor,device).use {reopened->
                assertEquals(17L,reopened.roomReadWatermark(first));assertEquals(18L,reopened.roomReadWatermark(second))
                assertEquals(ReadStatus.Archived,reopened.readWork(initial.command.operation)!!.status)
            }
        }
    }
    @Test fun publicReadsAreBoundedAndAppSnapshotChunksLargerConversationLists()=runBlocking {
        fixture {_,_,store->
            val rooms=(0..128).map {RoomId(id())};ready(store,rooms)
            store.enqueueRead(rooms.first(),20);store.enqueueRead(rooms.last(),19)
            assertTrue(store.roomReadWatermarks(persistentListOf()).isEmpty())
            try {store.roomReadWatermarks(rooms.toPersistentList());fail("unbounded request accepted")} catch(_:IllegalArgumentException) {}
            val counts=store.appSnapshot().conversations.associate {it.id to it.unread}
            assertEquals(129,counts.size);assertEquals(0,counts[rooms.first()]);assertEquals(1,counts[rooms.last()])
            assertTrue(rooms.drop(1).dropLast(1).all {counts[it]==14})
        }
    }
    @Test fun indexedRoomAndOperationIdentityMustMatchSerializedWork()=runBlocking {
        fixture {actor,device,store->
            val room=RoomId(id());val other=RoomId(id());ready(store,listOf(room,other));store.enqueueRead(room,12);store.prepareReads()
            val operation=store.readWorks().single().command.operation;store.close()
            SQLiteDatabase.openDatabase(accountDatabaseFile(context,actor,device).path,null,SQLiteDatabase.OPEN_READWRITE).use {db->
                db.execSQL("UPDATE read_operations SET room=? WHERE id=?",arrayOf(other.value,operation))
            }
            SqliteClientStore(context,actor,device).use {reopened->
                try {reopened.roomReadWatermark(other);fail("cross-room reading evidence escaped")} catch(_:IllegalArgumentException) {}
            }
        }
    }
}
