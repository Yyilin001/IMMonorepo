package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.PersistentSet
import kotlinx.collections.immutable.toPersistentSet
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.*
import java.util.Base64

internal object ImmutablePermissions : KSerializer<PersistentSet<GroupPermission>> {
    private val delegate = ListSerializer(GroupPermission.serializer())
    override val descriptor = delegate.descriptor
    override fun serialize(encoder: Encoder, value: PersistentSet<GroupPermission>) = delegate.serialize(encoder, value.sortedBy { it.wire })
    override fun deserialize(decoder: Decoder): PersistentSet<GroupPermission> {
        val values = delegate.deserialize(decoder); require(values.distinct().size == values.size); return values.toPersistentSet()
    }
}
internal val MemberRole.wire get() = name.lowercase()
/** Desired values and observed CAS revision are frozen together, never automatically rebased. */
@Serializable sealed interface GroupAction {
    val revision: Long
    val kind: String
    @Serializable data class Pin(val message: MessageId, val pinned: Boolean, override val revision: Long) : GroupAction { override val kind get() = "pinnedMessage" }
    @Serializable data class Announcement(val body: String, override val revision: Long) : GroupAction { override val kind get() = "groupAnnouncement" }
    @Serializable data class Permissions(val role: MemberRole, @Serializable(with = ImmutablePermissions::class) val permissions: PersistentSet<GroupPermission>, override val revision: Long) : GroupAction { override val kind get() = "groupPermission" }
    @Serializable data class Role(val target: UserId, val role: MemberRole, override val revision: Long) : GroupAction { override val kind get() = "groupRole" }
    @Serializable data class Transfer(val target: UserId, override val revision: Long) : GroupAction { override val kind get() = "groupOwnership" }
    @Serializable data class Dissolve(override val revision: Long) : GroupAction { override val kind get() = "groupDissolution" }
}
@Serializable data class GroupCapabilityIntent(val actor: UserId, val room: RoomId, val operation: String,
    val action: GroupAction, val confirmedUntilMilliseconds: Long) {
    init {
        require(uuidId(actor.value) == actor.value && uuidId(room.value) == room.value && uuidId(operation) == operation)
        require(confirmedUntilMilliseconds > 0 && action.revision in 0 until Long.MAX_VALUE)
        when(action) {
            is GroupAction.Pin -> require(uuidId(action.message.value) == action.message.value)
            is GroupAction.Announcement -> require((action.body.isEmpty() || action.body.isNotBlank()) && action.body.toByteArray().size <= 4096)
            is GroupAction.Permissions -> require(action.role != MemberRole.Owner && action.revision > 0)
            is GroupAction.Role -> require(action.role != MemberRole.Owner && action.target != actor && uuidId(action.target.value) == action.target.value)
            is GroupAction.Transfer -> require(action.target != actor && uuidId(action.target.value) == action.target.value && action.revision > 0)
            is GroupAction.Dissolve -> require(action.revision > 0)
        }
    }
    fun identity(): JsonObject {
        val base = roomIdentity(actor, room, operation, action.kind)
        return if (action is GroupAction.Pin) JsonObject(base + ("scope" to buildJsonObject {
            put("message", buildJsonObject { put("_0", wireId(room.value)); put("_1", wireId(action.message.value)) })
        })) else base
    }
    private val storageKey get() = "${actor.value}/" + (if(action is GroupAction.Pin) "message/${room.value}/${action.message.value}" else "room/${room.value}") + "/${action.kind}/$operation"
    val fingerprint get() = OperationFingerprint(action.kind).apply {
        if (action is GroupAction.Announcement) text("body", action.body)
        unsigned("confirmedUntil", confirmedUntilMilliseconds); text("identity", storageKey)
        if (action is GroupAction.Pin) { flag("isPinned", action.pinned); text("message", action.message.value) }
        unsigned("observedRevision", action.revision)
        if (action is GroupAction.Permissions) orderedText("permissions", action.permissions.map { it.wire }.sorted())
        when(action) { is GroupAction.Permissions -> text("role", action.role.wire); is GroupAction.Role -> text("role", action.role.wire); else -> Unit }
        when(action) { is GroupAction.Role -> text("target", action.target.value); is GroupAction.Transfer -> text("target", action.target.value); else -> Unit }
    }.digest()
    fun payload() = buildJsonObject {
        put("identity", identity()); put("confirmedUntilMilliseconds", confirmedUntilMilliseconds)
        put("action", buildJsonObject {
            val name = when(action) { is GroupAction.Pin -> "pin"; is GroupAction.Announcement -> "announcement"; is GroupAction.Permissions -> "rolePermissions"; is GroupAction.Role -> "memberRole"; is GroupAction.Transfer -> "transferOwnership"; is GroupAction.Dissolve -> "dissolve" }
            put(name, buildJsonObject { when(action) {
                is GroupAction.Pin -> { put("messageID", wireId(action.message.value)); put("isPinned", action.pinned); put("expectedRoomSequence", action.revision) }
                is GroupAction.Announcement -> { put("body", action.body); put("expectedRevision", action.revision) }
                is GroupAction.Permissions -> { put("role", action.role.wire); put("permissions", JsonArray(action.permissions.sortedBy { it.wire }.map { JsonPrimitive(it.wire) })); put("expectedRevision", action.revision) }
                is GroupAction.Role -> { put("targetUserID", wireId(action.target.value)); put("role", action.role.wire); put("expectedMembershipRevision", action.revision) }
                is GroupAction.Transfer -> { put("targetUserID", wireId(action.target.value)); put("expectedMembershipRevision", action.revision) }
                is GroupAction.Dissolve -> put("expectedMembershipRevision", action.revision)
            } })
        })
    }
    internal fun validateProof(value: JsonObject, digest: String, key: String = "fingerprint") {
        val identity = value.objectValue("identity"); val operationValue = identity.objectValue("operation"); val scope = identity.objectValue("scope")
        if (UserId(identity.identifier("accountID")) != actor || operationValue.keys != setOf(action.kind) || uuidId(operationValue.objectValue(action.kind).identifier("_0")) != operation) throw ClientFailure.Protocol()
        if (action is GroupAction.Pin) {
            if (scope.keys != setOf("message") || RoomId(scope.objectValue("message").identifier("_0")) != room || MessageId(scope.objectValue("message").identifier("_1")) != action.message) throw ClientFailure.Protocol()
        } else if(scope.keys != setOf("room") || RoomId(scope.objectValue("room").identifier("_0")) != room) throw ClientFailure.Protocol()
        val fp = value.objectValue(key); if(fp.capabilityNumber("version") != 1L || fp.string("digest") != digest) throw ClientFailure.Protocol()
    }
}
@Serializable data class GroupCapabilityAdmission(val id: String, val intentFingerprint: String, val issuedAt: Long, val expiresAt: Long, val joinedRevision: Long?) {
    init { require(uuidId(id) == id && issuedAt > 0 && expiresAt > issuedAt && expiresAt - issuedAt <= 120_000 && (joinedRevision == null || joinedRevision >= 0)) }
    fun validate(intent: GroupCapabilityIntent) {
        val needsJoined = intent.action is GroupAction.Role || intent.action is GroupAction.Transfer
        if (intentFingerprint != intent.fingerprint || expiresAt > intent.confirmedUntilMilliseconds || needsJoined != (joinedRevision != null) || joinedRevision?.let { it > intent.action.revision } == true) throw ClientFailure.Protocol()
    }
    fun payload(intent: GroupCapabilityIntent) = buildJsonObject {
        put("id", wireId(id)); put("identity", intent.identity()); put("intentFingerprint", fingerprintPayload(intentFingerprint))
        put("issuedAtMilliseconds", issuedAt); put("expiresAtMilliseconds", expiresAt); joinedRevision?.let { put("targetJoinedRevision", it) }
    }
}
@Serializable data class GroupCapabilityCommand(val intent: GroupCapabilityIntent, val admission: GroupCapabilityAdmission) {
    init { admission.validate(intent) }
    val fingerprint get() = OperationFingerprint(intent.action.kind).apply {
        text("admission", admission.id); unsigned("expires", admission.expiresAt); bytes("intent", Base64.getDecoder().decode(intent.fingerprint)); unsigned("issued", admission.issuedAt)
        admission.joinedRevision?.let { unsigned("targetJoinedRevision", it) } ?: absent("targetJoinedRevision")
    }.digest()
    fun payload() = buildJsonObject { put("intent", intent.payload()); put("admission", admission.payload(intent)) }
    fun recovery(close: Boolean) = buildJsonObject { put("identity", intent.identity()); put("fingerprint", fingerprintPayload(fingerprint)); put("action", if(close) "closeIfAbsent" else "query") }
}
sealed interface GroupCapabilityAdmissionResult {
    data class Admitted(val admission: GroupCapabilityAdmission) : GroupCapabilityAdmissionResult
    data class Unavailable(val reason: String) : GroupCapabilityAdmissionResult
    data class Deferred(val delayMilliseconds: Long) : GroupCapabilityAdmissionResult
    data object Conflict : GroupCapabilityAdmissionResult
}
sealed interface GroupCapabilityResult {
    data class Receipt(val status: GroupCapabilityStatus, val revision: Long?, val roomSequence: Long?, val rejection: String?, val wire: String) : GroupCapabilityResult
    data class Deferred(val delayMilliseconds: Long) : GroupCapabilityResult
    data object Unresolved : GroupCapabilityResult
    data object Conflict : GroupCapabilityResult
}
data class PinBaseline(val room: RoomId, val message: MessageId, val pinned: Boolean, val sequence: Long)
class GroupCapabilityClient(private val transport: AuthenticatedTransport, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun pinBaseline(room: RoomId, message: MessageId): PinBaseline {
        uuidId(room.value); uuidId(message.value)
        val response = transport.request("/v2/rooms/${room.value}/messages/${message.value}/pin-baseline")
        if(response.status != 200) throw response.failure()
        val body = response.body
        if (RoomId(body.identifier("roomID")) != room || MessageId(body.identifier("messageID")) != message || body.capabilityNumber("roomSequence") < 0) throw ClientFailure.Protocol()
        return PinBaseline(room, message, body.capabilityBoolean("isPinned"), body.capabilityNumber("roomSequence"))
    }
    suspend fun admit(intent: GroupCapabilityIntent): GroupCapabilityAdmissionResult {
        val response = transport.request("/v2/rooms/${intent.room.value}/group-capability-operations/admissions", intent.payload())
        if(response.status in setOf(429, 503)) return GroupCapabilityAdmissionResult.Deferred(response.retryAfter?.let { retryAfterMilliseconds(it, now()) } ?: 0)
        if(response.status != 200) throw response.failure()
        val root = response.body; if(root.size != 1) throw ClientFailure.Protocol()
        return when(root.keys.single()) {
            "admitted" -> {
                val value = root.objectValue("admitted").objectValue("_0"); intent.validateProof(value, intent.fingerprint, "intentFingerprint")
                val raw = value["targetJoinedRevision"]?.takeUnless { it is JsonNull }; val joined = raw?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull
                if(raw != null && joined == null) throw ClientFailure.Protocol()
                val admission = GroupCapabilityAdmission(uuidId(value.identifier("id")), intent.fingerprint, value.capabilityNumber("issuedAtMilliseconds"), value.capabilityNumber("expiresAtMilliseconds"), joined)
                admission.validate(intent); GroupCapabilityAdmissionResult.Admitted(admission)
            }
            "currentUnavailable" -> {
                val value = root.objectValue("currentUnavailable").objectValue("_0"); if(value.size != 1) throw ClientFailure.Protocol()
                val reason = when(value.keys.single()) {
                    "current" -> rejection(value.objectValue("current").objectValue("_0"))
                    "confirmationExpired", "invalidConfirmationDeadline" -> { if(value.objectValue(value.keys.single()).isNotEmpty()) throw ClientFailure.Protocol(); value.keys.single() }
                    else -> throw ClientFailure.Protocol()
                }; GroupCapabilityAdmissionResult.Unavailable(reason)
            }
            "fingerprintConflict" -> { emptyCase(root, "fingerprintConflict"); GroupCapabilityAdmissionResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    suspend fun execute(command: GroupCapabilityCommand, recover: Boolean, close: Boolean): GroupCapabilityResult {
        val body = if(recover) command.recovery(close) else command.payload(); require(body.toString().toByteArray().size <= 32768)
        val response = transport.request("/v2/rooms/${command.intent.room.value}/group-capability-operations/" + if(recover) "operations/recover" else "submit", body)
        if(response.status !in setOf(200, 429, 503)) throw response.failure()
        val root = response.body; if(root.size != 1) throw ClientFailure.Protocol()
        if(response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when(root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue("receipt").objectValue("_0"))
            "deferred" -> { val hint = root.objectValue("deferred").objectValue("_0"); command.intent.validateProof(hint, command.fingerprint); GroupCapabilityResult.Deferred(retryHintDelay(hint, response, now())) }
            "unresolved" -> { emptyCase(root, "unresolved"); GroupCapabilityResult.Unresolved }
            "fingerprintConflict" -> { emptyCase(root, "fingerprintConflict"); GroupCapabilityResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        private fun emptyCase(root: JsonObject, key: String) { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol() }
        private fun rejection(value: JsonObject): String {
            val allowed = setOf("invalidAdmission", "admissionExpired", "permissionDenied", "roomNotFound", "roomDissolved", "notGroupRoom", "messageNotFound", "messageWithdrawn", "targetNotMember", "targetChanged", "revisionChanged")
            if(value.size != 1 || value.keys.single() !in allowed) throw ClientFailure.Protocol()
            val key = value.keys.single(); if(key == "revisionChanged") { if(value.objectValue(key).capabilityNumber("currentRevision") < 0) throw ClientFailure.Protocol() } else emptyCase(value, key)
            return key
        }
        fun decodeReceipt(command: GroupCapabilityCommand, value: JsonObject): GroupCapabilityResult.Receipt {
            val intent = command.intent; intent.validateProof(value, command.fingerprint)
            if(value.capabilityNumber("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome"); if(outcome.size != 1) throw ClientFailure.Protocol()
            var revision: Long? = null; var sequence: Long? = null; var reason: String? = null
            val status = when(val key = outcome.keys.single()) {
                "applied", "alreadySatisfied" -> {
                    val applied = key == "applied"; val result = outcome.objectValue(key).objectValue("_0"); if(result.size != 1) throw ClientFailure.Protocol()
                    val action = intent.action; val expected = action.revision + if(applied) 1 else 0
                    val resultKey = when(action) { is GroupAction.Pin -> "pinned"; is GroupAction.Announcement -> "announcement"; is GroupAction.Permissions -> "rolePermissions"; is GroupAction.Role -> "memberRole"; is GroupAction.Transfer -> "ownershipTransferred"; is GroupAction.Dissolve -> "dissolved" }
                    val detail = result.objectValue(resultKey); sequence = detail.capabilityNumber("roomSequence")
                    if(sequence < 0 || applied && sequence == 0L) throw ClientFailure.Protocol()
                    when(action) {
                        is GroupAction.Pin -> { if(MessageId(detail.identifier("messageID")) != action.message || detail.capabilityBoolean("isPinned") != action.pinned || sequence != expected) throw ClientFailure.Protocol() }
                        is GroupAction.Announcement -> { revision = detail.capabilityNumber("revision"); if(detail["body"]?.jsonPrimitive?.takeIf { it.isString }?.content != action.body || sequence <= 0 || revision <= 0) throw ClientFailure.Protocol() }
                        is GroupAction.Permissions -> {
                            revision = detail.capabilityNumber("revision"); val values = detail["permissions"]?.jsonArray?.map { it.jsonPrimitive.takeIf { value -> value.isString }?.content ?: throw ClientFailure.Protocol() } ?: throw ClientFailure.Protocol()
                            if(detail.string("role") != action.role.wire || values.distinct().size != values.size || values.toSet() != action.permissions.map { it.wire }.toSet() || sequence <= 0 || revision <= 0) throw ClientFailure.Protocol()
                        }
                        is GroupAction.Role -> { revision = detail.capabilityNumber("membershipRevision"); if(UserId(detail.identifier("targetUserID")) != action.target || detail.string("role") != action.role.wire) throw ClientFailure.Protocol() }
                        is GroupAction.Transfer -> { revision = detail.capabilityNumber("membershipRevision"); if(!applied || UserId(detail.identifier("previousOwnerUserID")) != intent.actor || UserId(detail.identifier("ownerUserID")) != action.target || sequence <= 0) throw ClientFailure.Protocol() }
                        is GroupAction.Dissolve -> { revision = detail.capabilityNumber("membershipRevision"); if(!applied || sequence <= 0) throw ClientFailure.Protocol() }
                    }
                    if(revision != null && revision != expected) throw ClientFailure.Protocol()
                    GroupCapabilityStatus.Committed
                }
                "rejected" -> { reason = rejection(outcome.objectValue(key).objectValue("_0")); if(reason == "revisionChanged") GroupCapabilityStatus.Conflicted else GroupCapabilityStatus.Rejected }
                "closed" -> { emptyCase(outcome, key); GroupCapabilityStatus.Closed }
                else -> throw ClientFailure.Protocol()
            }
            return GroupCapabilityResult.Receipt(status, revision, sequence, reason, value.toString())
        }
    }
}
@Serializable enum class GroupCapabilityStatus { DraftReady, DraftPaused, DraftCancelled, Pending, NeedsAttention, Committed, Rejected, Conflicted, Closed }
@Serializable data class GroupCapabilityWork(val intent: GroupCapabilityIntent, val activation: String, val status: GroupCapabilityStatus = GroupCapabilityStatus.DraftReady,
    val admission: GroupCapabilityAdmission? = null, val preparationAttempts: Int = 0, val attempts: Int = 0,
    val nextAttemptMilliseconds: Long = 0, val reconcile: Boolean = false, val receipt: String? = null, val reason: String? = null,
    /** null denotes a legacy row; true survives retries, cancellation and process restart. */
    val executionStarted: Boolean? = null) {
    val terminal get() = status in setOf(GroupCapabilityStatus.DraftCancelled, GroupCapabilityStatus.Committed, GroupCapabilityStatus.Rejected, GroupCapabilityStatus.Conflicted, GroupCapabilityStatus.Closed)
    fun command() = GroupCapabilityCommand(intent, requireNotNull(admission))
}
interface GroupCapabilityStore {
    suspend fun capabilityWorks(): PersistentList<GroupCapabilityWork>
    suspend fun capabilityWork(operation:String): GroupCapabilityWork? = capabilityWorks().firstOrNull {it.intent.operation==operation}
    suspend fun prepareCapability(intent: GroupCapabilityIntent, activation: String): GroupCapabilityWork
    suspend fun replaceCapabilityDraft(expected: GroupCapabilityWork, intent: GroupCapabilityIntent, activation: String): GroupCapabilityWork
    suspend fun updateCapability(expected: GroupCapabilityWork, updated: GroupCapabilityWork)
}

/** Explicit reconfirmation may update only the observed revision, not silently replace the desired action. */
fun GroupAction.sameDesiredValue(other: GroupAction): Boolean = when(this) {
    is GroupAction.Pin -> other is GroupAction.Pin && message == other.message && pinned == other.pinned
    is GroupAction.Announcement -> other is GroupAction.Announcement && body == other.body
    is GroupAction.Permissions -> other is GroupAction.Permissions && role == other.role && permissions == other.permissions
    is GroupAction.Role -> other is GroupAction.Role && target == other.target && role == other.role
    is GroupAction.Transfer -> other is GroupAction.Transfer && target == other.target
    is GroupAction.Dissolve -> other is GroupAction.Dissolve
}

private fun JsonObject.capabilityNumber(key: String): Long = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
private fun JsonObject.capabilityBoolean(key: String): Boolean = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.booleanOrNull ?: throw ClientFailure.Protocol()
