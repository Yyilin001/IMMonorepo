package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.Closeable

/** A visible conversation owns account leases across physical reconnects. Call on the supplied
 * single-thread dispatcher. Draft restoration is presentation state; only updateTyping represents
 * a new editing event. Publication privacy remains owned by the foreground account runtime. */
class ConversationActivityScene(private val self: UserId, private val subscriptions: RoomSubscriptions,
    scope: CoroutineScope) : Closeable {
    private val job = SupervisorJob(requireNotNull(scope.coroutineContext[Job]))
    private val owner = CoroutineScope(scope.coroutineContext + job)
    private val mutableState = MutableStateFlow(ConversationActivityState())
    val state = mutableState.asStateFlow()
    private var desired = ConversationActivityInterest()
    private var lease: RoomSubscriptionLease? = null
    private var observation: Job? = null
    private var renewal: Job? = null
    private var observedConnection: String? = null
    private var closed = false
    init {
        @OptIn(DelicateCoroutinesApi::class)
        owner.launch(start = CoroutineStart.ATOMIC) { try { awaitCancellation() } finally { close() } }
    }
    fun update(value: ConversationActivityInterest) {
        if (closed) return
        val changed = desired.room != value.room || desired.peer != value.peer || desired.group != value.group
        desired = value
        if (changed) {
            cancelRenewal(); observation?.cancel(); observation = null; observedConnection = null
            lease?.let(subscriptions::release); lease = null
            mutableState.value = ConversationActivityState(value.room)
            value.room?.let { room ->
                var channels = persistentSetOf(RoomSubscriptionChannel.Typing)
                if (!value.group && value.peer != null) channels = channels.add(RoomSubscriptionChannel.Presence)
                // A bounded subscription refusal must not make durable local history unusable.
                val selected = try { subscriptions.acquire(room, channels) } catch (_: IllegalStateException) { return }
                lease = selected
                observation = owner.launch { selected.state.collect { snapshot ->
                    if (lease !== selected || closed) return@collect
                    if (observedConnection != snapshot.connectionId || snapshot.status != RoomSubscriptionStatus.Subscribed) cancelRenewal()
                    observedConnection = snapshot.connectionId.takeIf { snapshot.status == RoomSubscriptionStatus.Subscribed }
                    val typing = if (RoomSubscriptionChannel.Typing in snapshot.confirmed)
                        snapshot.typing.filter { it.user != self && (desired.group || it.user == desired.peer) }.map { it.user }.toPersistentSet()
                        else persistentSetOf()
                    val presence = snapshot.presence?.takeIf { RoomSubscriptionChannel.Presence in snapshot.confirmed && !desired.group && it.user == desired.peer }
                    mutableState.value = ConversationActivityState(selected.room, snapshot.confirmed.isNotEmpty(), presence?.online, typing)
                } }
            }
        }
        if (!value.hasDraft || !value.typingAllowed) stopTyping()
    }
    /** Called for an actual composer edit, never merely because an existing draft became visible. */
    fun updateTyping(draft: String) {
        if (closed) return
        if (draft.isBlank() || !desired.typingAllowed) { stopTyping(); return }
        val selected = lease ?: return
        val id = observedConnection ?: return
        val snapshot = selected.state.value
        if (snapshot.connectionId != id || snapshot.status != RoomSubscriptionStatus.Subscribed) return
        if (renewal?.isActive == true) return
        renewal = owner.launch(start = CoroutineStart.LAZY) {
            try {
                while (isActive) { subscriptions.setTyping(selected, id, true); delay(4_000) }
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { /* Transient activity cannot fail durable chat. A new edit may retry. */ }
            finally { if (renewal === currentCoroutineContext()[Job]) renewal = null }
        }
        renewal?.start()
    }
    private fun cancelRenewal() { renewal?.cancel(); renewal = null }
    private fun stopTyping() {
        if (renewal == null) return
        val selected = lease; val id = observedConnection
        cancelRenewal()
        if (selected != null && id != null) owner.launch {
            try { subscriptions.setTyping(selected, id, false) }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { /* The receiver TTL clears a lost stop. Never replay on another connection. */ }
        }
    }
    override fun close() {
        if (closed) return
        closed = true; cancelRenewal(); observation?.cancel(); observation = null; observedConnection = null
        lease?.let(subscriptions::release); lease = null; mutableState.value = ConversationActivityState(); job.cancel()
    }
    suspend fun awaitClosed() { close(); withContext(NonCancellable) { job.join() } }
}
