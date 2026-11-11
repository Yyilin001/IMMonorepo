package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

class PasswordLifecycleTests {
    private val device = DeviceId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private class Transport : AccountTransport {
        var calls = 0
        var path: String? = null
        var payload: JsonObject? = null
        var failure: Exception? = null
        override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
            calls++; this.path = path; this.payload = payload
            assertNull(accessToken); assertEquals(204, expectedStatus)
            failure?.let { throw it }; return buildJsonObject {}
        }
    }
    @Test fun `all three wire operations preserve exact secrets omit absent factors and use plain device ID`() = runTest {
        val transport = Transport(); val client = PasswordLifecycleClient(transport)
        val current = "password é e\u0301"; val next = "replacement-password"; val code = "0123456789abcdef".repeat(4)
        for(action in PasswordAction.entries) {
            val old = current.takeIf { action != PasswordAction.Recover }; val new = next.takeIf { action != PasswordAction.RecoveryCode }; val recovery = code.takeIf { action != PasswordAction.Change }
            client.perform(action, "account", device, old, new, recovery)
            assertEquals("/v2/account-auth/password/${action.path}", transport.path)
            assertEquals(buildJsonObject {
                put("accountHandle", "account"); put("deviceID", device.value)
                old?.let { put("currentPassword", it) }; new?.let { put("newPassword", it) }; recovery?.let { put("recoveryCode", it) }
            }, transport.payload)
        }
        assertEquals(3, transport.calls)
    }
    @Test fun `password UTF8 boundaries NUL and strict hex recovery code reject before network`() = runTest {
        val transport = Transport(); val client = PasswordLifecycleClient(transport)
        for(password in listOf("short", "x".repeat(1025), "x".repeat(11) + '\u0000')) {
            assertEquals(PasswordLifecycleFailure.Reason.InvalidPassword, assertFailsWith<PasswordLifecycleFailure> { client.perform(PasswordAction.Change, "account", device, "current-password", password) }.reason)
        }
        assertTrue(PasswordLifecycleClient.validPassword("中".repeat(4))); assertTrue(PasswordLifecycleClient.validPassword("é".repeat(512)))
        assertFalse(PasswordLifecycleClient.validPassword("é".repeat(513)))
        for(code in listOf("a".repeat(63), "a".repeat(65), "A".repeat(64), "g".repeat(64), " ".repeat(64))) {
            assertEquals(PasswordLifecycleFailure.Reason.InvalidRecoveryCode, assertFailsWith<PasswordLifecycleFailure> { client.perform(PasswordAction.Recover, "account", device, next = "replacement-password", recoveryCode = code) }.reason)
        }
        assertEquals(0, transport.calls)
    }
    @Test fun `uncertain failure and cancellation never retry or expose secrets in errors`() = runTest {
        for(error in listOf(IOException("lost"), ClientFailure.Http(503), CancellationException("cancelled"))) {
            val transport = Transport().apply { failure = error }
            val actual = assertFails { PasswordLifecycleClient(transport).perform(PasswordAction.Change, "account", device, "current-password", "replacement-password") }
            assertEquals(error.javaClass.name, actual.javaClass.name); assertEquals(error.message, actual.message)
            assertEquals(1, transport.calls)
        }
    }
    @Test fun `explicit rejection invalid input and rate limits remain distinct from uncertain outcomes`() = runTest {
        for((status, expected) in listOf(400 to PasswordLifecycleFailure.Reason.InvalidInput, 401 to PasswordLifecycleFailure.Reason.AuthenticationRejected, 429 to PasswordLifecycleFailure.Reason.RateLimited)) {
            val transport = Transport().apply { failure = ClientFailure.Http(status, retryAfter = "17") }
            val error = assertFailsWith<PasswordLifecycleFailure> { PasswordLifecycleClient(transport).perform(PasswordAction.Change, "account", device, "current-password", "replacement-password") }
            assertEquals(expected, error.reason); assertEquals(if(status == 429) 17L else null, error.retryAfterSeconds); assertEquals(1, transport.calls)
        }
    }
    @Test fun `256 bit generated recovery codes are distinct lowercase hex`() {
        val codes = (1..32).map { PasswordLifecycleClient.generateRecoveryCode() }
        assertEquals(32, codes.distinct().size); assertTrue(codes.all { PasswordLifecycleClient.validRecoveryCode(it) })
    }
}
