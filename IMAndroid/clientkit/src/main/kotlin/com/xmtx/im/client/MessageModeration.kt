package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable data class ModerationBaseline(val room: RoomId,val message: MessageId,val messageRevision: Long,val membershipRevision: Long,val redacted: Boolean) {
    init { require(uuidId(room.value) == room.value && uuidId(message.value) == message.value && messageRevision in 1 until Long.MAX_VALUE && membershipRevision in 0 until Long.MAX_VALUE) }
}
@Serializable data class ModerationIntent(val actor: UserId,val room: RoomId,val operation: String,val message: MessageId,val reason: String,
    val messageRevision: Long,val membershipRevision: Long,val deadline: Long) {
    init {
        listOf(actor.value,room.value,operation,message.value).forEach { require(uuidId(it) == it) }
        require(reason == moderationReason(reason) && messageRevision in 1 until Long.MAX_VALUE && membershipRevision in 0 until Long.MAX_VALUE && deadline > 0)
    }
    val key get() = "${actor.value}/room/${room.value}/moderation/$operation"
    fun identity() = roomIdentity(actor,room,operation,"moderation")
    val fingerprint get() = OperationFingerprint("moderation").apply {
        text("action","redactMessage");unsigned("confirmedUntil",deadline);text("identity",key);unsigned("membershipRevision",membershipRevision)
        text("message",message.value);unsigned("messageRevision",messageRevision);text("reason",reason)
    }.digest()
    fun payload() = buildJsonObject {
        put("roomID",wireId(room.value));put("actorUserID",wireId(actor.value));put("operationID",wireId(operation));put("messageID",wireId(message.value))
        put("reasonCode",buildJsonObject { put("rawValue",reason) });put("expectedMessageRevision",messageRevision);put("expectedMembershipRevision",membershipRevision);put("confirmedUntilMilliseconds",deadline)
    }
    fun recovery(close: Boolean) = buildJsonObject { put("intent",payload());put("action",if(close) "closeIfAbsent" else "query") }
    fun proof(value: JsonObject,key: String = "fingerprint") = validateRoomProof(actor,room,operation,"moderation",fingerprint,value,key)
}
@Serializable data class ModerationAdmission(val id: String,val intentFingerprint: String,val actorJoined: Long,val issued: Long,val expires: Long) {
    init { require(uuidId(id) == id && actorJoined >= 0 && issued > 0 && expires > issued && expires-issued <= 120000) }
    fun validate(intent: ModerationIntent) { require(intentFingerprint == intent.fingerprint && actorJoined <= intent.membershipRevision && expires <= intent.deadline) }
    fun payload(intent: ModerationIntent) = buildJsonObject {
        validate(intent);put("id",wireId(id));put("identity",intent.identity());put("intentFingerprint",fingerprintPayload(intentFingerprint));put("actorJoinedRevision",actorJoined)
        put("issuedAtMilliseconds",issued);put("expiresAtMilliseconds",expires)
    }
}
@Serializable data class ModerationCommand(val intent: ModerationIntent,val admission: ModerationAdmission) {
    init { admission.validate(intent) }
    val fingerprint get() = intent.fingerprint
    fun payload() = buildJsonObject { put("intent",intent.payload());put("admission",admission.payload(intent)) }
}
sealed interface ModerationAdmissionResult {
    data class Admitted(val value: ModerationAdmission): ModerationAdmissionResult
    data class Terminal(val receipt: ModerationResult.Receipt): ModerationAdmissionResult
    data class Unavailable(val reason: String): ModerationAdmissionResult
    data object Conflict: ModerationAdmissionResult
}
sealed interface ModerationResult {
    data class Receipt(val status: ModerationStatus,val revision: Long?,val sequence: Long?,val event: String?,val reason: String?,val wire: String): ModerationResult
    data class Deferred(val delay: Long): ModerationResult
    data object Unresolved: ModerationResult
    data object Conflict: ModerationResult
}
class ModerationBackpressure(val delay: Long): Exception()
class MessageModerationClient(private val api: AuthenticatedTransport,private val now: () -> Long = System::currentTimeMillis) {
    private fun path(room: RoomId,action: String) = "/v2/rooms/${room.value}/message-moderation-operations/$action"
    suspend fun baseline(room: RoomId,message: MessageId): ModerationBaseline = withTimeout(15000) {
        uuidId(room.value);uuidId(message.value)
        val response = api.request("/v2/rooms/${room.value}/messages/${message.value}/moderation-baseline");success(response)
        val v = response.body;require(v.identifier("roomID") == room.value && v.identifier("messageID") == message.value)
        ModerationBaseline(room,message,v.moderationNumber("messageRevision"),v.moderationNumber("membershipRevision"),v.getValue("isRedacted").jsonPrimitive.takeUnless { it.isString }?.booleanOrNull ?: throw ClientFailure.Protocol())
    }
    suspend fun admit(intent: ModerationIntent): ModerationAdmissionResult = withTimeout(15000) {
        val body = intent.payload();require(body.toString().toByteArray().size <= 4096)
        val response = api.request(path(intent.room,"admissions"),body);success(response)
        val root = response.body;require(root.size == 1)
        when(root.keys.single()) {
            "admitted" -> {
                val v = root.objectValue("admitted").objectValue("_0");intent.proof(v,"intentFingerprint")
                ModerationAdmission(uuidId(v.identifier("id")),intent.fingerprint,v.moderationNumber("actorJoinedRevision"),v.moderationNumber("issuedAtMilliseconds"),v.moderationNumber("expiresAtMilliseconds")).also { it.validate(intent) }.let { ModerationAdmissionResult.Admitted(it) }
            }
            "terminal" -> ModerationAdmissionResult.Terminal(decodeReceipt(intent,root.objectValue("terminal").objectValue("_0")))
            "currentUnavailable" -> ModerationAdmissionResult.Unavailable(rejection(root.objectValue("currentUnavailable").objectValue("_0")))
            "fingerprintConflict" -> { require(root.objectValue("fingerprintConflict").isEmpty());ModerationAdmissionResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    suspend fun execute(intent: ModerationIntent,command: ModerationCommand? = null,recover: Boolean = true,close: Boolean = false): ModerationResult = withTimeout(15000) {
        require(command == null || command.intent == intent)
        val body = if(recover) intent.recovery(close) else requireNotNull(command).payload();require(body.toString().toByteArray().size <= 4096)
        val response = api.request(path(intent.room,if(recover) "operations/recover" else "submit"),body)
        if(response.status !in setOf(200,429,503)) throw response.failure()
        val root = response.body
        if(response.status != 200 && (root.size != 1 || "deferred" !in root)) throw ModerationBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it,now()) } ?: 0)
        require(root.size == 1)
        when(root.keys.single()) {
            "receipt" -> decodeReceipt(intent,root.objectValue("receipt").objectValue("_0"))
            "deferred" -> { val hint = root.objectValue("deferred").objectValue("_0");intent.proof(hint);ModerationResult.Deferred(retryHintDelay(hint,response,now())) }
            "unresolved" -> { require(root.objectValue("unresolved").isEmpty());ModerationResult.Unresolved }
            "fingerprintConflict" -> { require(root.objectValue("fingerprintConflict").isEmpty());ModerationResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    private fun success(response: EdgeResponse) {
        if(response.status in setOf(429,503)) throw ModerationBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it,now()) } ?: 0)
        if(response.status != 200) throw response.failure()
    }
    companion object {
        private fun rejection(v: JsonObject): String {
            require(v.size == 1);val reason = v.keys.single()
            require(reason in setOf("confirmationExpired","invalidConfirmationDeadline","admissionExpired","invalidAdmission","permissionDenied","roomNotFound","messageNotFound","membershipChanged","messageChanged"))
            if(reason in setOf("membershipChanged","messageChanged")) require(v.objectValue(reason).moderationNumber("currentRevision") >= if(reason == "messageChanged") 1 else 0)
            else require(v.objectValue(reason).isEmpty())
            return reason
        }
        fun decodeReceipt(intent: ModerationIntent,value: JsonObject): ModerationResult.Receipt {
            intent.proof(value);require(value.moderationNumber("resolvedAtMilliseconds") > 0)
            val outcome = value.objectValue("outcome");require(outcome.size == 1);val name = outcome.keys.single()
            var revision: Long? = null;var sequence: Long? = null;var event: String? = null;var reason: String? = null
            val safeOutcome: JsonObject
            val status = when(name) {
                "redacted","alreadySatisfied" -> {
                    val v = outcome.objectValue(name);require(v.identifier("messageID") == intent.message.value)
                    revision = v.moderationNumber("messageRevision");require(revision == intent.messageRevision + if(name == "redacted") 1 else 0)
                    if(name == "redacted") { sequence = v.moderationNumber("roomSequence");require(sequence > 0);event = uuidId(v.identifier("eventID")) }
                    safeOutcome = buildJsonObject { put(name,buildJsonObject {
                        put("messageID",wireId(intent.message.value));put("messageRevision",revision);sequence?.let { put("roomSequence",it) };event?.let { put("eventID",wireId(it)) }
                    }) };ModerationStatus.Committed
                }
                "rejected" -> {
                    val v = outcome.objectValue(name).objectValue("_0");reason = rejection(v)
                    safeOutcome = buildJsonObject { put(name,buildJsonObject { put("_0",buildJsonObject { put(reason,buildJsonObject {
                        if(reason in setOf("membershipChanged","messageChanged")) put("currentRevision",v.objectValue(reason).moderationNumber("currentRevision"))
                    }) }) }) }
                    if(reason in setOf("membershipChanged","messageChanged")) ModerationStatus.Conflicted else ModerationStatus.Rejected
                }
                "closed" -> { require(outcome.objectValue(name).isEmpty());safeOutcome = buildJsonObject { put(name,buildJsonObject {}) };ModerationStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            val safe = buildJsonObject { put("identity",intent.identity());put("fingerprint",fingerprintPayload(intent.fingerprint));put("outcome",safeOutcome);put("resolvedAtMilliseconds",value.moderationNumber("resolvedAtMilliseconds")) }
            return ModerationResult.Receipt(status,revision,sequence,event,reason,safe.toString())
        }
    }
}
@Serializable enum class ModerationStatus { Pending,NeedsAttention,Committed,Rejected,Conflicted,Closed }
@Serializable data class ModerationWork(val intent: ModerationIntent,val activation: String,val status: ModerationStatus = ModerationStatus.Pending,
    val admission: ModerationAdmission? = null,val attempts: Int = 0,val roundEnd: Long,val nextAttempt: Long = 0,
    val reconcile: Boolean = false,val submissionStarted: Boolean = false,val recoveryOnly: Boolean = false,val receipt: String? = null,val reason: String? = null,val executionStarted: Boolean? = null) {
    val terminal get() = status in setOf(ModerationStatus.Committed,ModerationStatus.Rejected,ModerationStatus.Conflicted,ModerationStatus.Closed)
    fun command() = admission?.let { ModerationCommand(intent,it) }
}
interface ModerationStore {
    suspend fun moderationWorks(): PersistentList<ModerationWork>
    suspend fun moderationWork(id: String): ModerationWork? = moderationWorks().firstOrNull { it.intent.key == id }
    suspend fun enqueueModeration(work: ModerationWork): ModerationWork
    suspend fun updateModeration(expected: ModerationWork,updated: ModerationWork)
}
private fun JsonObject.moderationNumber(key: String) = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
