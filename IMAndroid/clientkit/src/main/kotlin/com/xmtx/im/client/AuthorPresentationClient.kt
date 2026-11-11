package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import com.xmtx.imclientkit.generated.im.realtime.v2.ProfilePresentationKey
import com.xmtx.imclientkit.generated.im.realtime.v2.AuthorPresentationStart as WireStart
import com.xmtx.imclientkit.generated.im.realtime.v2.AuthorPresentationEnd as WireEnd
import com.xmtx.imclientkit.generated.im.realtime.v2.AuthorPresentationInterests as WireInterests
import com.xmtx.imclientkit.generated.im.realtime.v2.AuthorPresentationReceipt as WireReceipt

/** Wire controls for an already negotiated, connection-bound author view. These do not create local view ownership. */
class AuthorPresentationClient(private val transport: EnvelopeTransport): AuthorPresentationCommands {
    override suspend fun start(value: AuthorPresentationStart) {
        val request=WireStart.newBuilder().setStreamId(value.stream).setViewId(value.view).addAllMessageRoomIds(value.messageRooms.map {it.value}).build()
        val response=transport.request(Envelope.newBuilder().setAuthorPresentationStart(request))
        if(!response.hasAuthorPresentationStarted() || response.authorPresentationStarted!=request) throw ClientFailure.Protocol()
    }
    override suspend fun end(value: AuthorPresentationStart) {
        val response=transport.request(Envelope.newBuilder().setAuthorPresentationEnd(WireEnd.newBuilder().setStreamId(value.stream).setViewId(value.view)))
        if(!response.hasAuthorPresentationEnded()) throw ClientFailure.Protocol()
        try {
            if(uuidId(response.authorPresentationEnded.streamId)!=value.stream || uuidId(response.authorPresentationEnded.viewId)!=value.view) throw ClientFailure.Protocol()
        } catch(_: IllegalArgumentException) {throw ClientFailure.Protocol()}
    }
    override suspend fun interests(value: AuthorPresentationInterests) {
        val request=WireInterests.newBuilder().setStreamId(value.stream).setViewId(value.view).setSequence(value.sequence).addAllKeys(value.keys.map {it.authorWire()}).build()
        val response=transport.request(Envelope.newBuilder().setAuthorPresentationInterests(request))
        if(!response.hasAuthorPresentationInterestsReceived() || response.authorPresentationInterestsReceived!=request) throw ClientFailure.Protocol()
    }
    override suspend fun receipt(value: AuthorPresentationReceipt) {
        val request=WireReceipt.newBuilder().setStreamId(value.stream).setViewId(value.view).setSequence(value.sequence)
            .addAllKeys(value.keys.map {it.authorWire()}).setMinimumRemainingMilliseconds(value.minimumRemainingMillis.toInt()).build()
        val response=transport.request(Envelope.newBuilder().setAuthorPresentationReceipt(request))
        if(!response.hasAuthorPresentationReceipted() || response.authorPresentationReceipted!=request) throw ClientFailure.Protocol()
    }
}
private fun ProfileKey.authorWire(): ProfilePresentationKey=ProfilePresentationKey.newBuilder().setUserId(user.value).apply {
    when(val scope=context) {
        ProfileContext.Relationship->setRelationship(true)
        ProfileContext.DirectConversation->setDirectConversation(true)
        is ProfileContext.Room->setRoomId(scope.room.value)
        is ProfileContext.GroupJoinReview->setGroupJoinReviewRoomId(scope.room.value)
    }
}.build()
