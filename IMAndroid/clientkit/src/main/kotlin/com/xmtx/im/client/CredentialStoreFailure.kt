package com.xmtx.im.client

import kotlinx.coroutines.CancellationException

/** Local credential evidence is inaccessible, not absent. Contains no underlying record or cause. */
class CredentialStoreFailure(val reason: Reason) : Exception("Credential storage: ${reason.name}") {
    enum class Reason { Unavailable, Malformed, PermanentlyInvalidated }
}

/** Adapts a generic secret backend to the credential boundary. Cancellation is never a storage error.
 * Platform backends should classify known corruption/key loss before this generic unavailable fallback.
 */
class ClassifiedCredentialStore(private val delegate: SecretStore) : SecretStore {
    override suspend fun read() = access { delegate.read() }
    override suspend fun write(value: String) = access { delegate.write(value) }
    override suspend fun delete() = access { delegate.delete() }
    private suspend fun <T> access(body: suspend () -> T): T = try { body() }
    catch (error: CancellationException) { throw error }
    catch (error: CredentialStoreFailure) { throw error }
    catch (_: Exception) { throw CredentialStoreFailure(CredentialStoreFailure.Reason.Unavailable) }
}
