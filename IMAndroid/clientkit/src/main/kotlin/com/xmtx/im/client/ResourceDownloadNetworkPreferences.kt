package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Account-local original-download policy. Existing physical transfers keep their admitted policy. */
data class ResourceAutomaticDownloadPolicy(val categories:PersistentSet<ResourceCategory> = persistentSetOf(),val maximumByteCount:Long=10L*1024*1024) {
    init {require(ResourceCategory.All !in categories && maximumByteCount in 1..512L*1024*1024)}
    fun allows(contentType:String,byteCount:Long)=byteCount in 1..maximumByteCount && categories.any {it.includes(contentType)}
}
/** Immutable demand carried across a physical writer's child coroutine, never persisted as authority. */
class AutomaticResourceDownload(val descriptor:ResourceDescriptor):AbstractCoroutineContextElement(Key) {
    companion object Key:CoroutineContext.Key<AutomaticResourceDownload>
}
data class ResourceDownloadNetworkPreferences(val allowsCellular:Boolean=true,val allowsConstrained:Boolean=false,
    val automaticDownloads:ResourceAutomaticDownloadPolicy=ResourceAutomaticDownloadPolicy()) {
    fun constraints(automatic:Boolean=false)=ResourceDownloadNetworkConstraints(
        allowsCellular && !automatic,!automatic,allowsConstrained && !automatic)
}
data class ResourceDownloadNetworkConstraints(val allowsCellular:Boolean,val allowsExpensive:Boolean,val allowsConstrained:Boolean) {
    fun intersecting(other:ResourceDownloadNetworkConstraints)=ResourceDownloadNetworkConstraints(
        allowsCellular && other.allowsCellular,allowsExpensive && other.allowsExpensive,allowsConstrained && other.allowsConstrained)
    fun allows(network:ResourceDownloadNetworkState)=
        (allowsCellular || network.cellular==false) && (allowsExpensive || !network.metered) && (allowsConstrained || !network.constrained)
}
/** Null cellular means the underlying transport cannot be established, for example an opaque VPN. */
data class ResourceDownloadNetworkState(val cellular:Boolean?,val metered:Boolean,val constrained:Boolean)
class ResourceDownloadPolicyRestricted:Exception("当前网络不符合原件下载设置")
interface ResourceDownloadNetworkSettings {
    suspend fun downloadNetworkPreferences():ResourceDownloadNetworkPreferences
    suspend fun setDownloadNetworkPreferences(value:ResourceDownloadNetworkPreferences)
}
