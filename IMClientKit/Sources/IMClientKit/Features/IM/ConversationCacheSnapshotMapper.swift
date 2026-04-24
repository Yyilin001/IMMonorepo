import Foundation

struct RestoredConversationCacheState {
    let conversations: [IMConversation]
    let selectedConversationID: String?
    let detailState: ConversationDetailState
}

enum ConversationCacheSnapshotMapper {
    static func makeSnapshot(
        conversations: [IMConversation],
        selectedConversationID: String?,
        detailState: ConversationDetailState,
        lastSummaryRefreshAt: Date?,
        summarySyncToken: String? = nil,
        summaryNextCursor: String? = nil,
        hasMoreConversationSummaries: Bool = false,
        trimMessages: ([IMConversationMessage], Int) -> [IMConversationMessage]
    ) -> IMConversationCacheSnapshot {
        var cursorStates: [IMSyncCursorState] = []
        let cachedConversations = conversations.map { conversation in
            let cachedMessages = trimMessages(
                conversation.messages,
                IMConversationCacheSnapshot.cachedMessageLimit
            )
            let cachedServerSequences = cachedMessages.compactMap(\.serverSequence)
            let hasLoadedMessages = detailState.loadedConversationIDs.contains(conversation.id)
            let latestSyncedServerSequence = cachedServerSequences.max()
            let oldestLoadedServerSequence = hasLoadedMessages ? cachedServerSequences.min() : nil

            cursorStates.append(
                IMSyncCursorState(
                    conversationID: conversation.id,
                    hasLoadedMessages: hasLoadedMessages,
                    latestSyncedServerSequence: latestSyncedServerSequence,
                    oldestLoadedServerSequence: oldestLoadedServerSequence
                )
            )

            return IMCachedConversationState(
                id: conversation.id,
                title: conversation.title,
                kind: conversation.kind,
                directMessagingState: conversation.directMessagingState,
                directPeer: conversation.directPeer,
                notice: conversation.notice,
                avatarPreset: conversation.avatarPreset,
                memberCount: conversation.memberCount,
                memberUserIDs: conversation.memberUserIDs,
                messages: cachedMessages.map { message in
                    IMCachedMessageState(
                        id: message.id,
                        conversationID: message.conversationID,
                        clientMessageID: message.clientMessageID,
                        serverMessageID: message.serverMessageID,
                        senderUserID: message.senderUserID,
                        serverSequence: message.serverSequence,
                        content: message.content,
                        direction: message.direction,
                        createdAt: message.createdAt,
                        deliveryState: message.deliveryState
                    )
                },
                hasLoadedMessages: hasLoadedMessages,
                lastMessagePreviewText: conversation.lastMessagePreviewText,
                hasMoreHistory: conversation.hasMoreHistory,
                latestSyncedServerSequence: latestSyncedServerSequence,
                oldestLoadedServerSequence: oldestLoadedServerSequence,
                serverLastReadSequence: conversation.serverLastReadSequence,
                serverUnreadCount: conversation.serverUnreadCount,
                isPinned: conversation.isPinned,
                pinnedAt: conversation.pinnedAt,
                isMuted: conversation.isMuted,
                draftText: conversation.draftText,
                draftUpdatedAt: conversation.draftUpdatedAt,
                updatedAt: conversation.updatedAt
            )
        }

        return IMConversationCacheSnapshot(
            metadata: IMCacheMetadataState(
                selectedConversationID: selectedConversationID,
                lastSummaryRefreshAt: lastSummaryRefreshAt,
                summarySyncToken: summarySyncToken,
                summaryNextCursor: summaryNextCursor,
                hasMoreConversationSummaries: hasMoreConversationSummaries
            ),
            conversations: cachedConversations,
            cursors: cursorStates
        )
    }

    static func restore(
        from snapshot: IMConversationCacheSnapshot,
        restoreDeliveryState: (IMMessageDeliveryState) -> IMMessageDeliveryState
    ) -> RestoredConversationCacheState {
        let cursorsByConversationID = Dictionary(
            uniqueKeysWithValues: snapshot.cursors.map { ($0.conversationID, $0) }
        )

        let conversations = snapshot.conversations.map { cachedConversation in
            IMConversation(
                id: cachedConversation.id,
                title: cachedConversation.title,
                kind: cachedConversation.kind,
                directMessagingState: cachedConversation.directMessagingState,
                directPeer: cachedConversation.directPeer,
                notice: cachedConversation.notice,
                avatarPreset: cachedConversation.avatarPreset,
                memberCount: cachedConversation.memberCount,
                memberUserIDs: cachedConversation.memberUserIDs,
                members: [],
                messages: cachedConversation.messages.map { cachedMessage in
                    IMConversationMessage(
                        id: cachedMessage.id,
                        conversationID: cachedMessage.conversationID,
                        clientMessageID: cachedMessage.clientMessageID,
                        serverMessageID: cachedMessage.serverMessageID,
                        senderUserID: cachedMessage.senderUserID,
                        serverSequence: cachedMessage.serverSequence,
                        content: cachedMessage.content,
                        direction: cachedMessage.direction,
                        createdAt: cachedMessage.createdAt,
                        deliveryState: restoreDeliveryState(cachedMessage.deliveryState)
                    )
                },
                lastMessagePreviewText: cachedConversation.lastMessagePreviewText,
                hasMoreHistory: cachedConversation.hasMoreHistory,
                serverLastReadSequence: cachedConversation.serverLastReadSequence,
                serverUnreadCount: cachedConversation.serverUnreadCount,
                localUnreadDelta: 0,
                isPinned: cachedConversation.isPinned,
                pinnedAt: cachedConversation.pinnedAt,
                isMuted: cachedConversation.isMuted,
                draftText: cachedConversation.draftText,
                draftUpdatedAt: cachedConversation.draftUpdatedAt,
                updatedAt: cachedConversation.updatedAt
            )
        }

        var detailState = ConversationDetailState()
        detailState.loadedConversationIDs = Set(
            snapshot.cursors
                .filter(\.hasLoadedMessages)
                .map(\.conversationID)
        )
        detailState.latestSyncedServerSequences = Dictionary(
            uniqueKeysWithValues: snapshot.conversations.compactMap { conversation in
                let cursor = cursorsByConversationID[conversation.id]
                return (cursor?.latestSyncedServerSequence ?? conversation.latestSyncedServerSequence)
                    .map { (conversation.id, $0) }
            }
        )
        detailState.oldestLoadedServerSequences = Dictionary(
            uniqueKeysWithValues: snapshot.conversations.compactMap { conversation in
                let cursor = cursorsByConversationID[conversation.id]
                return (cursor?.oldestLoadedServerSequence ?? conversation.oldestLoadedServerSequence)
                    .map { (conversation.id, $0) }
            }
        )

        let selectedConversationID: String?
        if let snapshotSelectedConversationID = snapshot.selectedConversationID,
           conversations.contains(where: { $0.id == snapshotSelectedConversationID }) {
            selectedConversationID = snapshotSelectedConversationID
        } else {
            selectedConversationID = conversations.first?.id
        }

        return RestoredConversationCacheState(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            detailState: detailState
        )
    }
}
