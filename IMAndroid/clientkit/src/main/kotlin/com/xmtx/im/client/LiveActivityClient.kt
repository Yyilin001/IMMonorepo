package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*

/** Connection-scoped, ephemeral values. They are never message-delivery evidence or stored history. */
data class PresenceState(val room: RoomId, val user: UserId, val online: Boolean, val expiresAtMillis: Long) {
    init { require(expiresAtMillis >= 0) }
}
data class TypingState(val room: RoomId, val user: UserId, val typing: Boolean, val expiresAtMillis: Long) {
    init { require(expiresAtMillis >= 0) }
}
enum class ActivityChannel { Presence, Typing }
enum class ActivityCoverageState { Recovering, Ready, Ended }
sealed interface LiveActivityHint {
    data class Presence(val value: PresenceState) : LiveActivityHint
    data class Typing(val value: TypingState) : LiveActivityHint
    data class Coverage(val room: RoomId, val channel: ActivityChannel, val state: ActivityCoverageState,
        val revision: Long, val generation: Long) : LiveActivityHint {
        init { require(revision > 0 && generation > 0) }
    }
    companion object {
        internal fun decode(envelope: Envelope): LiveActivityHint? = try {
            when {
                envelope.hasPresenceChanged() -> envelope.presenceChanged.let {
                    Presence(PresenceState(RoomId(it.roomId), UserId(it.targetUserId), it.isOnline, it.expiresAtMs))
                }
                envelope.hasTypingStateChanged() -> envelope.typingStateChanged.let {
                    Typing(TypingState(RoomId(it.roomId), UserId(it.userId), it.isTyping, it.expiresAtMs))
                }
                envelope.hasRealtimeCoverage() -> envelope.realtimeCoverage.let {
                    val channel = when (it.scope) {
                        RealtimeCoverage.Scope.PRESENCE -> ActivityChannel.Presence
                        RealtimeCoverage.Scope.TYPING -> ActivityChannel.Typing
                        else -> return null
                    }
                    val value = RealtimeCoverageState.decode(it, 1)
                    Coverage(RoomId(value.scopeId), channel, value.status, value.revision, value.scopeGeneration)
                }
                else -> null
            }
        } catch (_: IllegalArgumentException) { throw ClientFailure.Protocol() }
    }
}
data class RealtimeActivityEvent(val connectionEpoch: Long, val hint: LiveActivityHint, val sequence: Long = 0,
    val receivedAtMillis: Long = System.currentTimeMillis(), val receivedAtNanos: Long = System.nanoTime())
enum class PresencePublicationMode { Suppressed, AllowWhenAuthorized }

/** Wire operations only. The foreground owner controls subscriptions, publication policy and leases. */
interface LiveActivityCommands {
    suspend fun subscribePresence(room: RoomId): PresenceState
    suspend fun unsubscribePresence(room: RoomId)
    suspend fun subscribeTyping(room: RoomId)
    suspend fun unsubscribeTyping(room: RoomId)
    suspend fun setTyping(room: RoomId, typing: Boolean)
    suspend fun setPresencePublicationMode(mode: PresencePublicationMode)
}
class LiveActivityClient(private val transport: EnvelopeTransport) : LiveActivityCommands {
    override suspend fun subscribePresence(room: RoomId): PresenceState {
        val response = transport.request(Envelope.newBuilder().setSubscribePresence(
            SubscribePresence.newBuilder().setRoomId(room.value)))
        if (!response.hasPresenceSubscribed()) throw ClientFailure.Protocol()
        val value = response.presenceSubscribed
        if (value.roomId != room.value || value.expiresAtMs < 0) throw ClientFailure.Protocol()
        return try { PresenceState(room, UserId(value.targetUserId), value.isOnline, value.expiresAtMs) }
        catch (_: IllegalArgumentException) { throw ClientFailure.Protocol() }
    }
    override suspend fun unsubscribePresence(room: RoomId) = acknowledged(Envelope.newBuilder().setUnsubscribePresence(
        UnsubscribePresence.newBuilder().setRoomId(room.value)))
    override suspend fun subscribeTyping(room: RoomId) = acknowledged(Envelope.newBuilder().setSubscribeTyping(
        SubscribeTyping.newBuilder().setRoomId(room.value)))
    override suspend fun unsubscribeTyping(room: RoomId) = acknowledged(Envelope.newBuilder().setUnsubscribeTyping(
        UnsubscribeTyping.newBuilder().setRoomId(room.value)))
    override suspend fun setTyping(room: RoomId, typing: Boolean) = acknowledged(Envelope.newBuilder().setSetTypingState(
        SetTypingState.newBuilder().setRoomId(room.value).setIsTyping(typing)))
    override suspend fun setPresencePublicationMode(mode: PresencePublicationMode) {
        val wire = when (mode) {
            PresencePublicationMode.Suppressed -> PresencePublicationControl.Mode.SUPPRESSED
            PresencePublicationMode.AllowWhenAuthorized -> PresencePublicationControl.Mode.ALLOW_WHEN_AUTHORIZED
        }
        val response = transport.request(Envelope.newBuilder().setPresencePublicationControl(
            PresencePublicationControl.newBuilder().setMode(wire)))
        if (!response.hasPresencePublicationControlled() || response.presencePublicationControlled.mode != wire)
            throw ClientFailure.Protocol()
    }
    private suspend fun acknowledged(request: Envelope.Builder) {
        if (!transport.request(request).hasAcknowledged()) throw ClientFailure.Protocol()
    }
}
