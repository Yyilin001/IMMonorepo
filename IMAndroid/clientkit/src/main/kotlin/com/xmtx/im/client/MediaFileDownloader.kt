package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.*
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Foreground byte adapter. Destination must be in an app-private directory exclusively owned by the caller.
 * Concurrent writes through other APIs or processes to that directory are unsupported.
 * Retries require a fresh authorization; only verified byte checkpoints survive calls.
 * Account access checks, retention, cache ownership and OS background execution belong to the caller.
 */
class MediaFileDownloader(http: OkHttpClient?=null,private val chunkBytes: Long=1024*1024) {
    init { require(chunkBytes in 1..8L*1024*1024) }
    private val slots=Semaphore(2)
    private val client by lazy { (http?.newBuilder() ?: OkHttpClient.Builder()).apply {
        interceptors().clear();networkInterceptors().clear()
    }.cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE).eventListener(EventListener.NONE)
        .cache(null).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build() }
    suspend fun download(authorization: MediaDownloadTarget,destination: File): Unit=withContext(Dispatchers.IO) { withFallbackByteSlot(slots) {
        authorization.requireValid()
        val absolute=destination.absoluteFile
        val path=File(absolute.parentFile.canonicalFile,absolute.name).toPath()
        if(!active.add(path.toString())) throw MediaFileFailure(MediaFileFailureReason.DestinationExists)
        try {
            val context=currentCoroutineContext()
            MediaRangeFile(path,authorization) { context.ensureActive() }.use { file ->
                var rebuild:Pair<MeasuredResourceTransfer,Long>?=null
                try {
                    var first=true
                    while(first || file.offset<authorization.plan.expectedBytes) {
                        first=false;context.ensureActive();authorization.requireValid()
                        val start=file.offset;val priorETag=file.etag
                        val end=if(start<authorization.plan.expectedBytes) minOf(authorization.plan.expectedBytes-1,start+chunkBytes-1) else start+chunkBytes-1
                        val measured=stream(authorization,file,start,end)
                        if(measured!=null && start>0 && measured.metric.statusCode==200 && priorETag!=null && file.etag==priorETag) rebuild=measured to start
                        else measured?.record()
                        if(file.offset<=start && file.offset!=authorization.plan.expectedBytes) throw MediaFileFailure(MediaFileFailureReason.InvalidRange)
                    }
                    context.ensureActive();file.publish();rebuild?.let {(measured,prefix)->measured.record(prefix)};rebuild=null
                } catch(error: Exception) {
                    rebuild?.first?.record()
                    // HTTP callbacks are drained by stream() before touching the journal here.
                    runCatching { if(error is MediaFileFailure && error.reason==MediaFileFailureReason.VersionChanged) file.reset() else file.checkpoint() }
                    throw error
                }
            }
        } catch(error: CancellationException) { throw error }
        catch(error: MediaFileFailure) { throw error }
        catch(error: MediaReadFailure) { throw error }
        catch(error: ClientFailure) { throw error }
        catch(error: ByteTransferAdmissionFailure) { throw error }
        catch(error: ResourceTransferFailure) { throw error }
        catch(error: Exception) { throw redactedFailure(error) }
        finally { active.remove(path.toString()) }
    } }
    private suspend fun stream(target:MediaDownloadTarget,file:MediaRangeFile,start:Long,end:Long):MeasuredResourceTransfer? {
        target.requireValid()
        val budget=((target.remainingNanos().coerceAtMost(60_000_000_000)+999999)/1000000).coerceAtLeast(1)
        var completed:MeasuredResourceTransfer?=null
        try {
            withByteTransferPermit(NetworkWorkKind.Download,budget) {streamAdmitted(target,file,start,end) {completed=it}}
            return completed
        } catch(error:Exception) {completed?.record();throw error}
    }
    private suspend fun streamAdmitted(target: MediaDownloadTarget,file: MediaRangeFile,start: Long,end: Long,onMetric:(MeasuredResourceTransfer)->Unit) {
        target.requireValid()
        val admission=currentCoroutineContext()[NetworkWorkScope]
        val transfer=currentCoroutineContext()
        val duration=((target.remainingNanos().coerceAtMost(60_000_000_000)+999999)/1000000).coerceAtLeast(1)
        val headers=Headers.Builder().apply { target.plan.headers.forEach { addUnsafeNonAscii(it.name,it.value) } }.build()
        val request=Request.Builder().url(target.plan.url).headers(headers).header("Accept-Encoding","identity").header("Cache-Control","no-store")
            .header("Range","bytes=$start-$end").removeHeader("If-Range").apply { file.etag?.let { header("If-Range",it) } }.get().build()
        val call=client.newCall(request);call.timeout().timeout(duration,TimeUnit.MILLISECONDS)
        val measurement=ResourceTransferMeasurement(currentCoroutineContext(),ResourceTransferMetric.Mode.RangeDownload)
        val drained=CompletableDeferred<Unit>();var enqueued=false;var returned=false
        try { withTimeout(duration) {
            suspendCancellableCoroutine<Unit> { continuation ->
                continuation.invokeOnCancellation { measurement.cancel();call.cancel() }
                try { enqueued=true;measurement.start();call.enqueue(object: Callback {
                    override fun onFailure(call: Call,e: IOException) {
                        measurement.fail()
                        try { if(continuation.isActive) continuation.resumeWithException(redactedFailure(e)) } finally { drained.complete(Unit) }
                    }
                    override fun onResponse(call: Call,response: Response) {
                        var progress:ResourceTransferByteObserver?=null
                        try {
                            response.use {
                                measurement.headers(it.code);byteTransferHeaders(admission,it)
                                target.requireValid();val expected=file.accept(it,start,end)
                                if(expected>0) progress=transfer.beginResourceTransferProgress(expected)
                                var received=0L
                                val body=it.body ?: throw MediaFileFailure(MediaFileFailureReason.Integrity)
                                body.byteStream().use { input -> val buffer=ByteArray(65536)
                                    while(true) {
                                        if(call.isCanceled()) throw ResourceTransferFailure()
                                        target.requireValid();val count=input.read(buffer);if(count<0) break;if(count>0) {measurement.received(count.toLong());file.append(buffer,count);received+=count;progress?.report(received)}
                                    }
                                };file.finishResponse()
                            }
                            if(continuation.isActive) continuation.resume(Unit)
                        } catch(error: Exception) {
                            measurement.fail()
                            if(continuation.isActive) continuation.resumeWithException(when(error) { is MediaFileFailure,is MediaReadFailure,is ClientFailure -> error;else -> redactedFailure(error) })
                        } finally { progress?.end();drained.complete(Unit) }
                    }
                }) } catch(_: Exception) { measurement.fail();drained.complete(Unit);if(continuation.isActive) continuation.resumeWithException(ResourceTransferFailure()) }
            }
        };returned=true } finally {
            call.cancel();if(!enqueued) drained.complete(Unit)
            withContext(NonCancellable) {drained.await();measurement.finish()?.let {if(returned) onMetric(it) else it.record()}}
        }
    }
    private fun redactedFailure(error: Exception)=ResourceTransferFailure().apply { stackTrace=error.stackTrace }
    private companion object { val active=ConcurrentHashMap.newKeySet<String>() }
}
