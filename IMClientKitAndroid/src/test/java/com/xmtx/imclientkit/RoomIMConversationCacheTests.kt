package com.xmtx.imclientkit

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConversation
import com.xmtx.imclientkit.features.im.IMConversationMessage
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMMessageDeliveryState
import com.xmtx.imclientkit.features.im.IMMessageDirection
import com.xmtx.imclientkit.persistence.imcache.IMCacheDatabase
import com.xmtx.imclientkit.persistence.imcache.RoomIMConversationCache
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class RoomIMConversationCacheTests {
    private lateinit var database: IMCacheDatabase
    private lateinit var cache: RoomIMConversationCache

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            IMCacheDatabase::class.java,
        ).allowMainThreadQueries().build()
        cache = RoomIMConversationCache(database)
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun savesAndRestoresConversationSnapshot() = runTest {
        val state = ConversationListState(
            conversations = listOf(
                IMConversation(
                    id = "conversation-1",
                    summary = summary("conversation-1"),
                    messages = listOf(message(1UL)),
                    serverLastReadSequence = 1UL,
                    serverUnreadCount = 0,
                ),
            ),
            selectedConversationID = "conversation-1",
            nextCursor = "cursor",
            hasMore = true,
            snapshotToken = "token",
            lastSummaryRefreshAt = "2026-05-13T00:00:00Z",
            loadedConversationIDs = setOf("conversation-1"),
            latestSyncedServerSequences = mapOf("conversation-1" to 1UL),
            oldestLoadedServerSequences = mapOf("conversation-1" to 1UL),
        )

        cache.saveSnapshot("user-1", state)
        val restored = cache.loadSnapshot("user-1")

        assertEquals("conversation-1", restored?.selectedConversationID)
        assertEquals("token", restored?.snapshotToken)
        assertEquals("cursor", restored?.nextCursor)
        assertEquals(true, restored?.hasMore)
        assertEquals(setOf("conversation-1"), restored?.loadedConversationIDs)
        assertEquals(1UL, restored?.latestSyncedServerSequences?.get("conversation-1"))
        assertEquals("hello", restored?.conversations?.first()?.messages?.first()?.previewText)
    }

    @Test
    fun separatesSnapshotsByOwnerUserID() = runTest {
        cache.saveSnapshot(
            "user-1",
            ConversationListState(conversations = listOf(IMConversation("conversation-1", summary("conversation-1")))),
        )
        cache.saveSnapshot(
            "user-2",
            ConversationListState(conversations = listOf(IMConversation("conversation-2", summary("conversation-2")))),
        )

        assertEquals("conversation-1", cache.loadSnapshot("user-1")?.conversations?.first()?.id)
        assertEquals("conversation-2", cache.loadSnapshot("user-2")?.conversations?.first()?.id)
    }

    @Test
    fun clearRemovesOnlyRequestedOwnerSnapshot() = runTest {
        cache.saveSnapshot(
            "user-1",
            ConversationListState(conversations = listOf(IMConversation("conversation-1", summary("conversation-1")))),
        )
        cache.saveSnapshot(
            "user-2",
            ConversationListState(conversations = listOf(IMConversation("conversation-2", summary("conversation-2")))),
        )

        cache.clear("user-1")

        assertNull(cache.loadSnapshot("user-1"))
        assertEquals("conversation-2", cache.loadSnapshot("user-2")?.conversations?.first()?.id)
    }

    private fun summary(id: String) = IMConversationSummaryResponseBody(
        id = id,
        title = "General",
        memberCount = 2,
        updatedAt = "2026-05-13T00:00:00Z",
    )

    private fun message(sequence: ULong) = IMConversationMessage(
        id = "message-$sequence",
        conversationID = "conversation-1",
        clientMessageID = null,
        serverMessageID = "message-$sequence",
        senderUserID = "user-2",
        serverSequence = sequence,
        content = IMMessageContent.Text("hello"),
        direction = IMMessageDirection.Incoming,
        createdAt = "2026-05-13T00:00:00Z",
        deliveryState = IMMessageDeliveryState.Received,
    )
}
