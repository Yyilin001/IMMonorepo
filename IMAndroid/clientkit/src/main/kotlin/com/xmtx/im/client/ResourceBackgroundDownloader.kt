package com.xmtx.im.client

import kotlinx.coroutines.*
import okhttp3.*
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class ResourceDownloadReceipt(val status:Int,val receivedBytes:Long,val originDigest:String)

/** One explicitly delegated whole-object GET. The caller owns the bounded sink and its publication. */
class ResourceBackgroundDownloader(http:OkHttpClient?=null,private val now:()->Long=System::currentTimeMillis) {
    private val client by lazy {(http?.newBuilder() ?: OkHttpClient.Builder()).apply {interceptors().clear();networkInterceptors().clear()}
        .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE).eventListener(EventListener.NONE)
        .cache(null).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()}
    suspend fun download(plan:ResourceTransferPlan,output:OutputStream):ResourceDownloadReceipt=withContext(Dispatchers.IO) {
        val grant=requireNotNull(plan.backgroundDownload);require(plan.mode==ResourceTransferMode.Get)
        fun fresh() {if(now()<grant.issuedAt || now()>=grant.expiresAt) throw MediaReadFailure(MediaReadFailureReason.Expired)}
        fresh();val duration=minOf(120_000,grant.expiresAt-now()).coerceAtLeast(1)
        val headers=Headers.Builder().apply {plan.headers.forEach {addUnsafeNonAscii(it.name,it.value)}}.build()
        val request=Request.Builder().url(plan.url).headers(headers).header("Accept-Encoding","identity").header("Cache-Control","no-store").get().build()
        val call=client.newCall(request);call.timeout().timeout(duration,TimeUnit.MILLISECONDS)
        val transfer=currentCoroutineContext()
        val measurement=ResourceTransferMeasurement(transfer,ResourceTransferMetric.Mode.Download)
        val drained=CompletableDeferred<Unit>();var callbackExpected=false
        try {withTimeout(duration) {suspendCancellableCoroutine<ResourceDownloadReceipt> {continuation->
            continuation.invokeOnCancellation {measurement.cancel();call.cancel()}
            try {callbackExpected=true;measurement.start();call.enqueue(object:Callback {
                override fun onFailure(call:Call,e:IOException) {
                    measurement.fail()
                    try {if(continuation.isActive) continuation.resumeWithException(ResourceTransferFailure())} finally {drained.complete(Unit)}
                }
                override fun onResponse(call:Call,response:Response) {
                    var progress:ResourceTransferByteObserver?=null
                    try {
                        val receipt=response.use {value->
                            measurement.headers(value.code);fresh();val origin=resourceBackgroundOriginDigest(value.request.url.toString())
                            if(origin!=resourceBackgroundOriginDigest(plan.url)) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                            if(value.code!=200) throw ClientFailure.Http(value.code,retryAfter=value.header("Retry-After")?.takeIf {it.length<=256})
                            if(value.header("Content-Range")!=null || value.header("Content-Encoding")?.let {!it.equals("identity",true)}==true) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                            val body=value.body ?: throw MediaReadFailure(MediaReadFailureReason.Integrity)
                            if(body.contentLength()>=0 && body.contentLength()!=grant.expectedBytes) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                            if(grant.expectedBytes>0) progress=transfer.beginResourceTransferProgress(grant.expectedBytes)
                            val hash=MessageDigest.getInstance("SHA-256");var count=0L
                            body.byteStream().use {input->val buffer=ByteArray(65536)
                                while(true) {
                                    if(call.isCanceled()) throw ResourceTransferFailure();fresh()
                                    val read=input.read(buffer,0,minOf(buffer.size.toLong(),grant.expectedBytes-count+1).toInt());if(read<0) break
                                    measurement.received(read.toLong());if(read>grant.expectedBytes-count) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                                    if(read>0) {try {output.write(buffer,0,read)} catch(_:IOException) {throw ResourceSourceUnavailable()};count+=read;hash.update(buffer,0,read);progress?.report(count)}
                                }
                            }
                            if(count!=grant.expectedBytes || hash.digest().joinToString("") {"%02x".format(it)}!=grant.checksum.value) throw MediaReadFailure(MediaReadFailureReason.Integrity)
                            fresh();ResourceDownloadReceipt(200,count,origin)
                        }
                        if(continuation.isActive) continuation.resume(receipt)
                    } catch(error:Exception) {measurement.fail();if(continuation.isActive) continuation.resumeWithException(when(error) {
                        is MediaReadFailure,is ClientFailure,is ResourceSourceUnavailable->error
                        else->ResourceTransferFailure()
                    })} finally {progress?.end();drained.complete(Unit)}
                }
            })} catch(_:Exception) {measurement.fail();drained.complete(Unit);if(continuation.isActive) continuation.resumeWithException(ResourceTransferFailure())}
        }}} finally {call.cancel();if(callbackExpected) withContext(NonCancellable) {drained.await();measurement.finish()?.record()}}
    }
}
