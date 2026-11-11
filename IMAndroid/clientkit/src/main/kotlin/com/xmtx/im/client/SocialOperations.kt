package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.util.UUID

@Serializable enum class RelationshipState { None, Pending, Accepted;
    companion object { fun fromWire(value: String) = when (value) { "none" -> None; "pending" -> Pending; "accepted" -> Accepted; else -> throw ClientFailure.Protocol() } }
}
@Serializable enum class SocialAction(val wire: String, val kind: String, val windowMilliseconds: Long) {
    Request("request", "relationship", 600_000), Accept("accept", "relationship", 600_000),
    Reject("reject", "relationship", 600_000), Remove("remove", "relationship", 600_000),
    Block("block", "userBlock", 120_000), Unblock("unblock", "userBlock", 120_000)
}
data class Relationship(val target: UserId, val state: RelationshipState, val requestedBy: UserId?, val updatedAt: Long)
data class UserBlock(val target: UserId, val updatedAt: Long)
/** Own, audience-bound state. This never discloses whether the target has blocked the actor. */
data class SocialBaseline(val actor: UserId, val target: UserId, val relationship: RelationshipState,
    val requestedBy: UserId?, val relationshipRevision: Long, val blocked: Boolean, val blockRevision: Long) {
    init {
        require(actor != target && uuidId(actor.value) == actor.value && uuidId(target.value) == target.value)
        require(relationshipRevision >= 0 && blockRevision >= 0)
        require(if (relationship == RelationshipState.Pending) requestedBy == actor || requestedBy == target else requestedBy == null)
    }
    fun revision(action: SocialAction) = if (action.kind == "relationship") relationshipRevision else blockRevision
}
@Serializable data class SocialCommand(val actor: UserId, val target: UserId, val operation: String,
    val action: SocialAction, val expectedRevision: Long, val deadlineMilliseconds: Long) {
    init {
        require(actor != target && uuidId(actor.value) == actor.value && uuidId(target.value) == target.value)
        require(uuidId(operation) == operation && expectedRevision in 0 until Long.MAX_VALUE && deadlineMilliseconds > 0)
    }
    fun identity() = pairIdentity(actor, target, operation, action.kind)
    val fingerprint get() = OperationFingerprint(action.kind).apply {
        text("action", action.wire); unsigned("expectedRevision", expectedRevision)
        unsigned("firstSubmissionDeadline", deadlineMilliseconds)
        text("identity", pairStorageKey(actor, target, operation, action.kind))
    }.digest()
    fun payload() = buildJsonObject {
        put("identity", identity())
        put("action", buildJsonObject { put(action.kind, buildJsonObject { put("_0", action.wire) }) })
        put("expectedRevision", expectedRevision); put("firstSubmissionDeadlineMilliseconds", deadlineMilliseconds)
    }
    fun recovery(close: Boolean) = buildJsonObject {
        put("identity", identity()); put("fingerprint", fingerprintPayload(fingerprint)); put("action", if (close) "closeIfAbsent" else "query")
    }
}
@Serializable enum class SocialWorkStatus { Pending, NeedsAttention, Committed, Rejected, Conflicted, Closed }
sealed interface SocialResult {
    data class Receipt(val status: SocialWorkStatus, val relationship: RelationshipState?, val blocked: Boolean?,
        val revision: Long?, val rejection: String?, val wire: String) : SocialResult
    data class Deferred(val delayMilliseconds: Long) : SocialResult
    data object Unresolved : SocialResult
    data object Conflict : SocialResult
}
class SocialClient(private val transport: AuthenticatedTransport, private val account: UserId,
    private val now: () -> Long = System::currentTimeMillis) {
    suspend fun baseline(target: UserId): SocialBaseline {
        require(target != account); uuidId(target.value)
        val response = transport.request("/v2/social/targets/${target.value}/baseline")
        if (response.status != 200) throw response.failure()
        val value = response.body
        if (UserId(value.identifier("actorUserID")) != account || UserId(value.identifier("targetUserID")) != target) throw ClientFailure.Protocol()
        val requestedBy = value["requestedByUserID"]?.takeUnless { it is JsonNull }?.jsonObject?.string("rawValue")?.let { UserId(it) }
        return SocialBaseline(account, target, RelationshipState.fromWire(value.string("relationshipState")), requestedBy,
            value.number("relationshipRevision"), value["isBlocked"]?.jsonPrimitive?.booleanOrNull ?: throw ClientFailure.Protocol(), value.number("blockRevision"))
    }
    suspend fun execute(command: SocialCommand, recover: Boolean, close: Boolean): SocialResult {
        require(command.actor == account)
        val response = transport.request("/v2/social/operations/" + if (recover) "recover" else "submit", if (recover) command.recovery(close) else command.payload())
        if (response.status !in setOf(200, 429, 503)) throw response.failure()
        val root = response.body
        if (root.size != 1) throw ClientFailure.Protocol()
        if (response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when (root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue("receipt").objectValue("_0"))
            "deferred" -> {
                val hint = root.objectValue("deferred").objectValue("_0")
                validate(command, hint); SocialResult.Deferred(retryHintDelay(hint, response, now()))
            }
            "unresolved" -> { if (root.objectValue("unresolved").isNotEmpty()) throw ClientFailure.Protocol(); SocialResult.Unresolved }
            "fingerprintConflict" -> { if (root.objectValue("fingerprintConflict").isNotEmpty()) throw ClientFailure.Protocol(); SocialResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        private fun validate(command: SocialCommand, value: JsonObject) = validatePairProof(command.actor, command.target,
            command.operation, command.action.kind, command.fingerprint, value)
        fun decodeReceipt(command: SocialCommand, value: JsonObject): SocialResult.Receipt {
            validate(command, value)
            if (value.number("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome")
            if (outcome.size != 1) throw ClientFailure.Protocol()
            var relationship: RelationshipState? = null; var blocked: Boolean? = null; var revision: Long? = null; var rejection: String? = null
            val status = when (outcome.keys.single()) {
                "applied" -> {
                    val applied = outcome.objectValue("applied").objectValue("_0")
                    if (applied.keys != setOf(command.action.kind)) throw ClientFailure.Protocol()
                    val state = applied.objectValue(command.action.kind)
                    revision = state.number("revision")
                    if (revision != command.expectedRevision + 1) throw ClientFailure.Protocol()
                    if (command.action.kind == "relationship") {
                        relationship = RelationshipState.fromWire(state.string("state"))
                        val expected = when(command.action) { SocialAction.Request -> RelationshipState.Pending; SocialAction.Accept -> RelationshipState.Accepted; else -> RelationshipState.None }
                        if (relationship != expected) throw ClientFailure.Protocol()
                    } else {
                        blocked = state["isBlocked"]?.jsonPrimitive?.booleanOrNull ?: throw ClientFailure.Protocol()
                        if (blocked != (command.action == SocialAction.Block)) throw ClientFailure.Protocol()
                    }
                    SocialWorkStatus.Committed
                }
                "rejected" -> {
                    val reason = outcome.objectValue("rejected").objectValue("_0")
                    if (reason.size != 1) throw ClientFailure.Protocol()
                    rejection = reason.keys.single()
                    if (rejection == "revisionConflict") {
                        if (reason.objectValue(rejection).number("currentRevision") < 0) throw ClientFailure.Protocol()
                        SocialWorkStatus.Conflicted
                    } else {
                        if (rejection !in setOf("firstSubmissionExpired", "invalidDeadline", "permissionDenied", "invalidState") || reason.objectValue(rejection).isNotEmpty()) throw ClientFailure.Protocol()
                        SocialWorkStatus.Rejected
                    }
                }
                "closed" -> { if (outcome.objectValue("closed").isNotEmpty()) throw ClientFailure.Protocol(); SocialWorkStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            return SocialResult.Receipt(status, relationship, blocked, revision, rejection, value.toString())
        }
    }
}
@Serializable data class SocialProposal(val id: String, val actor: UserId, val target: UserId, val action: SocialAction) {
    init { require(uuidId(id) == id && actor != target && uuidId(actor.value) == actor.value && uuidId(target.value) == target.value) }
}
/** A confirmation is memory-only and expires even if the device wall clock moves backwards. */
data class SocialConfirmation(val proposal: SocialProposal, val baseline: SocialBaseline, val deadlineNanos: Long) {
    fun valid(nowNanos: Long = System.nanoTime()) = deadlineNanos - nowNanos > 0
}
@Serializable data class SocialWork(val command: SocialCommand, val status: SocialWorkStatus = SocialWorkStatus.Pending,
    val attempts: Int = 0, val nextAttemptMilliseconds: Long = 0, val receipt: String? = null, val rejection: String? = null,
    /** null is legacy uncertainty; new records explicitly start false before any command I/O. */
    val executionStarted: Boolean? = null, val reconcile: Boolean? = null) {
    val terminal get() = status in setOf(SocialWorkStatus.Committed, SocialWorkStatus.Rejected, SocialWorkStatus.Conflicted, SocialWorkStatus.Closed)
    companion object {
        /** Only for a newly frozen command, never for restoring or coalescing existing work. */
        fun fresh(command:SocialCommand)=SocialWork(command,executionStarted=false,reconcile=false)
    }
}
interface SocialStore {
    suspend fun socialProposals(): PersistentList<SocialProposal>
    suspend fun saveSocialProposal(proposal: SocialProposal): SocialProposal
    suspend fun discardSocialProposal(id: String)
    /** Atomically replace the exact proposal with SocialWork.fresh(command); no network precedes this commit. */
    suspend fun confirmSocial(proposal: SocialProposal, command: SocialCommand): SocialWork
    suspend fun socialWorks(): PersistentList<SocialWork>
    suspend fun socialWork(operation:String): SocialWork? = socialWorks().firstOrNull {it.command.operation==operation}
    suspend fun updateSocial(expected: SocialWork, updated: SocialWork)
}
class SocialService(private val account: UserId, private val client: SocialClient, private val store: SocialStore,
    private val now: () -> Long = System::currentTimeMillis, private val nanoTime: () -> Long = System::nanoTime) {
    private val mutex = Mutex()
    private val deadlines = mutableMapOf<String, Long>()
    suspend fun propose(target: UserId, action: SocialAction) = store.saveSocialProposal(SocialProposal(UUID.randomUUID().toString().uppercase(), account, target, action))
    suspend fun discard(id: String) = store.discardSocialProposal(id)
    suspend fun prepareConfirmation(id: String): SocialConfirmation {
        val proposal = store.socialProposals().firstOrNull { it.id == id } ?: throw IllegalStateException("操作已取消，请重新选择")
        require(proposal.actor == account)
        val baseline = client.baseline(proposal.target)
        return SocialConfirmation(proposal, baseline, nanoTime() + 30_000_000_000)
    }
    suspend fun confirm(confirmation: SocialConfirmation, confirmedAtMilliseconds: Long = now(),
        confirmedAtNanos: Long = nanoTime()): SocialWork = confirmAt(confirmation, confirmedAtMilliseconds, confirmedAtNanos)
    private suspend fun confirmAt(confirmation: SocialConfirmation, clickedAt: Long, clickedNanos: Long): SocialWork = mutex.withLock {
        check(confirmation.valid(nanoTime())) { "确认已过期，请重新读取后确认" }
        val proposal = confirmation.proposal; val baseline = confirmation.baseline
        require(proposal.actor == account && baseline.actor == account && baseline.target == proposal.target)
        val window = ClientSubmissionWindow.milliseconds(proposal.action.windowMilliseconds)
        val localDeadline = clickedNanos + window * 1_000_000
        val remaining = ((localDeadline - nanoTime()) / 1_000_000).coerceIn(0, window)
        val deadline = minOf(Math.addExact(clickedAt, window), Math.addExact(now(), remaining))
        check(localDeadline - nanoTime() > 0 && deadline > now()) { "操作已过期，请重新确认" }
        val command = SocialCommand(account, proposal.target, UUID.randomUUID().toString().uppercase(), proposal.action, baseline.revision(proposal.action), deadline)
        val work = store.confirmSocial(proposal, command)
        deadlines[work.command.operation] = localDeadline
        work
    }
    suspend fun enqueue(target: UserId, action: SocialAction): SocialWork {
        val clickedAt = now(); val clickedNanos = nanoTime()
        val proposal = propose(target, action)
        return confirmAt(prepareConfirmation(proposal.id), clickedAt, clickedNanos)
    }
    suspend fun retry(operation: String) = mutex.withLock {
        val work = store.socialWorks().firstOrNull { it.command.operation == operation } ?: return@withLock
        if (!work.terminal) store.updateSocial(work, work.copy(status = SocialWorkStatus.Pending, attempts = 0))
    }
    suspend fun flush() = mutex.withLock {
        val candidates=store.socialWorks();val candidatesObserved=System.nanoTime()
        for (saved in candidates) {
            if (saved.status != SocialWorkStatus.Pending || saved.nextAttemptMilliseconds > now()) continue
            val command = saved.command; require(command.actor == account)
            val clock = nanoTime()
            val remaining = (command.deadlineMilliseconds - now()).coerceIn(0, command.action.windowMilliseconds)
            val allowed = minOf(remaining, deadlines[command.operation]?.let { ((it - clock) / 1_000_000).coerceAtLeast(0) } ?: remaining)
            deadlines[command.operation] = clock + allowed * 1_000_000
            val isRetry = commandExecutionStarted(saved.executionStarted)
            val work = saved.copy(executionStarted = true,reconcile = true)
            if(work != saved) store.updateSocial(saved,work)
            val attempts = work.attempts + 1
            val recovering=allowed == 0L || (saved.reconcile ?: isRetry)
            measureOperationStep(if(command.action.kind=="userBlock") OperationKind.UserBlock else OperationKind.Relationship,
                if(recovering) OperationWorkAction.Reconcile else OperationWorkAction.Submit,attempts,isRetry,candidatesObserved,
                observe={store.socialWork(command.operation)?.takeIf {it.command==command}?.operationObservation(now())}) {
            try {
                val next = when (val result = withCommandAttempt(isRetry) {client.execute(command, recover = recovering, close = allowed == 0L)}) {
                    is SocialResult.Receipt -> work.copy(status = result.status, attempts = attempts, receipt = result.wire, rejection = result.rejection)
                    is SocialResult.Deferred -> work.copy(attempts = attempts, nextAttemptMilliseconds = now() + maxOf(5_000, result.delayMilliseconds))
                    SocialResult.Unresolved -> work.copy(reconcile = allowed == 0L,attempts = attempts, nextAttemptMilliseconds = now() + 5_000)
                    SocialResult.Conflict -> work.copy(status = SocialWorkStatus.NeedsAttention, attempts = attempts)
                }
                store.updateSocial(work, if (!next.terminal && attempts >= 12) next.copy(status = SocialWorkStatus.NeedsAttention) else next)
                if (next.terminal) deadlines.remove(command.operation)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                store.updateSocial(work, work.copy(attempts = attempts,
                    status = if (e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) SocialWorkStatus.NeedsAttention else SocialWorkStatus.Pending,
                    nextAttemptMilliseconds = now() + minOf(60_000, 1_000L shl minOf(attempts, 6))))
                if (e is ClientFailure.SignedOut) throw e
            }
            }
        }
    }
}
