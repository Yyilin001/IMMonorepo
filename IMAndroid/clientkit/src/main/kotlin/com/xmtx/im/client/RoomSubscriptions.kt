package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.Closeable
import java.util.UUID

enum class RoomSubscriptionChannel { RoomEvents, Presence, Typing }
data class RoomSubscriptionSnapshot(val room: RoomId, val connectionId: String? = null,
    val status: RoomSubscriptionStatus = RoomSubscriptionStatus.Offline,
    val confirmed: PersistentSet<RoomSubscriptionChannel> = persistentSetOf(),
    val baselineHead: Long? = null, val appliedThrough: Long? = null, val observedHead: Long? = null,
    val presence: PresenceState? = null, val typing: PersistentList<TypingState> = persistentListOf()) {
    val isCaughtUp: Boolean get() = RoomSubscriptionChannel.RoomEvents in confirmed && baselineHead != null && appliedThrough != null && appliedThrough >= baselineHead
}
class RoomSubscriptionLease internal constructor(val id: String, val room: RoomId,
    val channels: PersistentSet<RoomSubscriptionChannel>, val state: StateFlow<RoomSubscriptionSnapshot>)
/** Ports belong to one physical connection. retireConnection must stop its actual transport before
 * old work is joined; it is never called for a replacement connection. This bundle is not UI state. */
class RoomSubscriptionConnection(val epoch: Long, val state: StateFlow<RealtimeConnectionState>,
    val roomEvents: RoomEventSubscriptionCoordinator, val activity: LiveActivitySubscriptionCoordinator,
    val retireConnection: () -> Unit)

/** Account-owned intent registry, confined to the supplied single-thread dispatcher. Intents survive
 * connection replacement; connection facts and positive typing publications never do.
 */
class RoomSubscriptions(val account: UserId, scope: CoroutineScope,
    private val maximumRooms: Int = 128, private val maximumConsumers: Int = 512) : Closeable {
    private class Consumer(val lease: RoomSubscriptionLease, val mutable: MutableStateFlow<RoomSubscriptionSnapshot>)
    private class Bound(val event: RoomEventSubscriptionLease?, val activity: LiveActivitySubscriptionLease?, val watch: Job)
    private class Binding(val id: String, val ports: RoomSubscriptionConnection, parent: CoroutineScope) {
        val job = SupervisorJob(parent.coroutineContext[Job])
        val scope = CoroutineScope(parent.coroutineContext + job)
        val consumers = mutableMapOf<String, Bound>()
        var active = true
        var failure: Throwable? = null
    }
    private val job = SupervisorJob(requireNotNull(scope.coroutineContext[Job]))
    private val owner = CoroutineScope(scope.coroutineContext + job)
    private val transition = Mutex()
    private val consumers = linkedMapOf<String, Consumer>()
    private val retired = mutableListOf<Binding>()
    private var binding: Binding? = null
    private var closed = false
    init {
        require(maximumRooms > 0 && maximumConsumers > 0)
        @OptIn(DelicateCoroutinesApi::class)
        owner.launch(start = CoroutineStart.ATOMIC) { try { awaitCancellation() } finally { close() } }
    }
    fun acquire(room: RoomId, channels: PersistentSet<RoomSubscriptionChannel>): RoomSubscriptionLease {
        check(!closed); job.ensureActive(); require(channels.isNotEmpty())
        check(consumers.size < maximumConsumers && (consumers.values.any { it.lease.room == room } || consumers.values.map { it.lease.room }.toSet().size < maximumRooms)) { "房间订阅容量已满" }
        val id = UUID.randomUUID().toString().uppercase(); val mutable = MutableStateFlow(RoomSubscriptionSnapshot(room))
        val lease = RoomSubscriptionLease(id, room, channels, mutable.asStateFlow()); val consumer = Consumer(lease, mutable)
        consumers[id] = consumer
        val current = binding?.takeIf { it.active }
        try {
            // Socket state may already be offline before its dispatcher-confined watcher runs.
            // This new intent still belongs to the account and must survive that handoff.
            if (current != null && current.ports.state.value.connected && current.ports.state.value.epoch == current.ports.epoch)
                install(current, consumer)
        } catch (error: Throwable) {
            if (current != null && !closed && job.isActive &&
                (error is RealtimeUnavailableBeforeAdmission || error is CancellationException)) {
                stop(current); owner.launch { detach(current.id) }
            } else { release(lease); throw error }
        }
        return lease
    }
    fun release(lease: RoomSubscriptionLease) {
        val consumer = consumers[lease.id]?.takeIf { it.lease === lease } ?: return
        consumers.remove(lease.id); consumer.mutable.value = RoomSubscriptionSnapshot(lease.room)
        binding?.let { current -> current.consumers.remove(lease.id)?.let { bound ->
            bound.watch.cancel(); bound.event?.let(current.ports.roomEvents::release); bound.activity?.let(current.ports.activity::release)
        } }
    }
    /** Transfers ownership of the new ports even if cancellation or installation fails. */
    suspend fun attach(ports: RoomSubscriptionConnection): String {
        var installed: Binding? = null
        try {
            return transition.withLock {
                check(!closed); job.ensureActive(); currentCoroutineContext().ensureActive()
                binding?.let(::stop); drainRetired()
                currentCoroutineContext().ensureActive(); check(!closed); job.ensureActive()
                check(ports.epoch > 0 && ports.state.value.connected && ports.state.value.epoch == ports.epoch)
                val next = Binding(UUID.randomUUID().toString().uppercase(), ports, owner); installed = next; binding = next
                consumers.values.forEach { install(next, it) }
                next.scope.launch {
                    ports.state.first { !it.connected || it.epoch != ports.epoch }
                    if (binding === next && next.active) {
                        // A separate account-owned job drains this binding, never joins itself.
                        next.active = false; clearFacts()
                        owner.launch { detach(next.id) }
                    }
                }
                next.id
            }
        } catch (error: Throwable) {
            withContext(NonCancellable) { transition.withLock {
                val current = installed
                if (current != null) { if (binding === current) stop(current); drainRetired() }
                else {
                    try { ports.retireConnection() } finally {
                        ports.roomEvents.awaitClosed(); ports.activity.awaitClosed()
                    }
                }
            } }
            throw error
        }
    }
    suspend fun detach(connectionId: String) = transition.withLock {
        binding?.takeIf { it.id == connectionId }?.let(::stop)
        drainRetired()
    }
    suspend fun reconcile(connectionId: String) {
        currentCoroutineContext().ensureActive()
        val current = current(connectionId)
        try { current.scope.async { current.ports.roomEvents.reconcile() }.await(); current(connectionId) }
        catch (error: Throwable) { withContext(NonCancellable) { detach(connectionId) }; throw error }
    }
    fun authorityDidChange() { binding?.takeIf { it.active }?.let { it.ports.roomEvents.authorityDidChange(); it.ports.activity.authorityDidChange() } }
    suspend fun setTyping(lease: RoomSubscriptionLease, observedConnectionId: String, typing: Boolean) {
        currentCoroutineContext().ensureActive()
        check(consumers[lease.id]?.lease === lease && RoomSubscriptionChannel.Typing in lease.channels)
        val current = current(observedConnectionId)
        val child = requireNotNull(current.consumers[lease.id]?.activity)
        // Positive publications are commands of the observed binding, never remembered intent.
        try {
            current.scope.async { current.ports.activity.setTyping(child, current.ports.epoch, typing) }.await()
            current(observedConnectionId)
        } catch (error: Throwable) {
            // Cancellation after admission may leave a positive publication on the wire. Retire
            // this physical connection and drain its command instead of replaying or guessing.
            withContext(NonCancellable) { detach(observedConnectionId) }
            throw error
        }
    }
    private fun current(id: String): Binding {
        job.ensureActive()
        return binding?.takeIf { !closed && it.active && it.id == id && it.ports.state.value.connected && it.ports.state.value.epoch == it.ports.epoch }
            ?: throw RealtimeUnavailableBeforeAdmission()
    }
    private fun install(current: Binding, consumer: Consumer) {
        val lease = consumer.lease
        var event: RoomEventSubscriptionLease? = null; var activity: LiveActivitySubscriptionLease? = null
        try {
            if (RoomSubscriptionChannel.RoomEvents in lease.channels) event = current.ports.roomEvents.acquire(lease.room)
            val channels = lease.channels.mapNotNull { when (it) {
                RoomSubscriptionChannel.RoomEvents -> null
                RoomSubscriptionChannel.Presence -> ActivityChannel.Presence
                RoomSubscriptionChannel.Typing -> ActivityChannel.Typing
            } }.toPersistentSet()
            if (channels.isNotEmpty()) activity = current.ports.activity.acquire(lease.room, channels)
            val eventFlow: Flow<RoomEventSubscriptionSnapshot?> = event?.state ?: flowOf(null)
            val activityFlow: Flow<LiveActivitySubscriptionSnapshot?> = activity?.state ?: flowOf(null)
            val watch = current.scope.launch(start = CoroutineStart.UNDISPATCHED) {
                combine(eventFlow, activityFlow) { e, a -> snapshot(current, lease, e, a) }.collect { value ->
                    if (binding === current && current.active && consumers[lease.id] === consumer) consumer.mutable.value = value
                }
            }
            current.consumers[lease.id] = Bound(event, activity, watch)
        } catch (error: Throwable) {
            event?.let(current.ports.roomEvents::release); activity?.let(current.ports.activity::release); throw error
        }
    }
    private fun snapshot(current: Binding, lease: RoomSubscriptionLease, event: RoomEventSubscriptionSnapshot?, activity: LiveActivitySubscriptionSnapshot?): RoomSubscriptionSnapshot {
        if (!current.active || !current.ports.state.value.connected || current.ports.state.value.epoch != current.ports.epoch ||
            event != null && event.connectionEpoch != current.ports.epoch || activity != null && activity.connectionEpoch != current.ports.epoch)
            return RoomSubscriptionSnapshot(lease.room)
        var confirmed = persistentSetOf<RoomSubscriptionChannel>()
        if (event?.status == RoomSubscriptionStatus.Subscribed) confirmed = confirmed.add(RoomSubscriptionChannel.RoomEvents)
        activity?.confirmed?.forEach { confirmed = confirmed.add(if (it == ActivityChannel.Presence) RoomSubscriptionChannel.Presence else RoomSubscriptionChannel.Typing) }
        val status = if (event?.status == RoomSubscriptionStatus.Revoked || activity?.denied?.isNotEmpty() == true) RoomSubscriptionStatus.Revoked
            else if (confirmed.containsAll(lease.channels)) RoomSubscriptionStatus.Subscribed else RoomSubscriptionStatus.Reconciling
        return RoomSubscriptionSnapshot(lease.room, current.id, status, confirmed, event?.baselineHead, event?.appliedThrough, event?.observedHead, activity?.presence, activity?.typing ?: persistentListOf())
    }
    private fun clearFacts() { consumers.values.forEach { it.mutable.value = RoomSubscriptionSnapshot(it.lease.room) } }
    private fun stop(value: Binding) {
        if (binding === value) { binding = null; clearFacts() }
        if (value !in retired) retired += value
        value.active = false
        try { value.ports.retireConnection() } catch (error: Throwable) { value.failure = error }
        value.ports.roomEvents.close(); value.ports.activity.close(); value.job.cancel()
    }
    private suspend fun drainRetired() = withContext(NonCancellable) {
        for (old in retired.toList()) {
            old.job.join(); old.ports.roomEvents.awaitClosed(); old.ports.activity.awaitClosed()
            old.failure?.let { throw it }; retired.remove(old)
        }
    }
    override fun close() {
        if (closed) return
        closed = true; binding?.let(::stop); clearFacts(); consumers.clear(); job.cancel()
    }
    suspend fun awaitClosed() { close(); withContext(NonCancellable) { transition.withLock { drainRetired() }; job.join() } }
}
