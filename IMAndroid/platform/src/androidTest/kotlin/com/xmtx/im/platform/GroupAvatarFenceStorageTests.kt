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
import java.util.UUID

class GroupAvatarFenceStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun value(revision: Long,sequence: Long)=buildJsonObject {
        put("event_type","group.avatar_changed");put("room_id",room.value);put("revision",revision);put("room_sequence",sequence);put("server_created_at_ms",1000)
    }
    private suspend fun ready(store: SqliteClientStore,membership: Long=1) {
        store.reconcileDirectory(persistentMapOf(room to RoomKind.Group));store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(membership).setHead(20).build())
    }
    private fun event(source: String,value: JsonObject,sequence: Long)=GroupEvent.newBuilder().setSourceEventId(source).setRoomSequence(sequence)
        .setProjectionKind("group_capability").setPayload(ByteString.copyFromUtf8(value.toString())).build()
    private suspend fun apply(store: SqliteClientStore,revision: Long,sequence: Long,source: String=id(),payload: JsonObject=value(revision,sequence)) {
        store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence).addEvents(event(source,payload,sequence)).build(),store.roomCursor(room))
    }
    @Test fun invalidationReopensWithoutMediaAndConflictingBatchRollsBackCursorEpochAndFloor()=runBlocking {
        var store=store();try {
            ready(store);val initial=store.groupAvatarFence(room);assertTrue(initial.authorized)
            val source=id();apply(store,3,1,source);val first=store.groupAvatarFence(room)
            assertEquals(3L,first.revision);assertNotEquals(initial.generation,first.generation)
            val snapshot=store.snapshot();store.close();store=store();assertEquals(first,store.groupAvatarFence(room));assertEquals(snapshot.groupAvatarGeneration,store.snapshot().groupAvatarGeneration)
            val page=GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(3).addEvents(event(id(),value(4,2),2)).addEvents(event(id(),value(4,3),3)).build()
            try { store.commitRoom(page,store.roomCursor(room));fail("duplicate revision accepted") } catch(_: IllegalArgumentException) { }
            assertEquals(1L,store.roomCursor(room).sequence);assertEquals(first,store.groupAvatarFence(room));assertEquals(snapshot.groupAvatarGeneration,store.snapshot().groupAvatarGeneration)
            for(payload in listOf(JsonObject(value(4,2)+("media_id" to JsonPrimitive(id()))),JsonObject(value(4,2)+("revision" to JsonPrimitive("4"))),value(2,2))) {
                try { apply(store,4,2,payload=payload);fail("invalid event accepted") } catch(_: Exception) { }
                assertEquals(first,store.groupAvatarFence(room));assertEquals(1L,store.roomCursor(room).sequence)
            }
            try { apply(store,4,2,source);fail("source identity reused") } catch(_: IllegalArgumentException) { }
            try { apply(store,4,2,"$source/other");fail("invalid event identity accepted") } catch(_: IllegalArgumentException) { }
            assertEquals(first,store.groupAvatarFence(room))
            val file=File(context.noBackupFilesDir,"im-${store.resourceScope}.db")
            SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery("SELECT COUNT(*) FROM records WHERE kind='group_capability'",null).use { it.moveToFirst();assertEquals(0,it.getInt(0)) }
            }
        } finally { store.close() }
    }
    @Test fun snapshotRetainsOnlySameAuthorizedMembershipAndValidationDoesNotPublishEpoch()=runBlocking {
        val store=store();try {
            ready(store);apply(store,9,1);val first=store.groupAvatarFence(room);val global=store.snapshot().groupAvatarGeneration
            fun items(revision: Int)=persistentListOf(SnapshotItem("room","room:${room.value}","snapshot",1,ByteString.copyFromUtf8(buildJsonObject {
                put("event_type","room.created");put("room_id",room.value);put("membership_revision",revision);put("title","群")
                put("viewer_membership_revision",revision);put("viewer_is_member",true);put("viewer_membership_source_event_id","grant-$revision")
            }.toString())))
            val manifest=SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(10).setNextSyncToken("reset").build()
            store.validateSnapshot(items(1));assertEquals(first,store.groupAvatarFence(room));assertEquals(global,store.snapshot().groupAvatarGeneration)
            store.activateFixture(manifest,items(1));val retained=store.groupAvatarFence(room);assertEquals(9L,retained.revision);assertNotEquals(first.generation,retained.generation)
            store.activateFixture(manifest,items(2));assertEquals(0L,store.groupAvatarFence(room).revision)
            ready(store,2);apply(store,12,1);store.unavailable(room)
            assertFalse(store.groupAvatarFence(room).authorized);assertEquals(0L,store.groupAvatarFence(room).revision)
            ready(store,3);apply(store,15,1);store.reconcileDirectory(persistentMapOf());assertFalse(store.groupAvatarFence(room).authorized);assertEquals(0L,store.groupAvatarFence(room).revision)
        } finally { store.close() }
    }
    @Test fun legacyRawEventsMigrateTransactionallyAndRejectOutOfOrderContradictions()=runBlocking {
        var store=store();ready(store);val path=File(context.noBackupFilesDir,"im-${store.resourceScope}.db").path;store.close()
        val source=id()
        SQLiteDatabase.openDatabase(path,null,SQLiteDatabase.OPEN_READWRITE).use { db ->
            db.execSQL("DELETE FROM projection_migrations WHERE name='group_avatar_fences_v1'")
            db.execSQL("INSERT INTO records VALUES (?,?,?,?)",arrayOf(source,"group_capability",value(5,8).toString().toByteArray(),room.value))
            db.execSQL("INSERT INTO records VALUES (?,?,?,?)",arrayOf(id(),"group_capability",value(3,2).toString().toByteArray(),room.value))
        }
        store=store();try { assertEquals(5L,store.groupAvatarFence(room).revision) } finally { store.close() }
        SQLiteDatabase.openDatabase(path,null,SQLiteDatabase.OPEN_READWRITE).use { db ->
            db.rawQuery("SELECT COUNT(*) FROM records WHERE kind='group_capability'",null).use { it.moveToFirst();assertEquals(0,it.getInt(0)) }
            val projections=SqliteGroupAvatars(db);val before=projections.fence(room)
            projections.project(GroupAvatarEffect(source,room,5,8,1000));assertEquals(before,projections.fence(room))
            try { projections.project(GroupAvatarEffect(id(),room,4,1,1000));fail("contradictory middle event") } catch(_: IllegalArgumentException) { }
            assertEquals(before,projections.fence(room))
            db.execSQL("DELETE FROM rooms");db.execSQL("DELETE FROM room_cursors")
        }
        store=store();try {
            store.reconcileDirectory(persistentMapOf());assertEquals(0L,store.groupAvatarFence(room).revision);assertFalse(store.groupAvatarFence(room).authorized)
        } finally { store.close() }
    }
}
