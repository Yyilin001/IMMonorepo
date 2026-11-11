package com.xmtx.im.platform

import android.content.Context
import android.security.keystore.KeyPermanentlyInvalidatedException
import com.xmtx.im.client.*
import kotlinx.coroutines.CancellationException
import javax.crypto.AEADBadTagException

/** Credential-specific errors. Reads/writes never repair records; explicit deletion also retires the key. */
class KeystoreCredentialStore(context: Context, name: String) : SecretStore {
    private val delegate = KeystoreSecretStore(context, name)
    override suspend fun read() = access { delegate.read() }
    override suspend fun write(value: String) = access { delegate.write(value) }
    override suspend fun delete() = access { delegate.deleteAndRetireKey() }
    private suspend fun <T> access(body: suspend () -> T): T = try { body() }
    catch (error: CancellationException) { throw error }
    catch (error: KeystoreRecordFailure) { throw CredentialStoreFailure(when (error.reason) {
        KeystoreRecordFailure.Reason.Malformed -> CredentialStoreFailure.Reason.Malformed
        KeystoreRecordFailure.Reason.KeyMissing -> CredentialStoreFailure.Reason.PermanentlyInvalidated
    }) }
    catch (_: KeyPermanentlyInvalidatedException) { throw CredentialStoreFailure(CredentialStoreFailure.Reason.PermanentlyInvalidated) }
    catch (_: AEADBadTagException) { throw CredentialStoreFailure(CredentialStoreFailure.Reason.Malformed) }
    catch (_: Exception) { throw CredentialStoreFailure(CredentialStoreFailure.Reason.Unavailable) }
}
