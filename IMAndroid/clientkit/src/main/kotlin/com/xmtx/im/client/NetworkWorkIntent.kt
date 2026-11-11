package com.xmtx.im.client

import kotlinx.coroutines.withContext
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Domain attempt facts only. This carries no account, credential, permit, transport kind or service override.
 * The actual leaf transport chooses its activation owner and physical service before admission.
 */
class NetworkWorkIntent(val priority:NetworkWorkPriority,val isRetry:Boolean,val orderingKey:String?=null):
    AbstractCoroutineContextElement(Key) {
    companion object Key:CoroutineContext.Key<NetworkWorkIntent>
}

/** Owner-bound metadata from a different activation is never inherited. A nested domain step may refine facts. */
fun CoroutineContext.networkWorkFor(owner:AccountWorkScheduler):NetworkWorkContext? {
    val inherited=this[NetworkWorkScope]?.takeIf {it.scheduler===owner}?.work
    val intent=this[NetworkWorkIntent] ?: return inherited
    return (inherited ?: NetworkWorkContext("account")).copy(priority=intent.priority,isRetry=intent.isRetry,
        orderingKey=intent.orderingKey ?: inherited?.orderingKey)
}

internal suspend fun <T> withPreparationAttempt(attempts:Int,body:suspend ()->T):T {
    require(attempts>0)
    return withContext(NetworkWorkIntent(NetworkWorkPriority.Recovery,attempts>1)) {body()}
}

/** A legacy frozen command has no proof of being unattempted, even if an old manual round reset its counter. */
internal fun commandExecutionStarted(marker:Boolean?)=marker ?: true

internal suspend fun <T> withCommandAttempt(isRetry:Boolean,
    priority:NetworkWorkPriority=if(isRetry) NetworkWorkPriority.Recovery else NetworkWorkPriority.Interactive,body:suspend ()->T):T =
    withContext(NetworkWorkIntent(priority,isRetry)) {body()}
