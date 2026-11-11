package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.util.UUID

@Serializable
data class DirectRoomCommand(val actor: UserId, val target: UserId, val operation: String,
    val deadlineMilliseconds: Long) {
    init {
        require(actor != target && uuidId(actor.value) == actor.value && uuidId(target.value) == target.value)
        require(uuidId(operation) == operation && deadlineMilliseconds > 0)
    }
    fun payload() = buildJsonObject {
        put("actorUserID", wireId(actor.value)); put("targetUserID", wireId(target.value)); put("operationID", wireId(operation))
        put("firstSubmissionDeadlineMilliseconds", deadlineMilliseconds)
    }
    fun identity() = pairIdentity(actor, target, operation, "directRoom")
    val fingerprint: String get() = OperationFingerprint("directRoom").apply {
        unsigned("firstSubmissionDeadline", deadlineMilliseconds)
        text("identity", pairStorageKey(actor, target, operation, "directRoom"))
    }.digest()
    fun fingerprintPayload() = fingerprintPayload(fingerprint)
    fun recovery(close: Boolean) = buildJsonObject {
        put("identity", identity()); put("fingerprint", fingerprintPayload()); put("action", if (close) "closeIfAbsent" else "query")
    }
    companion object {
        fun create(actor: UserId, target: UserId, now: Long) = DirectRoomCommand(actor, target,
            UUID.randomUUID().toString().uppercase(), Math.addExact(now, ClientSubmissionWindow.COMMAND_MILLISECONDS))
    }
}

sealed interface DirectRoomResult {
    data class Receipt(val room: RoomId?, val rejection: String?, val closed: Boolean, val wire: String) : DirectRoomResult
    data object Processing : DirectRoomResult
    data class Deferred(val delayMilliseconds: Long) : DirectRoomResult
    data object Unresolved : DirectRoomResult
    data object Conflict : DirectRoomResult
}
class DirectRoomClient(private val transport: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun execute(command: DirectRoomCommand, recover: Boolean, close: Boolean): DirectRoomResult {
        val response = transport.request("/v2/direct-room-operations/" + if (recover) "operations/recover" else "submit",
            if (recover) command.recovery(close) else command.payload())
        if (response.status !in setOf(200, 429, 503)) throw response.failure()
        val root = response.body
        if (root.size != 1) throw ClientFailure.Protocol()
        if (response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when (root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue("receipt").objectValue("_0"))
            "processing" -> { validateBinding(command, root.objectValue("processing").objectValue("_0")); DirectRoomResult.Processing }
            "deferred" -> {
                val hint = root.objectValue("deferred").objectValue("_0")
                validateBinding(command, hint)
                DirectRoomResult.Deferred(retryHintDelay(hint, response, now()))
            }
            "unresolved" -> { if (root.objectValue("unresolved").isNotEmpty()) throw ClientFailure.Protocol(); DirectRoomResult.Unresolved }
            "fingerprintConflict" -> { if (root.objectValue("fingerprintConflict").isNotEmpty()) throw ClientFailure.Protocol(); DirectRoomResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        private fun validateBinding(command: DirectRoomCommand, value: JsonObject) =
            validatePairProof(command.actor, command.target, command.operation, "directRoom", command.fingerprint, value)
        fun decodeReceipt(command: DirectRoomCommand, value: JsonObject): DirectRoomResult.Receipt {
            validateBinding(command, value)
            if (value.number("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome")
            if (outcome.size != 1) throw ClientFailure.Protocol()
            var room: RoomId? = null
            var rejection: String? = null
            when (outcome.keys.single()) {
                "opened" -> {
                    val opened = outcome.objectValue("opened")
                    room = RoomId(uuidId(opened.identifier("roomID")))
                    if (opened.number("createdAtMilliseconds") <= 0) throw ClientFailure.Protocol()
                }
                "rejected" -> {
                    val reason = outcome.objectValue("rejected").objectValue("_0")
                    if (reason.size != 1 || reason.keys.single() !in setOf("firstSubmissionExpired", "invalidDeadline", "permissionDenied") || reason.objectValue(reason.keys.single()).isNotEmpty()) throw ClientFailure.Protocol()
                    rejection = reason.keys.single()
                }
                "closed" -> if (outcome.objectValue("closed").isNotEmpty()) throw ClientFailure.Protocol()
                else -> throw ClientFailure.Protocol()
            }
            return DirectRoomResult.Receipt(room, rejection, outcome.keys.single() == "closed", value.toString())
        }

    }
}

@Serializable enum class DirectWorkStatus { Pending, NeedsAttention, Opened, Rejected, Closed }
@Serializable data class DirectRoomWork(val command: DirectRoomCommand, val status: DirectWorkStatus = DirectWorkStatus.Pending,
    val processing: Boolean = false, val attempts: Int = 0, val nextAttemptMilliseconds: Long = 0,
    val receipt: String? = null, val room: RoomId? = null,
    /** null is legacy uncertainty; new records explicitly start false before any command I/O. */
    val executionStarted: Boolean? = null, val reconcile: Boolean? = null,
    /** Frozen user-selected identity; not a display lease or room-access grant. */
    val publicIdentity: PublicIdentity? = null) {
    init { require(publicIdentity == null || publicIdentity.user == command.target) }
    val terminal get() = status in setOf(DirectWorkStatus.Opened, DirectWorkStatus.Rejected, DirectWorkStatus.Closed)
    companion object {
        /** Only for a newly frozen command, never for restoring or coalescing existing work. */
        fun fresh(command:DirectRoomCommand, identity:PublicIdentity?=null)=DirectRoomWork(command,executionStarted=false,reconcile=false,publicIdentity=identity)
    }
}
interface DirectRoomStore {
    /** Coalesce existing work unchanged; use DirectRoomWork.fresh(command) only for a new target operation. */
    suspend fun prepareDirect(command: DirectRoomCommand): DirectRoomWork
    suspend fun prepareDirect(command: DirectRoomCommand, identity: PublicIdentity): DirectRoomWork =
        throw UnsupportedOperationException("This store does not persist direct-room identities")
    suspend fun directWorks(): PersistentList<DirectRoomWork>
    suspend fun directWork(operation:String): DirectRoomWork? = directWorks().firstOrNull {it.command.operation==operation}
    suspend fun updateDirect(expected: DirectRoomWork, updated: DirectRoomWork)
}
class DirectRoomService(private val account: UserId, private val client: DirectRoomClient, private val store: DirectRoomStore,
    private val now: () -> Long = System::currentTimeMillis, private val nanoTime: () -> Long = System::nanoTime) {
    private val mutex = Mutex()
    private val deadlines = mutableMapOf<String, Long>()
    suspend fun prepare(target: UserId): DirectRoomWork = store.prepareDirect(DirectRoomCommand.create(account, target, now()))
    suspend fun prepare(identity: PublicIdentity): DirectRoomWork = store.prepareDirect(DirectRoomCommand.create(account, identity.user, now()), identity)
    private fun localMessages() = store as? LocalDirectMessageStore ?: error("This store does not support local direct messages")
    suspend fun openLocal(identity: PublicIdentity): DirectConversationDestination {
        require(identity.user != account)
        localMessages().existingDirectRoom(account, identity.user)?.let { return DirectConversationDestination.Room(it) }
        return DirectConversationDestination.Pending(prepare(identity).command.operation)
    }
    suspend fun enqueueLocalMessage(message: LocalDirectMessage) = localMessages().saveLocalDirectMessage(account, message)
    suspend fun pendingMessages(operation: String) = localMessages().localDirectMessages(account, operation)
    suspend fun prepareLocalMessages(): Boolean {
        var changed = false
        while (localMessages().prepareNextLocalDirectMessage(account, now())) {
            kotlinx.coroutines.currentCoroutineContext().ensureActive(); changed = true
        }
        return changed
    }
    suspend fun runLocalMessagePreparation(onChanged: suspend () -> Unit, onFailure: suspend (Exception) -> Unit) {
        localMessages().localDirectMessageChanges.collect {
            try { if (prepareLocalMessages()) onChanged() }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { onChanged(); onFailure(error) }
        }
    }
    suspend fun retry(operation: String) = mutex.withLock {
        val work = store.directWorks().firstOrNull { it.command.operation == operation } ?: return@withLock
        if (!work.terminal) store.updateDirect(work, work.copy(status = DirectWorkStatus.Pending, attempts = 0))
    }
    suspend fun flush() = mutex.withLock {
        val candidates=store.directWorks();val candidatesObserved=System.nanoTime()
        for (saved in candidates) {
            if (saved.status != DirectWorkStatus.Pending || saved.nextAttemptMilliseconds > now()) continue
            require(saved.command.actor == account)
            val command = saved.command
            val clock = nanoTime()
            val remaining = (command.deadlineMilliseconds - now()).coerceIn(0, 600_000)
            val prior = deadlines[command.operation]
            val monotonicRemaining = prior?.let { ((it - clock) / 1_000_000).coerceAtLeast(0) } ?: remaining
            val allowed = minOf(remaining, monotonicRemaining)
            deadlines[command.operation] = clock + allowed * 1_000_000
            val expired = allowed == 0L
            val isRetry = commandExecutionStarted(saved.executionStarted)
            val work = saved.copy(executionStarted = true,reconcile = true)
            if(work != saved) store.updateDirect(saved,work)
            val attempts = work.attempts + 1
            val recovering=expired || saved.processing || (saved.reconcile ?: isRetry)
            measureOperationStep(OperationKind.DirectRoom,
                if(recovering) OperationWorkAction.Reconcile else OperationWorkAction.Submit,attempts,isRetry,candidatesObserved,
                observe={store.directWork(command.operation)?.takeIf {it.command==command}?.operationObservation(now())}) {
            try {
                val result = withCommandAttempt(isRetry) {client.execute(command, recover = recovering, close = expired)}
                val next = when (result) {
                    is DirectRoomResult.Receipt -> work.copy(status = when { result.room != null -> DirectWorkStatus.Opened; result.closed -> DirectWorkStatus.Closed; else -> DirectWorkStatus.Rejected },
                        attempts = attempts, receipt = result.wire, room = result.room)
                    DirectRoomResult.Processing -> work.copy(processing = true, attempts = attempts, nextAttemptMilliseconds = now() + 5_000)
                    is DirectRoomResult.Deferred -> work.copy(attempts = attempts, nextAttemptMilliseconds = now() + maxOf(5_000, result.delayMilliseconds))
                    DirectRoomResult.Unresolved -> work.copy(reconcile = expired || work.processing,attempts = attempts, nextAttemptMilliseconds = now() + 5_000)
                    DirectRoomResult.Conflict -> work.copy(status = DirectWorkStatus.NeedsAttention, attempts = attempts)
                }
                store.updateDirect(work, if (!next.terminal && attempts >= 12) next.copy(status = DirectWorkStatus.NeedsAttention) else next)
                if (next.terminal) deadlines.remove(command.operation)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                // An uncertain response never creates terminal evidence or a new operation ID.
                store.updateDirect(work, work.copy(attempts = attempts,
                    status = if (e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) DirectWorkStatus.NeedsAttention else DirectWorkStatus.Pending,
                    nextAttemptMilliseconds = now() + minOf(60_000, 1_000L shl minOf(attempts, 6))))
                if (e is ClientFailure.SignedOut) throw e
            }
            }
        }
    }
}
