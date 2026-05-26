package com.xmtx.imclientkit

import com.xmtx.imclientkit.features.im.IMConversationStore
import com.xmtx.imclientkit.features.im.IMActiveMessageStreamTarget
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMMessageDeliveryState
import com.xmtx.imclientkit.features.im.IMTCPAckPayload
import com.xmtx.imclientkit.features.im.IMTCPConversationEventPayload
import com.xmtx.imclientkit.features.im.IMTCPMessagePayload
import com.xmtx.imclientkit.features.im.IMTCPMessageStreamPayload
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class IMConversationStoreTests {
    @Test
    fun queueOutgoingTextCreatesQueuedLocalMessage() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())

        val didQueue = store.queueOutgoingText("hello", "conversation-1", "user-1")

        val message = store.state.value.conversations.first().messages.first()
        assertEquals(true, didQueue)
        assertEquals(IMMessageDeliveryState.Queued, message.deliveryState)
        assertEquals("hello", message.previewText)
    }

    @Test
    fun ackMarksOutgoingMessageSent() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())
        val request = store.prepareOutgoingText("hello", "conversation-1", "user-1")
        assertNotNull(request)

        store.applyOutgoingAcknowledgement(
            requestID = request!!.requestID,
            payload = IMTCPAckPayload(
                messageID = request.payload.clientMessageID!!,
                conversationID = "conversation-1",
                status = "accepted",
            ),
        )

        assertEquals(IMMessageDeliveryState.Sent, store.state.value.conversations.first().messages.first().deliveryState)
    }

    @Test
    fun failedAckMarksOutgoingMessageFailed() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())
        val request = store.prepareOutgoingText("hello", "conversation-1", "user-1")
        assertNotNull(request)

        store.applyOutgoingAcknowledgement(
            requestID = request!!.requestID,
            payload = IMTCPAckPayload(
                messageID = request.payload.clientMessageID!!,
                conversationID = "conversation-1",
                status = "conversation_unavailable",
            ),
        )

        val state = store.state.value
        assertEquals(IMMessageDeliveryState.Failed, state.conversations.first().messages.first().deliveryState)
        assertEquals("Conversation is unavailable.", state.statusMessage)
    }

    @Test
    fun serverAckUsesRequestIDWhenServerMessageIDArrivesBeforeCanonicalEcho() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())
        val request = store.prepareOutgoingText("hello", "conversation-1", "user-1")
        assertNotNull(request)

        store.applyOutgoingAcknowledgement(
            requestID = request!!.requestID,
            payload = IMTCPAckPayload(
                messageID = "server-message-1",
                conversationID = "conversation-1",
                status = "accepted",
            ),
        )

        val message = store.state.value.conversations.first().messages.first()
        assertEquals("server-message-1", message.serverMessageID)
        assertEquals(IMMessageDeliveryState.Sent, message.deliveryState)
    }

    @Test
    fun incomingMessageMergesIntoConversation() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())

        store.receiveIncomingMessage(
            com.xmtx.imclientkit.features.im.IMTCPMessagePayload(
                messageID = "message-1",
                conversationID = "conversation-1",
                senderUserID = "user-2",
                serverSequence = 3UL,
                serverTimestamp = "2026-05-13T00:00:00Z",
                content = IMMessageContent.plain("incoming"),
            ),
            currentUserID = "user-1",
        )

        val message = store.state.value.conversations.first().messages.first()
        assertEquals("incoming", message.previewText)
        assertEquals(3UL, message.serverSequence)
    }

    @Test
    fun ownRealtimeEchoMergesWithPendingMessageBeforeAck() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())
        val request = store.prepareOutgoingText("hello from device a", "conversation-1", "user-1")
        assertNotNull(request)

        store.receiveIncomingMessage(
            IMTCPMessagePayload(
                clientMessageID = request!!.payload.clientMessageID,
                messageID = "server-message-1",
                conversationID = "conversation-1",
                senderUserID = "user-1",
                serverSequence = 9UL,
                serverTimestamp = "2026-05-13T00:00:01Z",
                content = IMMessageContent.plain("hello from device a"),
            ),
            currentUserID = "user-1",
        )

        val messages = store.state.value.conversations.first().messages
        assertEquals(1, messages.size)
        assertEquals("server-message-1", messages.first().serverMessageID)
        assertEquals(9UL, messages.first().serverSequence)
        assertEquals(IMMessageDeliveryState.Sent, messages.first().deliveryState)
    }

    @Test
    fun lateAckAfterCanonicalEchoDoesNotDuplicateOrRegressSentState() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())
        val request = store.prepareOutgoingText("hello from device a", "conversation-1", "user-1")
        assertNotNull(request)

        store.receiveIncomingMessage(
            IMTCPMessagePayload(
                clientMessageID = request!!.payload.clientMessageID,
                messageID = "server-message-1",
                conversationID = "conversation-1",
                senderUserID = "user-1",
                serverSequence = 9UL,
                serverTimestamp = "2026-05-13T00:00:01Z",
                content = IMMessageContent.plain("hello from device a"),
            ),
            currentUserID = "user-1",
        )
        store.applyOutgoingAcknowledgement(
            requestID = request.requestID,
            payload = IMTCPAckPayload(
                messageID = "server-message-1",
                conversationID = "conversation-1",
                status = "internal_error",
            ),
        )

        val messages = store.state.value.conversations.first().messages
        assertEquals(1, messages.size)
        assertEquals("server-message-1", messages.first().serverMessageID)
        assertEquals(9UL, messages.first().serverSequence)
        assertEquals(IMMessageDeliveryState.Sent, messages.first().deliveryState)
    }

    @Test
    fun pendingReadSequenceKeepsHighestValueUntilCleared() {
        val store = IMConversationStore()
        store.recordPendingReadSequence("conversation-1", 2UL)
        store.recordPendingReadSequence("conversation-1", 5UL)
        store.recordPendingReadSequence("conversation-1", 3UL)

        assertEquals(5UL, store.state.value.pendingReadSequences["conversation-1"])

        store.clearPendingReadSequence("conversation-1", 4UL)
        assertEquals(5UL, store.state.value.pendingReadSequences["conversation-1"])

        store.clearPendingReadSequence("conversation-1", 5UL)
        assertEquals(null, store.state.value.pendingReadSequences["conversation-1"])
    }

    @Test
    fun summaryUpdateFromAnotherDeviceClearsUnreadDelta() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation(unreadCount = 1, lastReadSequence = 0))
        store.receiveIncomingMessage(
            IMTCPMessagePayload(
                messageID = "server-message-2",
                conversationID = "conversation-1",
                senderUserID = "user-2",
                serverSequence = 2UL,
                serverTimestamp = "2026-05-13T00:00:02Z",
                content = IMMessageContent.plain("new unread"),
            ),
            currentUserID = "user-1",
        )

        store.applyConversationSummary(
            conversation("conversation-1").copy(
                lastReadSequence = 2,
                unreadCount = 0,
                updatedAt = "2026-05-13T00:00:03Z",
            ),
        )

        val conversation = store.state.value.conversations.first()
        assertEquals(2UL, conversation.serverLastReadSequence)
        assertEquals(0, conversation.serverUnreadCount)
        assertEquals(0, conversation.localUnreadDelta)
        assertEquals(0, conversation.unreadCount)
    }

    @Test
    fun appendingMessagesRecordsLoadedCursorState() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())

        store.appendMessages(
            conversationID = "conversation-1",
            messages = listOf(
                com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody(
                    id = "message-1",
                    conversationID = "conversation-1",
                    senderUserID = "user-2",
                    serverSequence = 4,
                    content = IMMessageContent.plain("loaded"),
                    createdAt = "2026-05-13T00:00:00Z",
                ),
            ),
            currentUserID = "user-1",
        )

        val state = store.state.value
        assertEquals(setOf("conversation-1"), state.loadedConversationIDs)
        assertEquals(4UL, state.latestSyncedServerSequences["conversation-1"])
        assertEquals(4UL, state.oldestLoadedServerSequences["conversation-1"])
    }

    @Test
    fun streamEventsMergeChunksIdempotentlyAndCompleteWithCanonicalMessage() {
        val store = IMConversationStore()
        store.replaceSummaryWindow(pageWithConversation())

        store.applyMessageStreamEvent(
            payload = IMTCPConversationEventPayload(
                eventType = "message_stream_started",
                conversation = conversation("conversation-1"),
                message = com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody(
                    id = "message-1",
                    conversationID = "conversation-1",
                    senderUserID = "user-1",
                    serverSequence = 2,
                    content = IMMessageContent.plain(""),
                    createdAt = "2026-05-13T00:00:00Z",
                ),
                stream = IMTCPMessageStreamPayload(
                    streamID = "stream-1",
                    messageID = "message-1",
                    conversationID = "conversation-1",
                    chunkIndex = 0,
                    partialTextLength = 0,
                    state = "streaming",
                    serverTimestamp = "2026-05-13T00:00:00Z",
                ),
                actorUserID = "user-1",
                serverTimestamp = "2026-05-13T00:00:00Z",
            ),
            currentUserID = "user-1",
        )

        listOf(
            IMTCPMessageStreamPayload(
                streamID = "stream-1",
                messageID = "message-1",
                conversationID = "conversation-1",
                chunkIndex = 1,
                deltaText = "AI",
                partialTextLength = 2,
                state = "streaming",
                serverTimestamp = "2026-05-13T00:00:01Z",
            ),
            IMTCPMessageStreamPayload(
                streamID = "stream-1",
                messageID = "message-1",
                conversationID = "conversation-1",
                chunkIndex = 1,
                deltaText = "AI",
                partialTextLength = 2,
                state = "streaming",
                serverTimestamp = "2026-05-13T00:00:01Z",
            ),
            IMTCPMessageStreamPayload(
                streamID = "stream-1",
                messageID = "message-1",
                conversationID = "conversation-1",
                chunkIndex = 2,
                deltaText = " response",
                partialTextLength = 11,
                state = "streaming",
                serverTimestamp = "2026-05-13T00:00:02Z",
            ),
        ).forEach { stream ->
            store.applyMessageStreamEvent(
                payload = IMTCPConversationEventPayload(
                    eventType = "message_stream_chunk",
                    conversation = conversation("conversation-1"),
                    stream = stream,
                    actorUserID = "user-1",
                    serverTimestamp = stream.serverTimestamp,
                ),
                currentUserID = "user-1",
            )
        }

        var messages = store.state.value.conversations.first().messages
        assertEquals(1, messages.size)
        assertEquals("AI response", messages.first().previewText)
        assertEquals(
            listOf(
                IMActiveMessageStreamTarget(
                    conversationID = "conversation-1",
                    messageID = "message-1",
                    streamID = "stream-1",
                ),
            ),
            store.activeMessageStreamTargets(),
        )

        store.applyMessageStreamEvent(
            payload = IMTCPConversationEventPayload(
                eventType = "message_stream_chunk",
                conversation = conversation("conversation-1"),
                stream = IMTCPMessageStreamPayload(
                    streamID = "stream-1",
                    messageID = "message-1",
                    conversationID = "conversation-1",
                    chunkIndex = 4,
                    deltaText = " gap",
                    partialTextLength = 15,
                    state = "streaming",
                    serverTimestamp = "2026-05-13T00:00:04Z",
                ),
                actorUserID = "user-1",
                serverTimestamp = "2026-05-13T00:00:04Z",
            ),
            currentUserID = "user-1",
        )
        assertEquals("AI response", store.state.value.conversations.first().messages.first().previewText)
        assertEquals(
            listOf(
                IMActiveMessageStreamTarget(
                    conversationID = "conversation-1",
                    messageID = "message-1",
                    streamID = "stream-1",
                ),
            ),
            store.consumePendingStreamSnapshotTargets(),
        )

        store.applyMessageStreamEvent(
            payload = IMTCPConversationEventPayload(
                eventType = "message_stream_completed",
                conversation = conversation("conversation-1"),
                message = com.xmtx.imclientkit.features.im.IMConversationMessageResponseBody(
                    id = "message-1",
                    conversationID = "conversation-1",
                    senderUserID = "user-1",
                    serverSequence = 2,
                    content = IMMessageContent.plain("AI response"),
                    createdAt = "2026-05-13T00:00:00Z",
                ),
                stream = IMTCPMessageStreamPayload(
                    streamID = "stream-1",
                    messageID = "message-1",
                    conversationID = "conversation-1",
                    chunkIndex = Int.MAX_VALUE,
                    partialTextLength = 11,
                    state = "completed",
                    serverTimestamp = "2026-05-13T00:00:03Z",
                ),
                actorUserID = "user-1",
                serverTimestamp = "2026-05-13T00:00:03Z",
            ),
            currentUserID = "user-1",
        )

        messages = store.state.value.conversations.first().messages
        assertEquals(1, messages.size)
        assertEquals("AI response", messages.first().previewText)
        assertEquals(
            "completed",
            messages.first().derivedState["streamState"]!!.jsonObject["state"]!!.jsonPrimitive.toString().trim('"'),
        )
        assertEquals(emptyList<IMActiveMessageStreamTarget>(), store.activeMessageStreamTargets())

        store.applyMessageStreamEvent(
            payload = IMTCPConversationEventPayload(
                eventType = "message_stream_chunk",
                conversation = conversation("conversation-1"),
                stream = IMTCPMessageStreamPayload(
                    streamID = "stream-1",
                    messageID = "message-1",
                    conversationID = "conversation-1",
                    chunkIndex = 3,
                    deltaText = " late",
                    partialTextLength = 16,
                    state = "streaming",
                    serverTimestamp = "2026-05-13T00:00:05Z",
                ),
                actorUserID = "user-1",
                serverTimestamp = "2026-05-13T00:00:05Z",
            ),
            currentUserID = "user-1",
        )
        messages = store.state.value.conversations.first().messages
        assertEquals("AI response", messages.first().previewText)
        assertEquals(
            "completed",
            messages.first().derivedState["streamState"]!!.jsonObject["state"]!!.jsonPrimitive.toString().trim('"'),
        )
    }

    private fun pageWithConversation(unreadCount: Int = 0, lastReadSequence: Int = 0) =
        com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody(
            items = listOf(
                conversation("conversation-1").copy(
                    unreadCount = unreadCount,
                    lastReadSequence = lastReadSequence,
                ),
            ),
            hasMore = false,
            snapshotToken = "snapshot",
        )

    private fun conversation(id: String) =
        com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody(
            id = id,
            title = "General",
            memberCount = 2,
            updatedAt = "2026-05-13T00:00:00Z",
        )
}
