package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ProjectionDiagnosticsStorageTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private suspend fun fixture(body:suspend (SqliteClientStore,NetworkDiagnostics,UserId)->Unit) {
        val actor=UserId(id());val device=DeviceId(id());val store=SqliteClientStore(context,actor,device);val diagnostics=NetworkDiagnostics()
        try {store.installNetworkDiagnostics(diagnostics);body(store,diagnostics,actor)}
        finally {store.close();SQLiteDatabase.deleteDatabase(accountDatabaseFile(context,actor,device))}
    }
    private fun batch(vararg payloads:Pair<String,String>)=SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base").setNextSyncToken("opaque").setSyncReceipt("receipt")
        .addAllRecords(payloads.mapIndexed {i,(kind,payload)->SyncRecord.newBuilder().setUserSyncSequence(i+1L).setSourceEventId("event-$i").setProjectionKind(kind).setPayload(ByteString.copyFromUtf8(payload)).build()}).build()

    @Test fun committedProjectionPublishesOnceAndLaterCommitCannotBeConsumedByOlderSnapshot()=runBlocking {
        fixture {store,diagnostics,actor->
            store.enqueue(MessageCommand.text(actor,RoomId(id()),"first",System.currentTimeMillis()+ClientSubmissionWindow.COMMAND_MILLISECONDS))
            val first=store.observedAppSnapshot();assertNotNull(first.conversationCommit)
            val initial=diagnostics.snapshot();assertEquals(1L,initial.projectionRecorded)
            assertTrue(ProjectionScope.Conversations in initial.projections.single().scopes)
            store.enqueue(MessageCommand.text(actor,RoomId(id()),"second",System.currentTimeMillis()+ClientSubmissionWindow.COMMAND_MILLISECONDS))
            first.conversationCommit!!.didPublishSnapshot()
            val second=store.observedAppSnapshot();assertNotNull(second.conversationCommit);assertNotSame(first.conversationCommit,second.conversationCommit)
            second.conversationCommit!!.didPublishSnapshot();second.conversationCommit!!.didPublishSnapshot()
            assertEquals(4L,diagnostics.snapshot().projectionRecorded)
            assertEquals(2,diagnostics.snapshot().projections.count {it.phase==ProjectionMetric.Phase.CommitToConversationSnapshot})
            assertNull(store.observedAppSnapshot().conversationCommit)
            assertEquals(4L,diagnostics.snapshot().projectionRecorded)
            assertEquals(1,initial.projections.size)
        }
    }
    @Test fun rollbackDoesNotPublishDirtyScopesAndReadTransactionsDoNotInventCommits()=runBlocking {
        fixture {store,diagnostics,_->
            val relationship="""{"target_user_id":"friend","state":"accepted","updated_at_ms":1}"""
            try {store.commit(batch("relationship" to relationship,"message" to "{}"),store.cursor());fail("invalid batch accepted")} catch(_:ClientFailure.Protocol) {}
            assertEquals(SyncCursor(),store.cursor());assertTrue(store.appSnapshot().contacts.isEmpty())
            assertEquals(0L,diagnostics.snapshot().projectionRecorded);assertNull(store.observedAppSnapshot().conversationCommit)
            store.commit(batch("relationship" to relationship),store.cursor())
            val stamp=store.observedAppSnapshot().conversationCommit;assertNotNull(stamp)
            val count=diagnostics.snapshot().projectionRecorded
            repeat(3) {store.appSnapshot();store.snapshot();store.cursor()}
            assertEquals(count,diagnostics.snapshot().projectionRecorded)
            stamp!!.didPublishSnapshot();assertEquals(count+1,diagnostics.snapshot().projectionRecorded)
        }
    }
    @Test fun snapshotStagingHasNoVisibleMetricAndClosedOwnerCannotBeRebound()=runBlocking {
        fixture {store,diagnostics,actor->
            val manifest=SnapshotManifest.newBuilder().setSnapshotId(id()).setGeneration(2).setBaseUserSyncSequence(1).build()
            store.stage(manifest);assertEquals(0L,diagnostics.snapshot().projectionRecorded)
            store.cancelSnapshot(manifest);assertEquals(0L,diagnostics.snapshot().projectionRecorded)
            store.enqueue(MessageCommand.text(actor,RoomId(id()),"pending",System.currentTimeMillis()+ClientSubmissionWindow.COMMAND_MILLISECONDS))
            val stamp=store.observedAppSnapshot().conversationCommit;assertNotNull(stamp)
            diagnostics.close();stamp!!.didPublishSnapshot()
            store.enqueue(MessageCommand.text(actor,RoomId(id()),"later",System.currentTimeMillis()+ClientSubmissionWindow.COMMAND_MILLISECONDS));assertEquals(1L,diagnostics.snapshot().projectionRecorded)
            try {store.installNetworkDiagnostics(NetworkDiagnostics());fail("owner rebound")} catch(_:IllegalStateException) {}
        }
    }
}
