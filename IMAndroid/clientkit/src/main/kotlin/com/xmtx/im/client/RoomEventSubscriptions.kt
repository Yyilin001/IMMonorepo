package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.Closeable
import java.util.UUID

enum class RoomSubscriptionStatus { Offline, Reconciling, Subscribed, Revoked }
/** Full replacement value. Installation and durable catch-up are separate facts. */
data class RoomEventSubscriptionSnapshot(val room: RoomId, val connectionEpoch: Long? = null,
    val status: RoomSubscriptionStatus = RoomSubscriptionStatus.Offline, val baselineHead: Long? = null,
    val appliedThrough: Long? = null, val observedHead: Long? = null) {
    val isCaughtUp: Boolean get() = status == RoomSubscriptionStatus.Subscribed && baselineHead != null &&
        appliedThrough != null && appliedThrough >= baselineHead
}
class RoomEventSubscriptionLease internal constructor(val id: String, val room: RoomId,
    val state: StateFlow<RoomEventSubscriptionSnapshot>)
interface RoomEventSubscriptionCommands {
    suspend fun subscribe(room: RoomId, appliedThrough: Long): RoomEventSubscription
    suspend fun unsubscribe(room: RoomId)
}

/** One physical connection; use on the supplied scope's dispatcher. A runtime calls reconcile after
 * personal sync and durable room apply, and periodically. I/O is serialized; leases may change during it.
 * Scope cancellation/disconnect withdraw every snapshot. No commands migrate to a replacement epoch.
 */
class RoomEventSubscriptionCoordinator(
    private val epoch: Long, private val commands: RoomEventSubscriptionCommands,
    private val connection: StateFlow<RealtimeConnectionState>, events: Flow<RealtimeSyncEvent>,
    scope: CoroutineScope, private val isAuthorized: suspend (RoomId) -> Boolean,
    private val roomCursor: suspend (RoomId) -> Long,
    private val onSubscribed: (RoomEventSubscription) -> Unit = {},
    private val onRevoked: suspend (RoomId) -> Unit = {},
    private val wake: () -> Unit = {},
    private val maximumRooms: Int = 128, private val maximumConsumers: Int = 512,
) : Closeable {
    private class Consumer(val mutable: MutableStateFlow<RoomEventSubscriptionSnapshot>) { val state = mutable.asStateFlow() }
    private class Room {
        val consumers = linkedMapOf<String, Consumer>()
        var confirmed = false
        var invalidated = false
        var authorized = true
        var denied = false
        var baseline: Long? = null
        var applied: Long? = null
        var head: Long? = null
    }
    private val ownerJob = requireNotNull(scope.coroutineContext[Job])
    private val job = SupervisorJob(ownerJob)
    private val owner = CoroutineScope(scope.coroutineContext + job)
    private val serial = Mutex()
    private val rooms = linkedMapOf<RoomId, Room>()
    private var closed = false
    private var authorityGeneration = 0L
    init {
        require(epoch > 0 && maximumRooms > 0 && maximumConsumers > 0)
        // ATOMIC ensures an already-cancelled scope still clears consumer state in finally.
        @OptIn(DelicateCoroutinesApi::class)
        owner.launch(start = CoroutineStart.ATOMIC) {
            try { connection.first { !it.connected || it.epoch != epoch } }
            finally { close() }
        }
        owner.launch(start = CoroutineStart.UNDISPATCHED) { events.collect { event ->
            if (!closed && event.connectionEpoch == epoch) (event.hint as? RealtimeSyncHint.Room)?.let { hint ->
                rooms[hint.room]?.let { room ->
                    if (room.authorized && !room.denied) { room.head = maxOf(room.head ?: 0, hint.head); publish(hint.room, room) }
                }
            }
        } }
    }
    fun acquire(room: RoomId): RoomEventSubscriptionLease {
        requireOpen()
        check((room in rooms || rooms.size < maximumRooms) && rooms.values.sumOf { it.consumers.size } < maximumConsumers) { "房间订阅容量已满" }
        val id = UUID.randomUUID().toString().uppercase()
        val value = rooms.getOrPut(room) { Room() }
        val consumer = Consumer(MutableStateFlow(RoomEventSubscriptionSnapshot(room)))
        value.consumers[id] = consumer; publish(room, value); wake()
        return RoomEventSubscriptionLease(id, room, consumer.state)
    }
    fun release(lease: RoomEventSubscriptionLease) {
        val room = rooms[lease.room] ?: return
        val consumer = room.consumers[lease.id] ?: return
        // Tokens belong to this owner, not merely a caller-supplied room/id pair.
        if (consumer.state != lease.state) return
        room.consumers.remove(lease.id)
        consumer.mutable.value = RoomEventSubscriptionSnapshot(lease.room)
        wake()
    }
    fun authorityDidChange() {
        if (closed) return
        authorityGeneration++
        rooms.values.forEach { it.denied = false }
        // Hide old permission and catch-up facts until a fresh authority read has completed.
        rooms.forEach { (id, room) -> room.authorized = false; room.invalidated = true; clearFacts(room); publish(id, room) }
        wake()
    }
    suspend fun reconcile() = serial.withLock {
        try {
            requireActive()
            for ((id, room) in rooms.toList()) {
                val generation = authorityGeneration
                val authorized = isAuthorized(id); requireActive()
                if (generation != authorityGeneration) return@withLock
                room.authorized = authorized
                if (!authorized || room.denied) { clearFacts(room); publish(id, room) }
                val desired = room.consumers.isNotEmpty() && authorized && !room.denied
                if ((!desired || room.invalidated) && room.confirmed) {
                    try { commands.unsubscribe(id) }
                    catch (error: GatewayFailure) { if (error.code != "FORBIDDEN" || error.retryable) throw error }
                    requireActive(); room.confirmed = false; room.invalidated = false; clearFacts(room)
                }
                if (desired && !room.confirmed && generation == authorityGeneration) {
                    val cursor = roomCursor(id); requireActive(); require(cursor >= 0)
                    if (generation != authorityGeneration || room.consumers.isEmpty()) { wake(); continue }
                    try {
                        val result = commands.subscribe(id, cursor); requireActive()
                        if (result.room != id || result.head < 0 || result.membershipRevision < 0) throw ClientFailure.Protocol()
                        room.confirmed = true; room.invalidated = generation != authorityGeneration
                        if (generation == authorityGeneration && room.consumers.isNotEmpty()) {
                            room.baseline = result.head; room.applied = cursor; room.head = maxOf(room.head ?: 0, result.head)
                            onSubscribed(result)
                        } else { clearFacts(room); wake() }
                    } catch (error: GatewayFailure) {
                        if (error.code != "FORBIDDEN" || error.retryable) throw error
                        if (generation != authorityGeneration) { wake(); continue }
                        room.denied = true; clearFacts(room); publish(id, room)
                        onRevoked(id); requireActive()
                    }
                }
                if (room.confirmed && room.authorized && !room.denied && generation == authorityGeneration && room.consumers.isNotEmpty()) {
                    val applied = roomCursor(id); requireActive(); require(applied >= 0)
                    if (generation == authorityGeneration) room.applied = applied
                }
                publish(id, room)
                if (room.consumers.isEmpty() && !room.confirmed) rooms.remove(id)
            }
        } catch (error: Throwable) { close(); throw error }
    }
    private fun clearFacts(room: Room) { room.baseline = null; room.applied = null; room.head = null }
    private fun publish(id: RoomId, room: Room) {
        val status = if (closed) RoomSubscriptionStatus.Offline else if (!room.authorized || room.denied) RoomSubscriptionStatus.Revoked
            else if (room.confirmed && room.baseline != null) RoomSubscriptionStatus.Subscribed else RoomSubscriptionStatus.Reconciling
        val snapshot = RoomEventSubscriptionSnapshot(id, epoch.takeUnless { closed }, status, room.baseline, room.applied, room.head)
        room.consumers.values.forEach { it.mutable.value = snapshot }
    }
    private suspend fun requireActive() { currentCoroutineContext().ensureActive(); requireOpen() }
    private fun requireOpen() {
        ownerJob.ensureActive()
        if (closed || !connection.value.connected || connection.value.epoch != epoch) throw RealtimeUnavailableBeforeAdmission()
        job.ensureActive()
    }
    override fun close() {
        if (closed) return
        closed = true
        rooms.forEach { (id, room) -> room.consumers.values.forEach { it.mutable.value = RoomEventSubscriptionSnapshot(id) } }
        rooms.clear(); job.cancel()
    }
    suspend fun awaitClosed() { close(); withContext(NonCancellable) { job.join() } }

}
