package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.*
import java.util.Base64
import java.util.UUID

internal object ImmutableUserIds : KSerializer<PersistentList<UserId>> {
    private val delegate = ListSerializer(UserId.serializer())
    override val descriptor = delegate.descriptor
    override fun serialize(encoder: Encoder, value: PersistentList<UserId>) = delegate.serialize(encoder, value)
    override fun deserialize(decoder: Decoder) = delegate.deserialize(decoder).toPersistentList()
}
@Serializable enum class GroupCapacity(val wire: String) { Standard("standard"), Large("large") }
@Serializable data class GroupCreationCommand(val actor: UserId, val operation: String, val title: String,
    @Serializable(with = ImmutableUserIds::class) val members: PersistentList<UserId>, val deadlineMilliseconds: Long) {
    init {
        require(uuidId(actor.value) == actor.value && uuidId(operation) == operation && deadlineMilliseconds > 0)
        require(title == normalizedTitle(title) && title.isNotEmpty() && title.toByteArray(Charsets.UTF_8).size <= 120) { "群名称需要 1 至 120 个 UTF-8 字节" }
        require(title.codePoints().noneMatch { Character.isISOControl(it) || Character.getType(it) == Character.FORMAT.toInt() }) { "群名称含不可用的控制字符" }
        require(members.size < 100_000 && members.none { it == actor } && members.all { uuidId(it.value) == it.value })
        require(members.zipWithNext().all { (a, b) -> a.value < b.value }) { "成员必须去重并按标识排序" }
    }
    val capacity get() = if (members.size < 5_000) GroupCapacity.Standard else GroupCapacity.Large
    fun identity() = buildJsonObject {
        put("accountID", wireId(actor.value))
        put("scope", buildJsonObject { put("account", buildJsonObject { put("_0", wireId(actor.value)) }) })
        put("operation", buildJsonObject { put("groupRoom", buildJsonObject { put("_0", wireId(operation)) }) })
    }
    fun audienceDigest(count: Int = members.size): String {
        require(count in 0..members.size)
        return OperationFingerprint("groupRoom").apply {
            orderedText("members", members.take(count).map { it.value.lowercase() }); text("schema", "audience-prefix-v1")
        }.digest()
    }
    val fingerprint get() = OperationFingerprint("groupRoom").apply {
        bytes("audience", Base64.getDecoder().decode(audienceDigest())); text("capacity", capacity.wire)
        unsigned("deadline", deadlineMilliseconds); text("identity", "${actor.value}/account/${actor.value}/groupRoom/$operation")
        unsigned("memberCount", members.size.toLong()); text("title", title)
    }.digest()
    fun payload() = buildJsonObject {
        put("identity", identity()); put("title", title); put("capacityClass", capacity.wire); put("initialMemberCount", members.size)
        put("audienceDigest", fingerprintPayload(audienceDigest())); put("firstSubmissionDeadlineMilliseconds", deadlineMilliseconds)
    }
    fun page(offset: Int): JsonObject {
        require(offset >= 0 && offset < members.size && offset % 512 == 0)
        val page = members.subList(offset, minOf(offset + 512, members.size))
        val digest = OperationFingerprint("groupRoom").apply {
            bytes("intent", Base64.getDecoder().decode(fingerprint)); orderedText("members", page.map { it.value.lowercase() }); unsigned("offset", offset.toLong())
        }.digest()
        return buildJsonObject {
            put("intent", payload()); put("offset", offset); put("memberUserIDs", JsonArray(page.map { wireId(it.value) })); put("pageFingerprint", fingerprintPayload(digest))
        }
    }
    fun recovery(close: Boolean) = buildJsonObject { put("intent", payload()); put("action", if (close) "closeIfAbsent" else "query") }
    companion object {
        fun normalizedTitle(value: String) = value.trim { it.isWhitespace() || it == '\u0085' }
        fun create(actor: UserId, title: String, members: PersistentList<UserId>, now: Long) = GroupCreationCommand(actor,
            UUID.randomUUID().toString().uppercase(), normalizedTitle(title), members.sortedBy { it.value }.toPersistentList(), Math.addExact(now, ClientSubmissionWindow.COMMAND_MILLISECONDS))
    }
}
@Serializable enum class GroupCreationPhase { Staging, Finalizing }
@Serializable data class GroupCreationProgress(val room: RoomId, val phase: GroupCreationPhase, val accepted: Int, val copied: Int, val prefixDigest: String) {
    fun validate(command: GroupCreationCommand, previous: GroupCreationProgress? = null) {
        if (uuidId(room.value) != room.value || accepted !in 0..command.members.size || copied !in 0..command.members.size + 1 ||
            (accepted != command.members.size && accepted % 512 != 0) || (copied != command.members.size + 1 && copied % 512 != 0) ||
            (phase == GroupCreationPhase.Staging && copied != 0) || (phase == GroupCreationPhase.Finalizing && accepted != command.members.size) ||
            prefixDigest != command.audienceDigest(accepted)) throw ClientFailure.Protocol()
        if (previous != null && (previous.room != room || previous.accepted > accepted || previous.copied > copied ||
            (previous.phase == GroupCreationPhase.Finalizing && phase != GroupCreationPhase.Finalizing))) throw ClientFailure.Protocol()
    }
}
sealed interface GroupCreationResult {
    data class Progress(val value: GroupCreationProgress) : GroupCreationResult
    data class Receipt(val room: RoomId?, val rejection: String?, val closed: Boolean, val wire: String) : GroupCreationResult
    data class Deferred(val delayMilliseconds: Long) : GroupCreationResult
    data object Unresolved : GroupCreationResult
    data object Conflict : GroupCreationResult
}
class GroupCreationClient(private val transport: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun execute(command: GroupCreationCommand, progress: GroupCreationProgress?, recover: Boolean, close: Boolean): GroupCreationResult {
        val action = when { recover -> "operations/recover"; progress == null -> "begin"; progress.accepted < command.members.size -> "append"; else -> "finalize" }
        val body = when (action) { "operations/recover" -> command.recovery(close); "append" -> command.page(progress!!.accepted); else -> command.payload() }
        require(body.toString().toByteArray().size <= if (action == "append") 32_768 else 4_096)
        val response = transport.request("/v2/group-creation-operations/$action", body)
        if (response.status !in setOf(200, 429, 503)) throw response.failure()
        val root = response.body
        if (root.size != 1) throw ClientFailure.Protocol()
        if (response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when(root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue("receipt").objectValue("_0")).also {
                if (progress != null && it.room != null && progress.room != it.room) throw ClientFailure.Protocol()
            }
            "progress" -> {
                val value = root.objectValue("progress").objectValue("_0"); validateProof(command, value)
                val phase = when(value.string("phase")) { "staging" -> GroupCreationPhase.Staging; "finalizing" -> GroupCreationPhase.Finalizing; else -> throw ClientFailure.Protocol() }
                val prefix = value.objectValue("acceptedPrefixDigest")
                if (prefix.number("version") != 1L) throw ClientFailure.Protocol()
                val accepted = value.number("acceptedMemberCount"); val copied = value.number("copiedMemberCount")
                if (accepted !in 0..command.members.size.toLong() || copied !in 0..command.members.size.toLong() + 1) throw ClientFailure.Protocol()
                val result = GroupCreationProgress(RoomId(uuidId(value.identifier("roomID"))), phase, accepted.toInt(), copied.toInt(), prefix.string("digest"))
                result.validate(command, progress); GroupCreationResult.Progress(result)
            }
            "deferred" -> { val hint = root.objectValue("deferred").objectValue("_0"); validateProof(command, hint); GroupCreationResult.Deferred(retryHintDelay(hint, response, now())) }
            "unresolved" -> { if (root.objectValue("unresolved").isNotEmpty()) throw ClientFailure.Protocol(); GroupCreationResult.Unresolved }
            "fingerprintConflict" -> { if (root.objectValue("fingerprintConflict").isNotEmpty()) throw ClientFailure.Protocol(); GroupCreationResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        private fun validateProof(command: GroupCreationCommand, value: JsonObject) {
            val identity = value.objectValue("identity"); val scope = identity.objectValue("scope"); val operation = identity.objectValue("operation")
            if (UserId(identity.identifier("accountID")) != command.actor || scope.keys != setOf("account") || operation.keys != setOf("groupRoom") ||
                UserId(scope.objectValue("account").identifier("_0")) != command.actor || uuidId(operation.objectValue("groupRoom").identifier("_0")) != command.operation) throw ClientFailure.Protocol()
            val fingerprint = value.objectValue("fingerprint")
            if (fingerprint.number("version") != 1L || fingerprint.string("digest") != command.fingerprint) throw ClientFailure.Protocol()
        }
        fun decodeReceipt(command: GroupCreationCommand, value: JsonObject): GroupCreationResult.Receipt {
            validateProof(command, value)
            if (value.number("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome"); if (outcome.size != 1) throw ClientFailure.Protocol()
            var room: RoomId? = null; var rejection: String? = null
            when (outcome.keys.single()) {
                "created" -> {
                    val created = outcome.objectValue("created"); room = RoomId(uuidId(created.identifier("roomID")))
                    if (created.string("title") != command.title || created.string("capacityClass") != command.capacity.wire || created.number("memberCount") != command.members.size + 1L) throw ClientFailure.Protocol()
                }
                "rejected" -> { rejection = outcome.objectValue("rejected").string("_0"); if (rejection !in setOf("submissionExpired", "invalidAudience", "creationDenied")) throw ClientFailure.Protocol() }
                "closed" -> if (outcome.objectValue("closed").isNotEmpty()) throw ClientFailure.Protocol()
                else -> throw ClientFailure.Protocol()
            }
            return GroupCreationResult.Receipt(room, rejection, outcome.keys.single() == "closed", value.toString())
        }
    }
}
@Serializable enum class GroupCreationStatus { Pending, NeedsAttention, Created, Rejected, Closed }
@Serializable data class GroupCreationWork(val command: GroupCreationCommand, val status: GroupCreationStatus = GroupCreationStatus.Pending,
    val progress: GroupCreationProgress? = null, val cancellationRequested: Boolean = false, val reconcile: Boolean = false,
    val attempts: Int = 0, val nextAttemptMilliseconds: Long = 0, val receipt: String? = null, val room: RoomId? = null, val rejection: String? = null,
    /** null is legacy uncertainty, preserved across manually restarted rounds. */
    val retryRequired: Boolean? = null) {
    val terminal get() = status in setOf(GroupCreationStatus.Created, GroupCreationStatus.Rejected, GroupCreationStatus.Closed)
    companion object {
        /** Fresh creation has no failed step; verified progress may subsequently clear retryRequired. */
        fun fresh(command:GroupCreationCommand)=GroupCreationWork(command,retryRequired=false)
    }
}
interface GroupCreationStore {
    /** Preserve coalesced work; use GroupCreationWork.fresh(command) only for a new frozen creation. */
    suspend fun prepareGroup(command: GroupCreationCommand): GroupCreationWork
    suspend fun groupWorks(): PersistentList<GroupCreationWork>
    suspend fun groupWork(id: String): GroupCreationWork? = groupWorks().firstOrNull { it.command.operation == id }
    suspend fun updateGroup(expected: GroupCreationWork, updated: GroupCreationWork)
}
class GroupCreationService(private val account: UserId, private val client: GroupCreationClient, private val store: GroupCreationStore,
    private val now: () -> Long = System::currentTimeMillis, private val nanoTime: () -> Long = System::nanoTime) {
    private val mutex = Mutex(); private val deadlines = mutableMapOf<String, Long>()
    suspend fun prepare(title: String, members: PersistentList<UserId>) = mutex.withLock {
        val clickedAt = now(); val clock = nanoTime()
        val work = store.prepareGroup(GroupCreationCommand.create(account, title, members, clickedAt))
        deadlines.putIfAbsent(work.command.operation, clock + (work.command.deadlineMilliseconds - clickedAt).coerceIn(0, 600_000) * 1_000_000)
        work
    }
    suspend fun retry(id: String) = change(id) { it.copy(status = GroupCreationStatus.Pending, attempts = 0) }
    suspend fun cancel(id: String) = change(id) { it.copy(cancellationRequested = true, reconcile = true, status = GroupCreationStatus.Pending, attempts = 0) }
    private suspend fun change(id: String, transform: (GroupCreationWork) -> GroupCreationWork) = mutex.withLock {
        val work = store.groupWorks().firstOrNull { it.command.operation == id } ?: return@withLock
        if (!work.terminal) store.updateGroup(work, transform(work))
    }
    /** One bounded page or recovery per work, allowing the runtime to serve other operations between calls. */
    suspend fun flush() = mutex.withLock {
        val candidates = store.groupWorks(); val candidatesObserved = System.nanoTime()
        for (saved in candidates) {
            if (saved.status != GroupCreationStatus.Pending || saved.nextAttemptMilliseconds > now()) continue
            val command = saved.command; require(command.actor == account)
            val clock = nanoTime(); val remaining = (command.deadlineMilliseconds - now()).coerceIn(0, 600_000)
            val allowed = minOf(remaining, deadlines[command.operation]?.let { ((it - clock) / 1_000_000).coerceAtLeast(0) } ?: remaining)
            deadlines[command.operation] = clock + allowed * 1_000_000
            val close = allowed == 0L || saved.cancellationRequested
            val recover = close || saved.reconcile || saved.retryRequired == null || saved.progress?.phase == GroupCreationPhase.Finalizing
            // Persist uncertainty before a possible remote side effect, including cancellation between response and commit.
            val isRetry = commandExecutionStarted(saved.retryRequired)
            val priority = if(!isRetry && saved.progress==null) NetworkWorkPriority.Interactive else NetworkWorkPriority.Recovery
            val work = saved.copy(reconcile = true,retryRequired = true)
            if (work != saved) store.updateGroup(saved, work)
            val attempts = work.attempts + 1
            measureOperationStep(OperationKind.GroupRoom, if(recover) OperationWorkAction.Reconcile else OperationWorkAction.Submit,
                attempts, isRetry, candidatesObserved, priority = priority,
                observe = { store.groupWork(command.operation)?.takeIf { it.command == command }?.operationObservation(now()) }) {
                try {
                    val next = when (val result = withCommandAttempt(isRetry,priority) {client.execute(command, work.progress, recover, close)}) {
                        is GroupCreationResult.Receipt -> work.copy(status = when { result.room != null -> GroupCreationStatus.Created; result.closed -> GroupCreationStatus.Closed; else -> GroupCreationStatus.Rejected },
                            receipt = result.wire, room = result.room, rejection = result.rejection, attempts = attempts)
                        is GroupCreationResult.Progress -> {
                            val advanced = work.progress == null || work.progress != result.value
                            work.copy(retryRequired = false,progress = result.value, reconcile = close || result.value.phase == GroupCreationPhase.Finalizing,
                                attempts = if (advanced) 0 else attempts, nextAttemptMilliseconds = now() + if (advanced) 0 else 1_000)
                        }
                        GroupCreationResult.Unresolved -> work.copy(reconcile = close, attempts = attempts, nextAttemptMilliseconds = now() + 1_000)
                        GroupCreationResult.Conflict -> work.copy(status = GroupCreationStatus.NeedsAttention, attempts = attempts)
                        is GroupCreationResult.Deferred -> work.copy(attempts = attempts, nextAttemptMilliseconds = now() + maxOf(1_000, result.delayMilliseconds))
                    }
                    store.updateGroup(work, if (!next.terminal && next.attempts >= 12) next.copy(status = GroupCreationStatus.NeedsAttention) else next)
                    if (next.terminal) deadlines.remove(command.operation)
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    store.updateGroup(work, work.copy(attempts = attempts, status = if (e is ClientFailure.Protocol || e is IllegalArgumentException || attempts >= 12) GroupCreationStatus.NeedsAttention else GroupCreationStatus.Pending,
                        nextAttemptMilliseconds = now() + minOf(60_000, 1_000L shl minOf(attempts, 6))))
                    if (e is ClientFailure.SignedOut) throw e
                }
            }
        }
    }
}
