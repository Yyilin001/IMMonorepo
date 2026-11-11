package com.xmtx.im.platform

import android.content.Context
import com.xmtx.im.client.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import java.security.MessageDigest

/** One application-lifetime owner per credential/deployment namespace. No reads/network on creation.
 * Restore the auth journal before recoverUnclaimed; never interpret unreadable credentials as absent.
 */
class KeystoreIssuedCredentialRecovery(context: Context, namespace: String) {
    private val domain = MessageDigest.getInstance("SHA-256").digest(namespace.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
    val revocations = CredentialRevocationQueue(KeystoreCredentialStore(context, "credential-revocations-$domain"))
    val receipts = IssuedCredentialRecoveryStore(KeystoreCredentialStore(context, "credential-receipts-$domain"), revocations)
    val registrations = DeviceRegistrationStore(KeystoreCredentialStore(context, "credential-registrations-$domain"))
    fun runner(transport: AccountTransport, now: () -> Long = System::currentTimeMillis) = CredentialRevocationRunner(revocations, transport, now)
    fun cancellationRunner(transport: AccountTransport, now: () -> Long = System::currentTimeMillis) = RegistrationCancellationRunner(registrations, transport, now)
    fun statusUpdates(): Flow<RegistrationActivity> = combine(revocations.statusUpdates(), registrations.activityUpdates()) { revocation, registration ->
        val status = when {
            revocation == CredentialRevocationStatus.Paused || registration.cancellations == CredentialRevocationStatus.Paused -> CredentialRevocationStatus.Paused
            revocation == CredentialRevocationStatus.Pending || registration.cancellations == CredentialRevocationStatus.Pending -> CredentialRevocationStatus.Pending
            else -> CredentialRevocationStatus.Empty
        }
        RegistrationActivity(registration.awaitingRegistration, status)
    }.distinctUntilChanged()
}
