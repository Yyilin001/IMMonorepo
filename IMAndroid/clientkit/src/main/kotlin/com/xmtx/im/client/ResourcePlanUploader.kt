package com.xmtx.im.client

import kotlinx.coroutines.*
import okhttp3.*
import okio.BufferedSink
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class ResourceTransferFailure: IOException("资源传输未确认，请按原会话核对")

data class ResourceUploadReceipt(val status:Int,val sentBytes:Long,val originDigest:String)

/** Streams a whole immutable file or an already-managed part slice. Owns no file publication or cleanup. */
class ResourcePlanUploader(http: OkHttpClient? = null,private val now: () -> Long = System::currentTimeMillis) {
    private val client by lazy { (http?.newBuilder() ?: OkHttpClient.Builder()).apply {
        interceptors().clear();networkInterceptors().clear()
    }.cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE).eventListener(EventListener.NONE)
        .cache(null).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build() }
    suspend fun upload(file:File,plan:ResourceTransferPlan,expectedChecksum:ResourceChecksum?=plan.checksum) { uploadReceipt(file,plan,expectedChecksum) }
    suspend fun uploadReceipt(file: File,plan: ResourceTransferPlan,expectedChecksum: ResourceChecksum? = plan.checksum):ResourceUploadReceipt = withContext(Dispatchers.IO) {
        require(plan.mode in ResourceUploadClient.supportedModes && plan.formFields.isEmpty() && plan.formFileField == null)
        require(file.isFile && file.length() == plan.expectedBytes)
        require(plan.mode != ResourceTransferMode.PartPut || plan.range?.byteCount == plan.expectedBytes)
        require(expectedChecksum == null || plan.checksum == null || expectedChecksum == plan.checksum)
        val started = now();require(started >= 0 && plan.expiresAt > started) { "传输目标已过期" }
        val duration = minOf(60_000,plan.expiresAt-started)
        withTimeout(duration) {
            // Check the declared source before issuing any bytes, and recheck the streamed bytes below.
            expectedChecksum?.let { expected ->
                val digest = MessageDigest.getInstance("SHA-256");var count = 0L
                file.inputStream().use { input -> val buffer = ByteArray(64*1024);while(true) {
                    currentCoroutineContext().ensureActive();val read = input.read(buffer);if(read < 0) break
                    require(count <= plan.expectedBytes-read);count += read;digest.update(buffer,0,read)
                } }
                require(count == plan.expectedBytes && digest.hex() == expected.value) { "资源内容与校验摘要不符" }
            }
            withByteTransferPermit(NetworkWorkKind.Upload,(plan.expiresAt-now()).coerceIn(1,60_000)) {
            currentCoroutineContext().ensureActive();require(plan.expiresAt > now()) { "传输目标已过期" }
            val admission=currentCoroutineContext()[NetworkWorkScope]
            val sent=java.util.concurrent.atomic.AtomicLong()
            val transfer=currentCoroutineContext()
            val measurement=ResourceTransferMeasurement(transfer,if(plan.mode==ResourceTransferMode.PartPut) ResourceTransferMetric.Mode.MultipartUpload else ResourceTransferMetric.Mode.Upload)
            val progress=java.util.concurrent.atomic.AtomicReference<ResourceTransferByteObserver?>()
            val body = object: RequestBody() {
                override fun contentType(): MediaType? = null
                override fun contentLength() = plan.expectedBytes
                override fun isOneShot() = true
                override fun writeTo(sink: BufferedSink) {
                    val reporter=if(plan.expectedBytes>0) transfer.beginResourceTransferProgress(plan.expectedBytes) else null;progress.set(reporter)
                    val digest = MessageDigest.getInstance("SHA-256");var count = 0L
                    file.inputStream().use { input -> val buffer = ByteArray(64*1024);while(true) {
                        if(plan.expiresAt <= now()) throw ResourceTransferFailure()
                        val read = input.read(buffer);if(read < 0) break
                        if(count > plan.expectedBytes-read) throw ResourceTransferFailure()
                        count += read;digest.update(buffer,0,read);sink.write(buffer,0,read);sent.set(count);measurement.sent(count);reporter?.report(count)
                    } }
                    if(count != plan.expectedBytes || expectedChecksum?.let { digest.hex() != it.value } == true) throw ResourceTransferFailure()
                }
            }
            // Values already reject controls; the wire contract permits non-ASCII header values.
            val headers = Headers.Builder().apply { plan.headers.forEach { addUnsafeNonAscii(it.name,it.value) } }.build()
            val request = Request.Builder().url(plan.url).headers(headers).method(plan.mode.method,body).build()
            val call = client.newCall(request);call.timeout().timeout(duration,TimeUnit.MILLISECONDS)
            val drained = CompletableDeferred<Unit>();var enqueued=false
            try {
                suspendCancellableCoroutine<ResourceUploadReceipt> { continuation ->
                    continuation.invokeOnCancellation { measurement.cancel();call.cancel() }
                    try { enqueued=true;measurement.start();call.enqueue(object: Callback {
                        override fun onFailure(call: Call,e: IOException) {
                            measurement.fail()
                            try { if(continuation.isActive) continuation.resumeWithException(ResourceTransferFailure()) }
                            finally { drained.complete(Unit) }
                        }
                        override fun onResponse(call: Call,response: Response) {
                            try {
                                response.use { value ->
                                    measurement.headers(value.code);byteTransferHeaders(admission,value)
                                    val responseBody = value.body ?: throw ClientFailure.Protocol()
                                    if(responseBody.contentLength() > 524288) throw ClientFailure.Protocol()
                                    val source = responseBody.source();val buffer = okio.Buffer();var received = 0L
                                    while(true) {
                                        val bytes = source.read(buffer,minOf(65536,524289-received));if(bytes < 0) break
                                        received += bytes;measurement.received(bytes);buffer.clear();if(received > 524288) throw ClientFailure.Protocol()
                                    }
                                    if(value.code !in 200..299) throw ClientFailure.Http(value.code,retryAfter = value.header("Retry-After"))
                                }
                                if(sent.get()!=plan.expectedBytes) throw ResourceTransferFailure()
                                if(continuation.isActive) continuation.resume(ResourceUploadReceipt(response.code,sent.get(),resourceBackgroundOriginDigest(response.request.url.toString())))
                            } catch(e: Exception) {
                                if(e !is ClientFailure.Http) measurement.fail()
                                if(continuation.isActive) continuation.resumeWithException(if(e is ClientFailure) e else ResourceTransferFailure())
                            } finally { drained.complete(Unit) }
                        }
                    }) } catch(_: Exception) {
                        measurement.fail();drained.complete(Unit)
                        if(continuation.isActive) continuation.resumeWithException(ResourceTransferFailure())
                    }
                }
            } finally {
                call.cancel();if(!enqueued) drained.complete(Unit)
                // The caller may release its managed slice only after OkHttp has physically completed.
                withContext(NonCancellable) { drained.await();progress.getAndSet(null)?.end();measurement.finish()?.record() }
            }
            }
        }
    }
}
private fun MessageDigest.hex() = digest().joinToString("") { "%02x".format(it) }
