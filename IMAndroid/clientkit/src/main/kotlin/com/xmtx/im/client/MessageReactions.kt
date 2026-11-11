package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.text.Normalizer

/** Foundation's canonical composition, whitespace/newline and Cc/Cf control checks. */
fun normalizedReaction(value: String): String {
    val result = Normalizer.normalize(value, Normalizer.Form.NFC)
    require(result.isNotEmpty() && result.toByteArray(Charsets.UTF_8).size <= 16 && result.codePoints().allMatch {
        !Character.isWhitespace(it) && !Character.isSpaceChar(it) && it != 0x85 &&
            Character.getType(it) !in setOf(Character.CONTROL.toInt(), Character.FORMAT.toInt(), Character.SURROGATE.toInt())
    }) { "表情须为不含空白或控制字符的 1–16 UTF-8 字节" }
    return result
}
@Serializable data class ReactionIntent(val actor: UserId, val room: RoomId, val message: MessageId, val operation: String,
    val reaction: String, val present: Boolean, val deadline: Long) {
    init {
        require(uuidId(actor.value) == actor.value && uuidId(room.value) == room.value && uuidId(message.value) == message.value && uuidId(operation) == operation)
        require(normalizedReaction(reaction) == reaction && deadline > 0)
    }
    val orderingKey get() = "${room.value}/${message.value}/${actor.value}/$reaction"
}
@Serializable data class ReactionCommand(val intent: ReactionIntent, val revision: Long) {
    init { require(revision in 0 until Long.MAX_VALUE) }
    fun identity() = buildJsonObject {
        put("accountID", wireId(intent.actor.value)); put("scope", buildJsonObject { put("message", buildJsonObject { put("_0", wireId(intent.room.value)); put("_1", wireId(intent.message.value)) }) })
        put("operation", buildJsonObject { put("reaction", buildJsonObject { put("_0", wireId(intent.operation)) }) })
    }
    val fingerprint get() = OperationFingerprint("reaction").apply {
        unsigned("expectedReactionRevision", revision); unsigned("firstSubmissionDeadline", intent.deadline)
        text("identity", "${intent.actor.value}/message/${intent.room.value}/${intent.message.value}/reaction/${intent.operation}")
        text("reaction", intent.reaction); text("targetState", if(intent.present) "present" else "absent")
    }.digest()
    fun payload() = buildJsonObject {
        put("roomID", wireId(intent.room.value)); put("actorUserID", wireId(intent.actor.value)); put("operationID", wireId(intent.operation)); put("messageID", wireId(intent.message.value))
        put("reaction", intent.reaction); put("targetState", if(intent.present) "present" else "absent"); put("expectedReactionRevision", revision); put("firstSubmissionDeadlineMilliseconds", intent.deadline)
    }
    fun recovery(close: Boolean) = buildJsonObject { put("identity", identity()); put("fingerprint", fingerprintPayload(fingerprint)); put("action", if(close) "closeIfAbsent" else "query") }
    internal fun validateProof(value: JsonObject) {
        val identity = value.objectValue("identity"); val scope = identity.objectValue("scope"); val operation = identity.objectValue("operation")
        if(UserId(identity.identifier("accountID")) != intent.actor || scope.keys != setOf("message") || operation.keys != setOf("reaction") ||
            RoomId(scope.objectValue("message").identifier("_0")) != intent.room || MessageId(scope.objectValue("message").identifier("_1")) != intent.message ||
            uuidId(operation.objectValue("reaction").identifier("_0")) != intent.operation) throw ClientFailure.Protocol()
        val fp = value.objectValue("fingerprint"); if(fp.reactionLong("version") != 1L || fp.string("digest") != fingerprint) throw ClientFailure.Protocol()
    }
}
@Serializable enum class ReactionStatus { Draft, PreparationPaused, Pending, NeedsAttention, Committed, Rejected, Conflicted, Closed, Expired, Cancelled }
@Serializable data class ReactionWork(val intent: ReactionIntent, val command: ReactionCommand? = null, val status: ReactionStatus = ReactionStatus.Draft,
    val preparationAttempts: Int = 0, val preparationStarted: Long? = null, val attempts: Int = 0, val nextAttempt: Long = 0,
    val reconcile: Boolean = false, val receipt: String? = null, val reason: String? = null,
    /** null denotes a legacy row; true survives retries, cancellation and process restart. */
    val executionStarted: Boolean? = null) {
    val terminal get() = status in setOf(ReactionStatus.Committed, ReactionStatus.Rejected, ReactionStatus.Conflicted, ReactionStatus.Closed, ReactionStatus.Expired, ReactionStatus.Cancelled)
}
data class ReactionBaseline(val actor: UserId, val room: RoomId, val message: MessageId, val reaction: String, val present: Boolean, val revision: Long)
data class ReactionEvent(val sequence: Long, val event: String)
data class ReactionCommit(val present: Boolean, val revision: Long, val event: ReactionEvent?)
sealed interface ReactionResult {
    data class Receipt(val status: ReactionStatus, val commit: ReactionCommit?, val reason: String?, val wire: String) : ReactionResult
    data class Deferred(val delayMilliseconds: Long) : ReactionResult
    data object Unresolved : ReactionResult
    data object Conflict : ReactionResult
}
class ReactionBackpressure(val delayMilliseconds: Long) : Exception("稍后重试表情反应")
class MessageReactionClient(private val transport: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun baseline(intent: ReactionIntent): ReactionBaseline {
        val response = transport.request("/v2/rooms/${intent.room.value}/message-reactions/${intent.message.value}", query = "reaction" to intent.reaction)
        if(response.status in setOf(429,503)) throw ReactionBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it, now()) } ?: 5000)
        if(response.status != 200) throw response.failure()
        val value = response.body
        val baseline = ReactionBaseline(UserId(value.identifier("actorUserID")), RoomId(value.identifier("roomID")), MessageId(value.identifier("messageID")),
            normalizedReaction(value.reactionText("reaction")), value.reactionState(), value.reactionLong("revision"))
        if(baseline.actor != intent.actor || baseline.room != intent.room || baseline.message != intent.message || baseline.reaction != intent.reaction || baseline.revision < 0 || baseline.revision == 0L && baseline.present) throw ClientFailure.Protocol()
        return baseline
    }
    suspend fun execute(command: ReactionCommand, recover: Boolean, close: Boolean): ReactionResult {
        val action = if(recover) "operations/recover" else "change"
        val response = transport.request("/v2/rooms/${command.intent.room.value}/message-reactions/$action", if(recover) command.recovery(close) else command.payload())
        if(response.status !in setOf(200,429,503)) throw response.failure()
        val root = response.body; if(root.size != 1) throw ClientFailure.Protocol()
        if(response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when(val key = root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue(key).objectValue("_0"))
            "deferred" -> { val hint = root.objectValue(key).objectValue("_0"); command.validateProof(hint); ReactionResult.Deferred(retryHintDelay(hint, response, now())) }
            "unresolved" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); ReactionResult.Unresolved }
            "fingerprintConflict" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); ReactionResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        fun decodeReceipt(command: ReactionCommand, value: JsonObject): ReactionResult.Receipt {
            command.validateProof(value); if(value.reactionLong("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome"); if(outcome.size != 1) throw ClientFailure.Protocol()
            var commit: ReactionCommit? = null; var reason: String? = null
            val status = when(val key = outcome.keys.single()) {
                "committed" -> {
                    val fields = outcome.objectValue(key).objectValue("_0")
                    val event = fields["event"]?.takeUnless { it is JsonNull }?.jsonObject?.let {
                        ReactionEvent(it.reactionLong("roomSequence"), uuidId(it.identifier("eventID"))).also { proof -> if(proof.sequence <= 0) throw ClientFailure.Protocol() }
                    }
                    commit = ReactionCommit(fields.reactionState(), fields.reactionLong("revision"), event)
                    if(commit.present != command.intent.present || commit.revision != command.revision + 1) throw ClientFailure.Protocol()
                    ReactionStatus.Committed
                }
                "rejected" -> {
                    val rejected = outcome.objectValue(key).objectValue("_0"); if(rejected.size != 1) throw ClientFailure.Protocol()
                    reason = rejected.keys.single(); val fields = rejected.objectValue(reason)
                    if(reason == "revisionConflict") { if(fields.reactionLong("current") < 0) throw ClientFailure.Protocol(); ReactionStatus.Conflicted }
                    else { if(reason !in setOf("expiredUnsubmitted","permissionDenied","roomNotFound","messageNotFound","messageWithdrawn","reactionLimitReached") || fields.isNotEmpty()) throw ClientFailure.Protocol(); ReactionStatus.Rejected }
                }
                "closed" -> { if(outcome.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); ReactionStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            return ReactionResult.Receipt(status, commit, reason, value.toString())
        }
    }
}
private fun JsonObject.reactionText(key: String) = get(key)?.jsonPrimitive?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
private fun JsonObject.reactionLong(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
private fun JsonObject.reactionState(): Boolean = when(string("targetState")) { "present" -> true; "absent" -> false; else -> throw ClientFailure.Protocol() }
interface MessageReactionStore {
    suspend fun reactionWorks(): PersistentList<ReactionWork>
    /** Exact journal observation; persistent adapters use the operation primary key. */
    suspend fun reactionWork(operation:String): ReactionWork? = reactionWorks().firstOrNull {it.intent.operation==operation}
    suspend fun enqueueReaction(intent: ReactionIntent): ReactionWork
    suspend fun updateReaction(expected: ReactionWork, updated: ReactionWork)
}

/** Public counts come exclusively from room log effects, never from own-key HTTP baselines/receipts. */
data class MessageReactionSummary(val room: RoomId, val message: MessageId, val reaction: String, val count: Int, val own: Boolean)
@Serializable data class ReactionEffect(val room: RoomId, val message: MessageId, val actor: UserId, val reaction: String,
    val present: Boolean, val sequence: Long, val source: String) {
    companion object {
        fun decode(source: String, value: JsonObject, expectedSequence: Long): ReactionEffect {
            val reaction = value.reactionText("reaction"); val sequence = value.reactionLong("room_sequence")
            if(value.string("event_type") != "message.reaction_changed" || reaction.isEmpty() || reaction.toByteArray().size > 16 || sequence <= 0 || sequence != expectedSequence) throw ClientFailure.Protocol()
            val present = when(value.string("action")) { "add" -> true; "remove" -> false; else -> throw ClientFailure.Protocol() }
            return ReactionEffect(RoomId(value.reactionText("room_id")), MessageId(value.reactionText("message_id")), UserId(value.reactionText("actor_user_id")), reaction, present, sequence, canonicalId(source))
        }
    }
}
