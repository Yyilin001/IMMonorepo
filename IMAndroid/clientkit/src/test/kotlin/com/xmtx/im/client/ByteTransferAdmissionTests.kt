package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.test.*

class ByteTransferAdmissionTests {
    private fun https(body:suspend CoroutineScope.(MockWebServer,OkHttpClient,File)->Unit) {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val keys=HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val directory=Files.createTempDirectory("byte-admission").toFile()
        MockWebServer().use {server->
            server.protocols=listOf(Protocol.HTTP_1_1);server.useHttps(keys.sslSocketFactory(),false);server.start()
            val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).dns(object:Dns {override fun lookup(hostname:String)=listOf(java.net.InetAddress.getByName("127.0.0.1"))}).build()
            try {runBlocking {withTimeout(15000) {body(server,http,directory)}}}
            finally {http.dispatcher.executorService.shutdown();http.connectionPool.evictAll();directory.deleteRecursively()}
        }
    }
    private fun work(scheduler:AccountWorkScheduler,priority:NetworkWorkPriority=NetworkWorkPriority.Interactive)=
        NetworkWorkScope(scheduler,NetworkWorkContext("caller-metadata",priority))
    private fun plan(server:MockWebServer,path:String,mode:ResourceTransferMode=ResourceTransferMode.Get):ResourceTransferPlan {
        val checksum=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest("abcdefgh".toByteArray()).joinToString("") {"%02x".format(it)})
        return ResourceTransferPlan(mode,server.url(path).toString(),persistentListOf(),persistentMapOf(),null,System.currentTimeMillis()+60000,8,null,null,checksum)
    }
    private fun target(server:MockWebServer,path:String="/file")=MediaDownloadTarget(plan(server,path),null,System.nanoTime()+60_000_000_000,System::nanoTime)
    private suspend fun state(scheduler:AccountWorkScheduler,predicate:(AccountWorkScheduler.Snapshot)->Boolean)=withTimeout(5000) {
        while(!predicate(scheduler.snapshot())) delay(5)
    }
    private suspend fun request(server:MockWebServer)=assertNotNull(withContext(Dispatchers.IO) {server.takeRequest(5,TimeUnit.SECONDS)})
    @Test fun `domain PUT retries consume shared media quota and initial preview keeps its first attempt`()=https {server,http,directory->
        val clock=java.util.concurrent.atomic.AtomicLong(0);val scheduler=AccountWorkScheduler(nowMillis=clock::get)
        val source=File(directory,"source").apply {writeText("abcdefgh")}
        try {
            repeat(5) {
                server.enqueue(MockResponse().setResponseCode(204))
                withContext(work(scheduler)+NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {
                    ResourcePlanUploader(http).upload(source,plan(server,"/retry",ResourceTransferMode.Put))
                }
            }
            val next=async(work(scheduler)+NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {
                ResourcePlanUploader(http).upload(source,plan(server,"/sixth",ResourceTransferMode.Put))
            }
            state(scheduler) {it.waitingByteTransfers==1};assertEquals(5,server.requestCount)
            val preview=MessagePreviewFixture();server.enqueue(MockResponse().setBody(preview.bytes.toStringUtf8()))
            withContext(work(scheduler)+NetworkWorkIntent(NetworkWorkPriority.Interactive,false)) {
                assertEquals(preview.bytes,MediaPreviewDownloader(http).download(preview.target(server.url("/initial").toString())))
            }
            assertFalse(next.isCompleted);assertEquals(6,server.requestCount)
            server.enqueue(MockResponse().setResponseCode(204));clock.set(2000);scheduler.setDegraded(false);next.await()
            assertEquals(7,server.requestCount)
        } finally {scheduler.closeAndDrain()}
    }

    @Test fun `avatar and preview metrics use account diagnostics and queued cancellation emits none`()=https {server,http,_->
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(downloadTransferLimit=1));val scope=work(scheduler)
        val avatar=AvatarFixture();val presentation=avatar.scope(avatar.available(avatar.access(server.url("/avatar").toString())))
        try {
            server.enqueue(MockResponse().setBody(okio.Buffer().write(avatar.bytes)))
            withContext(scope) {AvatarDownloader(http).download(presentation.avatarReadGrant(avatar.key)!!)}
            val preview=MessagePreviewFixture();server.enqueue(MockResponse().setBody(preview.bytes.toStringUtf8()))
            withContext(scope) {MediaPreviewDownloader(http).download(preview.target(server.url("/preview").toString()))}
            val samples=scheduler.transferDiagnostics.snapshot().samples
            assertEquals(listOf(avatar.bytes.size.toLong(),preview.bytes.size().toLong()),samples.map {it.bodyBytesReceived})
            assertTrue(samples.all {it.mode==ResourceTransferMetric.Mode.Download && !it.failed && !it.cancelled && it.bodyBytesSent==0L})
            val held=scheduler.acquire(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download))
            try {
                val queued=launch(scope) {MediaPreviewDownloader(http).download(preview.target(server.url("/queued").toString()))}
                state(scheduler) {it.waitingByteTransfers==1};queued.cancelAndJoin()
                assertEquals(2,scheduler.transferDiagnostics.snapshot().recorded);assertEquals(2,server.requestCount)
            } finally {scheduler.release(held)}
        } finally {presentation.close();scheduler.closeAndDrain()}
    }
    @Test fun `all four adapters share account bytes while ordinary work remains independent`()=https {server,http,directory->
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=2,uploadTransferLimit=1,downloadTransferLimit=1,interactiveByteReserve=0))
        val f=AvatarFixture();val presentation=f.scope(f.available(f.access(server.url("/avatar").toString())))
        val source=File(directory,"source").apply {writeText("abcdefgh")}
        repeat(4) {server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))}
        val jobs=mutableListOf<Job>()
        try {
            jobs+=launch(work(scheduler)) {MediaFileDownloader(http).download(target(server),File(directory,"download"))}
            assertEquals("/file",request(server).path)
            jobs+=launch(work(scheduler)) {AvatarDownloader(http).download(presentation.avatarReadGrant(f.key)!!)}
            state(scheduler) {it.waitingByteTransfers==1}
            jobs+=launch(work(scheduler)) {ResourcePlanUploader(http).upload(source,plan(server,"/upload",ResourceTransferMode.Put))}
            assertEquals("PUT",request(server).method)
            jobs+=launch(work(scheduler)) {MediaPreviewDownloader(http).download(MessagePreviewFixture().target(server.url("/preview").toString()))}
            state(scheduler) {it.activeUploads==1 && it.activeDownloads==1 && it.waitingByteTransfers==2}
            scheduler.withPermit(NetworkWorkContext("account")) {assertEquals(3,scheduler.snapshot().active)}
            assertEquals(2,server.requestCount)
            jobs[0].cancelAndJoin();assertEquals("/avatar",request(server).path)
            jobs[1].cancelAndJoin();assertEquals("/preview",request(server).path)
        } finally {
            jobs.forEach {it.cancel()};jobs.forEach {it.join()};presentation.close()
            assertEquals(0,scheduler.snapshot().active);assertEquals(0,scheduler.snapshot().waiting)
            scheduler.closeAndDrain()
        }
    }

    @Test fun `download demand promotes both queued and active automatic requests`()=https {server,http,directory->
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=2,downloadTransferLimit=2,interactiveByteReserve=1))
        val firstDemand=ByteTransferDemand(NetworkWorkPriority.Background);val secondDemand=ByteTransferDemand(NetworkWorkPriority.Background)
        repeat(2) {server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))}
        val first=launch(work(scheduler,NetworkWorkPriority.Background)+firstDemand) {MediaFileDownloader(http).download(target(server,"/first"),File(directory,"first"))}
        var second:Job?=null
        try {
            assertEquals("/first",request(server).path)
            second=launch(work(scheduler,NetworkWorkPriority.Background)+secondDemand) {MediaFileDownloader(http).download(target(server,"/second"),File(directory,"second"))}
            state(scheduler) {it.activeBackgroundTransfers==1 && it.waitingByteTransfers==1}
            secondDemand.promote(NetworkWorkPriority.Interactive)
            assertEquals("/second",request(server).path)
            state(scheduler) {it.activeDownloads==2 && it.activeBackgroundTransfers==1}
            firstDemand.promote(NetworkWorkPriority.Interactive)
            state(scheduler) {it.activeBackgroundTransfers==0}
            assertEquals(2,server.requestCount)
        } finally {
            first.cancelAndJoin();second?.cancelAndJoin();scheduler.closeAndDrain()
            assertEquals(0,firstDemand.observerCount);assertEquals(0,secondDemand.observerCount)
        }
    }

    @Test fun `revoked queued avatar and expired queued PUT never reach provider`()=https {server,http,directory->
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=1,interactiveByteReserve=0))
        var hold=scheduler.acquire(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download))
        val f=AvatarFixture();val presentation=f.scope(f.available(f.access(server.url("/avatar").toString())))
        try {
            val avatar=async(work(scheduler)) {runCatching {AvatarDownloader(http).download(presentation.avatarReadGrant(f.key)!!)}}
            state(scheduler) {it.waiting==1};presentation.close();scheduler.release(hold)
            assertIs<AvatarAccessFailure>(avatar.await().exceptionOrNull());assertEquals(0,server.requestCount)
            hold=scheduler.acquire(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download))
            val source=File(directory,"source").apply {writeText("abcdefgh")};val uploadPlan=plan(server,"/upload",ResourceTransferMode.Put)
            val now=java.util.concurrent.atomic.AtomicLong(System.currentTimeMillis())
            val upload=async(work(scheduler)) {runCatching {ResourcePlanUploader(http,now::get).upload(source,uploadPlan)}}
            state(scheduler) {it.waiting==1};now.set(uploadPlan.expiresAt);scheduler.release(hold)
            assertIs<IllegalArgumentException>(upload.await().exceptionOrNull());assertEquals(0,server.requestCount)
        } finally {scheduler.release(hold);presentation.close();scheduler.closeAndDrain()}
    }

    @Test fun `provider retry after delays another byte adapter but not account requests`()=https {server,http,directory->
        val now=java.util.concurrent.atomic.AtomicLong(1000)
        val scheduler=AccountWorkScheduler(nowMillis=now::get)
        val source=File(directory,"source").apply {writeText("abcdefgh")}
        val f=AvatarFixture();val presentation=f.scope(f.available(f.access(server.url("/avatar").toString())))
        try {
            server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After","2"))
            withContext(work(scheduler)) {assertEquals(503,assertFailsWith<ClientFailure.Http> {ResourcePlanUploader(http).upload(source,plan(server,"/upload",ResourceTransferMode.Put))}.status)}
            request(server);server.enqueue(MockResponse().setBody(okio.Buffer().write(f.bytes)))
            val avatar=async(work(scheduler)) {AvatarDownloader(http).download(presentation.avatarReadGrant(f.key)!!)}
            state(scheduler) {it.waitingByteTransfers==1};assertEquals(1,server.requestCount)
            scheduler.withPermit(NetworkWorkContext("account")) {assertEquals(1,scheduler.snapshot().active)}
            now.addAndGet(2000);scheduler.setDegraded(false)
            assertContentEquals(f.bytes,avatar.await().read().toByteArray());assertEquals("/avatar",request(server).path)
        } finally {presentation.close();scheduler.closeAndDrain()}
    }

    @Test fun `ranges relinquish the slot before the next physical GET`()=https {server,http,directory->
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(downloadTransferLimit=1))
        val f=AvatarFixture();val presentation=f.scope(f.available(f.access(server.url("/avatar").toString())))
        val release=java.util.concurrent.CountDownLatch(1)
        server.dispatcher=object:okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse=when {
                request.path=="/avatar"->MockResponse().setBody(okio.Buffer().write(f.bytes))
                request.getHeader("Range")=="bytes=0-3"->{check(release.await(10,TimeUnit.SECONDS));MockResponse().setResponseCode(206).setHeader("Content-Range","bytes 0-3/8").setHeader("ETag","\"v1\"").setBody("abcd")}
                else->MockResponse().setResponseCode(206).setHeader("Content-Range","bytes 4-7/8").setHeader("ETag","\"v1\"").setBody("efgh")
            }
        }
        try {
            val download=async(work(scheduler)) {MediaFileDownloader(http,4).download(target(server),File(directory,"file"))}
            assertEquals("bytes=0-3",request(server).getHeader("Range"))
            val avatar=async(work(scheduler)) {AvatarDownloader(http).download(presentation.avatarReadGrant(f.key)!!)}
            state(scheduler) {it.waitingByteTransfers==1};release.countDown()
            avatar.await();download.await()
            assertEquals("/avatar",request(server).path);assertEquals("bytes=4-7",request(server).getHeader("Range"))
            assertEquals("abcdefgh",File(directory,"file").readText())
        } finally {release.countDown();presentation.close();scheduler.closeAndDrain()}
    }

    @Test fun `deadline and rejection leave no permit demand observer or provider request`()=https {server,http,_->
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(byteTransferLimit=1,byteTransferWaiterLimit=0,interactiveByteReserve=0))
        val held=scheduler.acquire(NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Upload))
        val demand=ByteTransferDemand(NetworkWorkPriority.Interactive)
        try {
            withContext(work(scheduler)+demand) {
                assertEquals(AccountWorkScheduler.Rejection.Overloaded,assertFailsWith<ByteTransferAdmissionFailure> {MediaPreviewDownloader(http).download(MessagePreviewFixture().target(server.url("/preview").toString()))}.reason)
                assertEquals(0,demand.observerCount)
            }
            scheduler.release(held)
            withContext(work(scheduler)+demand) {
                assertFailsWith<ResourceTransferFailure> {withByteTransferPermit(NetworkWorkKind.Download,50) {awaitCancellation()}}
                assertEquals(0,demand.observerCount);assertEquals(0,scheduler.snapshot().active)
            }
            scheduler.beginClose()
            withContext(work(scheduler)) {
                assertEquals(AccountWorkScheduler.Rejection.Closed,assertFailsWith<ByteTransferAdmissionFailure> {MediaPreviewDownloader(http).download(MessagePreviewFixture().target(server.url("/preview").toString()))}.reason)
            }
            assertEquals(0,server.requestCount)
        } finally {scheduler.release(held);scheduler.closeAndDrain()}
    }

    @Test fun `cancelled operation keeps permit until physical writer drain completes`()=runBlocking {
        val scheduler=AccountWorkScheduler();val entered=CompletableDeferred<Unit>();val drain=CompletableDeferred<Unit>()
        val task=launch(work(scheduler)) {withByteTransferPermit(NetworkWorkKind.Upload,5000) {
            try {entered.complete(Unit);awaitCancellation()} finally {withContext(NonCancellable) {drain.await()}}
        }}
        try {
            entered.await();task.cancel()
            assertEquals(1,scheduler.snapshot().activeUploads)
            val closing=launch {scheduler.closeAndDrain()}
            yield();assertFalse(closing.isCompleted)
            drain.complete(Unit);withTimeout(5000) {task.join();closing.join()};assertEquals(0,scheduler.snapshot().active)
        } finally {drain.complete(Unit);task.cancelAndJoin();scheduler.closeAndDrain()}
    }
}
