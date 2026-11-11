package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.*
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class AvatarIntegrityFailure: IOException("头像内容与已授权的摘要或长度不符")

/** Immutable verified bytes still require the original display permission each time they are borrowed. */
class AvatarDownloadedBytes internal constructor(private val data: ByteString,private val grant: AvatarReadGrant,private val validate: suspend ()->Unit={}) {
    val content get()=grant.content
    val deadlineNanos get()=grant.deadlineNanos
    suspend fun read(): ByteString { grant.requireValid();validate();grant.requireValid();return data }
    override fun toString()="AvatarDownloadedBytes(content=$content, bytes=<redacted>)"
}

/** Foreground, bounded avatar GET. Never shares bearer credentials, cookies, redirects or disk HTTP cache. */
class AvatarDownloader(http: OkHttpClient?=null) {
    private val slots=Semaphore(2)
    private val client by lazy { (http?.newBuilder() ?: OkHttpClient.Builder()).apply {
        interceptors().clear();networkInterceptors().clear()
    }.cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE).eventListener(EventListener.NONE)
        .cache(null).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build() }

    suspend fun download(grant: AvatarReadGrant): AvatarDownloadedBytes=withFallbackByteSlot(slots) {
        val (target,_)=grant.downloadTarget()
        val remaining=grant.remainingDownloadNanos()
        if(remaining<=0) throw AvatarTargetExpired()
        val duration=((remaining.coerceAtMost(60_000_000_000)+999_999)/1_000_000).coerceAtLeast(1)
        val data=withByteTransferPermit(NetworkWorkKind.Download,duration) {
            val admission=currentCoroutineContext()[NetworkWorkScope]
            grant.requireValid()
            val headers=Headers.Builder().apply { target.headers.forEach { addUnsafeNonAscii(it.name,it.value) } }.build()
            val request=Request.Builder().url(target.url).headers(headers).get().apply {
                if(headers["Accept-Encoding"]==null) header("Accept-Encoding","identity")
            }.build()
            val call=client.newCall(request);call.timeout().timeout(duration,TimeUnit.MILLISECONDS)
            if(grant.remainingDownloadNanos()<=0) throw AvatarTargetExpired()
            val measurement=ResourceTransferMeasurement(currentCoroutineContext(),ResourceTransferMetric.Mode.Download)
            val drained=CompletableDeferred<Unit>();var enqueued=false
            try {
                suspendCancellableCoroutine<ByteString> { continuation ->
                    continuation.invokeOnCancellation { measurement.cancel();call.cancel() }
                    try { enqueued=true;measurement.start();call.enqueue(object: Callback {
                        override fun onFailure(call: Call,e: IOException) {
                            measurement.fail()
                            try { if(continuation.isActive) continuation.resumeWithException(ResourceTransferFailure()) }
                            finally { drained.complete(Unit) }
                        }
                        override fun onResponse(call: Call,response: Response) {
                            try {
                                val bytes=response.use { value ->
                                    measurement.headers(value.code);byteTransferHeaders(admission,value)
                                    if(value.code!=200) throw ClientFailure.Http(value.code,retryAfter=value.header("Retry-After"))
                                    if(value.header("Content-Range")!=null || value.header("Content-Encoding")?.let { !it.equals("identity",true) }==true) throw AvatarIntegrityFailure()
                                    val body=value.body ?: throw AvatarIntegrityFailure()
                                    val expected=grant.content.byteCount
                                    if(body.contentLength()>=0 && body.contentLength()!=expected) throw AvatarIntegrityFailure()
                                    val output=ByteString.newOutput(minOf(expected.toInt(),65536));val buffer=ByteArray(65536)
                                    val digest=MessageDigest.getInstance("SHA-256");var count=0L
                                    body.byteStream().use { input -> while(true) {
                                        if(call.isCanceled()) throw ResourceTransferFailure()
                                        if(grant.remainingDownloadNanos()<=0) throw AvatarTargetExpired()
                                        val read=input.read(buffer,0,minOf(buffer.size.toLong(),expected-count+1).toInt())
                                        if(read<0) break
                                        if(read==0) continue
                                        measurement.received(read.toLong());count+=read;if(count>expected) throw AvatarIntegrityFailure()
                                        digest.update(buffer,0,read);output.write(buffer,0,read)
                                    } }
                                    if(count!=expected || digest.digest().joinToString("") { "%02x".format(it) }!=grant.content.checksum.value) throw AvatarIntegrityFailure()
                                    output.toByteString()
                                }
                                if(continuation.isActive) continuation.resume(bytes)
                            } catch(error: Exception) {
                                measurement.fail()
                                if(continuation.isActive) continuation.resumeWithException(when(error) {
                                    is ClientFailure,is AvatarIntegrityFailure,is AvatarTargetExpired->error
                                    else->ResourceTransferFailure()
                                })
                            } finally { drained.complete(Unit) }
                        }
                    }) } catch(_: Exception) { measurement.fail();drained.complete(Unit);if(continuation.isActive) continuation.resumeWithException(ResourceTransferFailure()) }
                }
            } finally { call.cancel();if(!enqueued) drained.complete(Unit);withContext(NonCancellable) { drained.await();measurement.finish()?.record() } }
        }
        grant.requireValid();AvatarDownloadedBytes(data,grant)
    }
}
