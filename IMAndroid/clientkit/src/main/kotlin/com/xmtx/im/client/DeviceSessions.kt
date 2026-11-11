package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/** Account-owned metadata is ephemeral; only frozen security commands enter the encrypted journal. */
data class DeviceSession(val device: DeviceId, val name: String, val platform: String, val createdAt: Long,
    val lastActiveAt: Long, val current: Boolean)
data class DeviceSessionPage(val sessions: PersistentList<DeviceSession>, val cursor: String?)
data class DeviceRevocationBaseline(val id: String, val actor: UserId, val current: DeviceId,
    val targets: PersistentList<DeviceId>, val issuedAt: Long, val expiresAt: Long) {
    init {
        require(UUID.fromString(id).toString().uppercase() == id)
        require(UUID.fromString(actor.value).toString().uppercase() == actor.value)
        require(targets.size <= 256 && targets.distinct().size == targets.size && current !in targets)
        require(targets.map { it.value } == targets.map { it.value }.sorted())
        require(issuedAt > 0 && expiresAt > issuedAt && expiresAt - issuedAt <= 120000)
    }
    fun payload() = buildJsonObject {
        put("id", id); put("actorUserID", deviceIDWire(actor.value)); put("currentDeviceID", deviceIDWire(current.value))
        put("targetDeviceIDs", JsonArray(targets.map { deviceIDWire(it.value) }))
        put("issuedAtMilliseconds", issuedAt); put("expiresAtMilliseconds", expiresAt)
    }
    companion object {
        fun decode(value: JsonObject) = DeviceRevocationBaseline(value.string("id"), UserId(value.getValue("actorUserID").jsonObject.string("rawValue")),
            DeviceId(value.getValue("currentDeviceID").jsonObject.string("rawValue")), value.getValue("targetDeviceIDs").jsonArray.map { DeviceId(it.jsonObject.string("rawValue")) }.toPersistentList(),
            value.number("issuedAtMilliseconds"), value.number("expiresAtMilliseconds"))
    }
}
/** Null selection means the exact frozen set of all observed other devices, never later sessions. */
data class DeviceRevocationCommand(val operation: String, val baseline: DeviceRevocationBaseline, val selection: DeviceId?, val deadline: Long) {
    init {
        require(UUID.fromString(operation).toString().uppercase() == operation)
        require(selection == null || selection in baseline.targets)
        require(deadline > baseline.issuedAt && deadline <= baseline.expiresAt)
    }
    val targets: PersistentList<DeviceId> get() = selection?.let { persistentListOf(it) } ?: baseline.targets
    fun payload() = buildJsonObject {
        put("operationID", operation); put("baseline", baseline.payload()); put("firstSubmissionDeadlineMilliseconds", deadline)
        put("selection", buildJsonObject { if(selection == null) put("allObservedOthers", buildJsonObject {})
            else put("device", buildJsonObject { put("_0", deviceIDWire(selection.value)) }) })
    }
    val fingerprint: String get() = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(
        "IMV2.remote-device-revocation.command.v1\u0000".toByteArray() + canonicalDeviceJSON(payload()).toString().toByteArray()))
    fun recovery(action: String = "closeIfAbsent") = buildJsonObject {
        require(action in setOf("query", "closeIfAbsent")); put("command", payload()); put("action", action)
    }
    companion object {
        fun decode(value: JsonObject): DeviceRevocationCommand {
            val selection = value.getValue("selection").jsonObject
            require(selection.size == 1 && selection.keys.single() in setOf("device", "allObservedOthers"))
            selection.values.single().jsonObject
            val device = selection["device"]?.jsonObject?.getValue("_0")?.jsonObject?.string("rawValue")?.let { DeviceId(it) }
            return DeviceRevocationCommand(value.string("operationID"), DeviceRevocationBaseline.decode(value.getValue("baseline").jsonObject), device, value.number("firstSubmissionDeadlineMilliseconds"))
        }
    }
}
private fun deviceIDWire(value: String) = buildJsonObject { put("rawValue", value) }
private fun canonicalDeviceJSON(value: JsonElement): JsonElement = when(value) {
    is JsonObject -> JsonObject(value.toSortedMap().mapValues { canonicalDeviceJSON(it.value) })
    is JsonArray -> JsonArray(value.map(::canonicalDeviceJSON))
    else -> value
}
enum class DeviceRevocationOutcome { Revoked, Closed, Rejected }
data class DeviceRevocationReceipt(val outcome: DeviceRevocationOutcome, val reason: String?, val resolvedAt: Long, val wire: String) {
    companion object {
        fun decode(command: DeviceRevocationCommand, value: JsonObject): DeviceRevocationReceipt {
            require(value.getValue("actorUserID") == deviceIDWire(command.baseline.actor.value))
            require(value.getValue("currentDeviceID") == deviceIDWire(command.baseline.current.value))
            require(value.string("operationID") == command.operation && value.string("fingerprint") == command.fingerprint)
            require(value.getValue("targetDeviceIDs") == JsonArray(command.targets.map { deviceIDWire(it.value) }))
            val outcome = value.getValue("outcome").jsonObject; require(outcome.size == 1)
            val kind = when(outcome.keys.single()) { "revoked" -> DeviceRevocationOutcome.Revoked; "closed" -> DeviceRevocationOutcome.Closed; "rejected" -> DeviceRevocationOutcome.Rejected; else -> throw ClientFailure.Protocol() }
            val reason = if(kind == DeviceRevocationOutcome.Rejected) outcome.getValue("rejected").jsonObject.string("_0").also {
                require(it in setOf("deadlineExpired", "baselineUnavailable", "authorizationDenied")) } else null
            val time = value.number("resolvedAtMilliseconds"); require(time > 0)
            return DeviceRevocationReceipt(kind, reason, time, canonicalDeviceJSON(value).toString())
        }
    }
}
sealed interface DeviceRevocationResult {
    data class Receipt(val receipt: DeviceRevocationReceipt): DeviceRevocationResult
    data object Unresolved: DeviceRevocationResult
    data object Conflict: DeviceRevocationResult
}
class DeviceBackpressure(val delayMilliseconds: Long): Exception()
class DeviceSessionClient(private val api: AuthenticatedTransport, private val current: DeviceId,
    private val now: () -> Long = System::currentTimeMillis) {
    suspend fun list(cursor: String? = null, pageSize: Int = 50): DeviceSessionPage = withTimeout(15000) {
        require(pageSize in 1..100)
        val query = buildMap { put("page_size", pageSize.toString()); cursor?.let { require(it.isNotBlank()); put("cursor", it) } }
        val response = checked(api.requestWithQuery("/v2/devices", query, 1_048_576))
        val sessions = response.getValue("sessions").jsonArray.map { item ->
            val value = item.jsonObject
            val id = DeviceId(value.string("deviceID")); val isCurrent = value.getValue("isCurrentDevice").jsonPrimitive.boolean
            require(isCurrent == (id == current))
            DeviceSession(id, value.getValue("deviceName").jsonPrimitive.content, value.getValue("platform").jsonPrimitive.content,
                value.number("createdAtMilliseconds"), value.number("lastActiveAtMilliseconds"), isCurrent)
        }.toPersistentList()
        require(sessions.size <= pageSize && sessions.map { it.device }.distinct().size == sessions.size)
        DeviceSessionPage(sessions, response["nextCursor"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content?.also { require(it.isNotBlank() && it != cursor) })
    }
    suspend fun baseline(): DeviceRevocationBaseline = withTimeout(15000) {
        DeviceRevocationBaseline.decode(checked(api.request("/v2/devices/revocation-baseline")))
    }
    suspend fun execute(command: DeviceRevocationCommand, recover: Boolean): DeviceRevocationResult = withTimeout(15000) {
        val body = if(recover) command.recovery() else command.payload(); require(body.toString().toByteArray().size <= 32768)
        val result = checked(api.requestWithoutReplay(if(recover) "/v2/devices/remote-revocations/operations/recover" else "/v2/devices/remote-revocations/submit", body))
        require(result.size == 1)
        when(result.keys.single()) {
            "receipt" -> DeviceRevocationResult.Receipt(DeviceRevocationReceipt.decode(command, result.getValue("receipt").jsonObject.getValue("_0").jsonObject))
            "unresolved" -> { result.getValue("unresolved").jsonObject; DeviceRevocationResult.Unresolved }
            "fingerprintConflict" -> { result.getValue("fingerprintConflict").jsonObject; DeviceRevocationResult.Conflict }
            else -> throw ClientFailure.Protocol()
        }
    }
    private fun checked(response: EdgeResponse): JsonObject {
        if(response.status in setOf(429,503)) throw DeviceBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it, now()) } ?: 0)
        if(response.status != 200) throw response.failure()
        return response.body
    }
}
