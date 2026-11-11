package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable

@Serializable data class PolicyRecoveryBinding(val actor: UserId,val device: DeviceId,val room: RoomId,val generation: Long,
    val membership: Long,val source: String,val grant: Long,val grantSource: String) {
    init { require(generation > 0 && membership > 0 && grant > 0 && source.isNotBlank() && grantSource.isNotBlank());listOf(actor.value,device.value,room.value).forEach { require(uuidId(it) == it) } }
}
@Serializable data class PolicyRecoveryRequest(val id: String,val binding: PolicyRecoveryBinding,val attempts: Int = 0,val nextAttempt: Long = 0,val paused: Boolean = false) {
    init { require(uuidId(id) == id && attempts >= 0 && nextAttempt >= 0) }
    val room get() = binding.room
}
enum class PolicyRecoveryStatus { Unavailable,WaitingForSync,Needed,Pending,Paused,Ready }
data class LocalRolePolicy(val room: RoomId,val role: MemberRole,val permissions: PersistentSet<GroupPermission>,val revision: Long)
/** These policies may combine a full observation and newer events. They never authorize a mutation. */
data class GroupPolicyState(val room: RoomId,val policies: PersistentList<LocalRolePolicy>,val status: PolicyRecoveryStatus,val nextAttempt: Long? = null,val membershipRevision: Long? = null)
sealed interface PolicyRecoveryDisposition {
    data class Retry(val at: Long): PolicyRecoveryDisposition { init { require(at >= 0) } }
    data object Pause: PolicyRecoveryDisposition
    data object Unauthorized: PolicyRecoveryDisposition
}
class PolicyRecoverySyncPending: Exception()
class PolicyRecoveryUnauthorized: Exception()
interface RolePolicyRecoveryStore {
    suspend fun discoverPolicyRecovery(limit: Int): Int
    suspend fun duePolicyRecovery(now: Long,limit: Int): PersistentList<PolicyRecoveryRequest>
    suspend fun requestPolicyRecovery(room: RoomId,resume: Boolean = false): PolicyRecoveryRequest
    suspend fun completePolicyRecovery(request: PolicyRecoveryRequest,baseline: GroupPolicies): Boolean
    suspend fun failPolicyRecovery(request: PolicyRecoveryRequest,disposition: PolicyRecoveryDisposition): Boolean
}
class RolePolicyRecoveryRunner(private val store: RolePolicyRecoveryStore,private val fetch: suspend (RoomId) -> GroupPolicies,
    private val batchSize: Int = 16,private val now: () -> Long = System::currentTimeMillis) {
    init { require(batchSize in 1..100) }
    private val mutex = Mutex()
    suspend fun recoverOnce(): Int {
        currentCoroutineContext().ensureActive();if(!mutex.tryLock()) return 0
        try {
            try { store.discoverPolicyRecovery(batchSize) } catch(_: PolicyRecoverySyncPending) { return 0 }
            val requests = try { store.duePolicyRecovery(now(),batchSize) } catch(_: PolicyRecoverySyncPending) { return 0 }
            var attempted = 0
            for(candidate in requests) {
                currentCoroutineContext().ensureActive()
                val request = try { store.requestPolicyRecovery(candidate.room) } catch(_: PolicyRecoverySyncPending) { return attempted } catch(_: PolicyRecoveryUnauthorized) { continue }
                if(request.paused || request.nextAttempt > now()) continue
                attempted++
                val disposition = try {
                    val baseline = withTimeout(15000) { fetch(request.room) };currentCoroutineContext().ensureActive()
                    if(store.completePolicyRecovery(request,baseline)) continue
                    PolicyRecoveryDisposition.Retry(retryAt(1000))
                } catch(_: PolicyRecoverySyncPending) { return attempted }
                catch(e: TimeoutCancellationException) { currentCoroutineContext().ensureActive();PolicyRecoveryDisposition.Retry(backoff(request,0)) }
                catch(e: CancellationException) { throw e }
                catch(e: GatewayFailure) {
                    currentCoroutineContext().ensureActive()
                    if(e.code in setOf("UNAUTHENTICATED","SESSION_REVOKED","DEVICE_REVOKED")) throw e
                    if(e.code in setOf("FORBIDDEN","NOT_FOUND")) PolicyRecoveryDisposition.Unauthorized
                    else if(e.retryable && e.retryAfterSeconds >= 0) PolicyRecoveryDisposition.Retry(backoff(request,e.retryAfterSeconds.toLong()*1000))
                    else PolicyRecoveryDisposition.Pause
                } catch(e: ClientFailure.SignedOut) { throw e }
                catch(e: ClientFailure.Protocol) { PolicyRecoveryDisposition.Pause }
                catch(e: IllegalArgumentException) { PolicyRecoveryDisposition.Pause }
                catch(e: Exception) { currentCoroutineContext().ensureActive();PolicyRecoveryDisposition.Retry(backoff(request,0)) }
                currentCoroutineContext().ensureActive()
                try { store.failPolicyRecovery(request,disposition) } catch(_: PolicyRecoverySyncPending) { return attempted }
            }
            return attempted
        } finally { mutex.unlock() }
    }
    private fun backoff(request: PolicyRecoveryRequest,floor: Long) = retryAt(maxOf(floor,minOf(60000,1000L shl minOf(request.attempts,6))))
    private fun retryAt(delay: Long): Long { val time = now();require(time >= 0);return Math.addExact(time,delay) }
}
