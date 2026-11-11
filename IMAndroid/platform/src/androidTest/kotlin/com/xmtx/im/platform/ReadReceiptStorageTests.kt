package com.xmtx.im.platform

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

class ReadReceiptStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId(id());private val peer = UserId(id());private val device = DeviceId(id());private val room = RoomId(id())
    private fun id() = UUID.randomUUID().toString().uppercase()
    private fun store() = SqliteClientStore(context,actor,device)
    private suspend fun ready(store: SqliteClientStore) {
        store.reconcileDirectory(persistentMapOf(room to RoomKind.Direct));store.acceptState(room,RoomSyncState.newBuilder().setHead(20).setUnreadCount(20).setViewerMembershipRevision(1).build())
        store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(20).build(),store.roomCursor(room))
    }
    private suspend fun project(store: SqliteClientStore,kind: String,value: JsonObject) {
        val cursor = store.cursor();val next = cursor.sequence+1
        store.commit(SyncBatch.newBuilder().setGeneration(maxOf(1,cursor.generation)).setNextSyncToken("$next").setSyncReceipt("$next")
            .addRecords(SyncRecord.newBuilder().setUserSyncSequence(next).setSourceEventId(id()).setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(value.toString()))).build(),cursor)
    }
    private fun direct(sequence: Long,visible: Boolean,reader: Long,viewer: Long) = buildJsonObject {
        put("room_id",room.value);put("reader_user_id",peer.value);put("read_through_room_sequence",sequence);put("is_visible",visible)
        put("recorded_at_ms",1000);put("reader_preference_revision",reader);put("viewer_preference_revision",viewer)
    }
    @Test fun intentsCoalesceFrozenCommandsSurviveReopenAndSuccessorsWait() = runBlocking {
        var store = store();try {
            ready(store);assertEquals(20L,store.latestReadSequence(room));assertEquals(20,store.snapshot().conversations.single().unread)
            assertTrue(store.enqueueRead(room,7));assertTrue(store.enqueueRead(room,12));assertFalse(store.enqueueRead(room,8));assertEquals(8,store.snapshot().conversations.single().unread)
            store.prepareReads();val first = store.readWorks().single();assertEquals(12L,first.command.sequence)
            assertTrue(store.enqueueRead(room,18));store.prepareReads();assertEquals(1,store.readWorks().size)
            val submitted = first.copy(submissionStarted = true,reconcile = true,attempts = 1,roundStarted = 1000)
            store.updateRead(first,submitted);store.close();store = store();assertEquals(submitted,store.readWorks().single())
            try { store.updateRead(first,submitted);fail("stale update accepted") } catch(_: IllegalStateException) { }
            store.updateRead(submitted,submitted.copy(status = ReadStatus.Confirmed,watermark = ReadWatermark(room,actor,15,1000),originalReceipt = false))
            store.prepareReads();assertEquals(listOf(12L,18L),store.readWorks().map { it.command.sequence });assertEquals(2,store.snapshot().conversations.single().unread)
            assertFalse(store.enqueueRead(room,15))
        } finally { store.close() }
    }
    @Test fun archiveRetainsUnknownIdentityAndRestoresQueryBeforeResubmission() = runBlocking {
        val store = store();try {
            ready(store);store.enqueueRead(room,7);store.prepareReads();val first = store.readWorks().single()
            try { store.archiveRead(first.command.operation,1000);fail("unsubmitted archived") } catch(_: IllegalArgumentException) { }
            val unavailable = first.copy(submissionStarted = true,reconcile = true,status = ReadStatus.NeedsAttention,reason = "currentUnavailable:permissionDenied")
            store.updateRead(first,unavailable);store.archiveRead(first.command.operation,1000)
            assertEquals(ReadStatus.Archived,store.readWorks().single().status);assertFalse(store.enqueueRead(room,7))
            store.enqueueRead(room,10);store.prepareReads();assertEquals(2,store.readWorks().size)
            store.restoreRead(first.command.operation,2000);val control = store.readWorks().first();assertTrue(control.control);assertTrue(control.reconcile);assertEquals(first.command,control.command)
            store.admitReadResubmission(control,control.copy(control = false,reconcile = false,nextAttempt = 3000))
            assertEquals("controlCapacityRequired",store.readWorks().first().reason);assertTrue(store.readWorks().first().control)
            store.archiveRead(first.command.operation,4000);assertEquals(ReadStatus.Archived,store.readWorks().first().status)
        } finally { store.close() }
    }
    @Test fun ownWatermarksAreMonotonicAndPeerPrivacyTombstonesSurviveReopen() = runBlocking {
        var store = store();try {
            ready(store)
            for(sequence in listOf(15,7)) project(store,"own_read_watermark",buildJsonObject { put("room_id",room.value);put("read_through_room_sequence",sequence);put("recorded_at_ms",1000) })
            assertEquals(5,store.snapshot().conversations.single().unread);assertFalse(store.enqueueRead(room,14))
            project(store,"direct_read_receipt",direct(8,true,2,2));assertEquals(8L,store.snapshot().directReads.single().sequence)
            project(store,"direct_read_receipt",direct(0,false,3,2));assertTrue(store.snapshot().directReads.isEmpty())
            store.close();store = store();project(store,"direct_read_receipt",direct(9,true,2,2));assertTrue(store.snapshot().directReads.isEmpty())
            val cursor = store.cursor()
            try { project(store,"direct_read_receipt",direct(9,true,4,1));fail("crossed privacy versions") } catch(_: IllegalArgumentException) { }
            assertEquals(cursor,store.cursor())
            project(store,"direct_read_receipt",direct(10,true,4,2));assertEquals(10L,store.snapshot().directReads.single().sequence)
            store.unavailable(room);assertTrue(store.snapshot().directReads.isEmpty());assertNull(store.latestReadSequence(room))
        } finally { store.close() }
    }
    @Test fun privacyRestrictionAppliesBeforePreferenceConfirmationAndCannotBeRelaxedByPendingGrant() = runBlocking {
        val store = store();try {
            ready(store);assertTrue(store.allowsReadPublication(room))
            store.savePreference(PreferenceSnapshot(actor,PreferenceValue(PreferenceKind.ReadReceipts,false,true),2));assertFalse(store.allowsReadPublication(room))
            store.savePreference(PreferenceSnapshot(actor,PreferenceValue(PreferenceKind.ReadReceipts,true,true),3));assertTrue(store.allowsReadPublication(room))
            val pending = PreferenceWork(actor,id(),PreferencePatch(PreferenceKind.ReadReceipts,first = false),id(),System.currentTimeMillis()+100000)
            store.preparePreference(pending);assertFalse(store.allowsReadPublication(room))
            store.unavailable(room);assertFalse(store.allowsReadPublication(room))
        } finally { store.close() }
    }
    @Test fun acceptedRoomPositionIsDistinctFromTimelineOrderAndLegacyMigrationRecoversOnlyEvidence() = runBlocking {
        var store = store();try {
            store.reconcileDirectory(persistentMapOf(room to RoomKind.Direct));store.acceptState(room,RoomSyncState.newBuilder().setHead(20).setViewerMembershipRevision(1).build())
            val message = MessageId(id())
            val accepted = buildJsonObject { put("event_type","message.accepted");put("message_id",message.value);put("room_id",room.value);put("sender_user_id",peer.value)
                put("text","position");put("message_revision",1);put("room_sequence",7);put("timeline_sequence",2);put("server_created_at_ms",1000) }
            val page = GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(7).addEvents(GroupEvent.newBuilder().setRoomSequence(7).setSourceEventId(id()).setProjectionKind("message").setPayload(ByteString.copyFromUtf8(accepted.toString()))).build()
            store.commitRoom(page,store.roomCursor(room));val observed = store.snapshot().messages.single()
            assertEquals(7L,observed.roomSequence);assertEquals(2L,observed.timelineSequence)
            store.close()
            val digest = java.security.MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
            android.database.sqlite.SQLiteDatabase.openDatabase(java.io.File(context.noBackupFilesDir,"im-$digest.db").path,null,android.database.sqlite.SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.execSQL("ALTER TABLE messages RENAME TO upgraded_messages")
                db.execSQL("CREATE TABLE messages (id TEXT PRIMARY KEY,room TEXT NOT NULL,sender TEXT NOT NULL,text TEXT NOT NULL,time INTEGER NOT NULL,revision INTEGER NOT NULL,sequence INTEGER NOT NULL,withdrawn INTEGER NOT NULL,forwarded_message TEXT,forwarded_sender TEXT)")
                db.execSQL("INSERT INTO messages SELECT id,room,sender,text,time,revision,sequence,withdrawn,forwarded_message,forwarded_sender FROM upgraded_messages")
                db.execSQL("DROP TABLE upgraded_messages")
                db.execSQL("INSERT INTO messages VALUES (?,?,?,?,?,?,?,0,NULL,NULL)",arrayOf<Any>(id(),room.value,peer.value,"no source",1000,1,3))
            }
            store = store();assertEquals(observed,store.snapshot().messages.first { it.id == message })
            assertEquals(0L,store.snapshot().messages.first { it.text == "no source" }.roomSequence)
            assertEquals(3L,store.snapshot().messages.first { it.text == "no source" }.timelineSequence)
            assertTrue(store.enqueueRead(room,observed.roomSequence));store.prepareReads();assertEquals(7L,store.readWorks().single().command.sequence)
        } finally { store.close() }
    }
    @Test fun personalSnapshotReplacesPeerDisclosureButPreservesFrozenLocalReadAndConfirmedFloor() = runBlocking {
        val store = store();try {
            ready(store);project(store,"direct_read_receipt",direct(9,true,2,2));store.enqueueRead(room,7);store.prepareReads();val work = store.readWorks().single()
            val submitted = work.copy(submissionStarted = true,reconcile = true);store.updateRead(work,submitted)
            val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(30).setNextSyncToken("reset").build()
            val payload = buildJsonObject { put("event_type","room.created");put("room_id",room.value);put("membership_revision",1);put("title","room");put("viewer_membership_revision",1);put("viewer_is_member",true);put("viewer_membership_source_event_id","state") }
            val items = persistentListOf(SnapshotItem("room","room:${room.value}","source",1,ByteString.copyFromUtf8(payload.toString())),SnapshotItem("direct_read_receipt",room.value,"privacy",2,ByteString.copyFromUtf8(direct(0,false,3,2).toString())))
            store.stage(manifest);store.validateSnapshot(items);assertEquals(9L,store.snapshot().directReads.single().sequence)
            store.activateFixture(manifest,items);store.reconcileDirectory(persistentMapOf(room to RoomKind.Direct));assertTrue(store.snapshot().directReads.isEmpty());assertEquals(submitted,store.readWorks().single())
            project(store,"direct_read_receipt",direct(12,true,2,2));assertTrue(store.snapshot().directReads.isEmpty())
        } finally { store.close() }
    }
    @Test fun recoveredWatermarkRetainsProofTypeAndPublishesDurableDiagnostic() = runBlocking {
        var store=store();val diagnostics=NetworkDiagnostics()
        try {
            ready(store);store.enqueueRead(room,7);store.prepareReads();val first=store.readWorks().single()
            val uncertain=first.copy(submissionStarted=true,reconcile=true);store.updateRead(first,uncertain)
            store.close();store=store();assertEquals(uncertain,store.readWork(first.command.operation));assertNull(store.readWork(id()))
            val remote=object:ReadReceiptTransport {
                override suspend fun submit(command:ReadCommand):ReadResult.Confirmed=error("unexpected replay")
                override suspend fun recover(command:ReadCommand):ReadResult {
                    val intent=kotlinx.coroutines.currentCoroutineContext()[NetworkWorkIntent]!!
                    assertTrue(intent.isRetry);assertEquals(NetworkWorkPriority.Recovery,intent.priority)
                    return ReadResult.Confirmed(ReadWatermark(room,actor,9,1000),false)
                }
            }
            kotlinx.coroutines.withContext(NetworkDiagnosticsScope(diagnostics)) {ReadReceiptService(actor,remote,store,{1000},{1000}).flush()}
            val observed=store.readWork(first.command.operation)!!
            assertEquals(ReadStatus.Confirmed,observed.status);assertEquals(false,observed.originalReceipt)
            val sample=diagnostics.snapshot().operations.single()
            assertEquals(OperationKind.ReadReceipt,sample.kind);assertEquals(OperationExecutionState.Committed,sample.observation!!.execution)
            assertEquals(NetworkMetric.Certainty.ResponseReceived,sample.certainty)
        } finally {store.close()}
    }

}
