package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.io.DataInputStream
import java.net.SocketTimeoutException
import java.net.Socket
import java.net.ServerSocket
import java.net.InetAddress
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.SSLSocket
import kotlin.test.*

class BackgroundSyncTlsTests {
    private fun SSLSocket.reset(request: Envelope) {
        outputStream.write(FrameCodec.encode(Envelope.newBuilder().setProtocolVersion(FrameCodec.VERSION).setRequestId(request.requestId)
            .setResetRequired(ResetRequired.newBuilder().setSnapshotId("00000000-0000-0000-0000-000000000002").setGeneration(2)
                .setBaseUserSyncSequence(1).setExpiresAtMs(2_000_000)).build()));outputStream.flush()
    }
    @Test fun `real TLS callers share one dedicated connection and cancellation of one waiter does not retire it`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use { peer ->
            val pulled=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use { socket ->
                val request=FrameCodec.read(socket.inputStream);assertTrue(request.hasSyncPull());pulled.complete(Unit);release.await()
                socket.reset(request);assertEquals(-1,socket.inputStream.read())
            }}
            var resolutions=0
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{assertNull(it);resolutions++;peer.credentials})
            val store=MemorySync();val runner=BackgroundSyncRunner(connection,SyncEngine(connection,store),this)
            try {
                val first=launch {runner.run()};withTimeout(3000) {pulled.await()}
                val second=async(start=CoroutineStart.UNDISPATCHED) {runner.run()};first.cancelAndJoin()
                assertTrue(peer.connection.state.value.connected);release.complete(Unit)
                assertEquals(IncrementalSyncStopReason.ResetPending,second.await().stopReason)
                assertFalse(peer.connection.state.value.connected);assertEquals(1,resolutions);server.await()
            } finally {release.complete(Unit);runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `real TLS deadline closes pending read and drains before reporting expiry without applying data`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer(timeout=5000).use { peer ->
            val pulled=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket ->
                assertTrue(FrameCodec.read(socket.inputStream).hasSyncPull());pulled.complete(Unit)
                assertEquals(-1,socket.inputStream.read())
            }}
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{peer.credentials})
            val store=MemorySync();val runner=BackgroundSyncRunner(connection,SyncEngine(connection,store),this,budget=BackgroundSyncBudget(workDurationMillis=1000))
            try {
                val work=async {runCatching {runner.run()}};withTimeout(3000) {pulled.await()}
                assertIs<BackgroundSyncDeadlineReached>(withTimeout(4000) {work.await()}.exceptionOrNull())
                assertFalse(peer.connection.state.value.connected);assertEquals(SyncCursor(1),store.position);server.await()
            } finally {runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `explicit authentication rejection refreshes once on same identity before bounded sync`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use {peer ->
            val server=async(Dispatchers.IO) {
                peer.accept(rejectAuthentication=true).use {assertEquals(-1,it.inputStream.read())}
                peer.accept().use {socket ->val pull=FrameCodec.read(socket.inputStream);assertTrue(pull.hasSyncPull());socket.reset(pull);assertEquals(-1,socket.inputStream.read())}
            }
            var calls=0
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{rejected ->
                if(calls++==0) {assertNull(rejected);peer.credentials} else {assertEquals(peer.credentials,rejected);peer.credentials.copy(accessToken="refreshed-fixture")}
            })
            val runner=BackgroundSyncRunner(connection,SyncEngine(connection,MemorySync()),this)
            try {assertEquals(IncrementalSyncStopReason.ResetPending,runner.run().stopReason);assertEquals(2,calls);server.await()}
            finally {runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `refresh cannot change account identity and repeated rejection is not retried indefinitely`() = runBlocking<Unit> {
        for (replacement in 0..2) RealtimeReceiveTests.Peer().use {peer ->
            var calls=0
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{rejected ->calls++;if(rejected==null) peer.credentials else when(replacement) { 1 -> peer.credentials.copy(userId=UserId("other")); 2 -> peer.credentials.copy(deviceId=DeviceId("00000000-0000-0000-0000-000000000003")); else -> peer.credentials }})
            val runner=BackgroundSyncRunner(connection,SyncEngine(connection,MemorySync()),this)
            val server=async(Dispatchers.IO) {repeat(if(replacement>0) 1 else 2) {peer.accept(rejectAuthentication=true).use {assertEquals(-1,it.inputStream.read())}}}
            try {
                val result=runCatching {runner.run()}
                if(replacement>0) assertIs<ClientFailure.SignedOut>(result.exceptionOrNull()) else assertIs<GatewayFailure>(result.exceptionOrNull())
                assertEquals(2,calls);assertFalse(peer.connection.state.value.connected);server.await()
            } finally {runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `stopping during uncooperative credential resolution cannot connect after drain`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use {peer ->
            val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{entered.complete(Unit);withContext(NonCancellable) {release.await()};peer.credentials})
            val runner=BackgroundSyncRunner(connection,SyncEngine(connection,MemorySync()),this)
            try {
                val work=async {runCatching {runner.run()}};entered.await()
                val stopping=launch(start=CoroutineStart.UNDISPATCHED) {runner.stop()};assertFalse(stopping.isCompleted)
                release.complete(Unit);stopping.join();assertIs<CancellationException>(work.await().exceptionOrNull())
                assertFalse(peer.connection.state.value.connected)
                withContext(Dispatchers.IO) {peer.listener.soTimeout=100;assertFailsWith<SocketTimeoutException> {peer.listener.accept()}}
            } finally {release.complete(Unit);runner.stop();peer.connection.close()}
        }
    }
    @Test fun `real TLS deadline interrupts an established socket still waiting for hello response`() = runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use {peer ->
            val helloRead=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {(peer.listener.accept() as SSLSocket).use {socket ->
                socket.soTimeout=5000;socket.startHandshake()
                val input=DataInputStream(socket.inputStream)
                assertEquals(0x494D,input.readUnsignedShort());assertEquals(0,input.readUnsignedByte());assertEquals(0,input.readUnsignedByte())
                assertEquals(1,input.readUnsignedShort());input.readLong()
                val bytes=ByteArray(input.readInt());input.readFully(bytes);assertTrue(Envelope.parseFrom(bytes).hasClientHello())
                helloRead.complete(Unit);assertEquals(-1,input.read())
            }}
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{peer.credentials})
            val store=MemorySync();val runner=BackgroundSyncRunner(connection,SyncEngine(connection,store),this,budget=BackgroundSyncBudget(workDurationMillis=1000))
            try {
                val work=async {runCatching {runner.run()}};withTimeout(3000) {helloRead.await()}
                assertIs<BackgroundSyncDeadlineReached>(withTimeout(4000) {work.await()}.exceptionOrNull())
                assertFalse(peer.connection.state.value.connected);assertEquals(SyncCursor(1),store.position);server.await()
            } finally {runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }

    @Test fun `account bound adapter revalidates identity after handshake and preserves replacement credentials`() = runBlocking<Unit> {
        for (replace in listOf(false,true)) RealtimeReceiveTests.Peer().use {peer ->
            val secret=MemorySecrets().apply {value=buildJsonObject {put("credentials",Json.encodeToJsonElement(peer.credentials))}.toString()}
            val auth=AuthSession(secret,FakeAccount()) {0};val identity=auth.localAccountIdentity()
            val connection=RealtimeBackgroundSyncConnection(peer.connection,auth,identity)
            val store=MemorySync();val runner=BackgroundSyncRunner(connection,SyncEngine(connection,store),this)
            val beforeAuthentication=CompletableDeferred<Unit>();val release=CountDownLatch(1)
            val server=async(Dispatchers.IO) {peer.accept(beforeAuthenticated={beforeAuthentication.complete(Unit);check(release.await(5,TimeUnit.SECONDS))}).use {socket ->
                if (!replace) {val pull=FrameCodec.read(socket.inputStream);assertTrue(pull.hasSyncPull());socket.reset(pull)}
                assertEquals(-1,socket.inputStream.read())
            }}
            try {
                val work=async {runCatching {runner.run()}};withTimeout(3000) {beforeAuthentication.await()}
                if (replace) secret.value=buildJsonObject {put("credentials",Json.encodeToJsonElement(peer.credentials.copy(userId=UserId("replacement"))))}.toString()
                val retained=secret.value;release.countDown()
                val result=withTimeout(3000) {work.await()}
                if (replace) {assertIs<ClientFailure.SessionInvalidated>(result.exceptionOrNull());assertNull(store.pendingReset())}
                else assertEquals(IncrementalSyncStopReason.ResetPending,result.getOrThrow().stopReason)
                assertEquals(retained,secret.value);assertFalse(peer.connection.state.value.connected);server.await()
            } finally {release.countDown();runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }

    @Test fun `deadline during socket allocation closes late socket before any network connection`() = runBlocking<Unit> {
        ServerSocket(0).use {listener ->
            val created=CompletableDeferred<Socket>();val retired=CompletableDeferred<Unit>();val release=CountDownLatch(1)
            val base=SSLSocketFactory.getDefault() as SSLSocketFactory
            val factory=object : SSLSocketFactory() {
                override fun getDefaultCipherSuites()=base.defaultCipherSuites
                override fun getSupportedCipherSuites()=base.supportedCipherSuites
                override fun createSocket(): Socket = base.createSocket().also {created.complete(it);check(release.await(5,TimeUnit.SECONDS))}
                override fun createSocket(socket: Socket,host: String,port: Int,autoClose: Boolean)=base.createSocket(socket,host,port,autoClose)
                override fun createSocket(host: String,port: Int)=base.createSocket(host,port)
                override fun createSocket(host: String,port: Int,local: InetAddress,localPort: Int)=base.createSocket(host,port,local,localPort)
                override fun createSocket(address: InetAddress,port: Int)=base.createSocket(address,port)
                override fun createSocket(address: InetAddress,port: Int,local: InetAddress,localPort: Int)=base.createSocket(address,port,local,localPort)
            }
            val socket=RealtimeConnection("localhost",listener.localPort,factory)
            val credentials=Credentials(UserId("user"),DeviceId("00000000-0000-0000-0000-000000000001"),"fixture",100000,"refresh","imv2-revoke-v1."+"A".repeat(43),100000)
            val adapter=RealtimeBackgroundSyncConnection(socket,{credentials})
            val connection=object : BackgroundSyncConnection {
                override suspend fun connect()=adapter.connect()
                override fun disconnect() {adapter.disconnect();retired.complete(Unit)}
            }
            val runner=BackgroundSyncRunner(connection,SyncEngine(adapter,MemorySync()),this,budget=BackgroundSyncBudget(workDurationMillis=200))
            try {
                val work=async {runCatching {runner.run()}};val allocated=withTimeout(3000) {created.await()}
                withTimeout(3000) {retired.await()};assertFalse(work.isCompleted);release.countDown()
                assertIs<BackgroundSyncDeadlineReached>(withTimeout(3000) {work.await()}.exceptionOrNull())
                assertTrue(allocated.isClosed);assertFalse(allocated.isConnected)
                withContext(Dispatchers.IO) {listener.soTimeout=100;assertFailsWith<SocketTimeoutException> {listener.accept()}}
            } finally {release.countDown();runner.stop();socket.close()}
        }
    }

}
