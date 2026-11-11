package com.xmtx.im.client

import kotlinx.serialization.json.*
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Base64

/** Swift operation v1 semantic encoding. Callers enumerate fields in UTF-8 lexical order. */
internal class OperationFingerprint(kind: String) {
    private val bytes = ByteArrayOutputStream()
    private val output = DataOutputStream(bytes)
    private var lastField: String? = null
    init { string("im.v2.operation"); output.writeLong(1); string(kind) }
    private fun string(value: String) { val encoded = value.toByteArray(Charsets.UTF_8); output.writeLong(encoded.size.toLong()); output.write(encoded) }
    private fun field(name: String, tag: Int) {
        require(name.isNotEmpty() && (lastField == null || lastField!! < name)); lastField = name
        string(name); output.writeByte(tag)
    }
    fun text(name: String, value: String) { field(name, 1); string(value) }
    fun unsigned(name: String, value: Long) { require(value >= 0); field(name, 2); output.writeLong(value) }
    fun flag(name: String, value: Boolean) { field(name, 5); output.writeByte(if(value) 1 else 0) }
    fun absent(name: String) { field(name, 0) }
    fun bytes(name: String, value: ByteArray) { field(name, 4); output.writeLong(value.size.toLong()); output.write(value) }
    fun orderedText(name: String, values: List<String>) { field(name, 6); output.writeLong(values.size.toLong()); values.forEach(::string) }
    fun digest(): String = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()))
}
internal fun pairIdentity(actor: UserId, target: UserId, operation: String, kind: String) = buildJsonObject {
    put("accountID", wireId(actor.value))
    put("scope", buildJsonObject { put("userPair", buildJsonObject { put("_0", wireId(actor.value)); put("_1", wireId(target.value)) }) })
    put("operation", buildJsonObject { put(kind, buildJsonObject { put("_0", wireId(operation)) }) })
}
internal fun pairStorageKey(actor: UserId, target: UserId, operation: String, kind: String) = "${actor.value}/pair/${actor.value}/${target.value}/$kind/$operation"
internal fun fingerprintPayload(digest: String) = buildJsonObject { put("version", 1); put("digest", digest) }
internal fun roomIdentity(actor: UserId, room: RoomId, operation: String, kind: String) = buildJsonObject {
    put("accountID", wireId(actor.value)); put("scope", buildJsonObject { put("room", buildJsonObject { put("_0", wireId(room.value)) }) })
    put("operation", buildJsonObject { put(kind, buildJsonObject { put("_0", wireId(operation)) }) })
}
internal fun validateRoomProof(actor: UserId, room: RoomId, operationID: String, kind: String, digest: String,
    value: JsonObject, fingerprintKey: String = "fingerprint") {
    val identity = value.objectValue("identity"); val scope = identity.objectValue("scope"); val operation = identity.objectValue("operation")
    if (UserId(identity.identifier("accountID")) != actor || scope.keys != setOf("room") || operation.keys != setOf(kind) ||
        RoomId(scope.objectValue("room").identifier("_0")) != room || canonicalId(operation.objectValue(kind).identifier("_0")) != operationID) throw ClientFailure.Protocol()
    val fp = value.objectValue(fingerprintKey)
    if (fp["version"]?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull != 1L || fp.string("digest") != digest) throw ClientFailure.Protocol()
}
internal fun validatePairProof(actor: UserId, target: UserId, operationID: String, kind: String, digest: String, value: JsonObject) {
    val identity = value.objectValue("identity")
    val scope = identity.objectValue("scope")
    val operation = identity.objectValue("operation")
    if (UserId(identity.identifier("accountID")) != actor || scope.keys != setOf("userPair") || operation.keys != setOf(kind)) throw ClientFailure.Protocol()
    val pair = scope.objectValue("userPair")
    if (UserId(pair.identifier("_0")) != actor || UserId(pair.identifier("_1")) != target || uuidId(operation.objectValue(kind).identifier("_0")) != operationID) throw ClientFailure.Protocol()
    val fp = value.objectValue("fingerprint")
    if (fp["version"]?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull != 1L || fp.string("digest") != digest) throw ClientFailure.Protocol()
}
internal fun retryAfterMilliseconds(value: String, now: Long): Long {
    val seconds = value.trim().toLongOrNull()
    val delay = if (seconds != null) {
        if (seconds !in 0..86_400) throw ClientFailure.Protocol()
        seconds * 1_000
    } else runCatching { (ZonedDateTime.parse(value, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() - now).coerceAtLeast(0) }
        .getOrElse { throw ClientFailure.Protocol() }
    if (delay > 86_400_000) throw ClientFailure.Protocol()
    return delay
}
internal fun retryHintDelay(hint: JsonObject, response: EdgeResponse, now: Long): Long {
    if (hint.string("reason") !in setOf("rateLimited", "admissionUnavailable")) throw ClientFailure.Protocol()
    val raw = hint["retryAfterMilliseconds"]?.takeUnless { it is JsonNull }
    val delay = raw?.jsonPrimitive?.longOrNull
    if (raw != null && (delay == null || delay !in 1..86_400_000)) throw ClientFailure.Protocol()
    return maxOf(delay ?: 0, response.retryAfter?.let { retryAfterMilliseconds(it, now) } ?: 0)
}
