package com.xmtx.im.client

import kotlinx.serialization.json.*

/** Exact provider delegation, never a room/presentation permission or a reusable login credential. */
sealed interface ResourceBackgroundUploadScope {
    data class Part(val number:Int):ResourceBackgroundUploadScope {init {require(number in 1..32)}}
    data class Whole(val byteCount:Long,val checksum:ResourceChecksum):ResourceBackgroundUploadScope {
        init {require(byteCount in 1..256L*1024*1024)}
    }
    fun payload()=buildJsonObject {when(val scope=this@ResourceBackgroundUploadScope) {
        is Part->put("part",buildJsonObject {put("number",scope.number)})
        is Whole->put("whole",buildJsonObject {put("byteCount",scope.byteCount);put("checksum",scope.checksum.payload())})
    }}
    companion object {fun decode(value:JsonObject):ResourceBackgroundUploadScope {
        require(value.size==1)
        return when(val key=value.keys.single()) {
            "part"->Part(Math.toIntExact(value.resourceObject(key).resourceNumber("number")))
            "whole"->value.resourceObject(key).let {Whole(it.resourceNumber("byteCount"),ResourceChecksum.decode(it.resourceObject("checksum")))}
            else->throw ClientFailure.Protocol()
        }
    }}
}
/** Safe immutable grant facts. This value contains neither the signed URL nor request headers. */
data class ResourceBackgroundUploadAuthorization(val id:String,val session:String,val generation:Long,val media:String,
    val scope:ResourceBackgroundUploadScope,val issuedAt:Long,val expiresAt:Long) {
    init {
        require(listOf(id,session,media).all {uuidId(it)==it})
        require(generation>0 && issuedAt>0 && expiresAt>issuedAt && expiresAt-issuedAt<=900_000)
    }
    fun payload()=buildJsonObject {
        put("id",id);put("sessionID",wireId(session));put("generation",generation);put("mediaID",wireId(media));put("scope",scope.payload())
        put("issuedAtMilliseconds",issuedAt);put("expiresAtMilliseconds",expiresAt)
    }
    companion object {fun decode(value:JsonObject)=ResourceBackgroundUploadAuthorization(uuidId(value.resourceString("id")),value.resourceId("sessionID"),
        value.resourceNumber("generation"),value.resourceId("mediaID"),ResourceBackgroundUploadScope.decode(value.resourceObject("scope")),
        value.resourceNumber("issuedAtMilliseconds"),value.resourceNumber("expiresAtMilliseconds"))}
}

/** Memory-only validated handoff. A system driver must recheck the current job before creating/resuming a task. */
class ResourceBackgroundUploadTarget internal constructor(val plan:ResourceTransferPlan,private val session:ResourceUploadSession,
    private val request:ResourceUploadRequest,private val deadlineNanos:Long,private val now:()->Long,private val nanoTime:()->Long) {
    val authorization:ResourceBackgroundUploadAuthorization get()=requireNotNull(plan.backgroundUpload)
    fun requireValid(currentSession:ResourceUploadSession,currentRequest:ResourceUploadRequest) {
        val grant=authorization;val wall=now()
        require(currentRequest==request && currentSession.locator==session.locator && currentSession.generation==session.generation && currentSession.media==session.media)
        require(currentRequest.usage is ResourceUsage.Attachment && currentSession.locator.home==ResourceHome.Room(currentRequest.usage.room))
        require(currentSession.state in setOf(ResourceSessionState.Created,ResourceSessionState.Uploading))
        require(grant.session==currentSession.locator.session && grant.generation==currentSession.generation && grant.media==currentRequest.media)
        // issuedAt is provider metadata, not a client-clock not-before constraint (matching the Swift upload coordinator).
        require(plan.mode in currentRequest.modes && grant.expiresAt>wall && currentSession.expiresAt>=grant.expiresAt && deadlineNanos-nanoTime()>0) {"后台传输授权无效或已过期"}
        when(val scope=grant.scope) {
            is ResourceBackgroundUploadScope.Part->require(plan.range!=null && plan.range.upper<currentRequest.byteCount && currentSession.parts.none {it.number==scope.number})
            is ResourceBackgroundUploadScope.Whole->require(scope.byteCount==currentRequest.byteCount && scope.checksum==currentRequest.checksum)
        }
    }
    fun remainingLifetimeMillis(currentSession:ResourceUploadSession,currentRequest:ResourceUploadRequest):Long {
        requireValid(currentSession,currentRequest)
        return minOf(authorization.expiresAt-now(),(deadlineNanos-nanoTime())/1_000_000).also {require(it>0)}
    }
    override fun toString()="ResourceBackgroundUploadTarget(<redacted>)"
}
