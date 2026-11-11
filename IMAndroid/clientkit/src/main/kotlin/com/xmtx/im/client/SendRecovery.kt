package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

@Serializable enum class SendAction { Submit, Recover }
@Serializable enum class SendRecoveryStatus { Queued, Confirming, NeedsAttention, ExpiredUnsubmitted, WaitingForNetwork, WaitingForAuthentication }
/** Durable scheduling metadata; the frozen command is never rewritten. */
@Serializable data class SendRecovery(val action: SendAction=SendAction.Submit,val submitted: Boolean=false,
    val status: SendRecoveryStatus=SendRecoveryStatus.Queued,val submitAttempts: Int=0,val recoveryAttempts: Int=0,
    val submitStarted: Long?=null,val recoveryStarted: Long?=null,val nextAt: Long=0) {
    companion object {val Legacy=SendRecovery(SendAction.Recover,true,SendRecoveryStatus.Confirming)}
}
/** Pure transitions shared by durable adapters; selection, leases and writes remain atomic store operations. */
sealed interface SendClaimDecision {
    data object Wait: SendClaimDecision
    data class Stop(val state: SendRecovery): SendClaimDecision
    data class Ready(val action: SendAction,val state: SendRecovery): SendClaimDecision
}
object SendRecoveryPolicy {
    const val MAX_ATTEMPTS=5
    const val ROUND_MILLISECONDS=60_000L
    const val LEASE_MILLISECONDS=60_000L
    fun claim(prior: SendRecovery,now: Long,submissionDeadline: Long): SendClaimDecision {
        require(now>=0 && now<Long.MAX_VALUE-LEASE_MILLISECONDS && submissionDeadline>0)
        if(prior.status in setOf(SendRecoveryStatus.NeedsAttention,SendRecoveryStatus.ExpiredUnsubmitted,SendRecoveryStatus.WaitingForNetwork,SendRecoveryStatus.WaitingForAuthentication) || prior.nextAt>now) return SendClaimDecision.Wait
        if(!prior.submitted && now>=submissionDeadline) return SendClaimDecision.Stop(prior.copy(status=SendRecoveryStatus.ExpiredUnsubmitted))
        val action=if(now>=submissionDeadline) SendAction.Recover else prior.action
        val attempts=if(action==SendAction.Submit) prior.submitAttempts else prior.recoveryAttempts
        val started=if(action==SendAction.Submit) prior.submitStarted else prior.recoveryStarted
        if(attempts>=MAX_ATTEMPTS || started!=null && now-started>=ROUND_MILLISECONDS)
            return SendClaimDecision.Stop(prior.copy(status=SendRecoveryStatus.NeedsAttention))
        return SendClaimDecision.Ready(action,prior.copy(action=SendAction.Recover,submitted=true,status=SendRecoveryStatus.Confirming,
            submitAttempts=prior.submitAttempts+if(action==SendAction.Submit) 1 else 0,
            recoveryAttempts=prior.recoveryAttempts+if(action==SendAction.Recover) 1 else 0,
            submitStarted=if(action==SendAction.Submit) prior.submitStarted ?: now else prior.submitStarted,
            recoveryStarted=if(action==SendAction.Recover) prior.recoveryStarted ?: now else prior.recoveryStarted))
    }
    /** Explicit user continuation never changes the frozen identity or bypasses the server cooldown. */
    fun resume(prior: SendRecovery,now: Long): SendRecovery {
        require(now>=0)
        if(prior.status!=SendRecoveryStatus.NeedsAttention) return prior
        return SendRecovery(action=if(prior.submitted) SendAction.Recover else SendAction.Submit,submitted=prior.submitted,
            status=if(prior.submitted) SendRecoveryStatus.Confirming else SendRecoveryStatus.Queued,nextAt=maxOf(now,prior.nextAt))
    }
    /** A validated authenticated connection may wake only explicit connection waits, never other pauses. */
    fun connected(prior: SendRecovery,now: Long): SendRecovery {
        require(now>=0)
        if(prior.status !in setOf(SendRecoveryStatus.WaitingForNetwork,SendRecoveryStatus.WaitingForAuthentication)) return prior
        return prior.copy(status=if(prior.submitted) SendRecoveryStatus.Confirming else SendRecoveryStatus.Queued,
            submitAttempts=0,recoveryAttempts=0,submitStarted=null,recoveryStarted=null,nextAt=maxOf(now,prior.nextAt))
    }
}
data class SendAttempt(val command: MessageSendOperation,val token: String,val action: SendAction,val state: SendRecovery,val isRetry: Boolean=true)
interface SendRecoveryStore {
    /** Optional exact journal observation; a handler return/receipt callback alone is not durable proof. */
    suspend fun observeSend(attempt:SendAttempt,now:Long):OperationStepObservation? = null
    /** Select one due, authorized room head and atomically persist Ready state plus an expiring unique lease.
     * Persist Stop decisions without sending. A replaced/expired lease must not accept a late completion.
     * Legacy rows without submission evidence must start from SendRecovery.Legacy, never Queued.
     * isRetry is the pre-claim submitted fact; only a proven first attempt bypasses retry quota.
     */
    suspend fun claimSend(now: Long): SendAttempt?
    /** Compare the lease token and frozen command; persist scheduling and release the matching lease. */
    suspend fun deferSend(attempt: SendAttempt,state: SendRecovery)
    /** Validate the receipt; atomically finish only the matching lease and its dependent send intent. */
    suspend fun completeSend(attempt: SendAttempt,receipt: MessageSendOperationReceipt)
    suspend fun resumeSend(room: RoomId,viewer: UserId,operation: String,now: Long)
    /** Call only after authenticating a new connection for viewer; preserve actions, identities and cooldowns. */
    suspend fun resumeNetworkWaitingSends(viewer: UserId,now: Long)
}
internal fun sendTimeAfter(now: Long,delay: Long)=if(delay>Long.MAX_VALUE-now) Long.MAX_VALUE else now+delay

/** Matches iOS commandRecovery's separate five-attempt / sixty-second submission and reconciliation rounds. */
internal class SendRecoveryRunner(private val transport: EnvelopeTransport,private val store: SendRecoveryStore,
    private val now: ()->Long,private val random: ()->Double={kotlin.random.Random.nextDouble()},
    private val admission: AccountRetryAdmission=AccountRetryAdmission()) {
    suspend fun flush() {
        repeat(4) {
            val attempt=store.claimSend(now()) ?: return
            val candidatesObserved=System.nanoTime()
            var requestSession:EnvelopeRequestSession?=null
            val proceed=measureOperationStep(OperationKind.SendMessage,
                if(attempt.action==SendAction.Submit) OperationWorkAction.Submit else OperationWorkAction.Reconcile,
                if(attempt.action==SendAction.Submit) attempt.state.submitAttempts else attempt.state.recoveryAttempts,
                attempt.isRetry,candidatesObserved,observe={store.observeSend(attempt,now())},
                diagnosticsProvider={requestSession?.scheduler?.networkDiagnostics}) {
            try {
                val session=(transport as? RealtimeConnection)?.captureRequestSession() ?: EnvelopeRequestSession(transport,null)
                requestSession=session
                try {if(session.scheduler==null) admission.await("durableOperations",attempt.isRetry)}
                catch(e: RetryAdmissionUnavailable) {defer(attempt,attempt.action,sendTimeAfter(now(),2_000));return@measureOperationStep false}
                val command=attempt.command
                val request=if(attempt.action==SendAction.Submit) Envelope.newBuilder().setMessageSendOperation(command) else
                    Envelope.newBuilder().setMessageSendOperationRecover(MessageSendOperationRecover.newBuilder()
                        .setIdentity(MessageSendOperationIdentity.newBuilder().setAccountId(command.senderUserId).setRoomId(command.roomId).setOperationId(command.clientMessageId))
                        .setFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(command.fingerprintVersion).setDigest(command.fingerprint))
                        .setDomainFingerprint(MessageSendOperationFingerprint.newBuilder().setVersion(command.domainFingerprintVersion).setDigest(command.domainFingerprint))
                        .setAction(if(now()<command.firstSubmissionDeadlineMs) MessageSendOperationRecover.Action.QUERY else MessageSendOperationRecover.Action.CLOSE_IF_ABSENT))
                val response=if(session.scheduler==null) session.transport.request(request) else withContext(NetworkWorkIntent(
                    if(attempt.isRetry) NetworkWorkPriority.Recovery else NetworkWorkPriority.Interactive,attempt.isRetry)) {
                    session.transport.request(request)
                }
                if(!response.hasMessageSendOperationResult()) throw ClientFailure.Protocol()
                val result=response.messageSendOperationResult
                when {
                    result.hasReceipt()->{validateSendReceipt(command,result.receipt);store.completeSend(attempt,result.receipt)}
                    result.hasDeferred()->{
                        val hint=result.deferred
                        if(hint.identity.accountId!=command.senderUserId || hint.identity.roomId!=command.roomId || hint.identity.operationId!=command.clientMessageId ||
                            hint.fingerprint.version!=command.fingerprintVersion || hint.fingerprint.digest!=command.fingerprint || hint.reasonValue !in 1..2 || hint.retryAfterMs<0) throw ClientFailure.Protocol()
                        coolDown(requestSession,hint.retryAfterMs)
                        defer(attempt,attempt.action,sendTimeAfter(now(),hint.retryAfterMs))
                    }
                    result.hasUnresolved() && result.unresolved && attempt.action==SendAction.Recover->{
                        defer(attempt,if(now()<command.firstSubmissionDeadlineMs) SendAction.Submit else SendAction.Recover,
                            sendTimeAfter(now(),2_000),pause=now()>=command.firstSubmissionDeadlineMs)
                    }
                    result.hasFingerprintConflict() && result.fingerprintConflict->defer(attempt,SendAction.Recover,now(),pause=true)
                    else->throw ClientFailure.Protocol()
                }
            } catch(e: RealtimeUnavailableBeforeAdmission) {
                if(e.reason==AccountWorkScheduler.Rejection.Overloaded || e.reason==AccountWorkScheduler.Rejection.DeadlineExceeded) {
                    defer(attempt,attempt.action,sendTimeAfter(now(),2_000));return@measureOperationStep false
                }
                park(attempt,SendRecoveryStatus.WaitingForNetwork);throw e
            } catch(e: CancellationException) {
                withContext(NonCancellable) {defer(attempt,SendAction.Recover,now())};throw e
            } catch(e: Exception) {
                if(e is GatewayFailure && e.code=="UNAUTHENTICATED" && !e.retryable && e.retryAfterSeconds<=0) {
                    park(attempt,SendRecoveryStatus.WaitingForAuthentication);throw e
                }
                // An exception provides no proof that bytes did not reach the server.
                val floor=(e as? GatewayFailure)?.retryAfterSeconds?.coerceAtLeast(0)?.toLong()?.times(1000) ?: 0
                if(floor>0) coolDown(requestSession,floor)
                defer(attempt,SendAction.Recover,sendTimeAfter(now(),floor),pause=e is ClientFailure.Protocol)
                throw e
            }
            true
            }
            if(!proceed) return
        }
    }
    private suspend fun coolDown(session:EnvelopeRequestSession?,millis:Long) {
        val scheduler=session?.scheduler
        if(scheduler!=null) scheduler.coolDown("realtime",millis) else admission.coolDown("durableOperations",millis)
    }
    private suspend fun park(attempt: SendAttempt,status: SendRecoveryStatus) {
        store.deferSend(attempt,attempt.state.copy(action=attempt.action,status=status,nextAt=maxOf(now(),attempt.state.nextAt)))
    }
    private suspend fun defer(attempt: SendAttempt,action: SendAction,floor: Long,pause: Boolean=false) {
        val state=attempt.state;val time=now();val attempts=if(action==SendAction.Submit) state.submitAttempts else state.recoveryAttempts
        val started=if(action==SendAction.Submit) state.submitStarted else state.recoveryStarted
        val deadline=sendTimeAfter(started ?: time,SendRecoveryPolicy.ROUND_MILLISECONDS);val base=maxOf(time,floor,state.nextAt)
        val exhausted=attempts>=SendRecoveryPolicy.MAX_ATTEMPTS || base>=deadline
        val ceiling=minOf(30_000L,500L shl (attempts-1).coerceIn(0,16))
        val next=if(exhausted) base else sendTimeAfter(base,(minOf(ceiling,deadline-base)*random().coerceIn(0.0,1.0)).toLong())
        store.deferSend(attempt,state.copy(action=action,status=if(pause || exhausted || next>=deadline) SendRecoveryStatus.NeedsAttention else SendRecoveryStatus.Confirming,nextAt=next))
    }
}

fun validateSendReceipt(command: MessageSendOperation,receipt: MessageSendOperationReceipt) {
    if(receipt.identity.accountId!=command.senderUserId || receipt.identity.roomId!=command.roomId || receipt.identity.operationId!=command.clientMessageId ||
        receipt.fingerprint.version!=command.fingerprintVersion || receipt.fingerprint.digest!=command.fingerprint || receipt.resolvedAtMs<=0 ||
        receipt.outcomeCase==MessageSendOperationReceipt.OutcomeCase.OUTCOME_NOT_SET ||
        (receipt.hasAccepted() && (receipt.accepted.messageId.isBlank() || receipt.accepted.roomSequence<=0)) ||
        (receipt.hasRejected() && receipt.rejected.reasonValue !in 1..6)) throw ClientFailure.Protocol()
}
