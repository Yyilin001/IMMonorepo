package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteReadOnlyDatabaseException
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LocalReadSessionTests {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private inner class Fixture {
        val user = UserId(UUID.randomUUID().toString()); val device = DeviceId(UUID.randomUUID().toString())
        val room = RoomId(UUID.randomUUID().toString()); val message = MessageId(UUID.randomUUID().toString())
        val file = accountDatabaseFile(context, user, device)
        var pending = false; var markerRead: suspend () -> Unit = {}
        val marker = object : LocalExitMarker {
            override suspend fun isPending(): Boolean { markerRead(); return pending }
            override suspend fun markPending() { pending = true }
            override suspend fun clearPending() { pending = false }
        }
        var secret: String? = buildJsonObject { put("credentials", Json.encodeToJsonElement(Credentials(user,device,"local-access",1,"local-refresh","imv2-revoke-v1.${"A".repeat(43)}",1))) }.toString()
        var secretReads = 0; var onRead: suspend (Int) -> Unit = {}
        val auth = AuthSession(object : SecretStore {
            override suspend fun read(): String? { onRead(++secretReads); return secret }
            override suspend fun write(value: String) { error("local read wrote credentials") }
            override suspend fun delete() { error("local read deleted credentials") }
        }, object : AccountTransport {
            override suspend fun post(path: String,payload: JsonObject,accessToken: String?,expectedStatus: Int): JsonObject = error("local read requested network")
        }, marker)
        var binding: LocalInstallationBinding? = LocalInstallationBinding.create()
        var bindingReads = 0; var onBindingRead: suspend (Int) -> Unit = {}
        val bindings = object : InstallationBindingStore {
            override suspend fun load(): LocalInstallationBinding? { onBindingRead(++bindingReads); return binding }
            override suspend fun save(binding: LocalInstallationBinding) { error("unexpected binding creation") }
            override suspend fun delete() { error("unexpected binding deletion") }
        }
        val bootstrap = LocalStoreBootstrapper(context,bindings)
        suspend fun seed() {
            bootstrap.open(user,device).use { s ->
                s.acceptState(room,RoomSyncState.newBuilder().setRoomId(room.value).setHead(1).setViewerMembershipRevision(1).build())
                database { db -> db.execSQL("INSERT INTO messages(id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn,rich) VALUES (?,?,?,?,?,1,1,1,1,0,?)",
                    arrayOf(message.value,room.value,user.value,"本地消息","本地消息",MessageRichContent.Empty.payload().toString())) }
                repeat(3) { s.processMessageSearchIndex() }
            }
        }
        fun database(body: (SQLiteDatabase) -> Unit) = SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.OPEN_READWRITE).use(body)
        fun close() { SQLiteDatabase.deleteDatabase(file) }
    }

    @Test fun actualReadOnlyConnectionReadsProjectionTimelineAndSearchAndRejectsWrites() = runBlocking {
        val f = Fixture()
        try {
            f.seed(); val before = f.file.readBytes(); val credentials = f.secret
            val permit = f.bootstrap.localReadBootstrap(f.auth,f.marker)
            f.bootstrap.openLocalReadSession(f.auth,permit,f.marker).use { s ->
                assertTrue(s.isReadOnly); assertEquals(permit.databaseIdentity,s.databaseIdentity)
                assertEquals(f.message,s.snapshot().messages.single().id)
                assertEquals(f.room,s.appSnapshot().conversations.single().id)
                assertEquals(f.message,s.conversationTimeline(f.room,f.user).messages.single().id)
                assertEquals(f.message,s.searchMessages(f.user,MessageSearchRequest("本地")).hits.single().message)
                try { s.enqueueRead(f.room,1); fail("read-only journal accepted write") } catch (_: SQLiteReadOnlyDatabaseException) {}
                try { s.rebuildMessageSearchIndex(); fail("read-only search rebuilt") } catch (_: SQLiteReadOnlyDatabaseException) {}
                assertTrue(s.readWorks().isEmpty())
                try { LocalDatabaseAccess.acquire(f.file,recovery=true).close(); fail("live read store did not hold gate") } catch (_: LocalStoreFailure) {}
            }
            assertArrayEquals(before,f.file.readBytes()); assertEquals(credentials,f.secret)
            LocalDatabaseAccess.acquire(f.file,recovery=true).close()
        } finally { f.close() }
    }

    @Test fun missingDatabaseAndMissingBindingNeverCreateOrAdoptFiles() = runBlocking {
        val f=Fixture()
        try {
            try { f.bootstrap.localReadBootstrap(f.auth,f.marker); fail("missing database") } catch (_: LocalStoreFailure) {}
            assertFalse(f.file.exists()); f.seed(); val bytes=f.file.readBytes();f.binding=null
            try { f.bootstrap.localReadBootstrap(f.auth,f.marker); fail("missing binding") } catch (_: LocalStoreFailure) {}
            assertArrayEquals(bytes,f.file.readBytes())
        } finally { f.close() }
    }

    @Test fun foreignOwnerChangedDatabaseAndPendingExitInvalidateThePermit() = runBlocking {
        val f=Fixture()
        try {
            f.seed();val permit=f.bootstrap.localReadBootstrap(f.auth,f.marker)
            try { LocalStoreBootstrapper(context,f.bindings).openLocalReadSession(f.auth,permit,f.marker).close();fail("foreign owner") } catch (_: ClientFailure.SessionInvalidated) {}
            f.database { it.execSQL("UPDATE im_database_identity SET identity=?",arrayOf(LocalDatabaseIdentity.create().value)) }
            try { f.bootstrap.openLocalReadSession(f.auth,permit,f.marker).close();fail("replacement") } catch (_: ClientFailure.SessionInvalidated) {}
            val next=f.bootstrap.localReadBootstrap(f.auth,f.marker);f.pending=true
            try { f.bootstrap.openLocalReadSession(f.auth,next,f.marker).close();fail("pending exit") } catch (_: ClientFailure.SignedOut) {}
        } finally { f.close() }
    }

    @Test fun postOpenExitAndCancellationCloseTheCapturedReadStore() = runBlocking {
        val f=Fixture()
        try {
            f.seed();val permit=f.bootstrap.localReadBootstrap(f.auth,f.marker)
            // Each revalidation reads the binding twice. The third load belongs to post-open validation.
            f.bindingReads=0;f.onBindingRead={ if(it==3) f.pending=true }
            try { f.bootstrap.openLocalReadSession(f.auth,permit,f.marker).close();fail("exit during open") } catch (_: ClientFailure.SignedOut) {}
            LocalDatabaseAccess.acquire(f.file,recovery=true).close()
        } finally { f.close() }
        val cancelled=Fixture()
        try {
            cancelled.seed();val permit=cancelled.bootstrap.localReadBootstrap(cancelled.auth,cancelled.marker)
            val entered=CompletableDeferred<Unit>();cancelled.bindingReads=0
            cancelled.onBindingRead={if(it==3) {entered.complete(Unit);awaitCancellation()}}
            val job=launch(Dispatchers.Default) {cancelled.bootstrap.openLocalReadSession(cancelled.auth,permit,cancelled.marker).close()}
            withTimeout(10_000) {entered.await()};job.cancelAndJoin()
            LocalDatabaseAccess.acquire(cancelled.file,recovery=true).close()
        } finally {cancelled.close()}
    }

    @Test fun oldSchemaIsNotMigratedAndUnavailableSearchDoesNotPreventMessageReads() = runBlocking {
        val f=Fixture()
        try {
            f.seed();f.database {it.execSQL("DROP TABLE account_room_heads")}
            val before=f.file.readBytes();val permit=f.bootstrap.localReadBootstrap(f.auth,f.marker)
            try {f.bootstrap.openLocalReadSession(f.auth,permit,f.marker).close();fail("missing required schema")} catch (_:LocalStoreFailure) {}
            assertArrayEquals(before,f.file.readBytes());LocalDatabaseAccess.acquire(f.file,recovery=true).close()
            f.bootstrap.open(f.user,f.device).close()
            f.database {it.execSQL("UPDATE message_search_meta SET format='old-format'")}
            val oldIndex=f.file.readBytes();val next=f.bootstrap.localReadBootstrap(f.auth,f.marker)
            f.bootstrap.openLocalReadSession(f.auth,next,f.marker).use {
                assertEquals(f.message,it.snapshot().messages.single().id)
                assertFalse(it.messageSearchProgress().ready)
                try {it.searchMessages(f.user,MessageSearchRequest("本地"));fail("old format published")} catch (_:MessageSearchFailure.Building) {}
            }
            assertArrayEquals(oldIndex,f.file.readBytes())
        } finally {f.close()}
    }

    @Test fun activeWalWriterAndReadonlySessionObserveCommittedProjection() = runBlocking {
        val f=Fixture()
        try {
            f.seed();f.bootstrap.open(f.user,f.device).use { writer ->
                val permit=f.bootstrap.localReadBootstrap(f.auth,f.marker)
                f.bootstrap.openLocalReadSession(f.auth,permit,f.marker).use { reader ->
                    writer.enqueueRead(f.room,1)
                    writer.prepareReads(16)
                    assertTrue(writer.readWorks().isNotEmpty())
                    assertEquals(writer.readWorks(),reader.readWorks())
                    assertEquals(f.message,reader.snapshot().messages.single().id)
                }
            }
        } finally {f.close()}
    }

    @Test fun readTransactionRetainsOneSnapshotAcrossConcurrentCommitAndReleasesAfterFailure() = runBlocking {
        val f=Fixture()
        try {
            f.seed()
            f.database { writer -> writer.enableWriteAheadLogging(); SqliteLocalReadConnection.open(f.file).use { reader ->
                fun text() = reader.rawQuery("SELECT text FROM messages",null).use {it.moveToFirst();it.getString(0)}
                SqliteLocalReadConnection.snapshot(reader) {
                    assertEquals("本地消息",text())
                    writer.execSQL("UPDATE messages SET text='new committed text'")
                    assertEquals("本地消息",text())
                }
                assertEquals("new committed text",text())
                try { SqliteLocalReadConnection.snapshot(reader) {
                    reader.execSQL("UPDATE messages SET text='forbidden'")
                };fail("write succeeded") } catch (_:SQLiteReadOnlyDatabaseException) {}
                writer.execSQL("UPDATE messages SET text='after failure'")
                assertEquals("after failure",SqliteLocalReadConnection.snapshot(reader) {text()})
            } }
        } finally { f.close() }
    }
}
