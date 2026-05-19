package com.xmtx.imclientkit.persistence.imcache

import android.content.Context
import com.xmtx.imclientkit.features.im.ConversationListState
import com.xmtx.imclientkit.features.im.IMConversation
import com.xmtx.imclientkit.features.im.IMConversationCaching
import com.xmtx.imclientkit.features.im.IMConversationMessage
import com.xmtx.imclientkit.features.im.IMConversationSummaryResponseBody
import com.xmtx.imclientkit.features.im.IMMessageContent
import com.xmtx.imclientkit.features.im.IMMessageDirection
import com.xmtx.imclientkit.features.im.IMMessageDeliveryState
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class RoomIMConversationCache private constructor(
    database: IMCacheDatabase,
    private val json: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    },
) : IMConversationCaching {
    private val dao = database.imConversationCacheDao()

    override suspend fun loadSnapshot(userID: String): ConversationListState? {
        val metadata = dao.metadata(userID) ?: return null
        val conversationEntities = dao.conversations(userID)
        val cursorEntities = dao.cursors(userID)
        val conversations = conversationEntities.map { entity ->
            val summary = json.decodeFromString<IMConversationSummaryResponseBody>(entity.summaryJson)
            val messages = dao.messages(userID, entity.conversationID).map { it.toDomain(json) }
            IMCachedConversationState(
                conversation = IMConversation(
                    id = entity.conversationID,
                    summary = summary,
                    messages = messages,
                    serverLastReadSequence = entity.serverLastReadSequence.toULong(),
                    serverUnreadCount = entity.serverUnreadCount,
                    localUnreadDelta = entity.localUnreadDelta,
                ),
                messages = messages,
            )
        }
        return IMConversationCacheSnapshotMapper.restore(
            IMConversationCacheSnapshot(
                metadata = IMCacheMetadataState(
                    selectedConversationID = metadata.selectedConversationID,
                    lastSummaryRefreshAt = metadata.lastSummaryRefreshAt,
                    summarySyncToken = metadata.summarySyncToken,
                    summaryNextCursor = metadata.summaryNextCursor,
                    hasMoreConversationSummaries = metadata.hasMoreConversationSummaries,
                ),
                conversations = conversations,
                cursors = cursorEntities.map { it.toDomain() },
            ),
        )
    }

    override suspend fun saveSnapshot(userID: String, snapshot: ConversationListState) {
        val cacheSnapshot = IMConversationCacheSnapshotMapper.makeSnapshot(snapshot)
        val conversationEntities = cacheSnapshot.conversations.map { cached ->
            cached.conversation.toEntity(userID, json)
        }
        val messageEntities = cacheSnapshot.conversations.flatMap { cached ->
            cached.messages.map { message -> message.toEntity(userID, json) }
        }
        dao.replaceSnapshot(
            ownerUserID = userID,
            metadata = cacheSnapshot.metadata.toEntity(userID),
            conversations = conversationEntities,
            messages = messageEntities,
            cursors = cacheSnapshot.cursors.map { it.toEntity(userID) },
        )
    }

    override suspend fun clear(userID: String) {
        dao.clear(userID)
    }

    companion object {
        fun create(database: IMCacheDatabase): RoomIMConversationCache =
            RoomIMConversationCache(database)

        fun create(context: Context): RoomIMConversationCache =
            RoomIMConversationCache(IMCacheDatabase.create(context))
    }
}

private fun IMCacheMetadataState.toEntity(ownerUserID: String): IMCacheMetadataEntity =
    IMCacheMetadataEntity(
        ownerUserID = ownerUserID,
        selectedConversationID = selectedConversationID,
        lastSummaryRefreshAt = lastSummaryRefreshAt,
        summarySyncToken = summarySyncToken,
        summaryNextCursor = summaryNextCursor,
        hasMoreConversationSummaries = hasMoreConversationSummaries,
    )

private fun IMSyncCursorState.toEntity(ownerUserID: String): IMSyncCursorEntity =
    IMSyncCursorEntity(
        ownerUserID = ownerUserID,
        conversationID = conversationID,
        hasLoadedMessages = hasLoadedMessages,
        latestSyncedServerSequence = latestSyncedServerSequence?.toLong(),
        oldestLoadedServerSequence = oldestLoadedServerSequence?.toLong(),
        pendingReadSequence = pendingReadSequence?.toLong(),
    )

private fun IMSyncCursorEntity.toDomain(): IMSyncCursorState =
    IMSyncCursorState(
        conversationID = conversationID,
        hasLoadedMessages = hasLoadedMessages,
        latestSyncedServerSequence = latestSyncedServerSequence?.toULong(),
        oldestLoadedServerSequence = oldestLoadedServerSequence?.toULong(),
        pendingReadSequence = pendingReadSequence?.toULong(),
    )

private fun IMConversation.toEntity(ownerUserID: String, json: Json): IMCachedConversationEntity =
    IMCachedConversationEntity(
        ownerUserID = ownerUserID,
        conversationID = id,
        summaryJson = json.encodeToString(summary),
        serverLastReadSequence = serverLastReadSequence.toLong(),
        serverUnreadCount = serverUnreadCount,
        localUnreadDelta = localUnreadDelta,
        updatedAt = summary.updatedAt,
    )

private fun IMConversationMessage.toEntity(ownerUserID: String, json: Json): IMCachedMessageEntity =
    IMCachedMessageEntity(
        ownerUserID = ownerUserID,
        conversationID = conversationID,
        messageID = id,
        clientMessageID = clientMessageID,
        serverMessageID = serverMessageID,
        senderUserID = senderUserID,
        serverSequence = serverSequence?.toLong(),
        contentJson = json.encodeToString<IMMessageContent>(content),
        derivedStateJson = json.encodeToString(derivedState),
        direction = direction.name,
        createdAt = createdAt,
        deliveryState = deliveryState.name,
    )

private fun IMCachedMessageEntity.toDomain(json: Json): IMConversationMessage =
    IMConversationMessage(
        id = messageID,
        conversationID = conversationID,
        clientMessageID = clientMessageID,
        serverMessageID = serverMessageID,
        senderUserID = senderUserID,
        serverSequence = serverSequence?.toULong(),
        content = json.decodeFromString<IMMessageContent>(contentJson),
        derivedState = json.decodeFromString(derivedStateJson),
        direction = IMMessageDirection.valueOf(direction),
        createdAt = createdAt,
        deliveryState = IMMessageDeliveryState.valueOf(deliveryState),
    )
