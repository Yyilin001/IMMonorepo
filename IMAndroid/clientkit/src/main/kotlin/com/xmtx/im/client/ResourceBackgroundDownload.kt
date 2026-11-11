package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.json.*

/** Memory-only handoff; a normal GET or preview is never sufficient for OS delegation. */
class ResourceBackgroundDownloadTarget(val target:MediaDownloadTarget) {
    val authorization:ResourceBackgroundDownloadAuthorization get()=requireNotNull(target.plan.backgroundDownload)
    init {require(target.preview==null && target.plan.backgroundDownload!=null)}
    fun remainingLifetimeMillis(descriptor:ResourceDescriptor,now:Long=System.currentTimeMillis()):Long {
        target.requireValid();val grant=authorization
        require(descriptor.state==ResourceState.Ready && descriptor.byteCount==grant.expectedBytes && descriptor.checksum==grant.checksum)
        require(grant.issuedAt<=now && grant.expiresAt>now) {"后台下载授权无效或已过期"}
        return minOf(grant.expiresAt-now,target.remainingNanos()/1_000_000).also {require(it>0)}
    }
    override fun toString()="ResourceBackgroundDownloadTarget(<redacted>)"
}

/** Account journal facts only: no signed URL, headers, local path, or read capability. */
data class ResourceBackgroundDownloadMapping(val id:String,val systemSession:String,val task:String,val download:String,
    val key:ResourceKey,val message:MediaMessageLocation,val authorization:ResourceBackgroundDownloadAuthorization,
    val originDigest:String,val constraints:ResourceDownloadNetworkConstraints,val createdAt:Long) {
    init {
        require(listOf(id,systemSession,task,download).all {uuidId(it)==it})
        require(key.home==ResourceHome.Room(message.room) && originDigest.matches(Regex("[0-9a-f]{64}")) && createdAt>=0)
    }
    fun payload()=buildJsonObject {
        put("id",id);put("systemSession",systemSession);put("task",task);put("download",download);put("key",key.payload())
        put("room",message.room.value);put("message",message.message.value);put("authorization",authorization.payload());put("originDigest",originDigest)
        put("cellular",constraints.allowsCellular);put("expensive",constraints.allowsExpensive);put("constrained",constraints.allowsConstrained);put("createdAt",createdAt)
    }
    companion object {fun decode(v:JsonObject)=ResourceBackgroundDownloadMapping(v.resourceString("id"),v.resourceString("systemSession"),
        v.resourceString("task"),v.resourceString("download"),ResourceKey.decode(v.resourceObject("key")),
        MediaMessageLocation(RoomId(v.resourceString("room")),MessageId(v.resourceString("message"))),
        ResourceBackgroundDownloadAuthorization.decode(v.resourceObject("authorization")),v.resourceString("originDigest"),
        ResourceDownloadNetworkConstraints(v.getValue("cellular").jsonPrimitive.boolean,v.getValue("expensive").jsonPrimitive.boolean,v.getValue("constrained").jsonPrimitive.boolean),v.resourceNumber("createdAt"))}
}

/** A physical completion is byte evidence only; publication requires a fresh authorized file borrow. */
data class ResourceBackgroundDownloadResult(val mapping:String,val task:String,val status:Int?,val issue:ResourceDownloadIssue?,
    val receivedBytes:Long,val originDigest:String?,val retryNotBefore:Long?=null,val observation:ResourceBackgroundTransferObservation?=null) {
    init {
        require(uuidId(mapping)==mapping && uuidId(task)==task && receivedBytes in 0..512L*1024*1024)
        require(status==null || status in 100..599);require(originDigest==null || originDigest.matches(Regex("[0-9a-f]{64}")))
        require(retryNotBefore==null || retryNotBefore>=0)
    }
}
data class ResourceBackgroundDownloadSnapshot(val mapping:ResourceBackgroundDownloadMapping,val received:Boolean)
interface ResourceBackgroundDownloadJournal {
    suspend fun backgroundDownloadSession():String
    suspend fun activeBackgroundDownloads():PersistentList<ResourceBackgroundDownloadSnapshot>
    /** Commit before handing the request to the platform; the original foreground claim becomes stale. */
    suspend fun installBackgroundDownload(claim:ResourceDownloadClaim,id:String,task:String,target:ResourceBackgroundDownloadTarget,now:Long=System.currentTimeMillis()):ResourceBackgroundDownloadMapping
    /** Call only after the physical task has drained; null means the driver proved it absent/drained. */
    suspend fun finishBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,result:ResourceBackgroundDownloadResult?,now:Long=System.currentTimeMillis()):Boolean
    /** Invoke inside a verified, freshly message-authorized borrow, after the received bytes were published. */
    suspend fun completeBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,read:MessageResourceRead,now:Long=System.currentTimeMillis()):Boolean
    /** A received source failed verification/publication; an ordinary late OS callback cannot perform this transition. */
    suspend fun discardReceivedBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,issue:ResourceDownloadIssue,now:Long=System.currentTimeMillis()):Boolean
    /** Retry fresh authorization using the durable bytes, or retire them after a terminal publication failure. */
    suspend fun failReceivedBackgroundDownload(mapping:ResourceBackgroundDownloadMapping,issue:ResourceDownloadIssue,retryAt:Long?,serverRetryAt:Long,now:Long=System.currentTimeMillis()):Boolean
}
