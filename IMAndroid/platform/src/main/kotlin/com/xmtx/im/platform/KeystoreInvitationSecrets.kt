package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.security.MessageDigest
import java.util.UUID

/** Separate no-backup encrypted items; a reference can never be rebound to another bearer. */
class KeystoreInvitationSecrets(private val context: Context, server: String, private val account: UserId,
    private val device: DeviceId) : InvitationSecretStore {
    private val mutex = Mutex()
    private val binding = MessageDigest.getInstance("SHA-256").digest(server.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun item(reference: String, actor: UserId): KeystoreSecretStore {
        require(actor == account && UUID.fromString(reference).toString().uppercase() == reference)
        return KeystoreSecretStore(context, "invitation-$binding-${account.value}-${device.value}-$reference")
    }
    override suspend fun save(reference: String, actor: UserId, secret: InvitationSecret) = mutex.withLock {
        val store = item(reference, actor); val existing = store.read()
        if(existing == null) store.write(secret.rawValue) else require(existing == secret.rawValue) { "Invitation reference cannot be rebound" }
    }
    override suspend fun load(reference: String, actor: UserId): InvitationSecret = mutex.withLock {
        try { InvitationSecret(item(reference, actor).read() ?: throw InvitationSecretUnavailable()) }
        catch(e: CancellationException) { throw e } catch(_: Exception) { throw InvitationSecretUnavailable() }
    }
    override suspend fun remove(reference: String, actor: UserId) = mutex.withLock { item(reference, actor).delete() }
}
