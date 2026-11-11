package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LocalDirectMessageStorageTests {
    private fun id() = UUID.randomUUID().toString().uppercase()
    private inner class Fixture {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val actor = UserId(id()); val peer = UserId(id()); val device = DeviceId(id()); val room = RoomId(id())
        val identity = PublicIdentity(peer, PublicHandle("friend"), "离线朋友", AccountKind.Regular)
        val file = accountDatabaseFile(context, actor, device)
        var store = SqliteClientStore(context, actor, device)
        suspend fun work() = store.prepareDirect(DirectRoomCommand.create(actor, peer, 1000), identity)
        fun reopen() { store.close(); store = SqliteClientStore(context, actor, device) }
        fun db(body: (SQLiteDatabase) -> Unit) = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use(body)
        suspend fun complete(work: DirectRoomWork, opened: Boolean = true) {
            val receipt = buildJsonObject {
                put("identity", work.command.identity()); put("fingerprint", work.command.fingerprintPayload()); put("resolvedAtMilliseconds", 3000)
                put("outcome", buildJsonObject {
                    if (opened) put("opened", buildJsonObject { put("roomID", buildJsonObject { put("rawValue", room.value) }); put("createdAtMilliseconds", 1000) })
                    else put("closed", buildJsonObject {})
                })
            }
            store.updateDirect(work, work.copy(status = if (opened) DirectWorkStatus.Opened else DirectWorkStatus.Closed, room = room.takeIf { opened }, receipt = receipt.toString()))
        }
        fun message(work: DirectRoomWork, text: String = "等待连接", time: Long = 1000) = LocalDirectMessage.create(work.command.operation, text, time)
        suspend fun messages() = store.localDirectMessages(actor)
        fun close() { store.close(); SQLiteDatabase.deleteDatabase(file) }
    }
    private suspend fun rejected(body: suspend () -> Unit) {
        try { body(); fail("invalid write accepted") } catch (_: IllegalArgumentException) { } catch (_: IllegalStateException) { }
    }
    @Test fun offlineMessagesSurviveRestartAndKeepIdsAndOriginalTimeThroughFreshSendWindow() = runBlocking {
        val f = Fixture()
        try {
            val work = f.work(); val first = f.message(work); val second = f.message(work, "第二条", 1001)
            f.store.saveLocalDirectMessage(f.actor, first); f.store.saveLocalDirectMessage(f.actor, second)
            assertFalse(f.store.prepareNextLocalDirectMessage(f.actor, 1002)); f.reopen()
            assertEquals(listOf(first, second), f.messages()); f.complete(work)
            val now = 2 * 86_400_000L
            assertTrue(f.store.prepareNextLocalDirectMessage(f.actor, now)); assertTrue(f.store.prepareNextLocalDirectMessage(f.actor, now))
            assertFalse(f.store.prepareNextLocalDirectMessage(f.actor, now)); f.reopen(); assertTrue(f.messages().isEmpty())
            val sends = f.store.sendIntents().map { it.intent }
            assertEquals(listOf(first.id, second.id), sends.map { it.id }); assertEquals(listOf(1000L, 1001L), sends.map { it.createdAt })
            assertTrue(sends.all { it.room == f.room && it.operation == it.id && it.preparationStartedAt == now && it.deadline == now + 86_400_000 })
            f.store.advanceSendIntents(now)
            assertEquals(listOf(1000L, 1001L), f.store.snapshot().messages.map { it.createdAt })
            f.db { db -> db.rawQuery("SELECT command FROM outbox ORDER BY rowid", null).use { rows ->
                val commands = buildList { while (rows.moveToNext()) add(MessageSendOperation.parseFrom(rows.getBlob(0))) }
                assertEquals(listOf(first.id, second.id), commands.map { it.clientMessageId })
                assertTrue(commands.all { it.firstSubmissionDeadlineMs > now })
            } }
        } finally { f.close() }
    }
    @Test fun ignoredInsertIgnoredDeleteAndReinsertCannotLoseOrDuplicateLocalMessage() = runBlocking {
        val f = Fixture()
        try {
            val work = f.work(); val message = f.message(work); f.store.saveLocalDirectMessage(f.actor, message); f.complete(work)
            for (sql in listOf(
                "CREATE TRIGGER fault BEFORE INSERT ON send_intents BEGIN SELECT RAISE(IGNORE); END",
                "CREATE TRIGGER fault BEFORE DELETE ON local_direct_messages BEGIN SELECT RAISE(IGNORE); END",
                "CREATE TRIGGER fault AFTER DELETE ON local_direct_messages BEGIN INSERT INTO local_direct_messages VALUES(old.id,old.operation,old.text,old.created); END")) {
                f.db { it.execSQL(sql) }
                rejected { f.store.prepareNextLocalDirectMessage(f.actor, 4000) }
                assertEquals(listOf(message), f.messages()); assertTrue(f.store.sendIntents().isEmpty())
                f.db { it.execSQL("DROP TRIGGER fault") }; f.reopen()
            }
            assertTrue(f.store.prepareNextLocalDirectMessage(f.actor, 4000)); assertTrue(f.messages().isEmpty())
            assertEquals(message.id, f.store.sendIntents().single().intent.id)
        } finally { f.close() }
    }
    @Test fun existingFrozenSendAndLateSaveAcknowledgementReuseOneIntent() = runBlocking {
        val f = Fixture()
        try {
            val work = f.work(); val message = f.message(work); f.store.saveLocalDirectMessage(f.actor, message); f.complete(work)
            val intent = SendIntent(message.id, f.actor, f.room, message.id, message.text, persistentListOf(), message.createdAt, 86_404_000, preparationStartedAt = 4000)
            f.store.enqueueSendIntent(intent, 4000); f.reopen()
            assertTrue(f.store.prepareNextLocalDirectMessage(f.actor, 5000)); f.store.advanceSendIntents(5000)
            f.store.saveLocalDirectMessage(f.actor, message); assertTrue(f.messages().isEmpty()); assertEquals(1, f.store.sendIntents().size)
            rejected { f.store.saveLocalDirectMessage(f.actor, message.copy(text = "冲突内容")) }
        } finally { f.close() }
    }
    @Test fun actorOperationAndCapacityChecksKeepOriginalRows() = runBlocking {
        val f = Fixture()
        try {
            val work = f.work(); val first = f.message(work)
            rejected { f.store.saveLocalDirectMessage(UserId(id()), first) }
            rejected { f.store.saveLocalDirectMessage(f.actor, first.copy(operation = id())) }
            rejected { f.store.localDirectMessages(UserId(id()), work.command.operation) }
            f.store.saveLocalDirectMessage(f.actor, first); f.store.saveLocalDirectMessage(f.actor, first)
            rejected { f.store.saveLocalDirectMessage(f.actor, first.copy(text = "不同")) }
            repeat(499) { f.store.saveLocalDirectMessage(f.actor, f.message(work, "消息$it", 1001L + it)) }
            rejected { f.store.saveLocalDirectMessage(f.actor, f.message(work, "超过容量")) }
            assertEquals(500, f.messages().size); assertEquals(first, f.messages().first())
        } finally { f.close() }
    }
    @Test fun explicitNewOpeningCarriesUnsubmittedMessagesAcrossTerminalRequest() = runBlocking {
        val f = Fixture()
        try {
            val old = f.work(); val message = f.message(old); f.store.saveLocalDirectMessage(f.actor, message); f.complete(old, false)
            assertFalse(f.store.prepareNextLocalDirectMessage(f.actor, 4000))
            val next = f.work(); assertNotEquals(old.command.operation, next.command.operation)
            assertEquals(message.copy(operation = next.command.operation), f.messages().single())
            f.reopen(); f.complete(next); assertTrue(f.store.prepareNextLocalDirectMessage(f.actor, 5000))
            assertEquals(message.id, f.store.sendIntents().single().intent.id)
        } finally { f.close() }
    }
    @Test fun roomEntryWaitsForHandoffAndPreservesBothCurrentAndConflictingDrafts() = runBlocking {
        val f = Fixture()
        try {
            val work = f.work(); val message = f.message(work); f.store.saveLocalDirectMessage(f.actor, message); f.complete(work)
            assertNull(f.store.enterLocalDirectRoom(f.actor, work.command.operation, "未发送输入"))
            f.store.prepareNextLocalDirectMessage(f.actor, 4000)
            assertEquals(f.room, f.store.enterLocalDirectRoom(f.actor, work.command.operation, "未发送输入"))
            val draft = f.store.conversationDraft(f.room)
            assertEquals("未发送输入", draft.text)
            assertEquals(f.room, f.store.enterLocalDirectRoom(f.actor, work.command.operation, draft.text))
            assertEquals(draft, f.store.conversationDraft(f.room))
            rejected { f.store.enterLocalDirectRoom(f.actor, work.command.operation, "另一份输入") }
            assertEquals(draft, f.store.conversationDraft(f.room)); assertEquals(f.room, f.store.enterLocalDirectRoom(f.actor, work.command.operation, ""))
        } finally { f.close() }
    }
    @Test fun snapshotReplacementKeepsLocalMessagesAndReceiptAloneDoesNotAllowExistingRoomReuse() = runBlocking {
        val f = Fixture()
        try {
            val work = f.work(); val message = f.message(work); f.store.saveLocalDirectMessage(f.actor, message); f.complete(work)
            assertNull(f.store.existingDirectRoom(f.actor, f.peer))
            val manifest = SnapshotManifest.newBuilder().setGeneration(2).setBaseUserSyncSequence(30).setNextSyncToken("reset").build()
            f.store.stage(manifest); f.store.validateSnapshot(persistentListOf()); f.store.activateFixture(manifest, persistentListOf())
            f.reopen(); assertEquals(listOf(message), f.messages()); assertNull(f.store.existingDirectRoom(f.actor, f.peer))
            val profile = buildJsonObject {
                put("room_id", f.room.value); put("target_user_id", f.peer.value); put("display_name", "当前资料")
                put("public_handle", "friend"); put("account_kind", "regular"); put("revision", 2)
                put("updated_at_ms", 4000); put("room_created_at_ms", 1000)
            }
            val cursor = f.store.cursor()
            f.store.commit(SyncBatch.newBuilder().setGeneration(cursor.generation).setNextSyncToken("profile")
                .addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setProjectionKind("direct_room_profile")
                    .setUserSyncSequence(cursor.sequence + 1).setPayload(com.google.protobuf.ByteString.copyFromUtf8(profile.toString()))).build(), cursor)
            assertEquals(f.room, f.store.existingDirectRoom(f.actor, f.peer))
            f.store.unavailable(f.room); assertNull(f.store.existingDirectRoom(f.actor, f.peer))
        } finally { f.close() }
    }
    @Test fun fullSendQueueMakesBoundedProgressAndResumesWithoutChangingRemainingMessage() = runBlocking {
        val f = Fixture()
        try {
            val work = f.work(); repeat(33) { f.store.saveLocalDirectMessage(f.actor, f.message(work, "正文$it", 1000L + it)) }; f.complete(work)
            repeat(32) { assertTrue(f.store.prepareNextLocalDirectMessage(f.actor, 4000)) }
            val remaining = f.messages().single()
            rejected { f.store.prepareNextLocalDirectMessage(f.actor, 4000) }
            assertEquals(remaining, f.messages().single()); f.store.discardSendIntent(f.store.sendIntents().first().intent.id)
            assertTrue(f.store.prepareNextLocalDirectMessage(f.actor, 5000)); assertTrue(f.messages().isEmpty())
            assertEquals(1, f.store.sendIntents().count { it.intent.id == remaining.id })
        } finally { f.close() }
    }
    @Test fun legacySendJournalMigrationPreservesRowsAndAcceptsMaximumEscapedText() = runBlocking {
        val f = Fixture()
        try {
            val prior = SendIntentService(f.actor, f.store) { 1000 }.enqueue(f.room, "旧意图", persistentListOf())
            val priorDraft = f.store.saveConversationText(f.store.conversationDraft(f.room), "旧草稿", 1000)
            f.store.close()
            f.db { db ->
                db.execSQL("ALTER TABLE conversation_drafts RENAME TO old_drafts")
                db.execSQL("CREATE TABLE conversation_drafts(room TEXT PRIMARY KEY,payload TEXT NOT NULL CHECK(length(payload)<=131072))")
                db.execSQL("INSERT INTO conversation_drafts SELECT * FROM old_drafts"); db.execSQL("DROP TABLE old_drafts")
                db.execSQL("ALTER TABLE send_intents RENAME TO old_send")
                db.execSQL("CREATE TABLE send_intents(id TEXT PRIMARY KEY,operation TEXT UNIQUE NOT NULL,payload TEXT NOT NULL CHECK(length(payload)<=131072),cancel_unfinished_only INTEGER NOT NULL DEFAULT 0)")
                db.execSQL("INSERT INTO send_intents SELECT * FROM old_send"); db.execSQL("DROP TABLE old_send")
                db.execSQL("CREATE INDEX preserved_send_index ON send_intents(operation)")
            }
            f.reopen(); assertEquals(prior, f.store.sendIntents().single().intent)
            assertEquals(priorDraft, f.store.conversationDraft(f.room))
            f.store.saveConversationText(priorDraft, "", 2000)
            val work = f.work(); val message = f.message(work, "\"".repeat(65_536))
            f.store.saveLocalDirectMessage(f.actor, message); f.complete(work)
            assertTrue(f.store.prepareNextLocalDirectMessage(f.actor, 4000))
            assertEquals(message.text, f.store.sendIntents().last().intent.text)
            assertEquals(f.room, f.store.enterLocalDirectRoom(f.actor, work.command.operation, message.text))
            assertEquals(message.text, f.store.conversationDraft(f.room).text)
            f.db { db -> db.rawQuery("SELECT 1 FROM sqlite_master WHERE name='preserved_send_index'", null).use { assertTrue(it.moveToFirst()) } }
        } finally { f.close() }
    }
}
