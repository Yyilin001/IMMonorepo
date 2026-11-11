package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class BackgroundRoomBudgetStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private inner class Fixture {
        val user=UserId(UUID.randomUUID().toString());val device=DeviceId(UUID.randomUUID().toString());val room=RoomId(UUID.randomUUID().toString())
        private val hash=MessageDigest.getInstance("SHA-256").digest("${user.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        private val file=File(context.noBackupFilesDir,"im-$hash.db")
        var store=SqliteClientStore(context,user,device);var now=1000L;var reports=0
        var onBody:(suspend ()->Unit)?=null
        fun reopen() {store.close();store=SqliteClientStore(context,user,device)}
        fun close() {store.close();SQLiteDatabase.deleteDatabase(file)}
        suspend fun seed() {
            store.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("seed").setSyncReceipt("receipt")
                .addRecords(SyncRecord.newBuilder().setUserSyncSequence(1).setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("room_head")
                    .setPayload(ByteString.copyFromUtf8("""{"room_id":"${room.value}","room_sequence":3,"membership_revision":1}"""))).build(),store.cursor())
            store.acknowledged(store.cursor())
            val scope=store.beginDirectory();store.commitDirectoryPage(store.directoryScan(scope),RoomDirectoryPage(persistentListOf(),"","t"))
        }
        private val wire=object:EnvelopeTransport {
            override suspend fun request(body:Envelope.Builder):Envelope {
                val request=body.build()
                return Envelope.newBuilder().apply {when {
                    request.hasRoomSyncStateBatch()->setRoomSyncStateBatchResult(RoomSyncStateBatchResult.newBuilder().addRooms(RoomSyncStateResult.newBuilder().setRoomId(room.value)
                        .setState(RoomSyncState.newBuilder().setRoomId(room.value).setOwnerEpoch(1).setViewerMembershipRevision(1).setHead(3).setUnreadCount(3))))
                    request.hasRoomLatestVisibleBatch()->setRoomLatestVisibleBatchResult(RoomLatestVisibleBatchResult.newBuilder().addRooms(RoomLatestVisibleResult.newBuilder()
                        .setRoomId(room.value).setSnapshot(RoomLatestVisibleSnapshot.newBuilder().setOwnerEpoch(1).setViewerMembershipRevision(1).setHead(3))))
                    request.hasGroupEventPullBatch()->{
                        val pull=request.groupEventPullBatch.getRooms(0);val next=pull.afterRoomSequence+1
                        onBody?.invoke()
                        setGroupEventPageBatch(GroupEventPageBatch.newBuilder().addRooms(GroupEventPageResult.newBuilder().setRoomId(room.value).setPage(
                            GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(next).setHasMore(next<3).addEvents(GroupEvent.newBuilder().setRoomSequence(next)
                                .setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(
                                    """{"event_type":"message.accepted","message_id":"${UUID.randomUUID()}","room_id":"${room.value}","sender_user_id":"${user.value}","text":"background $next","room_sequence":$next,"message_revision":1,"server_created_at_ms":1}"""))))))
                    }
                    request.hasDeviceRoomProgressReport()->{
                        reports++;assertEquals(store.roomCursor(room).sequence,request.deviceRoomProgressReport.getRooms(0).appliedThrough)
                        assertEquals(store.roomCursor(room).sequence.toInt(),store.snapshot().messages.size)
                        setDeviceRoomProgressRecorded(DeviceRoomProgressRecorded.newBuilder().addAllRooms(request.deviceRoomProgressReport.roomsList))
                    }
                    else->error("Unexpected background request ${request.bodyCase}")
                }}.build()
            }
        }
        suspend fun recovery():RoomDirectoryRecovery {
            val value=RoomDirectoryRecovery(wire,store,RoomSyncEngine(wire,store),{now});value.start()
            value.ensureVisible(store.pendingRoomHeads(limit=1).map {it.room}.let {persistentListOf(*it.toTypedArray())})
            return value
        }
    }
    private fun fixture(body:suspend CoroutineScope.(Fixture)->Unit)=runBlocking {val f=Fixture();try {body(f)} finally {f.close()}}
    @Test fun personalHeadAfterCompletedDirectoryUsesOneContentUnitAndResumesDurableCursorAfterReopen()=fixture {f->
        f.seed();val first=f.recovery().runBudget(0,1,roomPageLimit=1)
        assertEquals(0,first.directoryPages);assertEquals(1,first.processedRooms);assertEquals(1,first.appliedEventCount)
        assertTrue(first.progress.complete);assertEquals(1,first.progress.pendingRooms);assertEquals(1,f.reports)
        f.reopen();assertEquals(RoomCursor(1),f.store.roomCursor(f.room));assertEquals("background 1",f.store.snapshot().messages.single().text)
        f.now=2000;val next=f.recovery().runBudget(0,1,roomPageLimit=1)
        assertEquals(1,next.processedRooms);assertEquals(1,next.appliedEventCount);assertEquals(RoomCursor(2),f.store.roomCursor(f.room))
        assertEquals(2,f.store.snapshot().messages.size);assertEquals(2,f.reports)
    }
    @Test fun cancelledLateContentResponseCannotWriteSqliteOrSendProgress()=fixture {f->
        f.seed();val engine=f.recovery();val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        f.onBody={entered.complete(Unit);withContext(NonCancellable) {release.await()}}
        val work=async {engine.runBudget(0,1,roomPageLimit=1)}
        try {withTimeout(3000) {entered.await()};work.cancel();release.complete(Unit);work.join()}
        finally {release.complete(Unit);work.cancelAndJoin()}
        assertEquals(RoomCursor(),f.store.roomCursor(f.room));assertTrue(f.store.snapshot().messages.isEmpty());assertEquals(0,f.reports)
        f.reopen();assertEquals(RoomCursor(),f.store.roomCursor(f.room));assertTrue(f.store.snapshot().messages.isEmpty())
    }
    @Test fun newerDirectoryScopeFencesLateBackgroundBodyWithoutAcknowledgingIt()=fixture {f->
        f.seed();val engine=f.recovery();f.onBody={f.store.beginDirectory()}
        val error=runCatching {engine.runBudget(0,1,roomPageLimit=1)}.exceptionOrNull()
        assertTrue(error is RoomDirectoryFailure);assertEquals(RoomCursor(),f.store.roomCursor(f.room));assertEquals(0,f.reports)
        assertTrue(f.store.snapshot().messages.isEmpty())
    }
}
