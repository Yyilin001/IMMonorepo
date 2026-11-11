package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.security.MessageDigest

/** A prepared, still-suspended system task; its request is memory-only until the platform accepts delegation. */
data class ResourceBackgroundUploadRegistration(val id:String,val task:String,val target:ResourceBackgroundUploadTarget) {
    init {require(uuidId(id)==id && uuidId(task)==task)}
}
/** Durable identity and byte facts. Never add URL, headers, credentials, or absolute file paths. */
data class ResourceBackgroundUploadMapping(val id:String,val systemSession:String,val task:String,val batch:String,
    val upload:String,val asset:String,val activation:String,val requestDigest:String,val authorization:ResourceBackgroundUploadAuthorization,
    val range:ResourceRange?,val expectedBytes:Long,val originDigest:String,val createdAt:Long) {
    init {
        require(listOf(id,systemSession,task,batch,upload,asset,activation).all {uuidId(it)==it})
        require(requestDigest.matches(Regex("[0-9a-f]{64}")) && originDigest.matches(Regex("[0-9a-f]{64}")) && createdAt>=0)
        when(val scope=authorization.scope) {
            is ResourceBackgroundUploadScope.Part->require(range!=null && expectedBytes==range.byteCount && expectedBytes in 1..8L*1024*1024)
            is ResourceBackgroundUploadScope.Whole->require(range==null && expectedBytes==scope.byteCount)
        }
    }
    fun payload()=buildJsonObject {
        put("id",id);put("systemSession",systemSession);put("task",task);put("batch",batch);put("upload",upload);put("asset",asset)
        put("activation",activation);put("requestDigest",requestDigest);put("authorization",authorization.payload());range?.let {put("range",it.payload())}
        put("expectedBytes",expectedBytes);put("originDigest",originDigest);put("createdAt",createdAt)
    }
    companion object {fun decode(value:JsonObject)=ResourceBackgroundUploadMapping(value.resourceString("id"),value.resourceString("systemSession"),value.resourceString("task"),
        value.resourceString("batch"),value.resourceString("upload"),value.resourceString("asset"),value.resourceString("activation"),value.resourceString("requestDigest"),
        ResourceBackgroundUploadAuthorization.decode(value.resourceObject("authorization")),value.resourceOptionalObject("range")?.let {ResourceRange(it.resourceNumber("lowerBound"),it.resourceNumber("upperBound"))},
        value.resourceNumber("expectedBytes"),value.resourceString("originDigest"),value.resourceNumber("createdAt"))}
}
data class ResourceBackgroundUploadResult(val mapping:String,val task:String,val status:Int?,val error:Int?,val sentBytes:Long,
    val originDigest:String?,val retryNotBefore:Long?=null,val observation:ResourceBackgroundTransferObservation?=null) {
    init {
        require(uuidId(mapping)==mapping && uuidId(task)==task && sentBytes>=0)
        require(status==null || status in 100..599);require(originDigest==null || originDigest.matches(Regex("[0-9a-f]{64}")))
        require(retryNotBefore==null || retryNotBefore>=0)
    }
}
interface ResourceBackgroundUploadJournal {
    val resourceBackgroundUploadChanges:StateFlow<Long>
    suspend fun backgroundUploadSession():String
    suspend fun activeBackgroundUploads():PersistentList<ResourceBackgroundUploadMapping>
    /** Install the entire task batch atomically while holding the original upload claim, before resuming any system task. */
    suspend fun installBackgroundUploads(claim:ResourceUploadClaim,tasks:PersistentList<ResourceBackgroundUploadRegistration>,now:Long=System.currentTimeMillis()):PersistentList<ResourceBackgroundUploadMapping>
    /** Call only after actual physical task completion/drain. null means the driver proved the task absent or drained. */
    suspend fun completeBackgroundUpload(mapping:ResourceBackgroundUploadMapping,result:ResourceBackgroundUploadResult?,now:Long=System.currentTimeMillis()):Boolean
}
fun resourceBackgroundOriginDigest(url:String):String {
    val (parsed,strict)=try {url.toHttpUrl() to java.net.URI(url)} catch(_:Exception) {throw IllegalArgumentException("后台传输地址无效")}
    require(parsed.isHttps && parsed.username.isEmpty() && parsed.password.isEmpty() && parsed.fragment==null && strict.rawUserInfo==null && strict.rawFragment==null)
    return backgroundDigest("https|${parsed.host.lowercase(java.util.Locale.ROOT)}|${parsed.port}")
}
fun resourceBackgroundRequestDigest(request:ResourceUploadRequest):String=backgroundDigest(request.payload().toString())
private fun backgroundDigest(value:String)=MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") {"%02x".format(it)}

/** Preserve Retry-After even when the delegated byte response failed; malformed hints cool down for one day. */
fun resourceBackgroundRetryNotBefore(value:String?,now:Long):Long? {
    require(now>=0);if(value==null) return null
    val delay=runCatching {retryAfterMilliseconds(value,now)}.getOrDefault(86_400_000)
    return if(delay>Long.MAX_VALUE-now) Long.MAX_VALUE else now+delay
}
