package com.xmtx.imclientkit

import com.xmtx.imclientkit.features.im.IMConversationStore
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMMessageDeliveryState
import com.xmtx.imclientkit.features.im.IMTCPAckPayload
import com.xmtx.imclientkit.features.im.IMTCPMessagePayload
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
                status = "received",
            ),
        )

        assertEquals(IMMessageDeliveryState.Sent, store.state.value.conversations.first().messages.first().deliveryState)
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
                content = IMMessageContent.Text("incoming"),
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
                content = IMMessageContent.Text("hello from device a"),
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
                    content = IMMessageContent.Text("loaded"),
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

    private fun pageWithConversation() =
        com.xmtx.imclientkit.features.im.IMConversationSummaryPageResponseBody(
            items = listOf(
                com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody(
                    id = "conversation-1",
                    title = "General",
                    memberCount = 2,
                    updatedAt = "2026-05-13T00:00:00Z",
                ),
            ),
            hasMore = false,
            snapshotToken = "snapshot",
        )
}
