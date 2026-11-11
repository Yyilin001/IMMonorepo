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

/** Bounded derived-image GET only. Originals use a separate streaming download lifecycle. */
class MediaPreviewDownloader(http: OkHttpClient?=null) {
    private val slots=Semaphore(2)
    private val client by lazy { (http?.newBuilder() ?: OkHttpClient.Builder()).apply {
        interceptors().clear();networkInterceptors().clear()
    }.cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE).eventListener(EventListener.NONE)
        .cache(null).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build() }

    suspend fun download(authorization: MediaDownloadTarget): ByteString=withContext(Dispatchers.IO) { withFallbackByteSlot(slots) {
        val target=authorization.plan
        require(authorization.preview!=null && target.expectedBytes in 1..2L*1024*1024)
        authorization.requireValid()
        val remaining=authorization.remainingNanos()
        if(remaining<=0) throw MediaReadFailure(MediaReadFailureReason.Expired)
        val duration=((remaining.coerceAtMost(60_000_000_000)+999_999)/1_000_000).coerceAtLeast(1)
        val data=withByteTransferPermit(NetworkWorkKind.Download,duration) {
            val admission=currentCoroutineContext()[NetworkWorkScope]
            authorization.requireValid()
            val headers=Headers.Builder().apply { target.headers.forEach { addUnsafeNonAscii(it.name,it.value) } }.build()
            val request=Request.Builder().url(target.url).headers(headers).header("Accept-Encoding","identity").header("Cache-Control","no-store").get().build()
            val call=client.newCall(request);call.timeout().timeout(duration,TimeUnit.MILLISECONDS)
            if(authorization.remainingNanos()<=0) throw MediaReadFailure(MediaReadFailureReason.Expired)
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
                                    if(value.header("Content-Range")!=null || value.header("Content-Encoding")?.let { !it.equals("identity",true) }==true) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                                    val body=value.body ?: throw MediaReadFailure(MediaReadFailureReason.Integrity)
                                    val expected=target.expectedBytes
                                    if(body.contentLength()>=0 && body.contentLength()!=expected) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                                    val output=ByteString.newOutput(minOf(expected.toInt(),65536));val buffer=ByteArray(65536)
                                    val digest=MessageDigest.getInstance("SHA-256");var count=0L
                                    body.byteStream().use { input -> while(true) {
                                        if(call.isCanceled()) throw ResourceTransferFailure()
                                        if(authorization.remainingNanos()<=0) throw MediaReadFailure(MediaReadFailureReason.Expired)
                                        val read=input.read(buffer,0,minOf(buffer.size.toLong(),expected-count+1).toInt())
                                        if(read<0) break
                                        if(read==0) continue
                                        measurement.received(read.toLong());count+=read;if(count>expected) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                                        digest.update(buffer,0,read);output.write(buffer,0,read)
                                    } }
                                    if(count!=expected || digest.digest().joinToString("") { "%02x".format(it) }!=requireNotNull(target.checksum).value) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                                    output.toByteString()
                                }
                                if(continuation.isActive) continuation.resume(bytes)
                            } catch(error: Exception) {
                                measurement.fail()
                                if(continuation.isActive) continuation.resumeWithException(when(error) {
                                    is ClientFailure,is MediaReadFailure->error
                                    else->ResourceTransferFailure()
                                })
                            } finally { drained.complete(Unit) }
                        }
                    }) } catch(_: Exception) { measurement.fail();drained.complete(Unit);if(continuation.isActive) continuation.resumeWithException(ResourceTransferFailure()) }
                }
            } finally { call.cancel();if(!enqueued) drained.complete(Unit);withContext(NonCancellable) { drained.await();measurement.finish()?.record() } }
        }
        authorization.requireValid();data
    } }
}
