package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class InstallationBindingTests {
    private class Record : SecretStore {
        var value: String? = null
        var failure: Exception? = null
        override suspend fun read(): String? { failure?.let { throw it }; return value }
        override suspend fun write(value: String) { failure?.let { throw it }; this.value = value }
        override suspend fun delete() { failure?.let { throw it }; value = null }
    }
    @Test fun `independent record round trips and explicit deletion removes only its binding`() = runTest {
        val secret = Record(); val store = SecretInstallationBindingStore(secret)
        assertNull(store.load())
        val binding = LocalInstallationBinding.create()
        store.save(binding)
        assertEquals(binding, SecretInstallationBindingStore(secret).load())
        assertTrue(secret.value!!.contains("\"format\":1"))
        store.delete(); assertNull(store.load())
    }
    @Test fun `malformed record stays present instead of becoming a missing binding`() = runTest {
        val secret = Record(); val store = SecretInstallationBindingStore(secret)
        for (value in listOf("", "{}", "[]", "x".repeat(257),
            """{"format":2,"binding":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}""",
            """{"format":"1","binding":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}""",
            """{"format":1,"binding":"not-a-uuid"}""")) {
            secret.value = value
            assertEquals(LocalStoreFailure.Reason.BindingMalformed, assertFailsWith<LocalStoreFailure> { store.load() }.reason)
            assertEquals(value, secret.value)
        }
    }
    @Test fun `unavailable and terminal failures preserve the record and cancellation propagates`() = runTest {
        val secret = Record(); val store = SecretInstallationBindingStore(secret)
        val binding = LocalInstallationBinding.create(); store.save(binding); val saved = secret.value
        secret.failure = java.io.IOException("unavailable")
        assertEquals(LocalStoreFailure.Reason.BindingUnavailable, assertFailsWith<LocalStoreFailure> { store.load() }.reason)
        assertEquals(saved, secret.value)
        secret.failure = LocalStoreFailure(LocalStoreFailure.Reason.BindingInvalidated)
        assertEquals(LocalStoreFailure.Reason.BindingInvalidated, assertFailsWith<LocalStoreFailure> { store.load() }.reason)
        secret.failure = CancellationException()
        assertFailsWith<CancellationException> { store.load() }
        assertEquals(saved, secret.value)
    }
}
