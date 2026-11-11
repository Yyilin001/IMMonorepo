package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.math.BigDecimal
import java.util.Base64

@Serializable sealed interface PersonalTarget {
    val room: RoomId
    @Serializable data class Conversation(override val room: RoomId, val pinned: Boolean = false, val archived: Boolean = false, val muteUntil: Long = 0) : PersonalTarget {
        init { require(muteUntil >= 0) }
    }
    @Serializable data class Favorite(override val room: RoomId, val message: MessageId, val favorited: Boolean) : PersonalTarget
    val kind: String get() = if(this is Conversation) "conversationPreference" else "messageFavorite"
    val key: String get() = "$kind/${room.value}" + if(this is Favorite) "/${message.value}" else ""
}
data class ConversationPatch(val pinned: Boolean? = null, val archived: Boolean? = null, val muteUntil: Long? = null) {
    init { require(pinned != null || archived != null || muteUntil != null); require(muteUntil == null || muteUntil >= 0) }
    fun apply(value: PersonalTarget.Conversation) = value.copy(pinned = pinned ?: value.pinned, archived = archived ?: value.archived, muteUntil = muteUntil ?: value.muteUntil)
}
@Serializable data class PersonalState(val target: PersonalTarget, val revision: Long, val updatedAt: Long) {
    init { require(revision > 0 && updatedAt >= 0) }
    companion object {
        fun projection(kind: String, value: JsonObject): PersonalState {
            val room = RoomId(value.string("room_id"))
            val target = when(kind) {
                "conversation_state" -> PersonalTarget.Conversation(room, value.personalBool("is_pinned"), value.personalBool("is_archived"), value.personalLong("mute_until_ms"))
                "message_favorite" -> PersonalTarget.Favorite(room, MessageId(value.string("message_id")), value.personalBool("is_favorited"))
                else -> throw ClientFailure.Protocol()
            }
            return PersonalState(target, value.personalLong("revision"), value.personalLong("updated_at_ms"))
        }
    }
}
@Serializable data class PersonalCommand(val actor: UserId, val operation: String, val target: PersonalTarget, val revision: Long, val deadline: Long) {
    init { require(uuidId(actor.value) == actor.value && uuidId(operation) == operation && uuidId(target.room.value) == target.room.value && revision in 0 until Long.MAX_VALUE && deadline > 0); if(target is PersonalTarget.Favorite) require(uuidId(target.message.value) == target.message.value) }
    val fingerprint get() = OperationFingerprint(target.kind).apply {
        text("actor", actor.value)
        if(target is PersonalTarget.Conversation) flag("archived", target.archived)
        unsigned("expectedRevision", revision)
        if(target is PersonalTarget.Favorite) flag("favorited", target.favorited)
        unsigned("firstSubmissionDeadline", deadline)
        if(target is PersonalTarget.Favorite) text("message", target.message.value)
        if(target is PersonalTarget.Conversation) { if(target.muteUntil == 0L) absent("muteUntil") else unsigned("muteUntil", target.muteUntil) }
        text("operation", operation)
        if(target is PersonalTarget.Conversation) flag("pinned", target.pinned)
        text("room", target.room.value)
    }.digest()
    fun identity(): JsonObject {
        if(target is PersonalTarget.Conversation) return roomIdentity(actor, target.room, operation, target.kind)
        val favorite = target as PersonalTarget.Favorite
        return buildJsonObject {
            put("accountID", wireId(actor.value)); put("scope", buildJsonObject { put("message", buildJsonObject { put("_0", wireId(target.room.value)); put("_1", wireId(favorite.message.value)) }) })
            put("operation", buildJsonObject { put(target.kind, buildJsonObject { put("_0", wireId(operation)) }) })
        }
    }
    fun recovery(close: Boolean) = buildJsonObject { put("identity", identity()); put("fingerprint", fingerprintPayload(fingerprint)); put("action", if(close) "closeIfAbsent" else "query") }
    fun envelope(): Envelope.Builder = Envelope.newBuilder().apply {
        when(target) {
            is PersonalTarget.Conversation -> setSetConversationState(SetConversationState.newBuilder().setOperationId(operation).setRoomId(target.room.value)
                .setIsPinned(target.pinned).setIsArchived(target.archived).setMuteUntilMs(target.muteUntil).setExpectedRevision(revision).setFirstSubmissionDeadlineMs(deadline))
            is PersonalTarget.Favorite -> setSetMessageFavorite(SetMessageFavorite.newBuilder().setOperationId(operation).setRoomId(target.room.value).setMessageId(target.message.value)
                .setIsFavorited(target.favorited).setExpectedRevision(revision).setFirstSubmissionDeadlineMs(deadline))
        }
    }
    internal fun validateProof(value: JsonObject) {
        val identity = value.objectValue("identity"); val scope = identity.objectValue("scope"); val operationValue = identity.objectValue("operation")
        if(UserId(identity.identifier("accountID")) != actor || operationValue.keys != setOf(target.kind) || uuidId(operationValue.objectValue(target.kind).identifier("_0")) != operation) throw ClientFailure.Protocol()
        if(target is PersonalTarget.Conversation) {
            if(scope.keys != setOf("room") || RoomId(scope.objectValue("room").identifier("_0")) != target.room) throw ClientFailure.Protocol()
        } else {
            val favorite = target as PersonalTarget.Favorite
            if(scope.keys != setOf("message") || RoomId(scope.objectValue("message").identifier("_0")) != target.room || MessageId(scope.objectValue("message").identifier("_1")) != favorite.message) throw ClientFailure.Protocol()
        }
        val fp = value.objectValue("fingerprint"); if(fp.personalLong("version") != 1L || fp.string("digest") != fingerprint) throw ClientFailure.Protocol()
    }
}
@Serializable enum class PersonalStatus { Queued, Pending, NeedsAttention, Committed, Rejected, Conflicted, Closed, Expired, Cancelled }
@Serializable data class PersonalWork(val actor: UserId, val operation: String, val target: PersonalTarget, val deadline: Long,
    val status: PersonalStatus = PersonalStatus.Queued, val command: PersonalCommand? = null, val attempts: Int = 0,
    val nextAttempt: Long = 0, val reconcile: Boolean = false, val submissionStarted: Boolean = false, val receipt: String? = null, val reason: String? = null) {
    init { require(uuidId(actor.value) == actor.value && uuidId(operation) == operation && deadline > 0) }
    val terminal get() = status in setOf(PersonalStatus.Committed, PersonalStatus.Rejected, PersonalStatus.Conflicted, PersonalStatus.Closed, PersonalStatus.Expired, PersonalStatus.Cancelled)
}
sealed interface PersonalResult {
    data class Receipt(val status: PersonalStatus, val state: PersonalState?, val reason: String?, val wire: String) : PersonalResult
    data object Unresolved : PersonalResult
    data object Conflict : PersonalResult
}
class PersonalBackpressure(val delayMilliseconds: Long) : Exception("请稍后核对")
class PersonalPreferenceClient(private val transport: EnvelopeTransport, private val recovery: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun submit(command: PersonalCommand): PersonalResult.Receipt {
        val response = transport.request(command.envelope())
        if(!response.hasPersonalPreferenceReceipt()) throw ClientFailure.Protocol()
        return decodeWire(command, response.personalPreferenceReceipt)
    }
    suspend fun recover(command: PersonalCommand, close: Boolean): PersonalResult {
        val response = recovery.request("/v2/rooms/${command.target.room.value}/personal-preferences/operations/recover", command.recovery(close))
        if(response.status in setOf(429,503)) throw PersonalBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it, now()) } ?: 0)
        if(response.status != 200) throw response.failure()
        val root = response.body; if(root.size != 1) throw ClientFailure.Protocol()
        return when(val key = root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue(key).objectValue("_0"))
            "unresolved" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); PersonalResult.Unresolved }
            "fingerprintConflict" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); PersonalResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        fun decodeReceipt(command: PersonalCommand, value: JsonObject): PersonalResult.Receipt {
            command.validateProof(value); if(value.personalLong("resolvedAtMilliseconds") < 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome"); if(outcome.size != 1) throw ClientFailure.Protocol()
            var state: PersonalState? = null; var reason: String? = null
            val status = when(val key = outcome.keys.single()) {
                "committed" -> {
                    val wrapped = outcome.objectValue(key).objectValue("_0"); if(wrapped.size != 1) throw ClientFailure.Protocol()
                    val stateKind = wrapped.keys.single(); val fields = wrapped.objectValue(stateKind).objectValue("_0")
                    val room = RoomId(fields.identifier("roomID"))
                    val target = when(stateKind) {
                        "conversationState" -> PersonalTarget.Conversation(room, fields.personalBool("isPinned"), fields.personalBool("isArchived"), fields["muteUntil"]?.takeUnless { it is JsonNull }?.let(::dateMilliseconds) ?: 0)
                        "messageFavorite" -> PersonalTarget.Favorite(room, MessageId(fields.identifier("messageID")), fields.personalBool("isFavorited"))
                        else -> throw ClientFailure.Protocol()
                    }
                    state = PersonalState(target, fields.personalLong("revision"), dateMilliseconds(fields["updatedAt"] ?: throw ClientFailure.Protocol(), exact = false))
                    if(target != command.target || state.revision != command.revision + 1) throw ClientFailure.Protocol()
                    PersonalStatus.Committed
                }
                "rejected" -> {
                    val rejected = outcome.objectValue(key).objectValue("_0"); if(rejected.size != 1) throw ClientFailure.Protocol()
                    reason = rejected.keys.single(); val fields = rejected.objectValue(reason)
                    if(reason == "revisionConflict") { if(fields.personalLong("current") < 0) throw ClientFailure.Protocol(); PersonalStatus.Conflicted }
                    else { if(reason !in setOf("permissionDenied","notFound","expiredUnsubmitted") || fields.isNotEmpty()) throw ClientFailure.Protocol(); PersonalStatus.Rejected }
                }
                "closed" -> { if(outcome.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); PersonalStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            return PersonalResult.Receipt(status, state, reason, value.toString())
        }
        fun decodeWire(command: PersonalCommand, value: PersonalPreferenceReceipt): PersonalResult.Receipt {
            if(UserId(value.actorUserId) != command.actor || uuidId(value.operationId) != command.operation || RoomId(value.roomId) != command.target.room || value.fingerprintVersion != 1 ||
                Base64.getEncoder().encodeToString(value.fingerprint.toByteArray()) != command.fingerprint || value.resolvedAtMs < 0) throw ClientFailure.Protocol()
            when(val target = command.target) {
                is PersonalTarget.Conversation -> if(value.kind != PersonalPreferenceReceipt.Kind.CONVERSATION_STATE || value.messageId.isNotEmpty()) throw ClientFailure.Protocol()
                is PersonalTarget.Favorite -> if(value.kind != PersonalPreferenceReceipt.Kind.MESSAGE_FAVORITE || MessageId(value.messageId) != target.message) throw ClientFailure.Protocol()
            }
            val outcome = buildJsonObject {
                when(value.outcomeCase) {
                    PersonalPreferenceReceipt.OutcomeCase.CONVERSATION_STATE -> {
                        val fields = value.conversationState
                        put("committed", buildJsonObject { put("_0", buildJsonObject { put("conversationState", buildJsonObject { put("_0", buildJsonObject {
                            put("roomID", wireId(RoomId(fields.roomId).value)); put("isPinned", fields.isPinned); put("isArchived", fields.isArchived)
                            if(fields.muteUntilMs != 0L) put("muteUntil", dateValue(fields.muteUntilMs)); put("updatedAt", dateValue(fields.updatedAtMs)); put("revision", fields.revision)
                        }) }) }) })
                    }
                    PersonalPreferenceReceipt.OutcomeCase.MESSAGE_FAVORITE -> {
                        val fields = value.messageFavorite
                        put("committed", buildJsonObject { put("_0", buildJsonObject { put("messageFavorite", buildJsonObject { put("_0", buildJsonObject {
                            put("roomID", wireId(RoomId(fields.roomId).value)); put("messageID", wireId(MessageId(fields.messageId).value)); put("isFavorited", fields.isFavorited)
                            put("updatedAt", dateValue(fields.updatedAtMs)); put("revision", fields.revision)
                        }) }) }) })
                    }
                    PersonalPreferenceReceipt.OutcomeCase.REJECTED -> {
                        val rejected = value.rejected
                        val reason = when(rejected.reason) {
                            PersonalPreferenceRejection.Reason.REVISION_CONFLICT -> "revisionConflict"
                            PersonalPreferenceRejection.Reason.PERMISSION_DENIED -> "permissionDenied"
                            PersonalPreferenceRejection.Reason.NOT_FOUND -> "notFound"
                            PersonalPreferenceRejection.Reason.EXPIRED_UNSUBMITTED -> "expiredUnsubmitted"
                            else -> throw ClientFailure.Protocol()
                        }
                        if((reason == "revisionConflict") != rejected.hasCurrentRevision() || rejected.currentRevision < 0) throw ClientFailure.Protocol()
                        put("rejected", buildJsonObject { put("_0", buildJsonObject { put(reason, buildJsonObject { if(rejected.hasCurrentRevision()) put("current", rejected.currentRevision) }) }) })
                    }
                    PersonalPreferenceReceipt.OutcomeCase.CLOSED -> { if(!value.closed) throw ClientFailure.Protocol(); put("closed", buildJsonObject {}) }
                    else -> throw ClientFailure.Protocol()
                }
            }
            return decodeReceipt(command, buildJsonObject { put("identity", command.identity()); put("fingerprint", fingerprintPayload(command.fingerprint)); put("resolvedAtMilliseconds", value.resolvedAtMs); put("outcome", outcome) })
        }
    }
}
private fun JsonObject.personalLong(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
private fun JsonObject.personalBool(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.booleanOrNull ?: throw ClientFailure.Protocol()
private fun dateValue(milliseconds: Long): JsonPrimitive { if(milliseconds < 0) throw ClientFailure.Protocol(); return JsonPrimitive(BigDecimal.valueOf(milliseconds).movePointLeft(3).subtract(BigDecimal(978307200))) }
private fun dateMilliseconds(value: JsonElement, exact: Boolean = true): Long {
    val primitive = value as? JsonPrimitive ?: throw ClientFailure.Protocol(); if(primitive.isString) throw ClientFailure.Protocol()
    // Integer millisecond values synthesized from TLS must survive persistence
    // without a second lossy binary epoch conversion (for example .002 seconds).
    val decimalMilliseconds = try { BigDecimal(primitive.content).add(BigDecimal(978307200)).movePointRight(3) } catch(_: NumberFormatException) { throw ClientFailure.Protocol() }
    if(decimalMilliseconds.stripTrailingZeros().scale() <= 0) {
        return try { decimalMilliseconds.longValueExact().also { if(it < 0) throw ClientFailure.Protocol() } } catch(_: ArithmeticException) { throw ClientFailure.Protocol() }
    }
    val seconds = primitive.doubleOrNull ?: throw ClientFailure.Protocol()
    // Foundation Date uses binary seconds from 2001. Match its conversion to Unix
    // milliseconds; updatedAt may retain PostgreSQL microseconds in HTTP receipts.
    val milliseconds = (seconds + 978307200.0) * 1000.0
    if(!milliseconds.isFinite() || milliseconds < 0 || milliseconds >= Long.MAX_VALUE.toDouble()) throw ClientFailure.Protocol()
    if(exact && kotlin.math.abs(milliseconds - kotlin.math.round(milliseconds)) > 0.001) throw ClientFailure.Protocol()
    return if(exact) kotlin.math.round(milliseconds).toLong() else milliseconds.toLong()
}

interface PersonalPreferenceStore {
    suspend fun personalWorks(): PersistentList<PersonalWork>
    /** Exact journal observation; persistent adapters should use their operation primary key. */
    suspend fun personalWork(operation:String): PersonalWork? = personalWorks().firstOrNull {it.operation==operation}
    suspend fun enqueueConversation(room: RoomId, patch: ConversationPatch, now: Long): PersonalWork
    suspend fun enqueueFavorite(room: RoomId, message: MessageId, favorite: Boolean, now: Long): PersonalWork
    suspend fun preparePersonal(now: Long)
    suspend fun updatePersonal(expected: PersonalWork, updated: PersonalWork)
}
