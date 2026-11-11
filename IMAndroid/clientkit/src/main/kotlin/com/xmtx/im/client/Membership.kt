package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.util.Base64

@Serializable enum class MembershipAction(val wire: String) { Add("add"), Remove("remove") }
@Serializable data class MembershipIntent(val actor: UserId, val room: RoomId, val operation: String, val target: UserId,
    val action: MembershipAction, val revision: Long, val confirmedUntilMilliseconds: Long) {
    init { require(actor != target || action == MembershipAction.Remove); require(canonicalId(operation) == operation && revision in 0 until Long.MAX_VALUE && confirmedUntilMilliseconds > 0) }
    fun identity() = roomIdentity(actor, room, operation, "membership")
    val fingerprint get() = OperationFingerprint("membership").apply {
        text("action", action.wire); unsigned("confirmedUntil", confirmedUntilMilliseconds); unsigned("expectedMembershipRevision", revision)
        text("identity", "${actor.value}/room/${room.value}/membership/$operation"); text("target", target.value)
    }.digest()
    fun payload() = buildJsonObject {
        put("roomID", wireId(room.value)); put("actorUserID", wireId(actor.value)); put("operationID", wireId(operation)); put("targetUserID", wireId(target.value))
        put("action", action.wire); put("expectedMembershipRevision", revision); put("confirmedUntilMilliseconds", confirmedUntilMilliseconds)
    }
}
@Serializable data class MembershipAdmission(val id: String, val intentFingerprint: String, val action: MembershipAction,
    val revision: Long, val joinedRevision: Long?, val issuedAt: Long, val expiresAt: Long) {
    init {
        require(uuidId(id) == id && revision in 0 until Long.MAX_VALUE && issuedAt > 0 && expiresAt > issuedAt && expiresAt - issuedAt <= 120_000)
        require(if (action == MembershipAction.Add) joinedRevision == null else joinedRevision != null && joinedRevision in 0..revision)
    }
    fun validate(intent: MembershipIntent) {
        if (intentFingerprint != intent.fingerprint || action != intent.action || revision != intent.revision || expiresAt > intent.confirmedUntilMilliseconds) throw ClientFailure.Protocol()
    }
    fun payload(intent: MembershipIntent) = buildJsonObject {
        put("id", wireId(id)); put("identity", intent.identity()); put("intentFingerprint", fingerprintPayload(intentFingerprint)); put("action", action.wire)
        put("membershipRevision", revision); joinedRevision?.let { put("targetJoinedRevision", it) }
        put("issuedAtMilliseconds", issuedAt); put("expiresAtMilliseconds", expiresAt)
    }
}
@Serializable data class MembershipCommand(val intent: MembershipIntent, val admission: MembershipAdmission) {
    init { admission.validate(intent) }
    val fingerprint get() = OperationFingerprint("membership").apply {
        text("action", admission.action.wire); text("admissionID", admission.id); unsigned("expiresAt", admission.expiresAt)
        bytes("intent", Base64.getDecoder().decode(intent.fingerprint)); unsigned("issuedAt", admission.issuedAt)
        admission.joinedRevision?.let { unsigned("joined", it) } ?: absent("joined"); unsigned("membershipRevision", admission.revision)
    }.digest()
    fun payload() = buildJsonObject { put("intent", intent.payload()); put("admission", admission.payload(intent)) }
    fun recovery(close: Boolean) = buildJsonObject { put("identity", intent.identity()); put("fingerprint", fingerprintPayload(fingerprint)); put("action", if (close) "closeIfAbsent" else "query") }
}
sealed interface MembershipAdmissionResult {
    data class Admitted(val admission: MembershipAdmission) : MembershipAdmissionResult
    data class Unavailable(val reason: String) : MembershipAdmissionResult
    data class Deferred(val delayMilliseconds: Long) : MembershipAdmissionResult
    data object Conflict : MembershipAdmissionResult
}
sealed interface MembershipResult {
    data class Receipt(val status: MembershipStatus, val revision: Long?, val roomSequence: Long?, val event: String?, val rejection: String?, val wire: String) : MembershipResult
    data class Deferred(val delayMilliseconds: Long) : MembershipResult
    data object Unresolved : MembershipResult
    data object Conflict : MembershipResult
}
class MembershipClient(private val transport: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun admit(intent: MembershipIntent): MembershipAdmissionResult {
        val response = transport.request("/v2/rooms/${intent.room.value}/membership/admissions", intent.payload())
        if (response.status in setOf(429, 503)) return MembershipAdmissionResult.Deferred(response.retryAfter?.let { retryAfterMilliseconds(it, now()) } ?: 0)
        if (response.status != 200) throw response.failure()
        val root = response.body; if (root.size != 1) throw ClientFailure.Protocol()
        return when (root.keys.single()) {
            "admitted" -> {
                val value = root.objectValue("admitted").objectValue("_0")
                validateRoomProof(intent.actor, intent.room, intent.operation, "membership", intent.fingerprint, value, "intentFingerprint")
                val action = when(value.string("action")) { "add" -> MembershipAction.Add; "remove" -> MembershipAction.Remove; else -> throw ClientFailure.Protocol() }
                val joined = value["targetJoinedRevision"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.longOrNull
                if (value["targetJoinedRevision"]?.let { it !is JsonNull } == true && joined == null) throw ClientFailure.Protocol()
                val admission = MembershipAdmission(uuidId(value.identifier("id")), intent.fingerprint, action, value.number("membershipRevision"), joined,
                    value.number("issuedAtMilliseconds"), value.number("expiresAtMilliseconds"))
                admission.validate(intent); MembershipAdmissionResult.Admitted(admission)
            }
            "currentUnavailable" -> MembershipAdmissionResult.Unavailable(reason(root.objectValue("currentUnavailable").objectValue("_0"), admissionReasons))
            "fingerprintConflict" -> { if (root.objectValue("fingerprintConflict").isNotEmpty()) throw ClientFailure.Protocol(); MembershipAdmissionResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    suspend fun execute(command: MembershipCommand, recover: Boolean, close: Boolean): MembershipResult {
        val intent = command.intent; val body = if (recover) command.recovery(close) else command.payload()
        require(body.toString().toByteArray().size <= 4096)
        val response = transport.request("/v2/rooms/${intent.room.value}/membership/" + if (recover) "operations/recover" else "submit", body)
        if (response.status !in setOf(200, 429, 503)) throw response.failure()
        val root = response.body; if (root.size != 1) throw ClientFailure.Protocol()
        if (response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when(root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue("receipt").objectValue("_0"))
            "deferred" -> { val hint = root.objectValue("deferred").objectValue("_0"); validate(command, hint); MembershipResult.Deferred(retryHintDelay(hint, response, now())) }
            "unresolved" -> { if (root.objectValue("unresolved").isNotEmpty()) throw ClientFailure.Protocol(); MembershipResult.Unresolved }
            "fingerprintConflict" -> { if (root.objectValue("fingerprintConflict").isNotEmpty()) throw ClientFailure.Protocol(); MembershipResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        private val admissionReasons = setOf("confirmationExpired", "invalidConfirmationDeadline", "permissionDenied", "roomNotFound", "targetUnavailable", "targetAlreadyMember", "targetNotMember", "membershipChanged")
        private val rejectionReasons = setOf("admissionExpired", "invalidAdmission", "permissionDenied", "roomNotFound", "targetUnavailable", "targetAlreadyMember", "targetNotMember", "memberLimitReached", "membershipChanged")
        private fun reason(value: JsonObject, allowed: Set<String>): String {
            if (value.size != 1 || value.keys.single() !in allowed) throw ClientFailure.Protocol()
            val key = value.keys.single(); val detail = value.objectValue(key)
            if (key == "membershipChanged") { if (detail.number("currentRevision") < 0) throw ClientFailure.Protocol() }
            else if (detail.isNotEmpty()) throw ClientFailure.Protocol()
            return key
        }
        private fun validate(command: MembershipCommand, value: JsonObject) = validateRoomProof(command.intent.actor, command.intent.room,
            command.intent.operation, "membership", command.fingerprint, value)
        fun decodeReceipt(command: MembershipCommand, value: JsonObject): MembershipResult.Receipt {
            validate(command, value); if (value.number("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome"); if (outcome.size != 1) throw ClientFailure.Protocol()
            var revision: Long? = null; var sequence: Long? = null; var event: String? = null; var rejection: String? = null
            val status = when(outcome.keys.single()) {
                "changed" -> {
                    val changed = outcome.objectValue("changed").objectValue("_0")
                    revision = changed.number("membershipRevision"); sequence = changed.number("roomSequence"); event = canonicalId(changed.identifier("eventID"))
                    if (revision != command.intent.revision + 1 || sequence <= 0) throw ClientFailure.Protocol()
                    MembershipStatus.Committed
                }
                "rejected" -> { rejection = reason(outcome.objectValue("rejected").objectValue("_0"), rejectionReasons); if (rejection == "membershipChanged") MembershipStatus.Conflicted else MembershipStatus.Rejected }
                "closed" -> { if (outcome.objectValue("closed").isNotEmpty()) throw ClientFailure.Protocol(); MembershipStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            return MembershipResult.Receipt(status, revision, sequence, event, rejection, value.toString())
        }
    }
}
@Serializable enum class MembershipStatus { DraftReady, DraftPaused, DraftCancelled, Pending, NeedsAttention, Committed, Rejected, Conflicted, Closed }
@Serializable data class MembershipWork(val intent: MembershipIntent, val activation: String, val status: MembershipStatus = MembershipStatus.DraftReady,
    val admission: MembershipAdmission? = null, val preparationAttempts: Int = 0, val attempts: Int = 0,
    val nextAttemptMilliseconds: Long = 0, val reconcile: Boolean = false, val receipt: String? = null, val reason: String? = null,
    /** null denotes a legacy row; true survives retries, cancellation and process restart. */
    val executionStarted: Boolean? = null) {
    val terminal get() = status in setOf(MembershipStatus.DraftCancelled, MembershipStatus.Committed, MembershipStatus.Rejected, MembershipStatus.Conflicted, MembershipStatus.Closed)
    fun command() = MembershipCommand(intent, requireNotNull(admission))
}
interface MembershipStore {
    suspend fun membershipWorks(): PersistentList<MembershipWork>
    suspend fun membershipWork(operation:String): MembershipWork? = membershipWorks().firstOrNull {it.intent.operation==operation}
    suspend fun prepareMembership(intent: MembershipIntent, activation: String): MembershipWork
    suspend fun replaceMembershipDraft(expected: MembershipWork, intent: MembershipIntent, activation: String): MembershipWork
    suspend fun updateMembership(expected: MembershipWork, updated: MembershipWork)
}
