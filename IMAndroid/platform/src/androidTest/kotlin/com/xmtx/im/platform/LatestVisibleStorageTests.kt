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

class LatestVisibleStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private val actor=UserId(UUID.randomUUID().toString());private val device=DeviceId(UUID.randomUUID().toString())
    private val room=RoomId(UUID.randomUUID().toString());private val message=MessageId(UUID.randomUUID().toString())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun value(head: Long=10,preview: String="摘要",revision: Long=1)=LatestVisibleSnapshot(room,1,1,head,LatestVisibleMessage(message,actor,1,revision,preview,0,100))
    private suspend fun setup(s: SqliteClientStore): String {
        s.commit(SyncBatch.newBuilder().setGeneration(1).setNextSyncToken("seed").setSyncReceipt("receipt").build(),s.cursor())
        val scope=s.beginDirectory()
        s.commitDirectoryPage(s.directoryScan(scope),RoomDirectoryPage(persistentListOf(RoomDirectoryEntry(room,RoomKind.Group,1,1)),"","topology"))
        authorize(s);return scope
    }
    private suspend fun authorize(s: SqliteClientStore,head: Long=10,revision: Long=1)=s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setOwnerEpoch(1).setViewerMembershipRevision(revision).setHead(head).setUnreadCount(head).build())
    private suspend fun commit(s: SqliteClientStore,scope: String,v: LatestVisibleSnapshot=value()): Boolean {
        val work=s.directoryWork(scope,Long.MAX_VALUE,16).firstOrNull {it.room==room} ?: RoomDirectoryWork(room,"display")
        return s.commitLatestVisible(s.beginLatestVisible(scope),work,v)
    }
    private suspend fun localMessage(s: SqliteClientStore) {
        val payload="""{"event_type":"message.accepted","room_id":"${room.value}","message_id":"${message.value}","sender_user_id":"${actor.value}","text":"旧正文","room_sequence":1,"message_revision":1,"server_created_at_ms":1}"""
        s.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(1).addEvents(GroupEvent.newBuilder().setRoomSequence(1)
            .setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(payload))).build(),RoomCursor())
    }
    private fun database(block: (SQLiteDatabase)->Unit) {
        val digest=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$digest.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(block)
    }
    @Test fun displaySnapshotPersistsWithoutCreatingMessagesAdvancingCursorOrCompletingContentWork()=runBlocking<Unit> {
        var s=store();try {
            val scope=setup(s);assertTrue(commit(s,scope))
            assertEquals(RoomCursor(),s.roomCursor(room));assertTrue(s.snapshot().messages.isEmpty())
            val preview=s.snapshot().conversations.single();assertEquals("摘要",preview.preview);assertEquals(100L,preview.updatedAt);assertEquals(10,preview.unread)
            val work=s.directoryWork(scope,0,16).single();assertFalse(work.requiresSummary);assertEquals(10L,work.targetHead)
            assertNull(s.recoveryCandidate(scope));s.close();s=store()
            assertEquals("摘要",s.snapshot().conversations.single().preview);assertEquals(RoomCursor(),s.roomCursor(room))
        } finally {s.close()}
    }
    @Test fun explicitlyEmptyObservationOverridesOldLocalWindowAndAttachmentPreviewMatchesIOS()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);localMessage(s);assertEquals("旧正文",s.snapshot().conversations.single().preview)
            assertTrue(commit(s,scope,value().copy(latest=null)));assertEquals("暂无消息",s.snapshot().conversations.single().preview)
            assertEquals(1,s.snapshot().messages.size);assertEquals(1L,s.roomCursor(room).sequence)
            val media=value(11,"").let {it.copy(latest=it.latest!!.copy(mediaCount=2))}
            assertTrue(commit(s,scope,media));assertEquals("[附件]",s.snapshot().conversations.single().preview)
        } finally {s.close()}
    }
    @Test fun staleAuthorityUnknownRoomAndConflictingObservationCannotReplaceAcceptedPreview()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);val request=s.beginLatestVisible(scope);val work=s.directoryWork(scope,0,16).single()
            assertTrue(commit(s,scope));assertFalse(commit(s,scope,value(preview="冲突")));assertFalse(commit(s,scope,value(9)))
            assertFalse(commit(s,scope,value().copy(owner=2)));assertFalse(commit(s,scope,value().copy(membership=0)))
            assertEquals("摘要",s.snapshot().conversations.single().preview)
            s.unavailable(room);assertFalse(s.commitLatestVisible(request,work,value()));assertTrue(s.snapshot().conversations.isEmpty())
            assertEquals(0,s.directoryProgress(scope).pendingRooms)
        } finally {s.close()}
    }
    @Test fun messageRevisionWithdrawalAndNewCursorInvalidatePreviewAndAtomicallyRequeueSummary()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);localMessage(s);assertTrue(commit(s,scope))
            val old=s.directoryWork(scope,0,16).single()
            database {it.execSQL("UPDATE messages SET text='新正文',revision=2 WHERE id=?",arrayOf(message.value))}
            assertEquals("新正文",s.snapshot().conversations.single().preview)
            val changed=s.directoryWork(scope,0,16).single();assertTrue(changed.requiresSummary);assertNotEquals(old.revision,changed.revision)
            assertFalse(commit(s,scope,value()));assertTrue(commit(s,scope,value(11,"更新摘要",2)))
            database {it.execSQL("UPDATE messages SET text='',withdrawn=1 WHERE id=?",arrayOf(message.value))}
            assertNotEquals("更新摘要",s.snapshot().conversations.single().preview)
            assertFalse(commit(s,scope,value(12,"不应恢复",2)));assertTrue(commit(s,scope,value(12).copy(latest=null)))
            s.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(13).build(),RoomCursor(1))
            assertTrue(s.directoryWork(scope,0,16).single().requiresSummary)
            assertNotEquals("暂无消息",s.snapshot().conversations.single().preview)
            authorize(s,20);assertFalse(commit(s,scope,value(19).copy(latest=null)))
        } finally {s.close()}
    }
    @Test fun tombstonesRejectLateBodiesAndMembershipChangeClearsCachedObservation()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);assertTrue(commit(s,scope))
            database {it.execSQL("INSERT INTO message_tombstones(id,room,revision) VALUES (?,?,1)",arrayOf(message.value,room.value))}
            assertFalse(commit(s,scope,value(11)));assertNotEquals("摘要",s.snapshot().conversations.single().preview)
            assertTrue(commit(s,scope,value(11).copy(latest=null)))
            authorize(s,20,2);assertNotEquals("暂无消息",s.snapshot().conversations.single().preview)
            assertFalse(commit(s,scope,value(20).copy(latest=null)))
        } finally {s.close()}
    }
    @Test fun connectionAndGenerationFencesRejectLateSummaryAndSnapshotValidationRollsBackInvalidations()=runBlocking<Unit> {
        val s=store();try {
            val scope=setup(s);assertTrue(commit(s,scope));val request=s.beginLatestVisible(scope);val work=s.directoryWork(scope,0,16).single()
            val next=s.beginDirectory()
            assertTrue(runCatching {s.commitLatestVisible(request,work,value())}.exceptionOrNull() is RoomDirectoryFailure)
            val current=s.beginLatestVisible(next)
            assertTrue(runCatching {s.validateSnapshot(persistentListOf(SnapshotItem("membership",room.value,"bad",1,ByteString.copyFromUtf8("{}"))))}.isFailure)
            assertEquals("摘要",s.snapshot().conversations.single().preview)
            s.activateFixture(SnapshotManifest.newBuilder().setGeneration(2).setNextSyncToken("snapshot").build(),persistentListOf())
            assertFalse(s.commitLatestVisible(current,work,value()));assertTrue(s.snapshot().conversations.isEmpty())
        } finally {s.close()}
    }
    @Test fun migrationDiscoversExistingAuthorizedRoomsOnceAndDoesNotResetRetryOnReopen()=runBlocking<Unit> {
        var s=store();try {
            val scope=setup(s);val work=s.directoryWork(scope,0,16).single();s.finishDirectoryWork(scope,work,null);s.close()
            database {it.execSQL("DELETE FROM projection_migrations WHERE name='latest_visible_v1'")}
            s=store();val next=s.beginDirectory();val migrated=s.directoryWork(next,0,16).single();assertTrue(migrated.requiresSummary)
            s.finishDirectoryWork(next,migrated,20_000);s.close();s=store()
            val again=s.beginDirectory();assertTrue(s.directoryWork(again,19_999,16).isEmpty());assertEquals(migrated.revision,s.directoryWork(again,20_000,16).single().revision)
        } finally {s.close()}
    }
}
