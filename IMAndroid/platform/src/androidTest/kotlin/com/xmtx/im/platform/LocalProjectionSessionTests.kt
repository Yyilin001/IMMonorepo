package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.coroutines.CoroutineContext

class LocalProjectionSessionTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun id() = UUID.randomUUID().toString()
    private inner class Fixture {
        val user = UserId(id()); val device = DeviceId(id()); val room = RoomId(id())
        val file = accountDatabaseFile(context, user, device)
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var session: LocalProjectionSession? = null
        var pending = false
        var onSecretRead: suspend () -> Unit = {}
        var onBindingRead: suspend (Int) -> Unit = {}
        var bindingReads = 0
        val marker = object : LocalExitMarker {
            override suspend fun isPending() = pending
            override suspend fun markPending() { pending = true }
            override suspend fun clearPending() { pending = false }
        }
        var secret = credentials(user)
        fun credentials(account: UserId) = buildJsonObject {
            put("credentials", Json.encodeToJsonElement(Credentials(account, device, "local-access", 1,
                "local-refresh", "imv2-revoke-v1.${"A".repeat(43)}", 1)))
        }.toString()
        val auth = AuthSession(object : SecretStore {
            override suspend fun read(): String { onSecretRead(); return secret }
            override suspend fun write(value: String) { error("read projection wrote credentials") }
            override suspend fun delete() { error("read projection deleted credentials") }
        }, object : AccountTransport {
            override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject = error("read projection used network")
        }, marker)
        var binding = LocalInstallationBinding.create()
        val bootstrap = LocalStoreBootstrapper(context, object : InstallationBindingStore {
            override suspend fun load(): LocalInstallationBinding { onBindingRead(++bindingReads); return binding }
            override suspend fun save(binding: LocalInstallationBinding) { error("read projection created binding") }
            override suspend fun delete() { error("read projection deleted binding") }
        })
        fun database(body: (SQLiteDatabase) -> Unit) = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use(body)
        suspend fun project(store: SqliteClientStore, kind: String, value: JsonObject) {
            val cursor = store.cursor()
            store.commit(SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("next")
                .addRecords(SyncRecord.newBuilder().setSourceEventId(id()).setProjectionKind(kind)
                    .setUserSyncSequence(cursor.sequence + 1).setPayload(ByteString.copyFromUtf8(value.toString()))).build(), cursor)
        }
        suspend fun group(store: SqliteClientStore, target: RoomId = room) = project(store, "room", buildJsonObject {
            put("event_type", "room.created"); put("room_id", target.value); put("membership_revision", 1); put("title", "本地群")
        })
        suspend fun direct(store: SqliteClientStore, target: RoomId) = project(store, "direct_room_profile", buildJsonObject {
            put("room_id", target.value); put("target_user_id", id()); put("display_name", "未授权的资料名称")
            put("public_handle", "friend"); put("account_kind", "regular"); put("revision", 1)
            put("updated_at_ms", 10); put("room_created_at_ms", 1)
        })
        fun message(target: RoomId = room, sequence: Long = 1, body: String = "本地消息", withdrawn: Boolean = false): MessageId {
            val message = MessageId(id())
            database { it.execSQL("INSERT INTO messages(id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn,rich) VALUES (?,?,?,?,?,100,1,?,?,?,?)",
                arrayOf<Any>(message.value, target.value, user.value, body, body, sequence, sequence, if (withdrawn) 1 else 0, MessageRichContent.Empty.payload().toString())) }
            return message
        }
        suspend fun seed(extra: suspend (SqliteClientStore) -> Unit = {}) {
            bootstrap.open(user, device).use { group(it); extra(it) }
            message()
        }
        suspend fun open(): LocalProjectionSession = bootstrap.openLocalProjection(auth, marker, owner).also { session = it }
        suspend fun assertRetired(value: LocalProjectionSession) {
            withTimeout(10_000) { value.state.first { !it.active } }
            value.close() // Join actual handle retirement, not just publication of the cleared state.
            assertEquals(LocalProjectionSnapshot(active = false), value.state.value)
            LocalDatabaseAccess.acquire(file, recovery = true).close()
        }
        suspend fun cleanup() {
            session?.close(); owner.coroutineContext[Job]!!.cancelAndJoin()
            LocalDatabaseAccess.acquire(file, recovery = true).close()
            SQLiteDatabase.deleteDatabase(file)
        }
    }

    @Test fun boundedPagesUseStableTiesAndOnlyCommittedTextWithoutWriting() = runBlocking {
        val f = Fixture()
        try {
            val second = RoomId(id()); val third = RoomId(id())
            f.seed { f.group(it, second); f.direct(it, third) }
            f.message(second); f.message(third)
            val attachment = f.message(sequence = 2, body = "")
            val withdrawn = f.message(sequence = 3, body = "已删除的原文", withdrawn = true)
            val bytes = f.file.readBytes(); val secret = f.secret
            val s = f.open(); val first = s.conversations(limit = 2)
            assertEquals(2, first.entries.size); assertNotNull(first.next)
            val last = s.conversations(first.next, 2)
            assertNull(last.next)
            assertEquals(listOf(f.room, second, third).sortedBy { it.value }, (first.entries + last.entries).map { it.room })
            assertEquals("会话", (first.entries + last.entries).single { it.room == third }.title)
            val page = s.messages(f.room, limit = 2)
            assertEquals(listOf(attachment, withdrawn), page.entries.map { it.id })
            assertEquals(listOf("附件（联网后查看）", "消息已撤回"), page.entries.map { it.text })
            assertTrue(page.entries.first().attachment); assertTrue(page.entries.last().withdrawn)
            assertTrue(s.state.value.conversations.isEmpty())
            val older = s.messages(f.room, page.older, 2)
            assertEquals(1, older.entries.size); assertNull(older.older)
            s.close(); assertArrayEquals(bytes, f.file.readBytes()); assertEquals(secret, f.secret)
        } finally { f.cleanup() }
    }

    @Test fun cursorAndCachedMessagesDoNotGrantAccessAndExplicitDenialWins() = runBlocking {
        val f = Fixture()
        try {
            val unproven = RoomId(id()); val denied = RoomId(id())
            f.seed { store ->
                store.acceptState(unproven, RoomSyncState.newBuilder().setRoomId(unproven.value).setHead(9).setViewerMembershipRevision(1).build())
                f.direct(store, denied)
            }
            f.message(unproven); f.message(denied)
            f.database { it.execSQL("INSERT OR REPLACE INTO memberships VALUES (?,2,'denial',0)", arrayOf(denied.value)) }
            val s = f.open()
            assertEquals(listOf(f.room), s.conversations().entries.map { it.room })
            for (room in listOf(unproven, denied, RoomId(id()))) {
                val page = s.messages(room); assertFalse(page.available); assertTrue(page.entries.isEmpty())
            }
        } finally { f.cleanup() }
    }

    @Test fun pendingExitDuringPostReadValidationNeverPublishesAndReleasesGate() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); val s = f.open(); s.conversations()
            f.bindingReads = 0
            // Two binding loads per validation; the third belongs to validation after the SQL read.
            f.onBindingRead = { if (it == 3) f.pending = true }
            try { s.messages(f.room); fail("published after exit") } catch (_: ClientFailure.SignedOut) { }
            f.assertRetired(s)
        } finally { f.cleanup() }
    }

    @Test fun changedDatabaseIdentityAndInstallationBindingInvalidateCachedPages() = runBlocking {
        for (replaceDatabase in listOf(true, false)) {
            val f = Fixture()
            try {
                f.seed(); val s = f.open(); s.messages(f.room)
                if (replaceDatabase) f.database { it.execSQL("UPDATE im_database_identity SET identity=?", arrayOf(LocalDatabaseIdentity.create().value)) }
                else f.binding = LocalInstallationBinding.create()
                assertTrue(runCatching { s.revalidate() }.isFailure)
                f.assertRetired(s)
            } finally { f.cleanup() }
        }
    }

    @Test fun authExitAutomaticallyClearsPageWithoutAnotherRead() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); val s = f.open(); s.messages(f.room)
            f.auth.prepareLocalExit(); f.assertRetired(s)
        } finally { f.cleanup() }
    }

    @Test fun credentialReplacementAndUnavailableStateRetireObservedSession() = runBlocking {
        for (replacement in listOf(true, false)) {
            val f = Fixture()
            try {
                f.seed(); val s = f.open(); s.messages(f.room)
                if (replacement) f.secret = f.credentials(UserId(id()))
                else f.onSecretRead = { throw CredentialStoreFailure(CredentialStoreFailure.Reason.Unavailable) }
                runCatching { f.auth.localAccountIdentity() }
                f.assertRetired(s)
            } finally { f.cleanup() }
        }
    }

    @Test fun ownerCancellationClearsAndClosesEvenWhenReadCallerHasDifferentJob() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); val s = f.open(); s.conversations()
            val entered = CompletableDeferred<Unit>(); val resume = CompletableDeferred<Unit>()
            f.onBindingRead = { entered.complete(Unit); resume.await() }
            val request = async(Dispatchers.Default) { runCatching { s.messages(f.room) } }
            withTimeout(10_000) { entered.await() }
            f.owner.coroutineContext[Job]!!.cancelAndJoin(); resume.complete(Unit)
            assertTrue(withTimeout(10_000) { request.await() }.isFailure)
            f.assertRetired(s)
        } finally { f.cleanup() }
    }

    @Test fun cancellingOneReadDoesNotRetireOwnerAndForegroundRevalidationClearsOldPage() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); val s = f.open(); s.conversations()
            val entered = CompletableDeferred<Unit>()
            f.onBindingRead = { entered.complete(Unit); awaitCancellation() }
            val request = launch(Dispatchers.Default) { s.messages(f.room) }
            withTimeout(10_000) { entered.await() }; request.cancelAndJoin()
            f.onBindingRead = {}; assertTrue(s.state.value.active)
            assertTrue(s.messages(f.room).available)
            s.revalidate(); assertEquals(LocalProjectionSnapshot(), s.state.value)
            try { s.conversations(limit = 0); fail("invalid limit") } catch (_: IllegalArgumentException) { }
            assertTrue(s.messages(f.room).available)
        } finally { f.cleanup() }
    }

    @Test fun explicitCloseWhilePostValidationIsSuspendedPreventsLatePublication() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); val s = f.open(); s.conversations()
            val entered = CompletableDeferred<Unit>(); val resume = CompletableDeferred<Unit>()
            f.bindingReads = 0
            f.onBindingRead = { if (it == 3) { entered.complete(Unit); resume.await() } }
            val request = async(Dispatchers.Default) { runCatching { s.messages(f.room) } }
            withTimeout(10_000) { entered.await() }; s.close(); resume.complete(Unit)
            assertTrue(withTimeout(10_000) { request.await() }.exceptionOrNull() is ClientFailure.SessionInvalidated)
            f.assertRetired(s)
        } finally { f.cleanup() }
    }

    @Test fun alreadyCancelledOwnerNeverOpensOrLeaksTheDatabase() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); f.owner.cancel()
            try { f.open(); fail("cancelled owner accepted") } catch (_: CancellationException) { }
            LocalDatabaseAccess.acquire(f.file, recovery = true).close()
        } finally { f.cleanup() }
    }

    @Test fun cancellationBeforeObserverDispatchStillRetiresTheAlreadyOpenStore() = runBlocking {
        val f = Fixture(); val queued = ConcurrentLinkedQueue<Runnable>(); val job = SupervisorJob()
        val dispatcher = object : CoroutineDispatcher() {
            override fun dispatch(context: CoroutineContext, block: Runnable) { queued.add(block) }
        }
        try {
            f.seed()
            val s = f.bootstrap.openLocalProjection(f.auth, f.marker, CoroutineScope(job + dispatcher))
            f.session = s
            assertFalse(queued.isEmpty()); job.cancel()
            // This request belongs to runBlocking, not the cancelled lifecycle owner.
            try { s.messages(f.room); fail("cancelled owner published before observation started") } catch (_: CancellationException) { }
            withTimeout(10_000) { while (!job.isCompleted) { queued.poll()?.run() ?: delay(1) } }
            f.assertRetired(s)
        } finally {
            job.cancel()
            withTimeout(10_000) { while (!job.isCompleted) { queued.poll()?.run() ?: delay(1) } }
            f.cleanup()
        }
    }

    @Test fun permissionAndTextShareOneSqliteSnapshotAcrossConcurrentRevocation() = runBlocking {
        val f = Fixture()
        try {
            f.seed()
            f.database { writer ->
                writer.enableWriteAheadLogging()
                SqliteLocalReadConnection.open(f.file).use { reader ->
                    val projection = SqliteLocalProjection(reader, f.user)
                    SqliteLocalReadConnection.snapshot(reader) {
                        assertTrue(projection.allows(f.room))
                        writer.execSQL("UPDATE memberships SET member=0 WHERE room=?", arrayOf(f.room.value))
                        assertEquals("本地消息", projection.messages(f.room, null, 1).entries.single().text)
                    }
                    assertFalse(SqliteLocalReadConnection.snapshot(reader) { projection.messages(f.room, null, 1).available })
                }
            }
        } finally { f.cleanup() }
    }
}
