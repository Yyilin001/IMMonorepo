package com.xmtx.im.platform

import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** A lifecycle-owned text projection. The SQLite handle and its mutation APIs never escape.
 * Only the latest requested page is retained. Call revalidate on foreground entry and reload;
 * external file changes are not filesystem notifications. Previously returned values are snapshots.
 */
class LocalProjectionSession internal constructor(
    val identity: LocalAccountIdentity,
    val databaseIdentity: LocalDatabaseIdentity,
    private val store: SqliteClientStore,
    private val validate: suspend () -> Unit,
    updates: Flow<AuthSessionSnapshot>,
    scope: CoroutineScope,
) {
    private val lock = Any()
    private var closed = false
    private val drained = CompletableDeferred<Unit>()
    private val reads = Mutex()
    private val owner = requireNotNull(scope.coroutineContext[Job])
    private val mutable = MutableStateFlow(LocalProjectionSnapshot())
    val state: StateFlow<LocalProjectionSnapshot> = mutable.asStateFlow()
    // The already-open store must be retired even when the owner is cancelled before dispatch.
    // The body only observes state and releases resources; it does not access lifecycle UI objects.
    @OptIn(DelicateCoroutinesApi::class)
    private val observation = scope.launch(start = CoroutineStart.ATOMIC) {
        try {
            updates.first { snapshot ->
                val active = (snapshot.status as? AuthSessionSnapshot.Status.Active)?.state
                active !is AuthSessionState.Authenticated && active != AuthSessionState.Refreshing
            }
        } finally { retire() }
    }
    suspend fun conversations(before: LocalConversationCursor? = null, limit: Int = 50): LocalConversationPage {
        require(limit in 1..100)
        return read {
            val page = store.localConversations(before, limit)
            page to LocalProjectionSnapshot(conversations = page.entries, nextConversations = page.next)
        }
    }
    suspend fun messages(room: RoomId, before: TimelineCursor? = null, limit: Int = 100): LocalMessagePage {
        require(limit in 1..100)
        require(before == null || before.kind == TimelineItemKind.Message)
        return read {
            val page = store.localMessages(room, before, limit)
            page to LocalProjectionSnapshot(messages = page)
        }
    }
    suspend fun revalidate() = read { Unit to LocalProjectionSnapshot() }
    private fun requireOpen() = synchronized(lock) { if (closed) throw ClientFailure.SessionInvalidated() }
    private suspend fun <T> read(body: suspend () -> Pair<T, LocalProjectionSnapshot>): T = reads.withLock {
        currentCoroutineContext().ensureActive(); owner.ensureActive(); requireOpen()
        try {
            validate(); currentCoroutineContext().ensureActive(); requireOpen()
            val (result, publish) = body()
            validate(); currentCoroutineContext().ensureActive()
            synchronized(lock) { owner.ensureActive(); requireOpen(); mutable.value = publish }
            result
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { close(); throw error }
    }
    suspend fun close() = withContext(NonCancellable) { retire(); observation.cancelAndJoin() }
    private suspend fun retire() = withContext(NonCancellable) {
        val ownsClose = synchronized(lock) {
            if (closed) false else { closed = true; mutable.value = LocalProjectionSnapshot(active = false); true }
        }
        if (ownsClose) {
            try { withContext(Dispatchers.IO) { store.close() }; drained.complete(Unit) }
            catch (error: Throwable) { drained.completeExceptionally(error); throw error }
        } else drained.await()
    }
}
