package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import kotlinx.coroutines.withTimeout
import java.util.Base64

fun moderationReason(value: String): String = invitationTrim(value).also { require(it.matches(Regex("[A-Za-z0-9_-]{1,64}"))) }
@Serializable sealed interface AdministrationAction {
    @Serializable data class Mute(val until: Long): AdministrationAction { init { require(until > 0) } }
    @Serializable data object Remove: AdministrationAction
}
@Serializable data class AdministrationIntent(val actor: UserId, val room: RoomId, val operation: String, val target: UserId,
    val action: AdministrationAction, val reason: String, val revision: Long, val deadline: Long) {
    init {
        require(actor != target && revision in 0 until Long.MAX_VALUE && deadline > 0 && reason == moderationReason(reason))
        listOf(actor.value,room.value,operation,target.value).forEach { require(uuidId(it) == it) }
    }
    val kind get() = if(action is AdministrationAction.Mute) "memberMute" else "moderatedMemberRemoval"
    val key get() = "${actor.value}/room/${room.value}/$kind/$operation"
    fun identity() = roomIdentity(actor,room,operation,kind)
    val fingerprint get() = OperationFingerprint(kind).apply {
        text("action",if(action is AdministrationAction.Mute) "mute" else "remove");unsigned("confirmedUntil",deadline)
        unsigned("expectedMembershipRevision",revision);text("identity",key);unsigned("muteUntil",(action as? AdministrationAction.Mute)?.until ?: 0)
        text("reason",reason);text("target",target.value)
    }.digest()
    fun payload() = buildJsonObject {
        put("roomID",wireId(room.value));put("actorUserID",wireId(actor.value));put("operationID",wireId(operation));put("targetUserID",wireId(target.value))
        put("action",buildJsonObject { if(action is AdministrationAction.Mute) put("mute",buildJsonObject { put("untilMilliseconds",action.until) }) else put("remove",buildJsonObject {}) })
        put("reasonCode",buildJsonObject { put("rawValue",reason) });put("expectedMembershipRevision",revision);put("confirmedUntilMilliseconds",deadline)
    }
}
@Serializable data class AdministrationAdmission(val id: String, val intentFingerprint: String, val revision: Long, val joined: Long, val issued: Long, val expires: Long) {
    init { require(uuidId(id) == id && revision in 0 until Long.MAX_VALUE && joined in 0..revision && issued > 0 && expires > issued && expires-issued <= 120000) }
    fun validate(intent: AdministrationIntent) { require(intentFingerprint == intent.fingerprint && revision == intent.revision && expires <= intent.deadline) }
    fun payload(intent: AdministrationIntent) = buildJsonObject {
        validate(intent);put("id",wireId(id));put("identity",intent.identity());put("intentFingerprint",fingerprintPayload(intentFingerprint))
        put("membershipRevision",revision);put("targetJoinedRevision",joined);put("issuedAtMilliseconds",issued);put("expiresAtMilliseconds",expires)
    }
}
@Serializable data class AdministrationCommand(val intent: AdministrationIntent, val admission: AdministrationAdmission) {
    init { admission.validate(intent) }
    val fingerprint get() = OperationFingerprint(intent.kind).apply {
        text("admissionID",admission.id);unsigned("expiresAt",admission.expires);bytes("intent",Base64.getDecoder().decode(intent.fingerprint))
        unsigned("issuedAt",admission.issued);unsigned("membershipRevision",admission.revision);unsigned("targetJoinedRevision",admission.joined)
    }.digest()
    fun payload() = buildJsonObject { put("intent",intent.payload());put("admission",admission.payload(intent)) }
    fun recovery(close: Boolean) = buildJsonObject { put("identity",intent.identity());put("fingerprint",fingerprintPayload(fingerprint));put("action",if(close) "closeIfAbsent" else "query") }
    fun proof(value: JsonObject) = validateRoomProof(intent.actor,intent.room,intent.operation,intent.kind,fingerprint,value)
}
sealed interface AdministrationAdmissionResult {
    data class Admitted(val value: AdministrationAdmission): AdministrationAdmissionResult
    data class Unavailable(val reason: String): AdministrationAdmissionResult
    data object Conflict: AdministrationAdmissionResult
}
sealed interface AdministrationResult {
    data class Receipt(val status: AdministrationStatus, val revision: Long?, val until: Long?, val reason: String?, val wire: String): AdministrationResult
    data class Deferred(val delay: Long): AdministrationResult
    data object Unresolved: AdministrationResult
    data object Conflict: AdministrationResult
}
class AdministrationBackpressure(val delay: Long): Exception()
class AdministrationClient(private val api: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    private fun path(room: RoomId,action: String) = "/v2/rooms/${room.value}/member-administration/$action"
    suspend fun admit(intent: AdministrationIntent): AdministrationAdmissionResult = withTimeout(15000) {
        val body = intent.payload(); require(body.toString().toByteArray().size <= 4096)
        val response = api.request(path(intent.room,"admissions"),body)
        if(response.status in setOf(429,503)) throw AdministrationBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it,now()) } ?: 0)
        if(response.status != 200) throw response.failure()
        val root = response.body; require(root.size == 1)
        when(root.keys.single()) {
            "admitted" -> {
                val v = root.objectValue("admitted").objectValue("_0")
                validateRoomProof(intent.actor,intent.room,intent.operation,intent.kind,intent.fingerprint,v,"intentFingerprint")
                AdministrationAdmission(uuidId(v.identifier("id")),intent.fingerprint,v.administrationNumber("membershipRevision"),v.administrationNumber("targetJoinedRevision"),v.administrationNumber("issuedAtMilliseconds"),v.administrationNumber("expiresAtMilliseconds")).also { it.validate(intent) }.let { AdministrationAdmissionResult.Admitted(it) }
            }
            "currentUnavailable" -> AdministrationAdmissionResult.Unavailable(rejection(root.objectValue("currentUnavailable").objectValue("_0"),true))
            "fingerprintConflict" -> { require(root.objectValue("fingerprintConflict").isEmpty());AdministrationAdmissionResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    suspend fun execute(command: AdministrationCommand, recover: Boolean = true, close: Boolean = false): AdministrationResult = withTimeout(15000) {
        val body = if(recover) command.recovery(close) else command.payload();require(body.toString().toByteArray().size <= 4096)
        val response = api.request(path(command.intent.room,if(recover) "operations/recover" else "submit"),body)
        if(response.status !in setOf(200,429,503)) throw response.failure()
        val root = response.body
        if(response.status != 200 && (root.size != 1 || "deferred" !in root)) throw AdministrationBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it,now()) } ?: 0)
        require(root.size == 1)
        when(root.keys.single()) {
            "receipt" -> decodeReceipt(command,root.objectValue("receipt").objectValue("_0"))
            "deferred" -> { val hint = root.objectValue("deferred").objectValue("_0");command.proof(hint);AdministrationResult.Deferred(retryHintDelay(hint,response,now())) }
            "unresolved" -> { require(root.objectValue("unresolved").isEmpty());AdministrationResult.Unresolved }
            "fingerprintConflict" -> { require(root.objectValue("fingerprintConflict").isEmpty());AdministrationResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        private fun rejection(value: JsonObject, admission: Boolean = false): String {
            require(value.size == 1);val reason = value.keys.single()
            val allowed = if(admission) setOf("confirmationExpired","invalidConfirmationDeadline","permissionDenied","roomNotFound","targetNotMember","membershipChanged")
                else setOf("admissionExpired","invalidAdmission","permissionDenied","roomNotFound","targetNotMember","invalidMuteExpiry","membershipChanged")
            require(reason in allowed)
            if(reason == "membershipChanged") require(value.objectValue(reason).administrationNumber("currentRevision") >= 0) else require(value.objectValue(reason).isEmpty())
            return reason
        }
        fun decodeReceipt(command: AdministrationCommand,value: JsonObject): AdministrationResult.Receipt {
            command.proof(value);require(value.administrationNumber("resolvedAtMilliseconds") > 0)
            val outcome = value.objectValue("outcome");require(outcome.size == 1);val name = outcome.keys.single()
            var revision: Long? = null;var until: Long? = null;var reason: String? = null
            val safeOutcome: JsonObject
            val status = when(name) {
                "applied" -> {
                    val applied = outcome.objectValue(name).objectValue("_0");require(applied.size == 1)
                    val mute = command.intent.action as? AdministrationAction.Mute;val key = if(mute == null) "removed" else "muted"
                    val v = applied.objectValue(key);revision = v.administrationNumber("membershipRevision")
                    require(revision == command.intent.revision + if(mute == null) 1 else 0)
                    if(mute != null) { until = v.administrationNumber("untilMilliseconds");require(until == mute.until) }
                    val sequence = v.administrationNumber("roomSequence");require(sequence > 0);val event = uuidId(v.identifier("eventID"))
                    safeOutcome = buildJsonObject { put(name,buildJsonObject { put("_0",buildJsonObject { put(key,buildJsonObject {
                        until?.let { put("untilMilliseconds",it) };put("membershipRevision",revision);put("roomSequence",sequence);put("eventID",wireId(event))
                    }) }) }) };AdministrationStatus.Committed
                }
                "alreadySatisfied" -> {
                    val mute = command.intent.action as? AdministrationAction.Mute ?: throw ClientFailure.Protocol()
                    val v = outcome.objectValue(name);until = v.administrationNumber("muteUntilMilliseconds");revision = v.administrationNumber("membershipRevision")
                    require(until >= mute.until && revision == command.intent.revision)
                    safeOutcome = buildJsonObject { put(name,buildJsonObject { put("muteUntilMilliseconds",until);put("membershipRevision",revision) }) };AdministrationStatus.Committed
                }
                "rejected" -> {
                    val v = outcome.objectValue(name).objectValue("_0");reason = rejection(v)
                    safeOutcome = buildJsonObject { put(name,buildJsonObject { put("_0",buildJsonObject { put(reason,buildJsonObject {
                        if(reason == "membershipChanged") put("currentRevision",v.objectValue(reason).administrationNumber("currentRevision"))
                    }) }) }) }
                    if(reason == "membershipChanged") AdministrationStatus.Conflicted else AdministrationStatus.Rejected
                }
                "closed" -> { require(outcome.objectValue(name).isEmpty());safeOutcome = buildJsonObject { put(name,buildJsonObject {}) };AdministrationStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            val safe = buildJsonObject { put("identity",command.intent.identity());put("fingerprint",fingerprintPayload(command.fingerprint));put("outcome",safeOutcome);put("resolvedAtMilliseconds",value.administrationNumber("resolvedAtMilliseconds")) }
            return AdministrationResult.Receipt(status,revision,until,reason,safe.toString())
        }
    }
}
@Serializable enum class AdministrationStatus { DraftReady,DraftPaused,DraftCancelled,Pending,NeedsAttention,Committed,Rejected,Conflicted,Closed }
@Serializable data class AdministrationWork(val intent: AdministrationIntent,val activation: String,val status: AdministrationStatus = AdministrationStatus.DraftReady,
    val admission: AdministrationAdmission? = null,val preparationAttempts: Int = 0,val preparationEnd: Long = 0,
    val attempts: Int = 0,val roundEnd: Long = 0,val nextAttempt: Long = 0,val reconcile: Boolean = false,val submissionStarted: Boolean = false,
    val receipt: String? = null,val reason: String? = null,
    /** null denotes a legacy row; true survives retries, cancellation and process restart. */
    val executionStarted: Boolean? = null) {
    val draft get() = status in setOf(AdministrationStatus.DraftReady,AdministrationStatus.DraftPaused,AdministrationStatus.DraftCancelled)
    val terminal get() = status in setOf(AdministrationStatus.DraftCancelled,AdministrationStatus.Committed,AdministrationStatus.Rejected,AdministrationStatus.Conflicted,AdministrationStatus.Closed)
    fun command() = AdministrationCommand(intent,requireNotNull(admission))
}
interface AdministrationStore {
    suspend fun administrationWorks(): PersistentList<AdministrationWork>
    suspend fun administrationWork(id: String): AdministrationWork? = administrationWorks().firstOrNull { it.intent.key == id }
    suspend fun prepareAdministration(intent: AdministrationIntent,activation: String): AdministrationWork
    suspend fun replaceAdministrationDraft(expected: AdministrationWork,intent: AdministrationIntent,activation: String): AdministrationWork
    suspend fun updateAdministration(expected: AdministrationWork,updated: AdministrationWork)
}

private fun JsonObject.administrationNumber(key: String): Long = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
