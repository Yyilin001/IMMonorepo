package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import kotlinx.coroutines.withTimeout
import java.security.MessageDigest
import java.util.Base64

/** Bearer material is deliberately not serializable as an operation record. */
class InvitationSecret(val rawValue: String) {
    init { require(rawValue.matches(Regex("[A-Za-z0-9_-]{43}"))) }
    val digest: String get() = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(rawValue.toByteArray()))
    override fun toString() = "InvitationSecret(<redacted>)"
    override fun equals(other: Any?) = other is InvitationSecret && rawValue == other.rawValue
    override fun hashCode() = rawValue.hashCode()
}
internal fun invitationTrim(value: String) = value.trim { it.code in 9..13 || it.code in setOf(0x20,0x85,0xa0,0x1680,0x2028,0x2029,0x202f,0x205f,0x3000) || it.code in 0x2000..0x200b }
fun invitationNote(value: String?): String? = value?.let(::invitationTrim)?.takeIf { it.isNotEmpty() }?.also { require(it.toByteArray().size <= 500) }
@Serializable sealed interface InvitationAction {
    val kind: String
    val revision: Long? get() = null
    @Serializable data class Create(val lifetime: Long, val uses: Int, override val revision: Long) : InvitationAction { override val kind get() = "groupInvite" }
    @Serializable data class Revoke(val invite: String, override val revision: Long) : InvitationAction { override val kind get() = "groupInvite" }
    @Serializable data class Submit(val invite: String, val tokenDigest: String, val note: String?) : InvitationAction { override val kind get() = "groupJoinRequest" }
    @Serializable data class Cancel(val request: String) : InvitationAction { override val kind get() = "groupJoinRequest" }
    @Serializable data class Decide(val request: String, val approve: Boolean, override val revision: Long) : InvitationAction { override val kind get() = "groupJoinDecision" }
}
@Serializable data class InvitationIntent(val actor: UserId, val room: RoomId, val operation: String, val action: InvitationAction, val deadline: Long) {
    init {
        require(uuidId(actor.value) == actor.value && uuidId(room.value) == room.value && uuidId(operation) == operation && deadline > 0)
        require(action.revision?.let { it in 0 until Long.MAX_VALUE } != false)
        when(action) {
            is InvitationAction.Create -> require(action.lifetime in 300..2592000 && action.uses in 1..1000)
            is InvitationAction.Revoke -> require(uuidId(action.invite) == action.invite)
            is InvitationAction.Cancel -> require(uuidId(action.request) == action.request)
            is InvitationAction.Decide -> require(uuidId(action.request) == action.request)
            is InvitationAction.Submit -> {
                require(uuidId(action.invite) == action.invite && action.note == invitationNote(action.note))
                val bytes = Base64.getDecoder().decode(action.tokenDigest); require(bytes.size == 32 && Base64.getEncoder().encodeToString(bytes) == action.tokenDigest)
            }
        }
    }
    val key get() = "${actor.value}/room/${room.value}/${action.kind}/$operation"
    fun identity() = roomIdentity(actor, room, operation, action.kind)
    val fingerprint: String get() = OperationFingerprint(action.kind).apply {
        text("action", when(action) { is InvitationAction.Create -> "create"; is InvitationAction.Revoke -> "revoke"; is InvitationAction.Submit -> "submit"; is InvitationAction.Cancel -> "cancel"; is InvitationAction.Decide -> "decide" })
        unsigned("deadline", deadline)
        if(action is InvitationAction.Decide) text("decision", if(action.approve) "approve" else "reject")
        text("identity", key)
        when(action) { is InvitationAction.Revoke -> text("invite", action.invite); is InvitationAction.Submit -> text("invite", action.invite); else -> Unit }
        if(action is InvitationAction.Create) unsigned("lifetime", action.lifetime)
        action.revision?.let { unsigned("membership", it) }
        if(action is InvitationAction.Submit) action.note?.let { text("note", it) } ?: absent("note")
        when(action) { is InvitationAction.Cancel -> text("request", action.request); is InvitationAction.Decide -> text("request", action.request); else -> Unit }
        if(action is InvitationAction.Submit) bytes("tokenDigest", Base64.getDecoder().decode(action.tokenDigest))
        if(action is InvitationAction.Create) unsigned("uses", action.uses.toLong())
    }.digest()
    fun payload() = buildJsonObject {
        put("identity", identity()); put("confirmedUntilMilliseconds", deadline)
        put("action", buildJsonObject { when(action) {
            is InvitationAction.Create -> put("create", buildJsonObject { put("lifetimeSeconds", action.lifetime); put("maximumApprovedUses", action.uses); put("expectedMembershipRevision", action.revision) })
            is InvitationAction.Revoke -> put("revoke", buildJsonObject { put("inviteID", wireId(action.invite)); put("expectedMembershipRevision", action.revision) })
            is InvitationAction.Submit -> put("submit", buildJsonObject { put("inviteID", wireId(action.invite)); put("tokenDigest", action.tokenDigest); action.note?.let { put("note", it) } })
            is InvitationAction.Cancel -> put("cancel", buildJsonObject { put("requestID", wireId(action.request)) })
            is InvitationAction.Decide -> put("decide", buildJsonObject { put("requestID", wireId(action.request)); put("decision", if(action.approve) "approve" else "reject"); put("expectedMembershipRevision", action.revision) })
        } })
    }
    fun validateSecret(secret: InvitationSecret?) { if(action is InvitationAction.Submit) require(secret?.digest == action.tokenDigest) else require(secret == null) }
    fun admissionRequest(secret: InvitationSecret?) = buildJsonObject {
        validateSecret(secret); put("intent", payload()); secret?.let { put("secretAuthorization", buildJsonObject { put("rawValue", it.rawValue) }) }
    }
    fun recovery(close: Boolean) = buildJsonObject { put("intent", payload()); put("action", if(close) "closeIfAbsent" else "query") }
    internal fun proof(value: JsonObject, key: String = "fingerprint") = validateRoomProof(actor, room, operation, action.kind, fingerprint, value, key)
}
@Serializable data class InvitationAdmission(val id: String, val fingerprint: String, val revision: Long, val issuedAt: Long, val expiresAt: Long) {
    init { require(uuidId(id) == id && revision in 0 until Long.MAX_VALUE && issuedAt > 0 && expiresAt > issuedAt && expiresAt - issuedAt <= 120000) }
    fun validate(intent: InvitationIntent) { require(fingerprint == intent.fingerprint && expiresAt <= intent.deadline && (intent.action.revision == null || intent.action.revision == revision)) }
    fun payload(intent: InvitationIntent) = buildJsonObject {
        validate(intent); put("id", wireId(id)); put("identity", intent.identity()); put("intentFingerprint", fingerprintPayload(fingerprint))
        put("membershipRevision", revision); put("issuedAtMilliseconds", issuedAt); put("expiresAtMilliseconds", expiresAt)
    }
}
@Serializable data class InvitationCommand(val intent: InvitationIntent, val admission: InvitationAdmission) {
    init { admission.validate(intent) }
    fun payload() = buildJsonObject { put("intent", intent.payload()); put("admission", admission.payload(intent)) }
    fun submission(secret: InvitationSecret?) = buildJsonObject {
        intent.validateSecret(secret); put("command", payload()); secret?.let { put("secretAuthorization", buildJsonObject { put("rawValue", it.rawValue) }) }
    }
}
sealed interface InvitationAdmissionResult {
    data class Admitted(val admission: InvitationAdmission) : InvitationAdmissionResult
    data class Terminal(val receipt: InvitationResult.Receipt) : InvitationAdmissionResult
    data class Unavailable(val reason: String) : InvitationAdmissionResult
    data object Conflict : InvitationAdmissionResult
}
sealed interface InvitationResult {
    data class Receipt(val status: InvitationStatus, val valueID: String?, val revision: Long?, val reason: String?, val wire: String) : InvitationResult
    data class Deferred(val delay: Long) : InvitationResult
    data object Unresolved : InvitationResult
    data object Conflict : InvitationResult
}
class InvitationBackpressure(val delay: Long): Exception()
class InvitationClient(private val api: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    private fun endpoint(room: RoomId, action: String) = "/v2/rooms/${room.value}/invitation-operations/$action"
    suspend fun baseline(room: RoomId): Long = withTimeout(15000) {
        uuidId(room.value); val response = api.request(endpoint(room, "baseline")); requireSuccess(response)
        val value = response.body; require(RoomId(value.identifier("roomID")) == room)
        value.number("membershipRevision").also { require(it in 0 until Long.MAX_VALUE) }
    }
    suspend fun admit(intent: InvitationIntent, secret: InvitationSecret?): InvitationAdmissionResult = withTimeout(15000) {
        val body = intent.admissionRequest(secret); require(body.toString().toByteArray().size <= 8192)
        val response = api.request(endpoint(intent.room, "admissions"), body); requireSuccess(response)
        val root = response.body; require(root.size == 1)
        when(root.keys.single()) {
            "admitted" -> {
                val value = root.objectValue("admitted").objectValue("_0"); intent.proof(value, "intentFingerprint")
                val admission = InvitationAdmission(uuidId(value.identifier("id")), intent.fingerprint, value.number("membershipRevision"), value.number("issuedAtMilliseconds"), value.number("expiresAtMilliseconds"))
                admission.validate(intent); InvitationAdmissionResult.Admitted(admission)
            }
            "terminal" -> InvitationAdmissionResult.Terminal(decodeReceipt(intent, root.objectValue("terminal").objectValue("_0")))
            "currentUnavailable" -> InvitationAdmissionResult.Unavailable(rejection(root.objectValue("currentUnavailable").objectValue("_0")))
            "fingerprintConflict" -> { require(root.objectValue("fingerprintConflict").isEmpty()); InvitationAdmissionResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    suspend fun execute(intent: InvitationIntent, command: InvitationCommand? = null, secret: InvitationSecret? = null, recover: Boolean = true, close: Boolean = false): InvitationResult = withTimeout(15000) {
        require(command == null || command.intent == intent)
        val body = if(recover) intent.recovery(close) else requireNotNull(command).submission(secret)
        require(body.toString().toByteArray().size <= 8192)
        val response = api.request(endpoint(intent.room, if(recover) "operations/recover" else "submit"), body)
        if(response.status !in setOf(200,429,503)) throw response.failure()
        val root = response.body; require(root.size == 1)
        if(response.status != 200 && root.keys.single() != "deferred") throw InvitationBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it, now()) } ?: 0)
        when(root.keys.single()) {
            "receipt" -> decodeReceipt(intent, root.objectValue("receipt").objectValue("_0"))
            "deferred" -> { val hint = root.objectValue("deferred").objectValue("_0"); intent.proof(hint); InvitationResult.Deferred(retryHintDelay(hint, response, now())) }
            "unresolved" -> { require(root.objectValue("unresolved").isEmpty()); InvitationResult.Unresolved }
            "fingerprintConflict" -> { require(root.objectValue("fingerprintConflict").isEmpty()); InvitationResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    private fun requireSuccess(response: EdgeResponse) {
        if(response.status in setOf(429,503)) throw InvitationBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it, now()) } ?: 0)
        if(response.status != 200) throw response.failure()
    }
    companion object {
        private fun rejection(value: JsonObject): String {
            require(value.size == 1); val reason = value.keys.single()
            require(reason in setOf("admissionExpired","invalidAdmission","permissionDenied","roomNotFound","inviteUnavailable","requestNotFound","requestAlreadyDecided","alreadyMember","applicantUnavailable","memberLimitReached","membershipChanged"))
            if(reason == "membershipChanged") require(value.objectValue(reason).number("currentRevision") >= 0) else require(value.objectValue(reason).isEmpty())
            return reason
        }
        fun decodeReceipt(intent: InvitationIntent, value: JsonObject): InvitationResult.Receipt {
            intent.proof(value); require(value.number("resolvedAtMilliseconds") > 0)
            val outcome = value.objectValue("outcome"); require(outcome.size == 1)
            var id: String? = null; var revision: Long? = null; var reason: String? = null
            var safeOutcome: JsonObject? = null
            val status = when(val name = outcome.keys.single()) {
                "applied", "alreadySatisfied" -> {
                    val result = outcome.objectValue(name).objectValue("_0"); require(result.size == 1)
                    when(val action = intent.action) {
                        is InvitationAction.Create -> {
                            val detail = result.objectValue("inviteCreated"); id = uuidId(detail.identifier("inviteID"))
                            val created = detail.number("createdAtMilliseconds"); val expires = detail.number("expiresAtMilliseconds")
                            require(created > 0 && expires > created && expires - created == action.lifetime * 1000 && detail.number("maximumApprovedUses") == action.uses.toLong())
                        }
                        is InvitationAction.Revoke -> { id = uuidId(result.objectValue("inviteRevoked").identifier("inviteID")); require(id == action.invite) }
                        is InvitationAction.Submit -> { val detail = result.objectValue("requestSubmitted"); id = uuidId(detail.identifier("requestID")); require(detail.identifier("inviteID") == action.invite) }
                        is InvitationAction.Cancel -> { id = uuidId(result.objectValue("requestCancelled").identifier("requestID")); require(id == action.request) }
                        is InvitationAction.Decide -> {
                            val detail = result.objectValue("requestDecided"); id = uuidId(detail.identifier("requestID"))
                            require(id == action.request && detail.string("decision") == if(action.approve) "approve" else "reject")
                            revision = detail["membershipRevision"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.longOrNull
                            require(if(action.approve) revision == action.revision + 1 else detail["membershipRevision"] == null || detail["membershipRevision"] is JsonNull)
                        }
                    }
                    val safeValue = buildJsonObject { when(val action = intent.action) {
                        is InvitationAction.Create -> put("inviteCreated", buildJsonObject {
                            val detail = result.objectValue("inviteCreated"); put("inviteID", wireId(requireNotNull(id)))
                            put("createdAtMilliseconds", detail.number("createdAtMilliseconds")); put("expiresAtMilliseconds", detail.number("expiresAtMilliseconds")); put("maximumApprovedUses", action.uses)
                        })
                        is InvitationAction.Revoke -> put("inviteRevoked", buildJsonObject { put("inviteID", wireId(action.invite)) })
                        is InvitationAction.Submit -> put("requestSubmitted", buildJsonObject { put("requestID", wireId(requireNotNull(id))); put("inviteID", wireId(action.invite)) })
                        is InvitationAction.Cancel -> put("requestCancelled", buildJsonObject { put("requestID", wireId(action.request)) })
                        is InvitationAction.Decide -> put("requestDecided", buildJsonObject { put("requestID", wireId(action.request)); put("decision", if(action.approve) "approve" else "reject"); revision?.let { put("membershipRevision", it) } })
                    } }
                    safeOutcome = buildJsonObject { put(name, buildJsonObject { put("_0", safeValue) }) }
                    InvitationStatus.Committed
                }
                "rejected" -> { reason = rejection(outcome.objectValue(name).objectValue("_0")); if(reason == "membershipChanged") InvitationStatus.Conflicted else InvitationStatus.Rejected }
                "closed" -> { require(outcome.objectValue(name).isEmpty()); InvitationStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            val safe = buildJsonObject {
                put("identity", intent.identity()); put("fingerprint", fingerprintPayload(intent.fingerprint)); put("resolvedAtMilliseconds", value.number("resolvedAtMilliseconds"))
                put("outcome", safeOutcome ?: buildJsonObject {
                    if(status == InvitationStatus.Closed) put("closed", buildJsonObject {})
                    else put("rejected", buildJsonObject { put("_0", buildJsonObject { put(requireNotNull(reason), buildJsonObject {
                        if(reason == "membershipChanged") put("currentRevision", outcome.objectValue("rejected").objectValue("_0").objectValue("membershipChanged").number("currentRevision"))
                    }) }) })
                })
            }
            return InvitationResult.Receipt(status, id, revision, reason, safe.toString())
        }
    }
}
@Serializable enum class InvitationStatus { DraftReady, DraftPaused, DraftCancelled, Pending, NeedsAttention, Committed, Rejected, Conflicted, Closed }
@Serializable data class InvitationWork(val intent: InvitationIntent, val activation: String, val status: InvitationStatus = InvitationStatus.DraftReady,
    val admission: InvitationAdmission? = null, val secretReference: String? = null, val releaseSecret: Boolean = false,
    val preparationAttempts: Int = 0, val preparationEnd: Long = 0, val attempts: Int = 0, val roundEnd: Long = 0,
    val nextAttempt: Long = 0, val reconcile: Boolean = false, val submissionStarted: Boolean = false, val recoveryOnly: Boolean = false,
    val receipt: String? = null, val reason: String? = null,
    /** null denotes a legacy row; true survives retries, cancellation and process restart. */
    val executionStarted: Boolean? = null) {
    val terminal get() = status in setOf(InvitationStatus.DraftCancelled,InvitationStatus.Committed,InvitationStatus.Rejected,InvitationStatus.Conflicted,InvitationStatus.Closed)
    val draft get() = status in setOf(InvitationStatus.DraftReady,InvitationStatus.DraftPaused,InvitationStatus.DraftCancelled)
    fun command() = admission?.let { InvitationCommand(intent, it) }
}
interface InvitationStore {
    suspend fun invitationWorks(): PersistentList<InvitationWork>
    suspend fun invitationWork(id: String): InvitationWork? = invitationWorks().firstOrNull { it.intent.key == id }
    suspend fun prepareInvitation(intent: InvitationIntent, activation: String, secretReference: String?): InvitationWork
    suspend fun replaceInvitationDraft(expected: InvitationWork, intent: InvitationIntent, activation: String): InvitationWork
    suspend fun updateInvitation(expected: InvitationWork, updated: InvitationWork)
}
interface InvitationSecretStore {
    suspend fun save(reference: String, actor: UserId, secret: InvitationSecret)
    suspend fun load(reference: String, actor: UserId): InvitationSecret
    suspend fun remove(reference: String, actor: UserId)
}
fun InvitationAction.sameProposal(other: InvitationAction): Boolean = when(this) {
    is InvitationAction.Create -> other is InvitationAction.Create && lifetime == other.lifetime && uses == other.uses
    is InvitationAction.Revoke -> other is InvitationAction.Revoke && invite == other.invite
    is InvitationAction.Decide -> other is InvitationAction.Decide && request == other.request && approve == other.approve
    else -> this == other
}
