package com.xmtx.im.client

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonObject
import java.io.IOException

/** Stable content identity; neither this descriptor nor a cached byte array grants display access. */
data class AvatarContent(val media: String,val variant: String,val version: Long,val checksum: ResourceChecksum,val byteCount: Long) {
    init { require(uuidId(media)==media && uuidId(variant)==variant && version>0 && byteCount in 1..2L*1024*1024) }
    fun sameVariant(other: AvatarContent)=media==other.media && variant==other.variant
}
/** Memory-only authenticated response. Plans must never be persisted with resource descriptors. */
data class AvatarAccess(val content: AvatarContent,val plan: ResourceTransferPlan?) {
    init { require(plan==null || plan.mode==ResourceTransferMode.Get && plan.expectedBytes==content.byteCount && plan.checksum==content.checksum) }
    companion object {
        internal fun decode(value: JsonObject)=AvatarAccess(AvatarContent(value.resourceId("mediaID"),value.resourceId("variantID"),value.resourceNumber("version"),
            ResourceChecksum.decode(value.resourceObject("checksum")),value.resourceNumber("byteCount")),value.resourceOptionalObject("plan")?.let(ResourceTransferPlan::decode))
    }
}
class AvatarAccessFailure: IOException("头像展示授权已失效")
class AvatarTargetExpired: IOException("头像下载地址已过期，请重新读取资料授权")

/** Only a live presentation scope can mint this capability. Renewal cannot extend an existing grant. */
class AvatarReadGrant internal constructor(val actor: UserId,val device: DeviceId,val content: AvatarContent,val home: ResourceHome,val deadlineNanos: Long,
    private val plan: ResourceTransferPlan?,private val downloadDeadlineNanos: Long?,private val nanoTime: ()->Long,
    private val validate: suspend ()->Boolean) {
    suspend fun requireValid() {
        currentCoroutineContext().ensureActive()
        if(deadlineNanos-nanoTime()<=0 || !validate() || deadlineNanos-nanoTime()<=0) throw AvatarAccessFailure()
        currentCoroutineContext().ensureActive()
    }
    internal suspend fun downloadTarget(): Pair<ResourceTransferPlan,Long> {
        requireValid()
        val target=plan ?: throw AvatarTargetExpired();val deadline=downloadDeadlineNanos ?: throw AvatarTargetExpired()
        if(deadline-nanoTime()<=0) throw AvatarTargetExpired()
        return target to deadline
    }
    internal fun remainingDownloadNanos()=(downloadDeadlineNanos ?: nanoTime())-nanoTime()
    override fun toString()="AvatarReadGrant(content=$content, target=<redacted>)"
}
