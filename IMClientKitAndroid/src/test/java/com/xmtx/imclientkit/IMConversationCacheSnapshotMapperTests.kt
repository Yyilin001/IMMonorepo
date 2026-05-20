package com.xmtx.imclientkit

import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConversation
import com.xmtx.imclientkit.features.im.IMConversationMessage
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMMessageDeliveryState
import com.xmtx.imclientkit.features.im.IMMessageDirection
import com.xmtx.imclientkit.persistence.imcache.IMConversationCacheSnapshotMapper
import org.junit.Assert.assertEquals
import org.junit.Test

class IMConversationCacheSnapshotMapperTests {
    @Test
    fun trimsMessagesToCacheLimit() {
        val conversation = IMConversation(
            id = "conversation-1",
            summary = summary("conversation-1"),
            messages = (1..205).map { index -> message(index.toULong()) },
        )

        val snapshot = IMConversationCacheSnapshotMapper.makeSnapshot(
            state = ConversationListState(conversations = listOf(conversation)),
            messageLimit = 200,
        )

        val messages = snapshot.conversations.first().messages
        assertEquals(200, messages.size)
        assertEquals(6UL, messages.first().serverSequence)
        assertEquals(205UL, messages.last().serverSequence)
    }

    @Test
    fun restoreDowngradesSendingAndKeepsQueued() {
        val state = ConversationListState(
            conversations = listOf(
                IMConversation(
                    id = "conversation-1",
                    summary = summary("conversation-1"),
                    messages = listOf(
                        message(1UL, deliveryState = IMMessageDeliveryState.Sending),
                        message(2UL, deliveryState = IMMessageDeliveryState.Queued),
                    ),
                ),
            ),
            selectedConversationID = "conversation-1",
            loadedConversationIDs = setOf("conversation-1"),
            pendingReadSequences = mapOf("conversation-1" to 7UL),
        )

        val restored = IMConversationCacheSnapshotMapper.restore(
            IMConversationCacheSnapshotMapper.makeSnapshot(state),
        )

        val messages = restored.conversations.first().messages
        assertEquals(IMMessageDeliveryState.Unknown, messages[0].deliveryState)
        assertEquals(IMMessageDeliveryState.Queued, messages[1].deliveryState)
        assertEquals(setOf("conversation-1"), restored.loadedConversationIDs)
        assertEquals(7UL, restored.pendingReadSequences["conversation-1"])
    }

    private fun summary(id: String) = IMConversationSummaryResponseBody(
        id = id,
        title = "General",
        memberCount = 2,
        updatedAt = "2026-05-13T00:00:00Z",
    )

    private fun message(
        sequence: ULong,
        deliveryState: IMMessageDeliveryState = IMMessageDeliveryState.Received,
    ) = IMConversationMessage(
        id = "message-$sequence",
        conversationID = "conversation-1",
        clientMessageID = null,
        serverMessageID = "message-$sequence",
        senderUserID = "user-2",
        serverSequence = sequence,
        content = IMMessageContent.Text("message $sequence"),
        direction = IMMessageDirection.Incoming,
        createdAt = "2026-05-13T00:00:${sequence.toString().padStart(2, '0')}Z",
        deliveryState = deliveryState,
    )
}
