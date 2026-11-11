package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import com.xmtx.imclientkit.generated.im.realtime.v2.AuthorPresentationEnded
import com.xmtx.imclientkit.generated.im.realtime.v2.ProfilePresentationKey
import kotlinx.collections.immutable.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class AuthorPresentationClientTests {
    private val stream="EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE";private val view="FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
    private val user=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val keys=persistentListOf(ProfileKey(user,ProfileContext.Relationship),ProfileKey(user,ProfileContext.DirectConversation),
        ProfileKey(user,ProfileContext.Room(room)),ProfileKey(user,ProfileContext.GroupJoinReview(room)))
    private val start=AuthorPresentationStart(stream,view,persistentListOf(room))
    private fun client(block: (Envelope)->Envelope)=AuthorPresentationClient(object: EnvelopeTransport {
        override suspend fun request(body: Envelope.Builder)=block(body.build())
    })
    @Test fun `protobuf controls carry independent full contexts and explicit zero retention`() = runTest {
        val calls=mutableListOf<Int>()
        val client=client {request->calls+=request.bodyCase.number
            when {
                request.hasAuthorPresentationStart()->{
                    assertEquals(listOf(room.value),request.authorPresentationStart.messageRoomIdsList)
                    assertEquals(stream,request.authorPresentationStart.streamId);assertEquals(view,request.authorPresentationStart.viewId)
                    Envelope.newBuilder().setAuthorPresentationStarted(request.authorPresentationStart).build()
                }
                request.hasAuthorPresentationInterests()->{
                    val value=request.authorPresentationInterests
                    assertEquals(7,value.sequence);assertEquals(stream,value.streamId);assertEquals(view,value.viewId)
                    assertEquals(listOf(ProfilePresentationKey.ContextCase.RELATIONSHIP,ProfilePresentationKey.ContextCase.DIRECT_CONVERSATION,
                        ProfilePresentationKey.ContextCase.ROOM_ID,ProfilePresentationKey.ContextCase.GROUP_JOIN_REVIEW_ROOM_ID),value.keysList.map {it.contextCase})
                    assertTrue(value.keysList[0].relationship);assertTrue(value.keysList[1].directConversation)
                    assertEquals(room.value,value.keysList[2].roomId);assertEquals(room.value,value.keysList[3].groupJoinReviewRoomId)
                    assertTrue(value.keysList.all {it.userId==user.value})
                    Envelope.newBuilder().setAuthorPresentationInterestsReceived(value).build()
                }
                request.hasAuthorPresentationReceipt()->{
                    val value=request.authorPresentationReceipt
                    assertEquals(19,value.sequence);assertEquals(1,value.keysCount)
                    assertEquals(room.value,value.keysList.single().groupJoinReviewRoomId)
                    assertTrue(value.hasMinimumRemainingMilliseconds());assertEquals(0,value.minimumRemainingMilliseconds)
                    Envelope.newBuilder().setAuthorPresentationReceipted(value).build()
                }
                else->Envelope.newBuilder().setAuthorPresentationEnded(AuthorPresentationEnded.newBuilder().setStreamId(stream.lowercase()).setViewId(view.lowercase())).build()
            }
        }
        client.start(start);client.interests(AuthorPresentationInterests(stream,view,7,keys))
        client.receipt(AuthorPresentationReceipt(stream,view,19,persistentListOf(keys[3]),0));client.end(start)
        assertEquals(listOf(137,135,133,122),calls)
    }
    @Test fun `acknowledgement must echo exact identity order sequence and optional retention presence`() = runTest {
        assertFailsWith<ClientFailure.Protocol> {client {Envelope.newBuilder().setAuthorPresentationStarted(it.authorPresentationStart.toBuilder().setViewId(stream)).build()}.start(start)}
        val interests=AuthorPresentationInterests(stream,view,1,keys)
        assertFailsWith<ClientFailure.Protocol> {client {Envelope.newBuilder().setAuthorPresentationInterestsReceived(it.authorPresentationInterests.toBuilder().clearKeys().addAllKeys(it.authorPresentationInterests.keysList.reversed())).build()}.interests(interests)}
        val receipt=AuthorPresentationReceipt(stream,view,1,persistentListOf(keys[0]),0)
        assertFailsWith<ClientFailure.Protocol> {client {Envelope.newBuilder().setAuthorPresentationReceipted(it.authorPresentationReceipt.toBuilder().clearMinimumRemainingMilliseconds()).build()}.receipt(receipt)}
        assertFailsWith<ClientFailure.Protocol> {client {Envelope.newBuilder().setAuthorPresentationReceipted(it.authorPresentationReceipt.toBuilder().setSequence(2)).build()}.receipt(receipt)}
        assertFailsWith<ClientFailure.Protocol> {client {Envelope.newBuilder().setAuthorPresentationEnded(AuthorPresentationEnded.newBuilder().setStreamId(view).setViewId(view)).build()}.end(start)}
        assertFailsWith<ClientFailure.Protocol> {client {Envelope.getDefaultInstance()}.start(start)}
    }
    @Test fun `empty replacement and gateway failures retain original caller identity`() = runTest {
        val empty=AuthorPresentationInterests(stream,view,Long.MAX_VALUE,persistentListOf())
        client {assertEquals(0,it.authorPresentationInterests.keysCount);Envelope.newBuilder().setAuthorPresentationInterestsReceived(it.authorPresentationInterests).build()}.interests(empty)
        val failure=GatewayFailure("FORBIDDEN",false,0)
        assertSame(failure,assertFailsWith<GatewayFailure> {client {throw failure}.start(start)})
    }
}
