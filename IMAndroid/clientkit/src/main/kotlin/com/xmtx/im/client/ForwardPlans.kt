package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

internal open class ForwardListSerializer<T>(serializer: KSerializer<T>) : KSerializer<PersistentList<T>> {
    private val delegate = ListSerializer(serializer)
    override val descriptor = delegate.descriptor
    override fun serialize(encoder: Encoder, value: PersistentList<T>) = delegate.serialize(encoder, value)
    override fun deserialize(decoder: Decoder) = delegate.deserialize(decoder).toPersistentList()
}
internal object ForwardSourcesSerializer : ForwardListSerializer<ForwardSource>(ForwardSource.serializer())
internal object ForwardRoomsSerializer : ForwardListSerializer<RoomId>(RoomId.serializer())
internal object ForwardItemsSerializer : ForwardListSerializer<ForwardItem>(ForwardItem.serializer())
internal object ForwardChildrenSerializer : ForwardListSerializer<ForwardChild>(ForwardChild.serializer())
@Serializable data class ForwardSource(val room: RoomId, val message: MessageId, val revision: Long) {
    init { require(uuidId(room.value) == room.value && uuidId(message.value) == message.value && revision > 0) }
    fun payload() = buildJsonObject { put("roomID", room.value); put("messageID", message.value); put("revision", revision) }
}
@Serializable data class ForwardCommand(val actor: UserId, val operation: String,
    @Serializable(with = ForwardSourcesSerializer::class) val sources: PersistentList<ForwardSource>,
    @Serializable(with = ForwardRoomsSerializer::class) val targets: PersistentList<RoomId>, val deadline: Long) {
    init {
        require(uuidId(actor.value) == actor.value && uuidId(operation) == operation && deadline > 0)
        require(sources.size in 1..100 && targets.size in 1..10 && sources.map { it.message }.distinct().size == sources.size && targets.distinct().size == targets.size)
        require(targets.all { uuidId(it.value) == it.value })
    }
    val childCount get() = ((sources.size + 19) / 20) * targets.size
    val storageKey get() = "${actor.value}/account/${actor.value}/forwardMessage/$operation"
    fun identity() = buildJsonObject {
        put("accountID", wireId(actor.value)); put("scope", buildJsonObject { put("account", buildJsonObject { put("_0", wireId(actor.value)) }) })
        put("operation", buildJsonObject { put("forwardMessage", buildJsonObject { put("_0", wireId(operation)) }) })
    }
    val fingerprint get() = OperationFingerprint("forwardMessage").apply {
        unsigned("firstSubmissionDeadline", deadline); text("identity", storageKey)
        orderedText("sources", sources.flatMap { listOf(it.room.value, it.message.value, it.revision.toString()) })
        unsigned("sourcesPerChild", 20); orderedText("targets", targets.map { it.value })
    }.digest()
    fun childSources(index: Int): PersistentList<ForwardSource> {
        require(index in 0 until childCount); val start = index / targets.size * 20
        return sources.subList(start, minOf(start + 20, sources.size)).toPersistentList()
    }
    fun childTarget(index: Int): RoomId { require(index in 0 until childCount); return targets[index % targets.size] }
    fun childOperation(index: Int): String {
        require(index in 0 until childCount)
        val parent = UUID.fromString(operation)
        val bytes = "im-v2-forward-chunk-uuid-v1".toByteArray() + ByteBuffer.allocate(24).putLong(parent.mostSignificantBits).putLong(parent.leastSignificantBits).putLong(index.toLong()).array()
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        digest[6] = ((digest[6].toInt() and 15) or 128).toByte(); digest[8] = ((digest[8].toInt() and 63) or 128).toByte()
        val uuid = ByteBuffer.wrap(digest); return UUID(uuid.long, uuid.long).toString().uppercase()
    }
    fun payload() = buildJsonObject {
        put("actorUserID", wireId(actor.value)); put("firstSubmissionDeadlineMilliseconds", deadline)
        put("command", buildJsonObject { put("operationID", wireId(operation)); put("sources", JsonArray(sources.map { it.payload() })); put("targetRoomIDs", JsonArray(targets.map { wireId(it.value) })) })
    }
    fun recovery(action: String) = buildJsonObject {
        require(action in setOf("query", "closeIfUnstarted", "cancelRemaining")); put("command", payload()); put("action", action)
    }
    internal fun validateProof(value: JsonObject, identityKey: String = "identity", fingerprintKey: String = "fingerprint") {
        val identity = value.objectValue(identityKey); val scope = identity.objectValue("scope"); val ref = identity.objectValue("operation")
        if(UserId(identity.identifier("accountID")) != actor || scope.keys != setOf("account") || ref.keys != setOf("forwardMessage") ||
            UserId(scope.objectValue("account").identifier("_0")) != actor || uuidId(ref.objectValue("forwardMessage").identifier("_0")) != operation) throw ClientFailure.Protocol()
        val fp = value.objectValue(fingerprintKey); if(fp.forwardLong("version") != 1L || fp.forwardText("digest") != fingerprint) throw ClientFailure.Protocol()
    }
}
@Serializable data class ForwardItem(val source: MessageId, val target: RoomId, val message: MessageId? = null, val sequence: Long? = null, val rejection: String? = null)
@Serializable enum class ForwardChildState { Pending, Processing, Completed, Cancelled }
@Serializable data class ForwardChild(val index: Int, val operation: String, val state: ForwardChildState,
    val resolvedAt: Long? = null, @Serializable(with = ForwardItemsSerializer::class) val items: PersistentList<ForwardItem> = persistentListOf())
@Serializable data class ForwardProgress(val execution: String,
    @Serializable(with = ForwardChildrenSerializer::class) val children: PersistentList<ForwardChild>, val wire: String) {
    val succeeded get() = children.sumOf { child -> child.items.count { it.message != null } }
    val rejected get() = children.sumOf { child -> child.items.count { it.rejection != null } }
    fun cancelled(command: ForwardCommand) = children.filter { it.state == ForwardChildState.Cancelled }.sumOf { command.childSources(it.index).size }
    fun advances(old: ForwardProgress): Boolean {
        if(old.children.size != children.size || old.execution == "completed" && execution != "completed" ||
            old.execution == "cancelling" && execution !in setOf("cancelling", "completed") || old.execution == "processing" && execution == "waitingToStart") return false
        return old.children.zip(children).all { (before, after) -> when(before.state) {
            ForwardChildState.Completed, ForwardChildState.Cancelled -> before == after
            ForwardChildState.Processing -> after.state !in setOf(ForwardChildState.Pending, ForwardChildState.Cancelled)
            ForwardChildState.Pending -> true
        } }
    }
}
@Serializable enum class ForwardStatus { Pending, NeedsAttention, Committed, Rejected, Closed, Cancelled, Expired }
@Serializable data class ForwardWork(val command: ForwardCommand, val status: ForwardStatus = ForwardStatus.Pending,
    val progress: ForwardProgress? = null, val submissionStarted: Boolean = false, val reconcile: Boolean = false, val cancelRequested: Boolean = false,
    val attempts: Int = 0, val nextAttempt: Long = 0, val receipt: String? = null, val reason: String? = null) {
    val terminal get() = status in setOf(ForwardStatus.Committed, ForwardStatus.Rejected, ForwardStatus.Closed, ForwardStatus.Cancelled, ForwardStatus.Expired)
    val succeeded get() = progress?.succeeded ?: 0
    val rejected get() = progress?.rejected ?: 0
    val cancelled get() = if(status == ForwardStatus.Cancelled) command.sources.size * command.targets.size else progress?.cancelled(command) ?: 0
    val unresolved get() = if(status == ForwardStatus.Expired) 0 else command.sources.size * command.targets.size - succeeded - rejected - cancelled
}
sealed interface ForwardResult {
    data class Processing(val progress: ForwardProgress) : ForwardResult
    data class Receipt(val status: ForwardStatus, val progress: ForwardProgress, val wire: String) : ForwardResult
    data class Deferred(val delay: Long) : ForwardResult
    data object Unresolved : ForwardResult
    data object Conflict : ForwardResult
}
class ForwardPlanClient(private val transport: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun execute(command: ForwardCommand, recovery: String? = null): ForwardResult {
        val body = recovery?.let { command.recovery(it) } ?: command.payload()
        require(body.toString().toByteArray().size <= 65536)
        val response = transport.request("/v2/forward-plans/${if(recovery == null) "submit" else "operations/recover"}", body, maximumBytes = 1_048_576)
        if(response.status !in setOf(200,429,503)) throw response.failure()
        val root = response.body; if(root.size != 1) throw ClientFailure.Protocol()
        if(response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when(val key = root.keys.single()) {
            "receipt" -> decodeResolved(command, root.objectValue(key).objectValue("_0"))
            "processing" -> ForwardResult.Processing(decodeProgress(command, root.objectValue(key).objectValue("_0")))
            "deferred" -> { val hint = root.objectValue(key).objectValue("_0"); command.validateProof(hint); ForwardResult.Deferred(retryHintDelay(hint, response, now())) }
            "unresolved" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); ForwardResult.Unresolved }
            "fingerprintConflict" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); ForwardResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        private val reasons = setOf("sourceUnavailable", "sourceRevisionConflict", "permissionDenied", "targetUnavailable", "resourceUnavailable", "contentRejected", "capacityExceeded", "closedBeforeExecution", "identityConflict")
        fun decodeProgress(command: ForwardCommand, value: JsonObject): ForwardProgress {
            command.validateProof(value)
            val execution = value.forwardText("executionState"); if(execution !in setOf("waitingToStart", "processing", "cancelling", "completed")) throw ClientFailure.Protocol()
            val children = value["children"]?.jsonArray ?: throw ClientFailure.Protocol(); if(children.size != command.childCount) throw ClientFailure.Protocol()
            val messages = mutableSetOf<MessageId>(); val sequences = mutableSetOf<Pair<RoomId,Long>>()
            val parsed = children.mapIndexed { index, element ->
                val child = element.jsonObject; val operation = command.childOperation(index)
                if(child.forwardLong("index") != index.toLong() || uuidId(child.identifier("operationID")) != operation) throw ClientFailure.Protocol()
                val state = child.objectValue("state"); if(state.size != 1) throw ClientFailure.Protocol()
                when(val key = state.keys.single()) {
                    "pending", "processing" -> {
                        if(state.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol()
                        ForwardChild(index, operation, if(key == "pending") ForwardChildState.Pending else ForwardChildState.Processing)
                    }
                    "resolved" -> {
                        val receipt = state.objectValue(key).objectValue("_0"); command.validateProof(receipt, "parentIdentity", "parentFingerprint")
                        val resolvedAt = receipt.forwardLong("resolvedAtMilliseconds")
                        if(receipt.forwardLong("index") != index.toLong() || uuidId(receipt.identifier("operationID")) != operation || resolvedAt <= 0) throw ClientFailure.Protocol()
                        val outcome = receipt.objectValue("outcome"); if(outcome.size != 1) throw ClientFailure.Protocol()
                        when(val kind = outcome.keys.single()) {
                            "cancelledBeforeStart" -> {
                                if(outcome.objectValue(kind).isNotEmpty()) throw ClientFailure.Protocol()
                                ForwardChild(index, operation, ForwardChildState.Cancelled, resolvedAt)
                            }
                            "completed" -> {
                                val items = outcome.objectValue(kind)["_0"]?.jsonArray ?: throw ClientFailure.Protocol()
                                val expected = command.childSources(index); if(items.size != expected.size) throw ClientFailure.Protocol()
                                val results = items.mapIndexed { offset, item ->
                                    val fields = item.jsonObject; val source = MessageId(fields.identifier("sourceMessageID")); val target = RoomId(fields.identifier("targetRoomID"))
                                    if(source != expected[offset].message || target != command.childTarget(index)) throw ClientFailure.Protocol()
                                    val result = fields.objectValue("outcome"); if(result.size != 1) throw ClientFailure.Protocol()
                                    when(val resultKind = result.keys.single()) {
                                        "accepted" -> {
                                            val accepted = result.objectValue(resultKind).objectValue("_0"); val message = MessageId(uuidId(accepted.identifier("messageID"))); val sequence = accepted.forwardLong("roomSequence")
                                            if(sequence <= 0 || !messages.add(message) || !sequences.add(target to sequence)) throw ClientFailure.Protocol()
                                            ForwardItem(source, target, message, sequence)
                                        }
                                        "rejected" -> {
                                            val reason = result.objectValue(resultKind).forwardText("_0"); if(reason !in reasons) throw ClientFailure.Protocol()
                                            ForwardItem(source, target, rejection = reason)
                                        }
                                        else -> throw ClientFailure.Protocol()
                                    }
                                }.toPersistentList()
                                ForwardChild(index, operation, ForwardChildState.Completed, resolvedAt, results)
                            }
                            else -> throw ClientFailure.Protocol()
                        }
                    }
                    else -> throw ClientFailure.Protocol()
                }
            }.toPersistentList()
            if(execution == "completed" && parsed.any { it.state !in setOf(ForwardChildState.Completed, ForwardChildState.Cancelled) } ||
                execution == "waitingToStart" && parsed.any { it.state != ForwardChildState.Pending }) throw ClientFailure.Protocol()
            return ForwardProgress(execution, parsed, value.toString())
        }
        fun summary(command: ForwardCommand, progress: ForwardProgress): JsonObject {
            require(progress.execution == "completed" && decodeProgress(command, Json.parseToJsonElement(progress.wire).jsonObject) == progress)
            val ordered = buildList {
                progress.children.forEach { child ->
                    add(child.index.toString()); add(child.operation)
                    if(child.state == ForwardChildState.Cancelled) add("cancelledBeforeStart")
                    else {
                        require(child.state == ForwardChildState.Completed); add("completed"); add(child.items.size.toString())
                        child.items.forEach { item ->
                            add(item.source.value); add(item.target.value)
                            if(item.message != null) { add("accepted"); add(item.message.value); add(requireNotNull(item.sequence).toString()) }
                            else { add("rejected"); add(requireNotNull(item.rejection)) }
                        }
                    }
                }
            }
            val digest = OperationFingerprint("forwardMessage").apply {
                text("identity", command.storageKey); bytes("manifestFingerprint", Base64.getDecoder().decode(command.fingerprint)); orderedText("orderedResults", ordered)
            }.digest()
            return buildJsonObject {
                put("childCount", command.childCount); put("succeededItemCount", progress.succeeded); put("rejectedItemCount", progress.rejected)
                put("cancelledItemCount", progress.cancelled(command)); put("resultDigest", digest)
            }
        }
        fun decodeResolved(command: ForwardCommand, value: JsonObject): ForwardResult.Receipt {
            val receipt = value.objectValue("receipt"); command.validateProof(receipt)
            if(receipt.forwardLong("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val progress = decodeProgress(command, value.objectValue("progress")); if(progress.execution != "completed") throw ClientFailure.Protocol()
            val outcome = receipt.objectValue("outcome"); if(outcome.size != 1) throw ClientFailure.Protocol()
            val status = when(val key = outcome.keys.single()) {
                "completed" -> {
                    val expected = summary(command, progress); val supplied = outcome.objectValue(key).objectValue("_0")
                    for(field in listOf("childCount", "succeededItemCount", "rejectedItemCount", "cancelledItemCount")) if(supplied.forwardLong(field) != expected.forwardLong(field)) throw ClientFailure.Protocol()
                    if(supplied.forwardText("resultDigest") != expected.forwardText("resultDigest")) throw ClientFailure.Protocol()
                    ForwardStatus.Committed
                }
                "rejected" -> {
                    if(outcome.objectValue(key).forwardText("_0") != "expiredUnsubmitted" || progress.children.any { it.state != ForwardChildState.Cancelled }) throw ClientFailure.Protocol()
                    ForwardStatus.Rejected
                }
                "closedBeforeStart" -> {
                    if(outcome.objectValue(key).isNotEmpty() || progress.children.any { it.state != ForwardChildState.Cancelled }) throw ClientFailure.Protocol()
                    ForwardStatus.Closed
                }
                else -> throw ClientFailure.Protocol()
            }
            return ForwardResult.Receipt(status, progress, value.toString())
        }
    }
}
private fun JsonObject.forwardLong(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
private fun JsonObject.forwardText(key: String) = get(key)?.jsonPrimitive?.takeIf { it.isString }?.content ?: throw ClientFailure.Protocol()
interface ForwardPlanStore {
    suspend fun forwardWorks(): PersistentList<ForwardWork>
    /** Exact journal observation; persistent adapters should use their operation primary key. */
    suspend fun forwardWork(operation:String): ForwardWork? = forwardWorks().firstOrNull {it.command.operation==operation}
    suspend fun enqueueForward(command: ForwardCommand): ForwardWork
    suspend fun updateForward(expected: ForwardWork, updated: ForwardWork)
}
