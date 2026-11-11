package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class MessageModerationStorageTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val actor = UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room = RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB");private val message = MessageId("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    private val device = DeviceId(UUID.randomUUID().toString())
    private fun id() = UUID.randomUUID().toString().uppercase()
    private fun store() = SqliteClientStore(context,actor,device)
    private fun intent() = ModerationIntent(actor,room,"10000000-0000-0000-0000-000000000001",message,"ADMIN_ACTION",3,7,116000)
    private fun database(): File {
        val digest = MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") { "%02x".format(it) }
        return File(context.noBackupFilesDir,"im-$digest.db")
    }
    private fun payload(type: String,revision: Long) = buildJsonObject {
        put("event_type",type);put("message_id",message.value);put("room_id",room.value);put("message_revision",revision)
        put("sender_user_id",actor.value);put("text","original content");put("timeline_sequence",1);put("server_created_at_ms",1000)
        put("forwarded_from_message_id",id());put("forwarded_from_user_id",actor.value)
    }
    private suspend fun apply(store: SqliteClientStore,sequence: Long,value: JsonObject) = store.commitRoom(GroupEventPage.newBuilder().setRoomId(room.value).setNextRoomSequence(sequence)
        .addEvents(GroupEvent.newBuilder().setRoomSequence(sequence).setSourceEventId("moderation-$sequence").setProjectionKind("message").setPayload(ByteString.copyFromUtf8(value.toString()))).build(),store.roomCursor(room))
    @Test fun admittedModerationKeepsRetryHistoryAfterCancellationAndManualRounds() = runBlocking {
        var store = store(); var now = 1000L; var calls = 0
        var frozen: ModerationIntent? = null
        val transport = object: AuthenticatedTransport {
            override suspend fun request(path: String, payload: JsonObject?, query: Pair<String,String>?, maximumBytes: Long): EdgeResponse {
                calls++; val network = requireNotNull(currentCoroutineContext()[NetworkWorkIntent]); val intent = requireNotNull(frozen)
                assertEquals(calls > 1, network.isRetry)
                assertEquals(if(calls == 1) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery, network.priority)
                assertEquals(true, store.moderationWorks().single().executionStarted)
                if(calls == 1) {
                    assertTrue(path.endsWith("admissions")); assertEquals(intent.payload(), payload)
                    val admission = ModerationAdmission(id(), intent.fingerprint, 1, 2000, 110000)
                    return EdgeResponse(200, buildJsonObject { put("admitted", buildJsonObject { put("_0", admission.payload(intent)) }) })
                }
                if(calls == 3) {
                    assertTrue(path.endsWith("operations/recover")); assertEquals(intent.recovery(false), payload)
                    return EdgeResponse(200, buildJsonObject { put("unresolved", buildJsonObject {}) })
                }
                assertTrue(path.endsWith("submit")); assertEquals(store.moderationWorks().single().command()!!.payload(), payload)
                throw CancellationException("fixture interruption")
            }
        }
        fun service() = MessageModerationService(actor, MessageModerationClient(transport), store, {now}, {now * 1_000_000})
        try {
            val initial = service(); val confirmation = initial.confirmation(ModerationBaseline(room, message, 3, 7, false), "ADMIN_ACTION")
            frozen = confirmation.intent; assertEquals(false, initial.enqueue(confirmation).executionStarted)
            initial.flush(); try { initial.flush(); fail("expected interruption") } catch(_: CancellationException) {}
            store.close(); store = store()
            val saved = store.moderationWorks().single(); assertEquals(true, saved.executionStarted); assertTrue(saved.submissionStarted)
            try { store.updateModeration(saved, saved.copy(executionStarted = false)); fail("erased execution history") } catch(_: IllegalArgumentException) {}
            val resumed = service(); resumed.retry(confirmation.intent.key); assertEquals(0, store.moderationWorks().single().attempts)
            resumed.flush(); assertFalse(store.moderationWorks().single().reconcile)
            now = store.moderationWorks().single().nextAttempt; store.close(); store = store()
            val next = service(); next.retry(confirmation.intent.key)
            try { next.flush(); fail("expected interruption") } catch(_: CancellationException) {}
            assertEquals(4, calls); assertEquals(confirmation.intent, store.moderationWorks().single().intent)
        } finally { store.close() }
    }
    @Test fun frozenIntentAdmissionAndTerminalProofSurviveReopenWithoutProjectingContent() = runBlocking {
        var store = store()
        try {
            store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build());apply(store,1,payload("message.accepted",3))
            val intent = intent();val draft = store.enqueueModeration(ModerationWork(intent,"activation",roundEnd = 61000))
            val admission = ModerationAdmission("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",intent.fingerprint,1,2000,110000)
            val pending = draft.copy(admission = admission,submissionStarted = true,reconcile = true,recoveryOnly = true)
            store.updateModeration(draft,pending);store.close();store = store()
            try { store.updateModeration(pending,pending.copy(admission = admission.copy(actorJoined = 2)));fail("replaced admission") } catch(_: IllegalArgumentException) { }
            try { store.updateModeration(pending,pending.copy(recoveryOnly = false));fail("closed intent reopened") } catch(_: IllegalArgumentException) { }
            try { store.updateModeration(pending,pending.copy(submissionStarted = false));fail("unknown submission erased") } catch(_: IllegalArgumentException) { }
            try { store.updateModeration(pending,pending.copy(status = ModerationStatus.Committed));fail("missing proof") } catch(_: IllegalArgumentException) { }
            val lines = InstrumentationRegistry.getInstrumentation().context.assets.open("message-moderation-swift.txt").bufferedReader().use { it.readLines() }
            val receipt = MessageModerationClient.decodeReceipt(intent,Json.parseToJsonElement(lines[4]).jsonObject.getValue("receipt").jsonObject.getValue("_0").jsonObject)
            val finished = pending.copy(status = receipt.status,receipt = receipt.wire)
            store.updateModeration(pending,finished);store.close();store = store()
            assertEquals(finished,store.snapshot().moderationOperations.single());assertEquals("original content",store.snapshot().messages.single().text)
            assertFalse(store.snapshot().messages.single().redacted)
            try { store.updateModeration(finished,pending);fail("terminal reopened") } catch(_: IllegalArgumentException) { }
        } finally { store.close() }
    }
    @Test fun unknownOperationBlocksSecondConfirmationForSameMessageAndCasPreventsRebase() = runBlocking {
        val store = store()
        try {
            val first = store.enqueueModeration(ModerationWork(intent(),"activation",roundEnd = 61000))
            assertEquals(first,store.enqueueModeration(first.copy(activation = "another")))
            try { store.enqueueModeration(first.copy(intent = intent().copy(operation = id())));fail("parallel same message") } catch(_: IllegalStateException) { }
            try { store.updateModeration(first,first.copy(intent = intent().copy(messageRevision = 4)));fail("rebased version") } catch(_: IllegalArgumentException) { }
            store.updateModeration(first,first.copy(reconcile = true))
            try { store.updateModeration(first,first.copy(status = ModerationStatus.NeedsAttention));fail("stale writer") } catch(_: IllegalStateException) { }
            store.enqueueModeration(first.copy(intent = intent().copy(operation = id(),message = MessageId(id()))))
            assertEquals(2,store.moderationWorks().size)
        } finally { store.close() }
    }
    @Test fun redactionTombstoneKeepsAdministrativeLabelAndBlocksLateContentAfterReopen() = runBlocking {
        var store = store()
        try {
            store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
            apply(store,1,payload("message.accepted",1));assertNotNull(store.snapshot().messages.single().forwardedFrom)
            apply(store,2,payload("message.redacted",2));store.close();store = store()
            val removed = store.snapshot().messages.single();assertTrue(removed.withdrawn);assertTrue(removed.redacted);assertEquals("消息已由管理员移除",removed.text);assertNull(removed.forwardedFrom)
            apply(store,3,payload("message.accepted",1));apply(store,4,payload("message.edited",1))
            assertEquals(removed,store.snapshot().messages.single())
            try { apply(store,5,payload("message.withdrawn",2));fail("same revision changed removal kind") } catch(_: ClientFailure.Protocol) { }
            try { apply(store,5,payload("message.edited",3));fail("resurrected content") } catch(_: ClientFailure.Protocol) { }
            assertEquals(4L,store.roomCursor(room).sequence)
            store.unavailable(room);assertTrue(store.snapshot().messages.isEmpty())
            store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(2).setHead(20).build())
            apply(store,1,payload("message.redacted",2));apply(store,2,payload("message.accepted",1));assertTrue(store.snapshot().messages.isEmpty())
        } finally { store.close() }
    }
    @Test fun oldSchemaMigrationRecoversAdministrativeLabelFromCanonicalizedRoomEvents() = runBlocking {
        var store = store()
        try {
            store.acceptState(room,RoomSyncState.newBuilder().setViewerMembershipRevision(1).setHead(20).build())
            apply(store,1,payload("message.accepted",1))
            apply(store,2,JsonObject(payload("message.redacted",2)+mapOf("message_id" to JsonPrimitive(message.value.lowercase()),"room_id" to JsonPrimitive(room.value.lowercase()))))
            store.close()
            SQLiteDatabase.openDatabase(database().path,null,SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.execSQL("ALTER TABLE message_tombstones RENAME TO current_tombstones")
                db.execSQL("CREATE TABLE message_tombstones (id TEXT PRIMARY KEY,room TEXT NOT NULL,revision INTEGER NOT NULL)")
                db.execSQL("INSERT INTO message_tombstones SELECT id,room,revision FROM current_tombstones")
                db.execSQL("DROP TABLE current_tombstones")
                db.execSQL("UPDATE messages SET text='消息已撤回'")
            }
            store = store();assertTrue(store.snapshot().messages.single().redacted);assertEquals("消息已由管理员移除",store.snapshot().messages.single().text)
            store.close();store = store();assertTrue(store.snapshot().messages.single().redacted)
        } finally { store.close() }
    }
}
