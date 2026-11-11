package com.xmtx.im.platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import com.xmtx.im.client.SecretStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class KeystoreRecordFailure(val reason: Reason) : Exception("Encrypted record unavailable") {
    enum class Reason { Malformed, KeyMissing }
}

/** AES-GCM authenticated encryption, Android Keystore key, atomic no-backup journal. */
class KeystoreSecretStore(context: Context, name: String) : SecretStore {
    private val alias = "com.xmtx.im.$name.v1"
    private val file = AtomicFile(File(context.noBackupFilesDir, "$name.enc"))
    private val mutex = Mutex()
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) throw KeystoreRecordFailure(KeystoreRecordFailure.Reason.KeyMissing)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    override suspend fun read(): String? = mutex.withLock { withContext(Dispatchers.IO) {
        val bytes = try { file.openRead().use { it.readBytes() } } catch (e: java.io.FileNotFoundException) {
            if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) throw e
            return@withContext null
        }
        if (bytes.size < 29 || bytes[0] != 1.toByte()) throw KeystoreRecordFailure(KeystoreRecordFailure.Reason.Malformed)
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
            updateAAD(alias.toByteArray()); doFinal(bytes.copyOfRange(13, bytes.size)).toString(Charsets.UTF_8)
        }
    } }
    override suspend fun write(value: String) = mutex.withLock { withContext(Dispatchers.IO) {
        val hasRecord = listOf("", ".bak", ".new").any { File(file.baseFile.path + it).exists() }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key(!hasRecord)); updateAAD(alias.toByteArray()) }
        val bytes = byteArrayOf(1) + cipher.iv + cipher.doFinal(value.toByteArray())
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) } catch (e: Exception) { file.failWrite(stream); throw e }
    } }
    override suspend fun delete() = mutex.withLock { withContext(Dispatchers.IO) { file.delete() } }
    /** Hash only the ciphertext artifacts. Bounded streaming; no plaintext or key material escapes. */
    internal suspend fun recordRevision(): String? = mutex.withLock { withContext(Dispatchers.IO) {
        val digest = MessageDigest.getInstance("SHA-256")
        var present = false
        for (suffix in listOf("", ".bak", ".new")) {
            digest.update(suffix.toByteArray())
            val path = File(file.baseFile.path + suffix)
            val stat = try { android.system.Os.lstat(path.path) }
                catch (error: android.system.ErrnoException) { if (error.errno == android.system.OsConstants.ENOENT) null else throw error }
            if (stat == null) { digest.update(0.toByte()); continue }
            present = true
            check(android.system.OsConstants.S_ISREG(stat.st_mode)) { "Invalid encrypted record artifact" }
            digest.update(1.toByte())
            digest.update(java.nio.ByteBuffer.allocate(8).putLong(stat.st_size).array())
            java.io.FileInputStream(android.system.Os.open(path.path, android.system.OsConstants.O_RDONLY or android.system.OsConstants.O_NOFOLLOW or android.system.OsConstants.O_CLOEXEC, 0)).use { input ->
                val buffer = ByteArray(8192)
                while (true) { currentCoroutineContext().ensureActive(); val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
            }
        }
        if (present) digest.digest().joinToString("") { "%02x".format(it) } else null
    } }
    /** Credential owners retire the key only after all ciphertext artifacts are gone. */
    internal suspend fun deleteAndRetireKey() = mutex.withLock { withContext(Dispatchers.IO) {
        file.delete()
        check(listOf("", ".bak", ".new").none { File(file.baseFile.path + it).exists() })
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        keys.deleteEntry(alias)
        check(!keys.containsAlias(alias))
    } }
}
