package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.Closeable

/** One visible conversation. A direct room must have its authorized counterpart before observing presence. */
data class ConversationActivityInterest(val room: RoomId? = null, val peer: UserId? = null,
    val group: Boolean = false, val hasDraft: Boolean = false, val onlineAllowed: Boolean = false,
    val typingAllowed: Boolean = false)
/** subscribed means at least one authorized activity channel is ready. */
data class ConversationActivityState(val room: RoomId? = null, val subscribed: Boolean = false,
    val online: Boolean? = null, val typing: PersistentSet<UserId> = persistentSetOf())

/** Foreground, single-dispatcher owner. Call update/close on the supplied scope's dispatcher.
 * No jobs or mutable collections escape through state. Default close terminates this connection.
 * Shared consumers may release only their leases; privacy tightening and failures still disconnect.
 */
class ConversationActivitySession(
    private val self: UserId,
    private val epoch: Long,
    private val commands: LiveActivityCommands,
    events: Flow<RealtimeActivityEvent>,
    private val connection: StateFlow<RealtimeConnectionState>,
    scope: CoroutineScope,
    private val sequence: () -> Long,
    private val disconnect: (Long) -> Unit,
    private val wallMillis: () -> Long = System::currentTimeMillis,
    private val nanoTime: () -> Long = System::nanoTime,
    private val disconnectOnClose: Boolean = true,
) : Closeable {
    private val job = SupervisorJob(scope.coroutineContext[Job])
    private val owner = CoroutineScope(scope.coroutineContext + job)
    private val mutableState = MutableStateFlow(ConversationActivityState())
    val state = mutableState.asStateFlow()
    private var desired = ConversationActivityInterest()
    private var closed = false
    private var positiveInFlight = false
    private var binding: Binding? = null
    private var publishedOnline = false
    private var publishedTyping = false
    private var nextTyping = 0L
    private var nextRecovery = 0L
    private class Binding(val interest: ConversationActivityInterest, val floor: Long) {
        var typingConfirmed = false
        var presenceConfirmed = false
        var typingDenied = false
        var presenceDenied = false
        var typingReady = true
        var presenceReady = true
        var typingRevision = 0L
        var presenceRevision = 0L
        var typingGeneration = 0L
        var presenceGeneration = 0L
        var recover = false
        var retryDenied = false
        var presence: Boolean? = null
        var presenceDeadline = 0L
        var presenceObserved = false
        var typing: PersistentMap<UserId, Long> = persistentMapOf()
    }
    init {
        require(epoch > 0)
        owner.launch(start = CoroutineStart.UNDISPATCHED) { events.collect(::receive) }
        owner.launch(start = CoroutineStart.UNDISPATCHED) {
            connection.collect { if (it.epoch != epoch || !it.connected) close() }
        }
        owner.launch { while (isActive) { delay(250); publish() } }
        owner.launch {
            try {
                while (isActive) {
                    reconcile()
                    publish()
                    delay(250)
                }
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { end(true) }
            finally { close() }
        }
    }
    fun update(value: ConversationActivityInterest) {
        if (closed || desired == value) return
        val previous = desired
        desired = value
        // Tightening privacy or withdrawing a queued positive command ends the connection immediately.
        // The next connection authenticates suppressed, then reapplies the current local policy.
        if ((previous.onlineAllowed && !value.onlineAllowed) || (previous.typingAllowed && !value.typingAllowed) ||
            (positiveInFlight && (!sameRoom(previous, value) || previous.hasDraft && !value.hasDraft))) {
            end(true); return
        }
        // A confirmed policy change may restore a previously refused channel. Do not poll a denial.
        if ((!previous.typingAllowed && value.typingAllowed && binding?.typingDenied == true) ||
            (!previous.onlineAllowed && value.onlineAllowed && binding?.presenceDenied == true)) {
            binding?.retryDenied = true; binding?.recover = true; nextRecovery = 0
        }
        publish()
    }
    private suspend fun positive(block: suspend () -> Unit) {
        positiveInFlight = true
        try { block() } finally { positiveInFlight = false }
    }
    private suspend fun reconcile() {
        var current = binding
        if (current != null && (!sameRoom(current.interest, desired) || current.recover && nanoTime() >= nextRecovery)) {
            binding = null; publish()
            val room = requireNotNull(current.interest.room)
            if (publishedTyping) { authorized { commands.setTyping(room, false) }; publishedTyping = false }
            if (current.presenceConfirmed) authorized { commands.unsubscribePresence(room) }
            if (current.typingConfirmed) authorized { commands.unsubscribeTyping(room) }
            current = null
            nextRecovery = nanoTime() + 1_000_000_000L
        }
        if (publishedOnline != desired.onlineAllowed) {
            val allow = desired.onlineAllowed
            if (allow) positive { commands.setPresencePublicationMode(PresencePublicationMode.AllowWhenAuthorized) }
            else commands.setPresencePublicationMode(PresencePublicationMode.Suppressed)
            publishedOnline = allow
        }
        if (current == null && desired.room != null) {
            current = Binding(desired, sequence())
            binding = current
            val room = requireNotNull(current.interest.room)
            current.typingConfirmed = authorized { commands.subscribeTyping(room) }
            current.typingDenied = !current.typingConfirmed
            if (!current.interest.group && current.interest.peer != null && sameRoom(current.interest, desired)) {
                val subscribed = current
                subscribed.presenceConfirmed = authorized {
                    val seed = commands.subscribePresence(room)
                    if (seed.user != subscribed.interest.peer) throw ClientFailure.Protocol()
                    // A hint received during subscribe is newer than its initial snapshot.
                    if (!subscribed.presenceObserved) applyPresence(subscribed, seed, wallMillis(), nanoTime())
                }
                subscribed.presenceDenied = !subscribed.presenceConfirmed
            }
        }
        if (current != null && needsRecovery(current)) {
            if (!current.recover) nextRecovery = nanoTime() + 1_000_000_000L
            current.recover = true
        }
        if (current != null && sameRoom(current.interest, desired)) {
            val shouldType = desired.hasDraft && desired.typingAllowed && current.typingConfirmed && current.typingReady && !current.typingDenied
            if (shouldType && (!publishedTyping || nanoTime() >= nextTyping)) {
                val publishing = current
                positive { publishedTyping = authorized { commands.setTyping(requireNotNull(publishing.interest.room), true) } }
                if (!publishedTyping) { current.typingDenied = true; current.typing = persistentMapOf() }
                nextTyping = nanoTime() + 4_000_000_000L
            } else if (!shouldType && publishedTyping) {
                if (!authorized { commands.setTyping(requireNotNull(current.interest.room), false) }) {
                    current.typingDenied = true; current.typing = persistentMapOf()
                }
                publishedTyping = false
            }
        }
    }
    private fun receive(event: RealtimeActivityEvent) {
        if (closed || event.connectionEpoch != epoch) return
        val current = binding ?: return
        if (event.sequence <= current.floor || !sameRoom(current.interest, desired)) return
        val room = current.interest.room
        when (val hint = event.hint) {
            is LiveActivityHint.Presence -> if (hint.value.room == room && !current.interest.group &&
                hint.value.user == current.interest.peer && current.presenceReady && !current.presenceDenied) {
                current.presenceObserved = true
                applyPresence(current, hint.value, event.receivedAtMillis, event.receivedAtNanos)
            }
            is LiveActivityHint.Typing -> if (hint.value.room == room && hint.value.user != self && current.typingReady && !current.typingDenied &&
                (current.interest.group || hint.value.user == current.interest.peer)) {
                val deadline = deadline(hint.value.expiresAtMillis, event.receivedAtMillis, event.receivedAtNanos)
                current.typing = if (!hint.value.typing || deadline <= nanoTime()) current.typing.remove(hint.value.user)
                else if (hint.value.user in current.typing || current.typing.size < 64) current.typing.put(hint.value.user, deadline)
                else current.typing
            }
            is LiveActivityHint.Coverage -> if (hint.room == room) {
                when (hint.channel) {
                    ActivityChannel.Presence -> if (hint.revision > current.presenceRevision && hint.generation >= current.presenceGeneration) {
                        current.presenceRevision = hint.revision; current.presenceGeneration = hint.generation
                        current.presenceReady = hint.state == ActivityCoverageState.Ready
                        if (!current.presenceReady) { current.presence = null; current.recover = current.recover || current.presenceConfirmed }
                    }
                    ActivityChannel.Typing -> if (hint.revision > current.typingRevision && hint.generation >= current.typingGeneration) {
                        current.typingRevision = hint.revision; current.typingGeneration = hint.generation
                        current.typingReady = hint.state == ActivityCoverageState.Ready
                        if (!current.typingReady) { current.typing = persistentMapOf(); current.recover = current.recover || current.typingConfirmed }
                    }
                }
                current.recover = needsRecovery(current)
            }
        }
        publish()
    }
    private fun applyPresence(current: Binding, value: PresenceState, wall: Long, nanos: Long) {
        current.presence = value.online
        current.presenceDeadline = deadline(value.expiresAtMillis, wall, nanos)
    }
    private fun deadline(expiry: Long, wall: Long, nanos: Long): Long {
        val remaining = (expiry - wall).coerceAtLeast(0).coerceAtMost(86_400_000L)
        // A local monotonic lease cannot be extended by subsequent wall-clock corrections.
        return nanos + remaining * 1_000_000L
    }
    private fun publish() {
        val current = binding?.takeIf { !closed && sameRoom(it.interest, desired) }
        if (current == null) { mutableState.value = ConversationActivityState(desired.room); return }
        val now = nanoTime()
        current.typing = current.typing.filterValues { it > now }.toPersistentMap()
        val typingSubscribed = current.typingConfirmed && current.typingReady && !current.typingDenied
        val presenceSubscribed = current.presenceConfirmed && current.presenceReady && !current.presenceDenied
        val subscribed = typingSubscribed || presenceSubscribed
        mutableState.value = ConversationActivityState(desired.room, subscribed,
            current.presence.takeIf { presenceSubscribed && current.presenceDeadline > now },
            if (typingSubscribed) current.typing.keys.toPersistentSet() else persistentSetOf())
    }
    private fun needsRecovery(current: Binding) =
        current.retryDenied || !current.typingReady && current.typingConfirmed && !current.typingDenied ||
            !current.presenceReady && current.presenceConfirmed && !current.presenceDenied
    /** An activity permission denial is local to that channel; transport/protocol failures still end the connection. */
    private suspend fun authorized(block: suspend () -> Unit): Boolean = try { block(); true }
    catch (failure: GatewayFailure) { if (failure.code == "FORBIDDEN" && !failure.retryable) false else throw failure }
    override fun close() = end(disconnectOnClose)
    private fun end(disconnectConnection: Boolean) {
        if (closed) return
        closed = true; binding = null
        mutableState.value = ConversationActivityState()
        // An old owner's teardown must never terminate a newer epoch on the same transport.
        (commands as? LiveActivitySubscriptionClient)?.close()
        if (disconnectConnection && connection.value.epoch == epoch && connection.value.connected) disconnect(epoch)
        job.cancel()
    }
    private fun sameRoom(a: ConversationActivityInterest, b: ConversationActivityInterest) =
        a.room == b.room && a.peer == b.peer && a.group == b.group
}
