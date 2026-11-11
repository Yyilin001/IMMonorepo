package com.xmtx.im.client

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow

/** Token-free in-memory state. An authenticated value is not a remote or display permission. */
sealed interface AuthSessionState {
    data object Uninitialized : AuthSessionState
    data object Unauthenticated : AuthSessionState
    data object Establishing : AuthSessionState
    data object Refreshing : AuthSessionState
    data object CleanupPending : AuthSessionState
    data class Authenticated(val accessExpiresAt: Long) : AuthSessionState
    data class CredentialsUnavailable(val reason: CredentialStoreFailure.Reason) : AuthSessionState
    data class ExitUnavailable(val reason: LocalExitFailure.Reason) : AuthSessionState
}

data class AuthSessionSnapshot(val epoch: AuthSessionEpoch, val status: Status) {
    sealed interface Status {
        data class Active(val state: AuthSessionState) : Status
        data class Ended(val reason: EndReason) : Status
    }
    enum class EndReason { AuthenticationRequired, CredentialDeletionPending, Superseded }
}

/** Independent monitor permits subscriptions while credential I/O owns AuthSession's coroutine mutex.
 * Each subscription buffers only the newest snapshot. Ending always replaces it, then closes the stream.
 */
internal class AuthSessionUpdates(initial: AuthSessionEpoch) {
    private val lock = Any()
    private var epoch = initial
    private var state: AuthSessionState = AuthSessionState.Uninitialized
    private var lastEnded: Pair<AuthSessionEpoch, AuthSessionSnapshot.EndReason>? = null
    private val observers = mutableMapOf<Any, SendChannel<AuthSessionSnapshot>>()
    fun current(): AuthSessionState = synchronized(lock) { state }
    fun publish(value: AuthSessionState) = synchronized(lock) {
        state = value
        val snapshot = AuthSessionSnapshot(epoch, AuthSessionSnapshot.Status.Active(value))
        observers.values.toList().forEach { it.trySend(snapshot) }
    }
    fun advance(next: AuthSessionEpoch, reason: AuthSessionSnapshot.EndReason) = synchronized(lock) {
        val end = AuthSessionSnapshot(epoch, AuthSessionSnapshot.Status.Ended(reason))
        lastEnded = epoch to reason
        val retiring = observers.values.toList(); observers.clear()
        epoch = next; state = AuthSessionState.Uninitialized
        retiring.forEach { it.trySend(end); it.close() }
    }
    fun stream(expected: AuthSessionEpoch): Flow<AuthSessionSnapshot> = callbackFlow {
        val key = Any()
        synchronized(lock) {
            if (expected === epoch) {
                observers[key] = channel
                trySend(AuthSessionSnapshot(expected, AuthSessionSnapshot.Status.Active(state)))
            } else {
                val reason = lastEnded?.takeIf { it.first === expected }?.second ?: AuthSessionSnapshot.EndReason.Superseded
                trySend(AuthSessionSnapshot(expected, AuthSessionSnapshot.Status.Ended(reason))); close()
            }
        }
        awaitClose { synchronized(lock) { observers.remove(key) } }
    }.buffer(Channel.CONFLATED)
}
