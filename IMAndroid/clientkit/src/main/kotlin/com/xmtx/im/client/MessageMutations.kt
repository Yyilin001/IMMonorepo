package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable data class MessageMutationCommand(val actor: UserId, val room: RoomId, val message: MessageId, val operation: String,
    val revision: Long, val text: String?, val deadline: Long) {
    init {
        require(uuidId(actor.value) == actor.value && uuidId(room.value) == room.value && uuidId(message.value) == message.value && uuidId(operation) == operation)
        require(revision in 1 until Long.MAX_VALUE && deadline > 0)
        require(text == null || text.isNotEmpty() && text.toByteArray(Charsets.UTF_8).size <= 65_536) { "消息内容须为 1–65536 UTF-8 字节" }
    }
    val kind get() = if(text == null) "withdrawMessage" else "editMessage"
    val orderingKey get() = "${room.value}/${message.value}"
    fun identity() = buildJsonObject {
        put("accountID", wireId(actor.value)); put("scope", buildJsonObject { put("message", buildJsonObject { put("_0", wireId(room.value)); put("_1", wireId(message.value)) }) })
        put("operation", buildJsonObject { put(kind, buildJsonObject { put("_0", wireId(operation)) }) })
    }
    val fingerprint get() = OperationFingerprint(kind).apply {
        unsigned("expectedRevision", revision); unsigned("firstSubmissionDeadline", deadline)
        text("identity", "${actor.value}/message/${room.value}/${message.value}/$kind/$operation")
        if(this@MessageMutationCommand.text == null) absent("text") else text("text", this@MessageMutationCommand.text)
    }.digest()
    fun payload() = buildJsonObject {
        put("roomID", wireId(room.value)); put("actorUserID", wireId(actor.value)); put("operationID", wireId(operation)); put("messageID", wireId(message.value))
        put("expectedMessageRevision", revision); if(text != null) put("text", text); put("firstSubmissionDeadlineMilliseconds", deadline)
    }
    fun recovery(close: Boolean) = buildJsonObject { put("identity", identity()); put("fingerprint", fingerprintPayload(fingerprint)); put("action", if(close) "closeIfAbsent" else "query") }
    internal fun validateProof(value: JsonObject) {
        val identity = value.objectValue("identity"); val scope = identity.objectValue("scope"); val reference = identity.objectValue("operation")
        if(UserId(identity.identifier("accountID")) != actor || scope.keys != setOf("message") || reference.keys != setOf(kind) ||
            RoomId(scope.objectValue("message").identifier("_0")) != room || MessageId(scope.objectValue("message").identifier("_1")) != message ||
            uuidId(reference.objectValue(kind).identifier("_0")) != operation) throw ClientFailure.Protocol()
        val fp = value.objectValue("fingerprint"); if(fp.mutationLong("version") != 1L || fp.string("digest") != fingerprint) throw ClientFailure.Protocol()
    }
}
@Serializable enum class MutationStatus { Pending, NeedsAttention, Committed, Rejected, Conflicted, Closed }
@Serializable data class MessageMutationWork(val command: MessageMutationCommand, val status: MutationStatus = MutationStatus.Pending,
    val attempts: Int = 0, val nextAttempt: Long = 0, val reconcile: Boolean = false, val receipt: String? = null, val reason: String? = null, val executionStarted: Boolean? = null) {
    companion object { fun fresh(command: MessageMutationCommand) = MessageMutationWork(command, executionStarted = false) }
    val terminal get() = status in setOf(MutationStatus.Committed, MutationStatus.Rejected, MutationStatus.Conflicted, MutationStatus.Closed)
}
data class MutationCommit(val message: MessageId, val revision: Long, val roomSequence: Long, val event: String)
sealed interface MutationResult {
    data class Receipt(val status: MutationStatus, val commit: MutationCommit?, val reason: String?, val wire: String) : MutationResult
    data class Deferred(val delayMilliseconds: Long) : MutationResult
    data object Unresolved : MutationResult
    data object Conflict : MutationResult
}
class MessageMutationClient(private val transport: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun execute(command: MessageMutationCommand, recover: Boolean, close: Boolean): MutationResult {
        val payload = if(recover) command.recovery(close) else command.payload()
        require(payload.toString().toByteArray().size <= 1_048_576)
        val action = if(recover) "operations/recover" else if(command.text == null) "withdraw" else "edit"
        val response = transport.request("/v2/rooms/${command.room.value}/message-mutations/$action", payload)
        if(response.status !in setOf(200,429,503)) throw response.failure()
        val root = response.body; if(root.size != 1) throw ClientFailure.Protocol()
        if(response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when(val key = root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue(key).objectValue("_0"))
            "deferred" -> { val hint = root.objectValue(key).objectValue("_0"); command.validateProof(hint); MutationResult.Deferred(retryHintDelay(hint, response, now())) }
            "unresolved" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); MutationResult.Unresolved }
            "fingerprintConflict" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); MutationResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        fun decodeReceipt(command: MessageMutationCommand, value: JsonObject): MutationResult.Receipt {
            command.validateProof(value); if(value.mutationLong("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome"); if(outcome.size != 1) throw ClientFailure.Protocol()
            var commit: MutationCommit? = null; var reason: String? = null
            val status = when(val key = outcome.keys.single()) {
                "committed" -> {
                    val fields = outcome.objectValue(key).objectValue("_0")
                    commit = MutationCommit(MessageId(fields.identifier("messageID")), fields.mutationLong("messageRevision"), fields.mutationLong("roomSequence"), uuidId(fields.identifier("eventID")))
                    if(commit.message != command.message || commit.revision != command.revision + 1 || commit.roomSequence <= 0) throw ClientFailure.Protocol()
                    MutationStatus.Committed
                }
                "rejected" -> {
                    val rejected = outcome.objectValue(key).objectValue("_0"); if(rejected.size != 1) throw ClientFailure.Protocol()
                    reason = rejected.keys.single(); val fields = rejected.objectValue(reason)
                    if(reason == "revisionConflict") { if(fields.mutationLong("current") <= 0) throw ClientFailure.Protocol(); MutationStatus.Conflicted }
                    else { if(reason !in setOf("expiredUnsubmitted","permissionDenied","roomNotFound","messageNotFound","alreadyWithdrawn") || fields.isNotEmpty()) throw ClientFailure.Protocol(); MutationStatus.Rejected }
                }
                "closed" -> { if(outcome.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); MutationStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            return MutationResult.Receipt(status, commit, reason, value.toString())
        }
    }
}
private fun JsonObject.mutationLong(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
interface MessageMutationStore {
    suspend fun mutationWorks(): PersistentList<MessageMutationWork>
    /** Exact journal observation; persistent adapters use the operation primary key. */
    suspend fun mutationWork(operation:String): MessageMutationWork? = mutationWorks().firstOrNull {it.command.operation==operation}
    /** Atomically creates fresh(command); coalesced existing commands retain their execution history. */
    suspend fun enqueueMutation(command: MessageMutationCommand): MessageMutationWork
    suspend fun updateMutation(expected: MessageMutationWork, updated: MessageMutationWork)
}
