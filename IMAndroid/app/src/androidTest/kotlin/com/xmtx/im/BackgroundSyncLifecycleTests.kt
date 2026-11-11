package com.xmtx.im

import android.app.Application
import android.database.sqlite.SQLiteDatabase
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import com.xmtx.im.client.Credentials
import com.xmtx.im.platform.*
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import java.io.DataInputStream
import java.io.File
import java.net.InetAddress
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

class BackgroundSyncLifecycleTests {
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun hash(value:String)=MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") {"%02x".format(it)}
    private inner class Fixture {
        val name="credential-background-sync-${UUID.randomUUID()}"
        val user=UserId(UUID.randomUUID().toString());val device=DeviceId(UUID.randomUUID().toString())
        val credentials=Credentials(user,device,"fixture-access",System.currentTimeMillis()+600_000,"fixture-refresh","imv2-revoke-v1.${"A".repeat(43)}",System.currentTimeMillis()+3_600_000)
        val secrets=KeystoreCredentialStore(context,name)
        val credentialFile=File(context.noBackupFilesDir,"$name.enc")
        val owners=ViewModelStore();lateinit var model:AppViewModel
        val peers=CopyOnWriteArrayList<SSLSocket>();val connections=CopyOnWriteArrayList<RealtimeConnection>()
        val backgroundAllocated=AtomicInteger();val foregroundAllocated=AtomicInteger();val accepted=AtomicInteger()
        val foregroundStarted=CompletableDeferred<Unit>();val network=AccountNetworkActivity()
        var readGate:CompletableDeferred<Unit>?=null;var readEntered=CompletableDeferred<Unit>()
        val releases=mutableListOf<CompletableDeferred<Unit>>()
        val work=CoroutineScope(SupervisorJob()+Dispatchers.IO)
        private val certificate=HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").build()
        private val serverTrust=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        private val clientTrust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        private val listener=(serverTrust.sslContext().serverSocketFactory.createServerSocket(0,16,InetAddress.getByName("127.0.0.1")) as SSLServerSocket).apply {soTimeout=10_000}
        val http=OkHttpClient.Builder().addInterceptor {chain->
            val revoke=chain.request().url.encodedPath.contains("revoke")
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(if(revoke) 204 else 503).message("fixture")
                .body((if(revoke) "" else "{}").toResponseBody("application/json".toMediaType())).build()
        }.build()
        suspend fun prepare() {
            secrets.write(buildJsonObject {put("credentials",Json.encodeToJsonElement(credentials))}.toString())
            LocalStoreBootstrapper(context).open(user,device).close()
            context.getSharedPreferences("$name-prefs",0).edit().putString("url","https://127.0.0.1").commit()
        }
        suspend fun start(wait:Boolean=true) {
            withContext(Dispatchers.Main.immediate) {
                model=AppViewModel(context.applicationContext as Application,AppDependencies(
                    account={AccountClient(it,http)},networkActivity={network},
                    realtime={foregroundAllocated.incrementAndGet();foregroundStarted.complete(Unit);socket()},
                    backgroundRealtime={backgroundAllocated.incrementAndGet();socket()},
                    credentialsName=name,preferencesName="$name-prefs",credentialStore={_,_->object:SecretStore by secrets {
                        override suspend fun read():String? {
                            readGate?.let {gate->readEntered.complete(Unit);withContext(NonCancellable) {gate.await()}}
                            return secrets.read()
                        }
                    }}))
                owners.put("background",model)
            }
            if(wait) withTimeout(15_000) {model.state.first {it.session!=SessionUi.Loading}}
        }
        private fun socket()=RealtimeConnection("127.0.0.1",listener.localPort,clientTrust.sslSocketFactory(),requestTimeoutMillis=5000).also(connections::add)
        fun gate()=CompletableDeferred<Unit>().also(releases::add)
        fun serve(body:suspend (SSLSocket)->Unit):Deferred<Result<Unit>> = work.async {
            runCatching {
                val socket=listener.accept() as SSLSocket;peers+=socket;accepted.incrementAndGet()
                socket.use {socket.soTimeout=8000;socket.startHandshake()
                    val input=DataInputStream(socket.inputStream)
                    assertEquals(0x494D,input.readUnsignedShort());assertEquals(0,input.readUnsignedByte());assertEquals(0,input.readUnsignedByte());assertEquals(1,input.readUnsignedShort())
                    val id=input.readLong();val bytes=ByteArray(input.readInt());input.readFully(bytes)
                    assertTrue(Envelope.parseFrom(bytes).hasClientHello())
                    socket.send(id,Envelope.newBuilder().setServerHello(ServerHello.newBuilder().setServerTimeMs(System.currentTimeMillis())
                        .setSelectedProtocolVersion(FrameCodec.VERSION).setSelectedCapabilityProfile("base").setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(FrameCodec.MAX_PAYLOAD)))
                    val auth=FrameCodec.read(input);assertEquals(device.value,auth.authenticate.deviceId)
                    assertTrue(auth.authenticate.presencePublicationSuppressed)
                    socket.send(auth.requestId,Envelope.newBuilder().setAuthenticated(Authenticated.newBuilder().setUserId(user.value).setDeviceId(device.value)
                        .setSelectedCapabilityProfile("base").setSupportsMessageSendOperations(true).setMaximumMessageSendPayloadBytes(FrameCodec.MAX_PAYLOAD)))
                    body(socket)
                }
            }
        }
        suspend fun finish(server:Deferred<Result<Unit>>) {withTimeout(10_000) {server.await()}.getOrThrow()}
        suspend fun stop() {
            if(!::model.isInitialized) return
            withContext(Dispatchers.Main.immediate) {owners.clear()}
            withTimeout(15_000) {model.awaitShutdown()}
        }
        suspend fun close() {
            readGate?.complete(Unit);readGate=null;releases.forEach {it.complete(Unit)}
            try {stop()} finally {
                connections.forEach {it.close()};peers.forEach {runCatching {it.close()}};listener.close();work.cancel();work.coroutineContext.job.join()
                secrets.delete();context.getSharedPreferences("$name-prefs",0).edit().clear().commit()
                for(suffix in listOf("",".bak",".new")) File(context.noBackupFilesDir,"local-exit-${hash(name)}.json$suffix").delete()
                val id=hash("${user.value}/${device.value}")
                SQLiteDatabase.deleteDatabase(File(context.noBackupFilesDir,"im-$id.db"));File(context.noBackupFilesDir,"resources-$id").deleteRecursively()
                val keys=KeyStore.getInstance("AndroidKeyStore").apply {load(null);deleteEntry("com.xmtx.im.$name.v1")}
                for(kind in listOf("receipts","revocations","registrations")) {
                    val journal="credential-$kind-${hash(credentialRecoveryNamespace(name,"https://127.0.0.1"))}"
                    for(suffix in listOf("", ".bak", ".new")) File(context.noBackupFilesDir,"$journal.enc$suffix").delete()
                    keys.deleteEntry("com.xmtx.im.$journal.v1")
                }
                http.dispatcher.cancelAll();http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()
            }
        }
    }
    private fun fixture(body:suspend CoroutineScope.(Fixture)->Unit)=runBlocking {
        val f=Fixture();try {f.prepare();body(f)} finally {withContext(NonCancellable) {f.close()}}
    }
    private fun SSLSocket.send(id:Long,body:Envelope.Builder) {outputStream.write(FrameCodec.encode(body.setProtocolVersion(FrameCodec.VERSION).setRequestId(id).build()));outputStream.flush()}
    private fun SSLSocket.reset(id:Long) = send(id,Envelope.newBuilder().setResetRequired(ResetRequired.newBuilder().setSnapshotId("00000000-0000-0000-0000-000000000001")
        .setGeneration(2).setBaseUserSyncSequence(1).setExpiresAtMs(System.currentTimeMillis()+60000)))
    @Test fun wakeWaitsForRestorePersistsNewRecordsAndUsesDedicatedConnection()=fixture {f->
        val peer=UserId(UUID.randomUUID().toString())
        val server=f.serve {socket->
            val pull=FrameCodec.read(socket.inputStream);assertTrue(pull.hasSyncPull())
            socket.send(pull.requestId,Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base").setNextSyncToken("next").setSyncReceipt("receipt")
                .addRecords(SyncRecord.newBuilder().setUserSyncSequence(1).setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("user_block")
                    .setPayload(ByteString.copyFromUtf8("""{"target_user_id":"${peer.value}","is_blocked":true,"updated_at_ms":1}""")))))
            val ack=FrameCodec.read(socket.inputStream);assertTrue(ack.hasSyncAck());socket.send(ack.requestId,Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()))
            val start=FrameCodec.read(socket.inputStream);assertTrue(start.hasAccountRoomChangesStart())
            socket.send(start.requestId,Envelope.newBuilder().setAccountRoomChangesReady(AccountRoomChangesReady.newBuilder().setConnectionEpoch(UUID.randomUUID().toString())))
            val directory=FrameCodec.read(socket.inputStream);assertTrue(directory.hasUserRoomDirectoryList())
            socket.send(directory.requestId,Envelope.newBuilder().setUserRoomDirectoryPage(UserRoomDirectoryPage.newBuilder().setTopologyGeneration("fixture")))
            assertEquals(-1,socket.inputStream.read())
        }
        f.start(wait=false)
        assertEquals(BackgroundSyncOutcome.NewData,withTimeout(15_000) {f.model.synchronizeInBackground()})
        f.finish(server);assertEquals(1,f.accepted.get());assertEquals(0,f.foregroundAllocated.get());assertEquals(1,f.backgroundAllocated.get())
        val admission=f.network.scheduler.snapshot();assertEquals(0,admission.active);assertEquals(0,admission.waiting)
        val projections=f.network.scheduler.networkDiagnostics.snapshot().projections
        assertTrue(projections.any {it.phase==ProjectionMetric.Phase.Commit && ProjectionScope.Conversations in it.scopes})
        assertFalse(projections.any {it.phase==ProjectionMetric.Phase.CommitToConversationSnapshot})
        f.stop();LocalStoreBootstrapper(context).open(f.user,f.device).use {assertEquals(peer,it.snapshot().blockedUsers.single().target)}
    }
    @Test fun concurrentWakeWaitersShareTransportAndCancellingOneDoesNotRetireWork()=fixture {f->
        f.start();val entered=CompletableDeferred<Unit>();val release=f.gate()
        val server=f.serve {socket->val pull=FrameCodec.read(socket.inputStream);assertTrue(pull.hasSyncPull());entered.complete(Unit);release.await();socket.reset(pull.requestId);assertEquals(-1,socket.inputStream.read())}
        val first=async {f.model.synchronizeInBackground()};withTimeout(5000) {entered.await()}
        assertTrue(f.network.scheduler.snapshot().active>0)
        val second=async(start=CoroutineStart.UNDISPATCHED) {f.model.synchronizeInBackground()}
        withContext(Dispatchers.Main.immediate) { } // Join the second caller before cancelling the first.
        first.cancelAndJoin();assertTrue(f.connections.single().state.value.connected)
        release.complete(Unit);assertEquals(BackgroundSyncOutcome.NoData,withTimeout(5000) {second.await()});f.finish(server)
        assertEquals(1,f.accepted.get());f.stop()
        LocalStoreBootstrapper(context).open(f.user,f.device).use {assertNotNull(it.pendingReset());assertNull(it.pendingSnapshot())}
    }
    @Test fun restoreTimeConsumesWakeDeadlineWithoutCancellingRestoreOrOpeningSocket()=fixture {f->
        f.readGate=f.gate();f.start(wait=false);withTimeout(5000) {f.readEntered.await()}
        assertEquals(BackgroundSyncOutcome.Failed,withTimeout(3000) {f.model.synchronizeInBackground(System.nanoTime()+100_000_000)})
        assertEquals(SessionUi.Loading,f.model.state.value.session);assertEquals(0,f.accepted.get())
        f.readGate?.complete(Unit);f.readGate=null
        withTimeout(15000) {f.model.state.first {it.session is SessionUi.SignedIn}}
        assertEquals(0,f.foregroundAllocated.get())
    }
    @Test fun foregroundWaitsForCancelledBackgroundCredentialReadToDrainBeforeStartingRuntime()=fixture {f->
        f.start();f.readGate=f.gate()
        val wake=async {f.model.synchronizeInBackground()};withTimeout(5000) {f.readEntered.await()}
        withContext(Dispatchers.Main.immediate) {f.model.foreground(true)}
        assertFalse(f.foregroundStarted.isCompleted);assertFalse(wake.isCompleted)
        f.readGate?.complete(Unit);f.readGate=null
        withTimeout(5000) {f.foregroundStarted.await()}
        withContext(Dispatchers.Main.immediate) {f.model.foreground(false)}
        assertEquals(BackgroundSyncOutcome.NoData,withTimeout(5000) {wake.await()})
        assertEquals(0,f.accepted.get())
    }
    @Test fun clearingAccountOwnerClosesPendingTlsReadAndDrainsSchedulerBeforeStoreClose()=fixture {f->
        f.start();val entered=CompletableDeferred<Unit>()
        val server=f.serve {socket->assertTrue(FrameCodec.read(socket.inputStream).hasSyncPull());entered.complete(Unit);assertEquals(-1,socket.inputStream.read())}
        val wake=async {f.model.synchronizeInBackground()};withTimeout(5000) {entered.await()}
        f.stop();assertEquals(BackgroundSyncOutcome.NoData,withTimeout(5000) {wake.await()});f.finish(server)
        val network=f.network.scheduler.snapshot();assertTrue(network.closed);assertEquals(0,network.active);assertEquals(0,network.waiting)
        LocalStoreBootstrapper(context).open(f.user,f.device).use {assertEquals(0L,it.cursor().sequence)}
    }
    @Test fun signOutRetiresBackgroundSocketAndNeverCommitsOrRestartsIt()=fixture {f->
        f.start();val entered=CompletableDeferred<Unit>()
        val server=f.serve {socket->assertTrue(FrameCodec.read(socket.inputStream).hasSyncPull());entered.complete(Unit);assertEquals(-1,socket.inputStream.read())}
        val wake=async {f.model.synchronizeInBackground()};withTimeout(5000) {entered.await()}
        withContext(Dispatchers.Main.immediate) {f.model.signOut()}
        assertEquals(BackgroundSyncOutcome.NoData,withTimeout(5000) {wake.await()});f.finish(server)
        withTimeout(15000) {f.model.state.first {it.session==SessionUi.SignedOut}}
        assertEquals(BackgroundSyncOutcome.NoData,f.model.synchronizeInBackground());assertEquals(1,f.accepted.get())
        assertTrue(f.network.scheduler.snapshot().closed)
    }
    @Test fun replacedCredentialsArePreservedAndCannotAuthenticateBackgroundSocket()=fixture {f->
        f.start();val replacement=f.credentials.copy(userId=UserId(UUID.randomUUID().toString()),deviceId=DeviceId(UUID.randomUUID().toString()))
        f.secrets.write(buildJsonObject {put("credentials",Json.encodeToJsonElement(replacement))}.toString());val bytes=f.credentialFile.readBytes()
        assertTrue(withTimeout(5000) {f.model.synchronizeInBackground()} in setOf(BackgroundSyncOutcome.Failed,BackgroundSyncOutcome.NoData))
        withTimeout(15000) {f.model.state.first {it.session==SessionUi.SignedOut}}
        assertArrayEquals(bytes,f.credentialFile.readBytes());assertEquals(0,f.accepted.get());assertTrue(f.network.scheduler.snapshot().closed)
    }
    @Test fun expiredWakeDoesNotConnectAndGoingToBackgroundDoesNotScheduleWork()=fixture {f->
        f.start();withContext(Dispatchers.Main.immediate) {f.model.foreground(false)}
        assertEquals(BackgroundSyncOutcome.Failed,f.model.synchronizeInBackground(System.nanoTime()-1))
        assertEquals(0,f.accepted.get());assertTrue(f.connections.none {it.state.value.connected})
        f.stop();assertEquals(BackgroundSyncOutcome.NoData,f.model.synchronizeInBackground())
    }
}
