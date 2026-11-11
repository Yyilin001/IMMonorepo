package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable enum class PreferenceKind(val wire: String, val projection: String) {
    StrangerMessages("strangerMessagePreference", "stranger_message_permission"), UserAdd("userAddPreference", "user_add_permission"),
    ReadReceipts("readReceiptPreference", "read_receipt_preferences"), LiveActivity("liveActivityPreference", "live_activity_preferences")
}
/** The second field is present only for paired preferences. A patch can leave either field untouched. */
@Serializable data class PreferenceValue(val kind: PreferenceKind, val first: Boolean, val second: Boolean? = null) {
    init { require((kind in setOf(PreferenceKind.ReadReceipts, PreferenceKind.LiveActivity)) == (second != null)) }
    fun payload() = buildJsonObject {
        when(kind) {
            PreferenceKind.StrangerMessages, PreferenceKind.UserAdd -> put(if(kind == PreferenceKind.StrangerMessages) "strangerMessage" else "userAdd", buildJsonObject { put("_0", if(first) "allow" else "deny") })
            PreferenceKind.ReadReceipts -> put("readReceipt", buildJsonObject { put("allowsDirectReadReceipts", first); put("allowsGroupReadReceipts", requireNotNull(second)) })
            PreferenceKind.LiveActivity -> put("liveActivity", buildJsonObject { put("allowsOnlinePresence", first); put("allowsTypingIndicators", requireNotNull(second)) })
        }
    }
    companion object {
        fun decode(value: JsonObject): PreferenceValue {
            if(value.size != 1) throw ClientFailure.Protocol()
            val key = value.keys.single(); val detail = value.objectValue(key)
            return when(key) {
                "strangerMessage", "userAdd" -> PreferenceValue(if(key == "strangerMessage") PreferenceKind.StrangerMessages else PreferenceKind.UserAdd,
                    when(detail.string("_0")) { "allow" -> true; "deny" -> false; else -> throw ClientFailure.Protocol() })
                "readReceipt" -> PreferenceValue(PreferenceKind.ReadReceipts, detail.preferenceBoolean("allowsDirectReadReceipts"), detail.preferenceBoolean("allowsGroupReadReceipts"))
                "liveActivity" -> PreferenceValue(PreferenceKind.LiveActivity, detail.preferenceBoolean("allowsOnlinePresence"), detail.preferenceBoolean("allowsTypingIndicators"))
                else -> throw ClientFailure.Protocol()
            }
        }
    }
}
@Serializable data class PreferencePatch(val kind: PreferenceKind, val first: Boolean? = null, val second: Boolean? = null) {
    init { require(first != null || second != null); require(kind in setOf(PreferenceKind.ReadReceipts, PreferenceKind.LiveActivity) || first != null && second == null) }
    fun apply(baseline: PreferenceValue): PreferenceValue { require(kind == baseline.kind); return baseline.copy(first = first ?: baseline.first, second = second ?: baseline.second) }
    fun matches(value: PreferenceValue) = value.kind == kind && (first == null || first == value.first) && (second == null || second == value.second)
}
@Serializable data class PreferenceSnapshot(val actor: UserId, val value: PreferenceValue, val revision: Long) {
    init { require(uuidId(actor.value) == actor.value && revision >= 0) }
}
@Serializable data class PreferenceCommand(val actor: UserId, val operation: String, val value: PreferenceValue, val revision: Long, val deadline: Long) {
    init { require(uuidId(actor.value) == actor.value && uuidId(operation) == operation && revision in 0 until Long.MAX_VALUE && deadline > 0) }
    fun identity() = buildJsonObject {
        put("accountID", wireId(actor.value)); put("scope", buildJsonObject { put("account", buildJsonObject { put("_0", wireId(actor.value)) }) })
        put("operation", buildJsonObject { put(value.kind.wire, buildJsonObject { put("_0", wireId(operation)) }) })
    }
    val fingerprint get() = OperationFingerprint(value.kind.wire).apply {
        when(value.kind) {
            PreferenceKind.ReadReceipts -> { flag("allowsDirectReadReceipts", value.first); flag("allowsGroupReadReceipts", requireNotNull(value.second)) }
            PreferenceKind.LiveActivity -> { flag("allowsOnlinePresence", value.first); flag("allowsTypingIndicators", requireNotNull(value.second)) }
            else -> Unit
        }
        unsigned("expectedRevision", revision); unsigned("firstSubmissionDeadline", deadline)
        text("identity", "${actor.value}/account/${actor.value}/${value.kind.wire}/$operation")
        if(value.second == null) text("permission", if(value.first) "allow" else "deny")
    }.digest()
    fun payload() = buildJsonObject { put("identity", identity()); put("value", value.payload()); put("expectedRevision", revision); put("firstSubmissionDeadlineMilliseconds", deadline) }
    fun recovery(close: Boolean) = buildJsonObject { put("identity", identity()); put("fingerprint", fingerprintPayload(fingerprint)); put("action", if(close) "closeIfAbsent" else "query") }
    internal fun validateProof(proof: JsonObject) {
        val identity = proof.objectValue("identity"); val scope = identity.objectValue("scope"); val operationValue = identity.objectValue("operation")
        if(UserId(identity.identifier("accountID")) != actor || scope.keys != setOf("account") || UserId(scope.objectValue("account").identifier("_0")) != actor ||
            operationValue.keys != setOf(value.kind.wire) || uuidId(operationValue.objectValue(value.kind.wire).identifier("_0")) != operation) throw ClientFailure.Protocol()
        val fp = proof.objectValue("fingerprint"); if(fp.preferenceLong("version") != 1L || fp.string("digest") != fingerprint) throw ClientFailure.Protocol()
    }
}
sealed interface PreferenceResult {
    data class Receipt(val status: PreferenceStatus, val applied: PreferenceSnapshot?, val rejection: String?, val wire: String) : PreferenceResult
    data class Deferred(val delayMilliseconds: Long) : PreferenceResult
    data object Unresolved : PreferenceResult
    data object Conflict : PreferenceResult
}
class PreferenceBackpressure(val delayMilliseconds: Long) : Exception("请稍后重试")
class AccountPreferenceClient(private val transport: AuthenticatedTransport, private val actor: UserId, private val now: () -> Long = System::currentTimeMillis) {
    suspend fun baseline(kind: PreferenceKind): PreferenceSnapshot {
        val response = transport.request("/v2/account-preferences/${kind.wire}/baseline")
        if(response.status in setOf(429,503)) throw PreferenceBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it, now()) } ?: 0)
        if(response.status != 200) throw response.failure()
        val body = response.body; val value = PreferenceValue.decode(body.objectValue("value"))
        if(UserId(body.identifier("ownerUserID")) != actor || value.kind != kind) throw ClientFailure.Protocol()
        return PreferenceSnapshot(actor, value, body.preferenceLong("revision"))
    }
    suspend fun execute(command: PreferenceCommand, recover: Boolean, close: Boolean): PreferenceResult {
        require(command.actor == actor)
        val payload = if(recover) command.recovery(close) else command.payload(); require(payload.toString().toByteArray().size <= 4096)
        val response = transport.request("/v2/account-preferences/operations/" + if(recover) "recover" else "submit", payload)
        if(response.status !in setOf(200,429,503)) throw response.failure()
        val root = response.body; if(root.size != 1) throw ClientFailure.Protocol()
        if(response.status != 200 && root.keys.single() != "deferred") throw response.failure()
        return when(val key = root.keys.single()) {
            "receipt" -> decodeReceipt(command, root.objectValue(key).objectValue("_0"))
            "deferred" -> { val hint = root.objectValue(key).objectValue("_0"); command.validateProof(hint); PreferenceResult.Deferred(retryHintDelay(hint, response, now())) }
            "unresolved" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); PreferenceResult.Unresolved }
            "fingerprintConflict" -> { if(root.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); PreferenceResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    companion object {
        fun decodeReceipt(command: PreferenceCommand, value: JsonObject): PreferenceResult.Receipt {
            command.validateProof(value); if(value.preferenceLong("resolvedAtMilliseconds") <= 0) throw ClientFailure.Protocol()
            val outcome = value.objectValue("outcome"); if(outcome.size != 1) throw ClientFailure.Protocol()
            var applied: PreferenceSnapshot? = null; var reason: String? = null
            val status = when(val key = outcome.keys.single()) {
                "applied" -> {
                    val fields = outcome.objectValue(key); val desired = PreferenceValue.decode(fields.objectValue("value")); val revision = fields.preferenceLong("revision")
                    if(desired != command.value || revision != command.revision + 1) throw ClientFailure.Protocol()
                    applied = PreferenceSnapshot(command.actor, desired, revision); PreferenceStatus.Committed
                }
                "closed" -> { if(outcome.objectValue(key).isNotEmpty()) throw ClientFailure.Protocol(); PreferenceStatus.Closed }
                "rejected" -> {
                    val rejected = outcome.objectValue(key).objectValue("_0"); if(rejected.size != 1) throw ClientFailure.Protocol()
                    reason = rejected.keys.single(); val fields = rejected.objectValue(reason)
                    when(reason) {
                        "revisionConflict" -> { if(fields.preferenceLong("currentRevision") < 0) throw ClientFailure.Protocol(); PreferenceStatus.Conflicted }
                        "firstSubmissionExpired", "invalidDeadline", "permissionDenied" -> { if(fields.isNotEmpty()) throw ClientFailure.Protocol(); PreferenceStatus.Rejected }
                        else -> throw ClientFailure.Protocol()
                    }
                }
                else -> throw ClientFailure.Protocol()
            }
            return PreferenceResult.Receipt(status, applied, reason, value.toString())
        }
        fun projection(actor: UserId, kind: PreferenceKind, payload: JsonObject): Pair<PreferenceSnapshot, Long> {
            val value = when(kind) {
                PreferenceKind.StrangerMessages -> PreferenceValue(kind, payload.preferenceBoolean("allows_stranger_messages"))
                PreferenceKind.UserAdd -> PreferenceValue(kind, payload.preferenceBoolean("allows_being_added"))
                PreferenceKind.ReadReceipts -> PreferenceValue(kind, payload.preferenceBoolean("allows_direct_read_receipts"), payload.preferenceBoolean("allows_group_read_receipts"))
                PreferenceKind.LiveActivity -> PreferenceValue(kind, payload.preferenceBoolean("allows_online_presence"), payload.preferenceBoolean("allows_typing_indicators"))
            }
            val revision = payload.preferenceLong(if(kind == PreferenceKind.ReadReceipts) "preference_revision" else "revision")
            val time = payload.preferenceLong("updated_at_ms"); if(revision <= 0 || time < 0) throw ClientFailure.Protocol()
            return PreferenceSnapshot(actor, value, revision) to time
        }
    }
}
@Serializable enum class PreferenceStatus { DraftReady, DraftPaused, DraftCancelled, Pending, NeedsAttention, Committed, Rejected, Conflicted, Closed }
@Serializable data class PreferenceWork(val actor: UserId, val operation: String, val patch: PreferencePatch, val activation: String, val confirmedUntil: Long,
    val status: PreferenceStatus = PreferenceStatus.DraftReady, val command: PreferenceCommand? = null, val preparationAttempts: Int = 0,
    val attempts: Int = 0, val nextAttemptMilliseconds: Long = 0, val reconcile: Boolean = false, val receipt: String? = null, val reason: String? = null,
    /** null denotes a legacy row; true survives retries, cancellation and process restart. */
    val executionStarted: Boolean? = null) {
    init { require(uuidId(actor.value) == actor.value && uuidId(operation) == operation && confirmedUntil > 0) }
    val terminal get() = status in setOf(PreferenceStatus.DraftCancelled, PreferenceStatus.Committed, PreferenceStatus.Rejected, PreferenceStatus.Conflicted, PreferenceStatus.Closed)
}
interface AccountPreferenceStore {
    suspend fun preferenceWorks(): PersistentList<PreferenceWork>
    suspend fun preferenceWork(operation:String): PreferenceWork? = preferenceWorks().firstOrNull {it.operation==operation}
    suspend fun preferenceSnapshots(): PersistentList<PreferenceSnapshot>
    suspend fun savePreference(snapshot: PreferenceSnapshot)
    suspend fun preparePreference(work: PreferenceWork): PreferenceWork
    suspend fun replacePreferenceDraft(expected: PreferenceWork, replacement: PreferenceWork): PreferenceWork
    suspend fun updatePreference(expected: PreferenceWork, updated: PreferenceWork)
}
/** Pending restrictions take effect locally; pending grants never override confirmed denial. */
data class PreferencePublicationPolicy(val directRead: Boolean, val groupRead: Boolean, val online: Boolean, val typing: Boolean) {
    companion object {
        fun derive(snapshots: PersistentList<PreferenceSnapshot>, works: PersistentList<PreferenceWork>): PreferencePublicationPolicy {
            val read = snapshots.firstOrNull { it.value.kind == PreferenceKind.ReadReceipts }?.value
            val live = snapshots.firstOrNull { it.value.kind == PreferenceKind.LiveActivity }?.value
            var direct = read?.first ?: true; var group = read?.second ?: true; var online = live?.first ?: true; var typing = live?.second ?: true
            works.filter { !it.terminal }.forEach { work ->
                val first = work.command?.value?.first ?: work.patch.first; val second = work.command?.value?.second ?: work.patch.second
                when(work.patch.kind) {
                    PreferenceKind.ReadReceipts -> { if(first == false) direct = false; if(second == false) group = false }
                    PreferenceKind.LiveActivity -> { if(first == false) online = false; if(second == false) typing = false }
                    else -> Unit
                }
            }
            return PreferencePublicationPolicy(direct, group, online, typing)
        }
    }
}
private fun JsonObject.preferenceBoolean(key: String): Boolean = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.booleanOrNull ?: throw ClientFailure.Protocol()
private fun JsonObject.preferenceLong(key: String): Long = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
