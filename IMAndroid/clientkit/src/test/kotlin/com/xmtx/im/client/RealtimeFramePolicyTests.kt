package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlin.test.*
import com.xmtx.imclientkit.generated.im.realtime.v2.AuthorPresentationInterests as WireInterests

class RealtimeFramePolicyTests {
    @Test fun `control and ephemeral do not inherit domain recovery ordering or quota`() {
        val scoped=NetworkWorkContext("domain",NetworkWorkPriority.Background,NetworkWorkKind.Upload,"frozen",true)
        assertEquals(NetworkWorkContext("realtime",NetworkWorkPriority.Critical,NetworkWorkKind.Authentication),
            RealtimeFramePolicy.of(Envelope.newBuilder().setSyncAck(SyncAck.getDefaultInstance()).build()).context(scoped))
        assertEquals(NetworkWorkContext("realtime"),RealtimeFramePolicy.Ephemeral.context(scoped))
        for(kind in listOf(RealtimeFramePolicy.Read,RealtimeFramePolicy.Mutation))
            assertEquals(NetworkWorkContext("realtime",NetworkWorkPriority.Background,orderingKey="frozen",isRetry=true),kind.context(scoped))
        assertTrue(RealtimeFramePolicy.entries.none {it.permitsAutomaticReplay})
    }
    @Test fun `clearing interests uses reserved control but adding interests is ordinary read`() {
        val frame=Envelope.newBuilder().setAuthorPresentationInterests(WireInterests.getDefaultInstance())
        assertEquals(RealtimeFramePolicy.Control,RealtimeFramePolicy.of(frame.build()))
        frame.setAuthorPresentationInterests(WireInterests.newBuilder().addKeys(ProfilePresentationKey.getDefaultInstance()))
        assertEquals(RealtimeFramePolicy.Read,RealtimeFramePolicy.of(frame.build()))
        assertEquals(RealtimeFramePolicy.Mutation,RealtimeFramePolicy.of(Envelope.newBuilder().setMessageSendOperationRecover(MessageSendOperationRecover.getDefaultInstance()).build()))
        assertEquals(RealtimeFramePolicy.Read,RealtimeFramePolicy.of(Envelope.newBuilder().setAccountRoomChangesStart(AccountRoomChangesStart.getDefaultInstance()).build()))
    }
    @Test fun `handshake and server only bodies cannot become ordinary client requests`() {
        assertFailsWith<ClientFailure.Protocol> {RealtimeFramePolicy.Handshake.context()}
        assertFailsWith<ClientFailure.Protocol> {RealtimeFramePolicy.ServerOnly.context()}
        assertFailsWith<ClientFailure.Protocol> {RealtimeFramePolicy.of(Envelope.getDefaultInstance())}
    }
}
