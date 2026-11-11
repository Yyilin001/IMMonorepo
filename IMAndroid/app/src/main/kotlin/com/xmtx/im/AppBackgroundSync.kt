package com.xmtx.im

import com.xmtx.im.client.*
import com.xmtx.im.platform.SqliteClientStore
import kotlinx.coroutines.*

/** One account activation owns a dedicated socket and all shared background flights. */
internal class AppBackgroundSync(
    socket: RealtimeConnection,
    private val auth: AuthSession,
    private val identity: LocalAccountIdentity,
    store: SqliteClientStore,
    network: AccountNetworkActivity,
    parent: CoroutineScope,
) {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job + network.recoveryScope())
    private val connection = RealtimeBackgroundSyncConnection(socket, auth, identity, network.scheduler)
    private val rooms = BackgroundRoomSync(socket, store, store, store)
    private val runner = BackgroundSyncRunner(connection, SyncEngine(connection, store), scope, roomSync = { pages ->
        auth.requireLocalIdentity(identity)
        rooms.run(pages).also { auth.requireLocalIdentity(identity) }
    })

    suspend fun run(deadlineNanos: Long): IncrementalSyncResult = runner.run(deadlineNanos)
    /** Synchronous withdrawal; stop/close still await actual I/O before a new owner may use the store. */
    fun interrupt() { job.cancelChildren(); connection.disconnect() }
    suspend fun stop() = runner.stop()
    suspend fun close() = withContext(NonCancellable) {
        job.cancel()
        runner.stop()
        job.join()
    }
}

enum class BackgroundSyncOutcome { NewData, NoData, Failed }
