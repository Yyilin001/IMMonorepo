package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.Closeable
import java.util.UUID

/** Full replacement, containing only channels requested by this consumer. */
data class LiveActivitySubscriptionSnapshot(val room: RoomId, val connectionEpoch: Long? = null,
    val confirmed: PersistentSet<ActivityChannel> = persistentSetOf(), val denied: PersistentSet<ActivityChannel> = persistentSetOf(),
    val presence: PresenceState? = null, val typing: PersistentList<TypingState> = persistentListOf())
class LiveActivitySubscriptionLease internal constructor(val id: String, val room: RoomId,
    val channels: PersistentSet<ActivityChannel>, val state: StateFlow<LiveActivitySubscriptionSnapshot>)

interface LiveActivitySubscriptionClient : LiveActivityCommands, Closeable

/** One connection, confined to the scope's single-thread dispatcher. Network work belongs to this
 * owner: cancellation of one waiter releases only its lease, never another consumer's subscription.
 */
class LiveActivitySubscriptionCoordinator(private val epoch: Long, private val commands: LiveActivityCommands,
    events: Flow<RealtimeActivityEvent>, private val connection: StateFlow<RealtimeConnectionState>, scope: CoroutineScope,
    private val disconnect: (Long) -> Unit, private val isAuthorized: suspend (RoomId) -> Boolean = { true },
    private val wallMillis: () -> Long = System::currentTimeMillis, private val nanoTime: () -> Long = System::nanoTime,
    private val maximumRooms: Int = 128, private val maximumConsumers: Int = 512) : Closeable {
    private class Consumer(val lease: LiveActivitySubscriptionLease, val mutable: MutableStateFlow<LiveActivitySubscriptionSnapshot>)
    private class Slot {
        var confirmed = false; var denied = false; var ready = true; var revision = 0L; var generation = 0L; var ended = 0L
        var retryAt = 0L; var observation = 0L
    }
    private data class Timed<T>(val value: T, val deadline: Long)
    private class Room {
        val consumers = linkedMapOf<String, Consumer>()
        val slots = ActivityChannel.entries.associateWith { Slot() }
        var presence: Timed<PresenceState>? = null
        var typing = persistentMapOf<UserId, Timed<TypingState>>()
        val publishers = mutableSetOf<String>()
        var stopTyping = false
        var allowed = true
    }
    private val parent = requireNotNull(scope.coroutineContext[Job])
    private val job = SupervisorJob(parent)
    private val owner = CoroutineScope(scope.coroutineContext + job)
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val wire = Mutex()
    private val rooms = linkedMapOf<RoomId, Room>()
    private var closed = false
    private var authority = 0L
    init {
        require(epoch > 0 && maximumRooms > 0 && maximumConsumers > 0)
        @OptIn(DelicateCoroutinesApi::class)
        owner.launch(start = CoroutineStart.ATOMIC) {
            try { connection.first { !it.connected || it.epoch != epoch } } finally { close() }
        }
        owner.launch(start = CoroutineStart.UNDISPATCHED) { events.collect(::accept) }
        owner.launch { while (isActive) { delay(250); rooms.forEach { (id, room) -> publish(id, room) } } }
        owner.launch {
            try {
                while (isActive) {
                    wire.withLock { reconcile() }
                    withTimeoutOrNull(1000) { wake.receive() }
                }
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { if (!closed && connection.value.connected && connection.value.epoch == epoch) disconnect(epoch) }
            finally { close() }
        }
    }
    fun acquire(room: RoomId, channels: PersistentSet<ActivityChannel>): LiveActivitySubscriptionLease {
        requireOpen(); require(channels.isNotEmpty())
        check((room in rooms || rooms.size < maximumRooms) && rooms.values.sumOf { it.consumers.size } < maximumConsumers) { "活动订阅容量已满" }
        val id = UUID.randomUUID().toString().uppercase()
        val mutable = MutableStateFlow(LiveActivitySubscriptionSnapshot(room))
        val lease = LiveActivitySubscriptionLease(id, room, channels, mutable.asStateFlow())
        val value = rooms.getOrPut(room) { Room() }; value.consumers[id] = Consumer(lease, mutable)
        publish(room, value); wake.trySend(Unit); return lease
    }
    fun release(lease: LiveActivitySubscriptionLease) {
        val room = rooms[lease.room] ?: return
        val consumer = room.consumers[lease.id]?.takeIf { it.lease === lease } ?: return
        room.consumers.remove(lease.id); consumer.mutable.value = LiveActivitySubscriptionSnapshot(lease.room)
        if (room.publishers.remove(lease.id) && room.publishers.isEmpty()) room.stopTyping = true
        wake.trySend(Unit)
    }
    fun authorityDidChange() {
        if (closed) return
        authority++
        rooms.forEach { (id, room) ->
            room.allowed = false; room.presence = null; room.typing = persistentMapOf()
            room.slots.values.forEach { it.denied = false; it.ready = false; it.retryAt = 0 }
            publish(id, room)
        }; wake.trySend(Unit)
    }
    private fun member(lease: LiveActivitySubscriptionLease): Room {
        requireOpen()
        return rooms[lease.room]?.takeIf { it.consumers[lease.id]?.lease === lease } ?: throw CancellationException("Activity lease released")
    }
    suspend fun awaitConfirmed(lease: LiveActivitySubscriptionLease) {
        lease.state.first { it.connectionEpoch == null || it.denied.isNotEmpty() || it.confirmed.containsAll(lease.channels) }
        member(lease)
        if (lease.state.value.denied.isNotEmpty()) throw GatewayFailure("FORBIDDEN", false, 0)
    }
    suspend fun setTyping(lease: LiveActivitySubscriptionLease, expectedEpoch: Long, typing: Boolean) = wire.withLock {
        currentCoroutineContext().ensureActive()
        val room = member(lease)
        require(expectedEpoch == epoch && ActivityChannel.Typing in lease.channels)
        val slot = room.slots.getValue(ActivityChannel.Typing)
        check(room.allowed && slot.confirmed && slot.ready && !slot.denied)
        if (typing) {
            room.publishers.add(lease.id); room.stopTyping = false
            commands.setTyping(lease.room, true)
        } else if (room.publishers.remove(lease.id) && room.publishers.isEmpty()) {
            room.stopTyping = true; commands.setTyping(lease.room, false); room.stopTyping = false
        }
        requireOpen()
    }
    /** A separate command facade per scene; subscription ownership never uses a global room counter. */
    fun consumerCommands(): LiveActivitySubscriptionClient = object : LiveActivitySubscriptionClient {
        private var retired = false
        private val leases = mutableMapOf<Pair<RoomId, ActivityChannel>, LiveActivitySubscriptionLease>()
        private suspend fun subscribe(room: RoomId, channel: ActivityChannel): LiveActivitySubscriptionLease {
            check(!retired) { "Activity consumer closed" }
            val key = room to channel
            val lease = leases.getOrPut(key) { acquire(room, persistentSetOf(channel)) }
            try { awaitConfirmed(lease); return lease }
            catch (error: Throwable) { if (leases[key] === lease) leases.remove(key); release(lease); throw error }
        }
        override suspend fun subscribeTyping(room: RoomId) { subscribe(room, ActivityChannel.Typing) }
        override suspend fun subscribePresence(room: RoomId): PresenceState {
            val lease = subscribe(room, ActivityChannel.Presence)
            return requireNotNull(member(lease).presence).value
        }
        override suspend fun unsubscribeTyping(room: RoomId) { leases.remove(room to ActivityChannel.Typing)?.let(::release) }
        override suspend fun unsubscribePresence(room: RoomId) { leases.remove(room to ActivityChannel.Presence)?.let(::release) }
        override suspend fun setTyping(room: RoomId, typing: Boolean) {
            val lease = leases[room to ActivityChannel.Typing] ?: throw CancellationException("Typing lease missing")
            this@LiveActivitySubscriptionCoordinator.setTyping(lease, epoch, typing)
        }
        override fun close() {
            if (retired) return
            retired = true; leases.values.toList().forEach(::release); leases.clear()
        }
        override suspend fun setPresencePublicationMode(mode: PresencePublicationMode) {
            check(!retired) { "Activity consumer closed" }
            // Account-wide privacy policy remains owned by the foreground account session.
            wire.withLock { check(!retired) { "Activity consumer closed" }; requireOpen(); commands.setPresencePublicationMode(mode); requireOpen() }
        }
    }
    private suspend fun reconcile() {
        requireOpen()
        for ((id, room) in rooms.toList()) {
            val generation = authority
            val allowed = isAuthorized(id); requireOpen()
            if (generation != authority) return
            room.allowed = allowed
            if (!allowed) { room.presence = null; room.typing = persistentMapOf(); room.publishers.clear(); room.stopTyping = true }
            var stoppedTyping = false
            if (room.stopTyping && room.slots.getValue(ActivityChannel.Typing).confirmed) {
                permitted { commands.setTyping(id, false) }; requireOpen(); room.stopTyping = false; stoppedTyping = true
            }
            for (channel in ActivityChannel.entries) {
                val slot = room.slots.getValue(channel)
                val desired = allowed && !slot.denied && room.consumers.values.any { channel in it.lease.channels }
                if (slot.confirmed && (!desired || !slot.ready && nanoTime() >= slot.retryAt)) {
                    if (channel == ActivityChannel.Presence) permitted { commands.unsubscribePresence(id) }
                    else { if (!stoppedTyping) permitted { commands.setTyping(id, false) }; permitted { commands.unsubscribeTyping(id) }; room.publishers.clear() }
                    requireOpen(); slot.confirmed = false; clear(room, channel)
                }
                if (desired && !slot.confirmed && generation == authority) {
                    slot.ready = true
                    val observed = slot.observation
                    val accepted = permitted {
                        if (channel == ActivityChannel.Typing) commands.subscribeTyping(id)
                        else {
                            val seed = commands.subscribePresence(id); require(seed.room == id)
                            if (observed == slot.observation && generation == authority) room.presence = timed(seed, seed.expiresAtMillis, wallMillis(), nanoTime())
                        }
                    }; requireOpen()
                    slot.confirmed = accepted
                    if (generation == authority) slot.denied = !accepted
                    else { slot.ready = false; slot.retryAt = 0; clear(room, channel); wake.trySend(Unit) }
                }
            }
            publish(id, room)
            if (room.consumers.isEmpty() && room.slots.values.none { it.confirmed }) rooms.remove(id)
        }
    }
    private suspend fun permitted(body: suspend () -> Unit): Boolean = try { body(); true }
    catch (error: GatewayFailure) { if (error.code == "FORBIDDEN" && !error.retryable) false else throw error }
    private fun clear(room: Room, channel: ActivityChannel) {
        if (channel == ActivityChannel.Presence) room.presence = null else room.typing = persistentMapOf()
    }
    private fun <T> timed(value: T, expiry: Long, wall: Long, nanos: Long) = Timed(value, nanos + (expiry - wall).coerceIn(0, 86_400_000) * 1_000_000)
    private fun accept(event: RealtimeActivityEvent) {
        if (closed || event.connectionEpoch != epoch) return
        val id = when (val hint = event.hint) { is LiveActivityHint.Presence -> hint.value.room; is LiveActivityHint.Typing -> hint.value.room; is LiveActivityHint.Coverage -> hint.room }
        val room = rooms[id] ?: return
        if (!room.allowed) return
        when (val hint = event.hint) {
            is LiveActivityHint.Presence -> {
                val slot = room.slots.getValue(ActivityChannel.Presence)
                if (!slot.denied && slot.ready && room.consumers.values.any { ActivityChannel.Presence in it.lease.channels }) {
                    slot.observation++; room.presence = timed(hint.value, hint.value.expiresAtMillis, event.receivedAtMillis, event.receivedAtNanos)
                }
            }
            is LiveActivityHint.Typing -> {
                val slot = room.slots.getValue(ActivityChannel.Typing)
                if (!slot.denied && slot.ready && room.consumers.values.any { ActivityChannel.Typing in it.lease.channels }) {
                    val value = timed(hint.value, hint.value.expiresAtMillis, event.receivedAtMillis, event.receivedAtNanos)
                    room.typing = if (!hint.value.typing || value.deadline <= nanoTime()) room.typing.remove(hint.value.user)
                        else if (hint.value.user in room.typing || room.typing.size < 64) room.typing.put(hint.value.user, value) else room.typing
                }
            }
            is LiveActivityHint.Coverage -> {
                val slot = room.slots.getValue(hint.channel)
                if (hint.revision <= slot.revision || hint.generation < slot.generation || hint.state != ActivityCoverageState.Ended && hint.generation <= slot.ended) return
                slot.revision = hint.revision; slot.generation = hint.generation
                if (hint.state == ActivityCoverageState.Ended) slot.ended = hint.generation
                slot.ready = hint.state == ActivityCoverageState.Ready
                if (!slot.ready) { clear(room, hint.channel); slot.retryAt = nanoTime() + 1_000_000_000 }
                wake.trySend(Unit)
            }
        }; publish(id, room)
    }
    private fun publish(id: RoomId, room: Room) {
        val now = nanoTime(); room.typing = room.typing.filterValues { it.deadline > now }.toPersistentMap()
        room.consumers.values.forEach { consumer ->
            val channels = consumer.lease.channels
            val ready = channels.filter { room.allowed && room.slots.getValue(it).let { slot -> slot.confirmed && slot.ready && !slot.denied } }.toPersistentSet()
            val denied = channels.filter { !room.allowed || room.slots.getValue(it).denied }.toPersistentSet()
            consumer.mutable.value = LiveActivitySubscriptionSnapshot(id, epoch, ready, denied,
                room.presence?.takeIf { ActivityChannel.Presence in ready && it.deadline > now }?.value,
                if (ActivityChannel.Typing in ready) room.typing.values.map { it.value }.sortedBy { it.user.value }.toPersistentList() else persistentListOf())
        }
    }
    private fun requireOpen() {
        parent.ensureActive()
        if (closed || !connection.value.connected || connection.value.epoch != epoch) throw RealtimeUnavailableBeforeAdmission()
        job.ensureActive()
    }
    override fun close() {
        if (closed) return
        closed = true
        rooms.forEach { (id, room) -> room.consumers.values.forEach { it.mutable.value = LiveActivitySubscriptionSnapshot(id) } }
        rooms.clear(); wake.close(); job.cancel()
    }
    suspend fun awaitClosed() { close(); withContext(NonCancellable) { job.join() } }

}
