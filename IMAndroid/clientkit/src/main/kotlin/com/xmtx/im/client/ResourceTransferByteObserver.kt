package com.xmtx.im.client

import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Observation of one physical byte request. It grants no admission, credentials or publication. */
interface ResourceTransferByteObserver {
    fun report(bytes:Long)
    fun end()
}
class ResourceTransferProgressScope(val begin:(expectedBytes:Long)->ResourceTransferByteObserver?):AbstractCoroutineContextElement(Key) {
    companion object Key:CoroutineContext.Key<ResourceTransferProgressScope>
}
internal fun CoroutineContext.beginResourceTransferProgress(expectedBytes:Long):ResourceTransferByteObserver? {
    val native=get(ResourceTransferProgressScope)
    return if(native!=null) native.begin(expectedBytes) else get(ResourceTransferWaitScope)?.beginAttempt(expectedBytes)
}
