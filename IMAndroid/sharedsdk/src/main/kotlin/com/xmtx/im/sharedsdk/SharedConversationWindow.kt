package com.xmtx.im.sharedsdk

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

/** A Swift-owned query and subscription. Kotlin only converts calls and owns their waiters. */
class SharedConversationWindow internal constructor(private val client: SharedClient, val id: String) {
    private val closed = AtomicBoolean(false)
    private val observing = AtomicBoolean(false)
    private suspend fun call(operation: String): SharedSnapshot {
        check(!closed.get()) { "Window is closed" }
        return client.windowCall(operation, id)
    }
    suspend fun snapshot(): SharedSnapshot = call("readWindow")
    suspend fun nextPage(): SharedSnapshot = call("nextWindowPage")
    suspend fun reset(): SharedSnapshot = call("resetWindow")
    fun states(): Flow<SharedSnapshot> = flow {
        check(observing.compareAndSet(false, true)) { "One observer per window; open another window for an independent observer" }
        try {
            while (currentCoroutineContext().isActive && !closed.get()) {
                val value = call("watchWindow")
                if (!closed.get()) emit(value)
            }
        } finally { observing.set(false) }
    }
    suspend fun close() = withContext(NonCancellable) {
        if (closed.compareAndSet(false, true)) {
            try { client.windowCall("closeWindow", id) }
            catch (error: SharedSdkException) {
                if (error.reason !in setOf(SharedError.Closed, SharedError.AuthenticationRequired)) throw error
            }
        }
    }
}
