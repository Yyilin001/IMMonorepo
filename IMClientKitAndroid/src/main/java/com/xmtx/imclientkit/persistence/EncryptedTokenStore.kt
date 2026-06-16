package com.xmtx.imclientkit.persistence

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class EncryptedTokenStore internal constructor(
    private val preferences: SharedPreferences,
    private val cipher: TokenCipher,
) : TokenStore {
    constructor(context: Context) : this(
        preferences = context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE),
        cipher = AndroidKeystoreTokenCipher(),
    )

    override suspend fun load(): TokenSnapshot? {
        val accessToken = preferences.getString(ACCESS_TOKEN, null)
        val refreshToken = preferences.getString(REFRESH_TOKEN, null)
        if (accessToken != null && refreshToken != null) {
            return runCatching {
                TokenSnapshot(
                    accessToken = cipher.decrypt(accessToken),
                    refreshToken = cipher.decrypt(refreshToken),
                )
            }.getOrElse {
                clear()
                null
            }
        }
        if (accessToken != null || refreshToken != null) {
            clear()
            return null
        }
        return null
    }

    override suspend fun save(snapshot: TokenSnapshot) {
        preferences.edit()
            .putString(ACCESS_TOKEN, cipher.encrypt(snapshot.accessToken))
            .putString(REFRESH_TOKEN, cipher.encrypt(snapshot.refreshToken))
            .apply()
    }

    override suspend fun clear() {
        preferences.edit()
            .remove(ACCESS_TOKEN)
            .remove(REFRESH_TOKEN)
            .apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "imclientkit_encrypted_tokens"
        const val ACCESS_TOKEN = "access_token"
        const val REFRESH_TOKEN = "refresh_token"
    }
}

internal interface TokenCipher {
    fun encrypt(value: String): String
    fun decrypt(value: String): String
}

internal class AndroidKeystoreTokenCipher(
    private val keyAlias: String = "imclientkit_token_key",
) : TokenCipher {
    private val secureRandom = SecureRandom()

    override fun encrypt(value: String): String {
        val iv = ByteArray(GCM_IV_BYTES)
        secureRandom.nextBytes(iv)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return "${iv.base64()}:${encrypted.base64()}"
    }

    override fun decrypt(value: String): String {
        val parts = value.split(":", limit = 2)
        require(parts.size == 2) { "Invalid encrypted token." }
        val iv = parts[0].fromBase64()
        val encrypted = parts[1].fromBase64()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(encrypted).toString(Charsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        if (!keyStore.containsAlias(keyAlias)) {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
            val spec = KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
            generator.init(spec)
            generator.generateKey()
        }
        return (keyStore.getEntry(keyAlias, null) as KeyStore.SecretKeyEntry).secretKey
    }

    private fun ByteArray.base64(): String = Base64.getEncoder().encodeToString(this)
    private fun String.fromBase64(): ByteArray = Base64.getDecoder().decode(this)

    private companion object {
        const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_IV_BYTES = 12
        const val GCM_TAG_BITS = 128
    }
}
