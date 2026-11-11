package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.Response
import java.io.IOException
import java.util.UUID

/** This physical request did not start. Earlier business attempts remain the caller's responsibility. */
class ByteTransferAdmissionFailure(val reason:AccountWorkScheduler.Rejection):IOException("Byte transfer admission: $reason")

private class TransferResult<T>(val value:T)
/** Only leaf byte adapters acquire this permit. No credential, file publication or business claim is granted. */
internal suspend fun <T> withByteTransferPermit(kind:NetworkWorkKind,budgetMillis:Long,body:suspend ()->T):T {
    require(kind.bytes && budgetMillis>0)
    val scope=currentCoroutineContext()[NetworkWorkScope] ?: return withTimeout(budgetMillis) {body()}
    val work=(currentCoroutineContext().networkWorkFor(scope.scheduler) ?: scope.work).copy(service="mediaProvider",kind=kind)
    try {
        return (withTimeoutOrNull(budgetMillis) {
            TransferResult(scope.scheduler.withPermit(work) {permit->coroutineScope {
                val demand=currentCoroutineContext()[ByteTransferDemand]?.takeIf {kind==NetworkWorkKind.Download}
                val observer=UUID.randomUUID()
                try {
                    demand?.observe(observer) {priority->launch {scope.scheduler.promoteDownloadPermit(permit,priority)}}
                        ?.let {scope.scheduler.promoteDownloadPermit(permit,it)}
                    body()
                } finally {demand?.remove(observer)}
            }})
        } ?: throw ResourceTransferFailure()).value
    } catch(error:AccountWorkScheduler.AdmissionException) {throw ByteTransferAdmissionFailure(error.reason)}
    catch(error:TimeoutCancellationException) {
        currentCoroutineContext().ensureActive()
        throw ResourceTransferFailure()
    }
}
/** The shared account scheduler supersedes adapter-local slots, including automatic/user reservations. */
internal suspend fun <T> withFallbackByteSlot(slots:Semaphore,body:suspend ()->T):T=
    if(currentCoroutineContext()[NetworkWorkScope]==null) slots.withPermit {body()} else body()

/** Called before consuming an error body, while the physical callback still owns its permit. */
internal fun byteTransferHeaders(scope:NetworkWorkScope?,response:Response) {
    if(scope==null || response.code !in setOf(429,503)) return
    val delay=response.header("Retry-After")?.let {runCatching {retryAfterMilliseconds(it,System.currentTimeMillis())}.getOrNull()} ?: return
    runBlocking {scope.scheduler.coolDown("mediaProvider",delay)}
}
