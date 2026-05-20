package com.xmtx.imclientkit

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.xmtx.imclientkit.persistence.EncryptedTokenStore
import com.xmtx.imclientkit.persistence.InMemoryTokenStore
import com.xmtx.imclientkit.persistence.TokenCipher
import com.xmtx.imclientkit.persistence.TokenSnapshot
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class EncryptedTokenStoreTests {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("encrypted-token-test", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test
    fun savesLoadsAndClearsEncryptedTokens() = runTest {
        val store = EncryptedTokenStore(
            preferences = context.getSharedPreferences("encrypted-token-test", Context.MODE_PRIVATE),
            cipher = PrefixTokenCipher(),
        )

        store.save(TokenSnapshot("access", "refresh"))

        assertEquals(TokenSnapshot("access", "refresh"), store.load())

        store.clear()

        assertNull(store.load())
    }

    @Test
    fun migratesLegacyDataStoreTokenAndClearsLegacy() = runTest {
        val legacy = InMemoryTokenStore(TokenSnapshot("legacy-access", "legacy-refresh"))
        val store = EncryptedTokenStore(
            preferences = context.getSharedPreferences("encrypted-token-test", Context.MODE_PRIVATE),
            cipher = PrefixTokenCipher(),
            legacyStore = legacy,
        )

        assertEquals(TokenSnapshot("legacy-access", "legacy-refresh"), store.load())
        assertNull(legacy.load())
        assertEquals(TokenSnapshot("legacy-access", "legacy-refresh"), store.load())
    }

    private class PrefixTokenCipher : TokenCipher {
        override fun encrypt(value: String): String = "encrypted:$value"
        override fun decrypt(value: String): String = value.removePrefix("encrypted:")
    }
}
