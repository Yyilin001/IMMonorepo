package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class DirectSendingCapabilityStorageTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val device=DeviceId(id());private val room=RoomId(id())
    private fun store()=SqliteClientStore(context,actor,device)
    private fun database(block:(SQLiteDatabase)->Unit) {
        val hash=MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
        SQLiteDatabase.openDatabase(File(context.noBackupFilesDir,"im-$hash.db").path,null,SQLiteDatabase.OPEN_READWRITE).use(block)
    }
    private fun payload(version:Long,allowed:Boolean,time:Long=5)="""{"room_id":"${room.value}","can_send":$allowed,"state_version":$version,"updated_at_ms":$time}"""
    private suspend fun project(s:SqliteClientStore,version:Long,allowed:Boolean,time:Long=5) {
        val cursor=s.cursor()
        s.commit(SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("next").setSyncReceipt("receipt")
            .addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setProjectionKind("direct_sending_capability").setUserSyncSequence(cursor.sequence+1).setPayload(ByteString.copyFromUtf8(payload(version,allowed,time)))).build(),cursor)
    }
    @Test fun versionsAreMonotonicAndSameVersionConflictsRollBackCursor()=runBlocking {
        var s=store()
        try {
            assertNull(s.directSendingCapability(room,actor));project(s,2,false);project(s,1,true);project(s,2,false)
            val before=s.cursor()
            for(action in listOf<suspend ()->Unit>({project(s,2,true)},{project(s,2,false,6)})) {
                assertNotNull(runCatching {action()}.exceptionOrNull());assertEquals(before,s.cursor())
            }
            s.close();s=store();assertEquals(DirectSendingCapability(room,false,2,5),s.directSendingCapability(room,actor))
            project(s,3,true);assertEquals(true,s.directSendingCapability(room,actor)?.canSend)
        } finally {s.close()}
    }
    @Test fun readIsActorAndRoomScopedAndRevocationPurgesProjection()=runBlocking {
        val s=store()
        try {
            project(s,1,false);assertNull(s.directSendingCapability(room,UserId(id())));assertNull(s.directSendingCapability(RoomId(id()),actor))
            database {it.execSQL("INSERT INTO room_kinds VALUES (?,?)",arrayOf(room.value,RoomKind.Group.name))}
            assertNull(s.directSendingCapability(room,actor))
            database {it.execSQL("DELETE FROM room_kinds")};assertEquals(false,s.directSendingCapability(room,actor)?.canSend)
            s.unavailable(room);assertNull(s.directSendingCapability(room,actor))
            database {db->db.rawQuery("SELECT COUNT(*) FROM direct_sending_capabilities",null).use {it.moveToFirst();assertEquals(0,it.getInt(0))}}
        } finally {s.close()}
    }
    @Test fun legacyRawProjectionMigratesAndDiscardsUnexposedFields()=runBlocking {
        var s=store();s.close()
        database {it.execSQL("INSERT INTO records VALUES (?,?,?,?)",arrayOf(id(),"direct_sending_capability",payload(1,false).dropLast(1).plus(",\"internal_reason\":\"private\"}").toByteArray(),room.value))}
        s=store()
        try {
            assertEquals(false,s.directSendingCapability(room,actor)?.canSend)
            database {db->db.rawQuery("SELECT COUNT(*) FROM records WHERE kind='direct_sending_capability'",null).use {it.moveToFirst();assertEquals(0,it.getInt(0))}}
            s.close();s=store();assertEquals(false,s.directSendingCapability(room,actor)?.canSend)
        } finally {s.close()}
    }
    @Test fun denialBetweenFreezeAndSubmitKeepsDraftAndFilesButAcceptedReplayStillWorks()=runBlocking {
        var s=store();var files=ManagedResourceFiles(context,s)
        val source=File.createTempFile("capability-",".txt",context.cacheDir)
        try {
            source.writeText("原件")
            val asset=files.importFile(source,"原件.txt","text/plain",ResourceUsage.Attachment(room),1024)
            var draft=s.addConversationAttachment(room,SendAttachment(asset.id,asset.id,asset.displayName,asset.contentType,asset.byteCount),5)
            draft=s.saveConversationText(draft,"保留正文",5)
            val now=System.currentTimeMillis();val intent=SendIntentService(actor,s) {now}.prepareDraft(draft)
            project(s,1,false)
            assertTrue(runCatching {s.submitConversationDraft(draft,intent,now)}.exceptionOrNull() is ConversationDraftSubmissionRejected)
            assertEquals(draft,s.conversationDraft(room));assertTrue(s.resourceOriginal(selection=asset.id).selectionActive);assertTrue(s.sendIntents().isEmpty())
            files.close();s.close();s=store();files=ManagedResourceFiles(context,s)
            assertEquals(draft,s.conversationDraft(room));project(s,2,true)
            assertEquals(intent,s.submitConversationDraft(draft,intent,now));val next=s.saveConversationText(s.conversationDraft(room),"下一条草稿",now)
            project(s,3,false)
            assertEquals(intent,s.submitConversationDraft(draft,intent,now));assertEquals(next,s.conversationDraft(room));assertEquals(1,s.sendIntents().size)
        } finally {source.delete();files.close();s.close()}
    }
    @Test fun snapshotPreflightRollsBackAndActivationReplacesCapabilityAuthority()=runBlocking {
        val s=store()
        try {
            project(s,10,false)
            val baseline=snapshotFixture(listOf(listOf(SnapshotItem("direct_sending_capability",room.value,id(),1,ByteString.copyFromUtf8(payload(1,true))))))
            s.stage(baseline.manifest);baseline.pages.forEach {s.importSnapshotPage(baseline.manifest,it)}
            s.prepareSnapshotActivation(baseline.manifest);assertEquals(false,s.directSendingCapability(room,actor)?.canSend)
            s.activateAcknowledgedSnapshot(baseline.manifest);assertEquals(1L,s.directSendingCapability(room,actor)?.stateVersion);assertEquals(true,s.directSendingCapability(room,actor)?.canSend)
            val empty=snapshotFixture(emptyList()).manifest.toBuilder().setGeneration(3).build()
            s.stage(empty);s.prepareSnapshotActivation(empty);s.activateAcknowledgedSnapshot(empty);assertNull(s.directSendingCapability(room,actor))
        } finally {s.close()}
    }
}
