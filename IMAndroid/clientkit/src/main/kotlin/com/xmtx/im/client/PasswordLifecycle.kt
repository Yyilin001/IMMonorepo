package com.xmtx.im.client

import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.security.SecureRandom

/** Explicit factor operations: no bearer token, secret journal, or automatic retry. */
enum class PasswordAction(val path: String) { Change("change"), RecoveryCode("recovery-code"), Recover("recover") }
class PasswordLifecycleFailure(val reason: Reason, val retryAfterSeconds: Long? = null) : Exception(reason.name) {
    enum class Reason { InvalidPassword, InvalidRecoveryCode, AuthenticationRejected, InvalidInput, RateLimited }
}
class PasswordLifecycleClient(private val transport: AccountTransport) {
    suspend fun perform(action: PasswordAction, account: String, device: DeviceId, current: String? = null,
        next: String? = null, recoveryCode: String? = null) = withTimeout(15000) {
        if(action != PasswordAction.Recover && !validPassword(current) || action != PasswordAction.RecoveryCode && !validPassword(next))
            throw PasswordLifecycleFailure(PasswordLifecycleFailure.Reason.InvalidPassword)
        if(action != PasswordAction.Change && !validRecoveryCode(recoveryCode))
            throw PasswordLifecycleFailure(PasswordLifecycleFailure.Reason.InvalidRecoveryCode)
        val input = buildJsonObject {
            put("accountHandle", account); put("deviceID", device.value)
            current?.let { put("currentPassword", it) }; next?.let { put("newPassword", it) }; recoveryCode?.let { put("recoveryCode", it) }
        }
        try {
            val response = transport.post("/v2/account-auth/password/${action.path}", input, expectedStatus = 204)
            if(response.isNotEmpty()) throw ClientFailure.Protocol()
        } catch(error: ClientFailure.Http) {
            when(error.status) {
                400 -> throw PasswordLifecycleFailure(PasswordLifecycleFailure.Reason.InvalidInput)
                401 -> throw PasswordLifecycleFailure(PasswordLifecycleFailure.Reason.AuthenticationRejected)
                429 -> throw PasswordLifecycleFailure(PasswordLifecycleFailure.Reason.RateLimited, error.retryAfter?.toLongOrNull()?.takeIf { it > 0 })
                else -> throw error
            }
        }
    }
    companion object {
        fun validPassword(value: String?) = value != null && value.toByteArray(Charsets.UTF_8).size in 12..1024 && '\u0000' !in value
        fun validRecoveryCode(value: String?) = value != null && value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
        fun generateRecoveryCode(): String {
            val bytes = ByteArray(32).also { random.nextBytes(it) }
            val hex = "0123456789abcdef"
            return buildString(64) { bytes.forEach { byte -> val value = byte.toInt() and 255; append(hex[value ushr 4]); append(hex[value and 15]) } }
        }
        private val random = SecureRandom()
    }
}
