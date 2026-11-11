package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class LiveActivityClientTests {
    private class Transport(var response: Envelope = Envelope.newBuilder().setAcknowledged(Acknowledged.getDefaultInstance()).build()) : EnvelopeTransport {
        var sent: Envelope? = null
        override suspend fun request(body: Envelope.Builder): Envelope { sent = body.build(); return response }
    }
    @Test fun `subscriptions and typing use room scoped contract and require acknowledgement`() = runTest {
        val transport = Transport(); val client = LiveActivityClient(transport); val room = RoomId("room")
        client.subscribeTyping(room); assertEquals("room", transport.sent!!.subscribeTyping.roomId)
        client.setTyping(room, true); assertEquals("room", transport.sent!!.setTypingState.roomId); assertTrue(transport.sent!!.setTypingState.isTyping)
        client.setTyping(room, false); assertFalse(transport.sent!!.setTypingState.isTyping)
        client.unsubscribeTyping(room); assertEquals("room", transport.sent!!.unsubscribeTyping.roomId)
        client.unsubscribePresence(room); assertEquals("room", transport.sent!!.unsubscribePresence.roomId)
        transport.response = Envelope.newBuilder().setHeartbeatAck(HeartbeatAck.getDefaultInstance()).build()
        assertFailsWith<ClientFailure.Protocol> { client.subscribeTyping(room) }
        assertFailsWith<ClientFailure.Protocol> { client.setTyping(room, true) }
        assertFailsWith<ClientFailure.Protocol> { client.unsubscribeTyping(room) }
        assertFailsWith<ClientFailure.Protocol> { client.unsubscribePresence(room) }
    }
    @Test fun `presence response binds requested room identity and nonnegative expiry`() = runTest {
        val response = PresenceSubscribed.newBuilder().setRoomId("room").setTargetUserId("peer").setIsOnline(true).setExpiresAtMs(10_000)
        val transport = Transport(); val client = LiveActivityClient(transport)
        fun respond() { transport.response = Envelope.newBuilder().setPresenceSubscribed(response).build() }
        respond()
        assertEquals(PresenceState(RoomId("room"), UserId("peer"), true, 10_000), client.subscribePresence(RoomId("room")))
        assertEquals("room", transport.sent!!.subscribePresence.roomId)
        response.setRoomId("other"); respond()
        assertFailsWith<ClientFailure.Protocol> { client.subscribePresence(RoomId("room")) }
        response.setRoomId("room").setExpiresAtMs(-1); respond()
        assertFailsWith<ClientFailure.Protocol> { client.subscribePresence(RoomId("room")) }
        response.setExpiresAtMs(0).setTargetUserId("invalid/user"); respond()
        assertFailsWith<ClientFailure.Protocol> { client.subscribePresence(RoomId("room")) }
    }
    @Test fun `publication mode never accepts an unconfirmed or opposite privacy mode`() = runTest {
        val transport = Transport(); val client = LiveActivityClient(transport)
        transport.response = Envelope.newBuilder().setPresencePublicationControlled(PresencePublicationControlled.newBuilder()
            .setMode(PresencePublicationControl.Mode.SUPPRESSED)).build()
        client.setPresencePublicationMode(PresencePublicationMode.Suppressed)
        assertEquals(PresencePublicationControl.Mode.SUPPRESSED, transport.sent!!.presencePublicationControl.mode)
        assertFailsWith<ClientFailure.Protocol> { client.setPresencePublicationMode(PresencePublicationMode.AllowWhenAuthorized) }
        transport.response = Envelope.newBuilder().setPresencePublicationControlled(PresencePublicationControlled.newBuilder()
            .setMode(PresencePublicationControl.Mode.ALLOW_WHEN_AUTHORIZED)).build()
        client.setPresencePublicationMode(PresencePublicationMode.AllowWhenAuthorized)
        assertEquals(PresencePublicationControl.Mode.ALLOW_WHEN_AUTHORIZED, transport.sent!!.presencePublicationControl.mode)
    }
    @Test fun `activity decoder validates identities and lease bounds and preserves false transitions`() {
        val typing = TypingStateChanged.newBuilder().setRoomId("room").setUserId("peer").setIsTyping(false).setExpiresAtMs(0)
        fun typed() = LiveActivityHint.decode(Envelope.newBuilder().setTypingStateChanged(typing).build())
        assertEquals(LiveActivityHint.Typing(TypingState(RoomId("room"), UserId("peer"), false, 0)), typed())
        typing.setExpiresAtMs(-1); assertFailsWith<ClientFailure.Protocol> { typed() }
        typing.setExpiresAtMs(1).setUserId(""); assertFailsWith<ClientFailure.Protocol> { typed() }
        val presence = PresenceChanged.newBuilder().setRoomId("room").setTargetUserId("peer").setIsOnline(false)
        assertEquals(LiveActivityHint.Presence(PresenceState(RoomId("room"), UserId("peer"), false, 0)),
            LiveActivityHint.decode(Envelope.newBuilder().setPresenceChanged(presence).build()))
        presence.setRoomId("../other")
        assertFailsWith<ClientFailure.Protocol> { LiveActivityHint.decode(Envelope.newBuilder().setPresenceChanged(presence).build()) }
    }
    @Test fun `coverage exposes ordered activity channel transitions without interpreting durable sync hints`() {
        val coverage = RealtimeCoverage.newBuilder().setScope(RealtimeCoverage.Scope.TYPING).setScopeId("00000000-0000-0000-0000-000000000001")
            .setState(RealtimeCoverage.State.RECOVERING).setReason(RealtimeCoverage.Reason.INSTALLING).setRevision(5).setScopeGeneration(2)
        fun decoded() = LiveActivityHint.decode(Envelope.newBuilder().setRealtimeCoverage(coverage).build())
        assertEquals(LiveActivityHint.Coverage(RoomId("00000000-0000-0000-0000-000000000001"), ActivityChannel.Typing, ActivityCoverageState.Recovering, 5, 2), decoded())
        coverage.setScope(RealtimeCoverage.Scope.PRESENCE).setState(RealtimeCoverage.State.ENDED).setReason(RealtimeCoverage.Reason.CANCELLED)
        assertEquals(ActivityCoverageState.Ended, (decoded() as LiveActivityHint.Coverage).state)
        coverage.setRevision(0); assertFailsWith<ClientFailure.Protocol> { decoded() }
        coverage.setRevision(6).setState(RealtimeCoverage.State.STATE_UNSPECIFIED); assertFailsWith<ClientFailure.Protocol> { decoded() }
        coverage.setScope(RealtimeCoverage.Scope.ROOM); assertNull(decoded())
        assertNull(LiveActivityHint.decode(Envelope.newBuilder().setHeartbeatAck(HeartbeatAck.getDefaultInstance()).build()))
    }
}
