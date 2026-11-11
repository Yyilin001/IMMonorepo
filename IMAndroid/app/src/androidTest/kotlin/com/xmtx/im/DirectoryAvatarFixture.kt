package com.xmtx.im

import android.graphics.Bitmap
import com.google.protobuf.ByteString
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.*

/** A real HTTPS byte transfer, with a test-only trusted localhost certificate. */
internal class DirectoryAvatarFixture(val actor: UserId,val device: DeviceId,val room: RoomId): AutoCloseable {
    val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    val reads=CopyOnWriteArrayList<ProfileKey>()
    var beforeRead: suspend () -> Unit = {}
    val grants=CopyOnWriteArrayList<AvatarReadGrant>()
    val pages=CopyOnWriteArrayList<ProfilePresentationPage>()
    val requests=CopyOnWriteArrayList<String>()
    val errors=CopyOnWriteArrayList<String>()
    fun diagnostics()="reads=${reads.size}, grants=${grants.size}, requests=${requests.size}, profiles=${pages.map {it.state.value.display.profiles.size}}, images=${pages.map {it.state.value.display.avatars.size}}, errors=$errors"
    private val bytes: ByteString
    private val server: SSLServerSocket
    private val worker=Executors.newSingleThreadExecutor()
    private val http: OkHttpClient
    private val cache: AvatarCache
    init {
        val bitmap=Bitmap.createBitmap(64,64,Bitmap.Config.ARGB_8888);val output=ByteString.newOutput()
        try {bitmap.eraseColor(android.graphics.Color.rgb(23,107,82));bitmap.compress(Bitmap.CompressFormat.PNG,100,output)} finally {bitmap.recycle()}
        bytes=output.toByteString()
        // Generate a fresh test identity instead of depending on PKCS#12 MAC
        // algorithms that differ between Android 12 and newer providers.
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").build()
        val keys=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        // Android may choose ::1 for getLoopbackAddress while localhost resolves only to 127.0.0.1.
        // Bind and address the same loopback family; the certificate explicitly covers this IP.
        server=keys.sslContext().serverSocketFactory.createServerSocket(0,32,java.net.InetAddress.getByName("127.0.0.1")) as SSLServerSocket
        http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        cache=AvatarCache(actor,device,AvatarDownloader(http)::download)
        worker.submit {
            while(!server.isClosed) {
                try {server.accept().use {socket->
                    socket.soTimeout=5000
                    val input=socket.getInputStream().bufferedReader(Charsets.US_ASCII)
                    val request=input.readLine() ?: return@use
                    while(true) {val line=input.readLine() ?: break;if(line.isEmpty()) break}
                    require(request.startsWith("GET /avatar/"));requests.add(request.split(' ')[1])
                    val outputStream=socket.getOutputStream()
                    outputStream.write("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: ${bytes.size()}\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                    bytes.writeTo(outputStream);outputStream.flush()
                }} catch(error: Exception) {
                    // Scrolling legitimately cancels old requests, including their TLS handshake.
                    // One cancelled connection must not stop the fixture accepting the new viewport.
                    if(!server.isClosed) errors.add("server: ${error::class.simpleName}: ${error.message}")
                    if(!server.isClosed && error !is IOException) throw error
                }
            }
        }
    }
    fun open(): ProfilePresentationPage=ProfilePresentationPage(actor,device,{keys->
        reads.addAll(keys)
        beforeRead()
        try {keys.map {key->
            val checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()).joinToString("") {"%02x".format(it)})
            val content=AvatarContent(key.user.value,device.value,1,checksum,bytes.size().toLong())
            val plan=ResourceTransferPlan(ResourceTransferMode.Get,"https://127.0.0.1:${server.localPort}/avatar/${key.user.value}",persistentListOf(),persistentMapOf(),null,
                System.currentTimeMillis()+60000,content.byteCount,null,null,checksum)
            val deadline=System.nanoTime()+60_000_000_000
            val authorityRoom=when(val context=key.context) { is ProfileContext.Room -> context.room; is ProfileContext.GroupJoinReview -> context.room; else -> null }
            val membership=if(authorityRoom==null) 0L else 1L
            ProfileReadResult.Available(AuthorizedProfile(ProfileView(key.user,PublicIdentity(key.user,PublicHandle("reader"),"成员 ${key.user.value.takeLast(3)}",AccountKind.Regular),
                key.user.value,ProfileState.Active,1,1),ProfileLease(actor,device,key,1,1,membership,ProfileAuthority(1,authorityRoom,membership,membership),0,300000)),
                deadline,AvatarAccess(content,plan),deadline)
        }.toPersistentList()} catch(error: Exception) {errors.add("profile: ${error::class.simpleName}: ${error.stackTrace.firstOrNull()}");throw error}
    },{keys->ProfileFenceSnapshot("directory",keys.associateWith {ProfileFence()}.toPersistentMap())},scope,
        avatarReader={grant->grants.add(grant);try {cache.read(grant)} catch(error: Exception) {errors.add("download: ${error::class.simpleName}");throw error}}).also(pages::add)
    override fun close() {
        pages.forEach {it.close()}
        runBlocking {cache.close()};scope.cancel();server.close();worker.shutdownNow();check(worker.awaitTermination(6,TimeUnit.SECONDS))
        http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()
    }
}
