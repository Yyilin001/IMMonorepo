import Foundation

struct RestoredConversationCacheState {
    let conversations: [IMConversation]
    let selectedConversationID: String?
    let detailState: ConversationDetailState
    let diagnostics: IMCacheRestoreDiagnostics
}

public struct IMCacheRestoreDiagnostics: Equatable, Sendable {
    public struct DroppedCanonicalMessage: Equatable, Sendable {
        public let conversationID: String
        public let messageID: String
        public let reason: String
    }

    public private(set) var droppedCanonicalMessages: [DroppedCanonicalMessage] = []
    public private(set) var droppedCanonicalMessagesDuringSnapshot: [DroppedCanonicalMessage] = []
    public private(set) var droppedTimelineNotices: [DroppedCanonicalMessage] = []
    public private(set) var droppedTimelineNoticesDuringSnapshot: [DroppedCanonicalMessage] = []

    public var droppedCanonicalMessageCount: Int {
        droppedCanonicalMessages.count + droppedCanonicalMessagesDuringSnapshot.count
    }

    public var droppedTimelineNoticeCount: Int {
        droppedTimelineNotices.count + droppedTimelineNoticesDuringSnapshot.count
    }

    mutating func recordDroppedCanonicalMessage(
        conversationID: String,
        messageID: String,
        reason: String
    ) {
        droppedCanonicalMessages.append(
            DroppedCanonicalMessage(
                conversationID: conversationID,
                messageID: messageID,
                reason: reason
            )
        )
    }

    mutating func recordDroppedCanonicalMessageDuringSnapshot(
        conversationID: String,
        messageID: String,
        reason: String
    ) {
        droppedCanonicalMessagesDuringSnapshot.append(
            DroppedCanonicalMessage(
                conversationID: conversationID,
                messageID: messageID,
                reason: reason
            )
        )
    }

    mutating func recordDroppedTimelineNotice(
        conversationID: String,
        noticeID: String,
        reason: String
    ) {
        droppedTimelineNotices.append(
            DroppedCanonicalMessage(
                conversationID: conversationID,
                messageID: noticeID,
                reason: reason
            )
        )
    }

    mutating func recordDroppedTimelineNoticeDuringSnapshot(
        conversationID: String,
        noticeID: String,
        reason: String
    ) {
        droppedTimelineNoticesDuringSnapshot.append(
            DroppedCanonicalMessage(
                conversationID: conversationID,
                messageID: noticeID,
                reason: reason
            )
        )
    }

    mutating func merge(_ other: IMCacheRestoreDiagnostics) {
        droppedCanonicalMessages.append(contentsOf: other.droppedCanonicalMessages)
        droppedCanonicalMessagesDuringSnapshot.append(contentsOf: other.droppedCanonicalMessagesDuringSnapshot)
        droppedTimelineNotices.append(contentsOf: other.droppedTimelineNotices)
        droppedTimelineNoticesDuringSnapshot.append(contentsOf: other.droppedTimelineNoticesDuringSnapshot)
    }
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
        transferSnapshots: [IMTransferSnapshot] = [],
        domainEventState: IMDomainEventCacheState = IMDomainEventCacheState(),
        trimMessages: ([IMConversationMessage], Int) -> [IMConversationMessage]
    ) -> IMConversationCacheSnapshot {
        var cursorStates: [IMSyncCursorState] = []
        var diagnostics = IMCacheRestoreDiagnostics()
        let cachedConversations = conversations.map { conversation in
            let cachedMessages = trimMessages(
                conversation.messages,
                IMConversationCacheSnapshot.cachedMessageLimit
            )
            let hasLoadedMessages = detailState.loadedConversationIDs.contains(conversation.id)
            let cachedTimelineSequences = cachedMessages.map(\.timelineSequence)
                + conversation.notices.map(\.timelineSequence)
            let latestLoadedTimelineSequence = cachedTimelineSequences.max()
            let oldestLoadedTimelineSequence = hasLoadedMessages ? cachedTimelineSequences.min() : nil

            cursorStates.append(
                IMSyncCursorState(
                    conversationID: conversation.id,
                    hasLoadedMessages: hasLoadedMessages,
                    latestLoadedTimelineSequence: latestLoadedTimelineSequence,
                    oldestLoadedTimelineSequence: oldestLoadedTimelineSequence
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
                messages: cachedMessages.compactMap { message in
                    do {
                        return try IMCachedMessageState(
                            id: message.id,
                            conversationID: message.conversationID,
                            clientMessageID: message.clientMessageID,
                            serverMessageID: message.serverMessageID,
                            senderUserID: message.senderUserID,
                            serverSequence: message.serverSequence,
                            timelineSequence: message.timelineSequence,
                            content: message.content,
                            derivedState: message.derivedState,
                            direction: message.direction,
                            createdAt: message.createdAt,
                            deliveryState: message.deliveryState,
                            transferTaskID: message.resolvedTransferTaskID,
                            localTransferState: message.localTransferState,
                            localDownloadState: message.localDownloadState
                        )
                    } catch {
                        diagnostics.recordDroppedCanonicalMessageDuringSnapshot(
                            conversationID: message.conversationID,
                            messageID: message.serverMessageID,
                            reason: String(describing: error)
                        )
                        return nil
                    }
                },
                pendingMessages: conversation.pendingMessages.map { message in
                    IMCachedPendingMessageState(
                        localMessageID: message.localMessageID,
                        clientMessageID: message.clientMessageID,
                        serverMessageID: message.serverMessageID,
                        conversationID: message.conversationID,
                        senderUserID: message.senderUserID,
                        content: message.content,
                        createdAt: message.createdAt,
                        deliveryState: message.deliveryState,
                        transferTaskID: message.resolvedTransferTaskID,
                        localTransferState: message.localTransferState,
                        localDownloadState: message.localDownloadState
                    )
                },
                notices: conversation.notices.compactMap { notice in
                    do {
                        return try IMCachedTimelineNoticeState(
                            id: notice.id,
                            conversationID: notice.conversationID,
                            timelineSequence: notice.timelineSequence,
                            eventType: notice.eventType,
                            actorUserID: notice.actorUserID,
                            targetUserIDs: notice.targetUserIDs,
                            noticeKind: notice.noticeKind,
                            params: notice.params,
                            fallbackText: notice.fallbackText,
                            createdAt: notice.createdAt
                        )
                    } catch {
                        diagnostics.recordDroppedTimelineNoticeDuringSnapshot(
                            conversationID: notice.conversationID,
                            noticeID: notice.id,
                            reason: String(describing: error)
                        )
                        return nil
                    }
                },
                hasLoadedMessages: hasLoadedMessages,
                lastMessagePreviewText: conversation.lastMessagePreviewText,
                hasMoreHistory: conversation.hasMoreHistory,
                latestLoadedTimelineSequence: latestLoadedTimelineSequence,
                oldestLoadedTimelineSequence: oldestLoadedTimelineSequence,
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

        let fullRefreshConversationIDs = Set(domainEventState.fullRefreshConversationIDs)
            .union(diagnostics.droppedCanonicalMessagesDuringSnapshot.map(\.conversationID))
            .union(diagnostics.droppedTimelineNoticesDuringSnapshot.map(\.conversationID))

        return IMConversationCacheSnapshot(
            metadata: IMCacheMetadataState(
                selectedConversationID: selectedConversationID,
                lastSummaryRefreshAt: lastSummaryRefreshAt,
                summarySyncToken: summarySyncToken,
                summaryNextCursor: summaryNextCursor,
                hasMoreConversationSummaries: hasMoreConversationSummaries
            ),
            conversations: cachedConversations,
            cursors: cursorStates,
            transferSnapshots: transferSnapshots,
            domainEventState: IMDomainEventCacheState(
                cursor: domainEventState.cursor,
                appliedEventIDs: domainEventState.appliedEventIDs,
                ownerAggregateHighWatermarks: domainEventState.ownerAggregateHighWatermarks,
                deferredEvents: domainEventState.deferredEvents,
                fullRefreshConversationIDs: fullRefreshConversationIDs.sorted()
            ),
            diagnostics: diagnostics
        )
    }

    static func restore(
        from snapshot: IMConversationCacheSnapshot,
        restoreDeliveryState: (IMMessageDeliveryState) -> IMMessageDeliveryState
    ) -> RestoredConversationCacheState {
        let cursorsByConversationID = Dictionary(
            uniqueKeysWithValues: snapshot.cursors.map { ($0.conversationID, $0) }
        )

        var diagnostics = snapshot.diagnostics
        let conversations = snapshot.conversations.map { cachedConversation in
            let restoredMessages = cachedConversation.messages.compactMap { cachedMessage -> IMConversationMessage? in
                do {
                    return try IMConversationMessage(
                        id: cachedMessage.id,
                        conversationID: cachedMessage.conversationID,
                        clientMessageID: cachedMessage.clientMessageID,
                        serverMessageID: cachedMessage.serverMessageID,
                        senderUserID: cachedMessage.senderUserID,
                        serverSequence: cachedMessage.serverSequence,
                        timelineSequence: cachedMessage.timelineSequence,
                        content: cachedMessage.content,
                        derivedState: cachedMessage.derivedState,
                        direction: cachedMessage.direction,
                        createdAt: cachedMessage.createdAt,
                        deliveryState: restoreDeliveryState(cachedMessage.deliveryState),
                        transferTaskID: cachedMessage.transferTaskID,
                        localTransferState: cachedMessage.localTransferState,
                        localDownloadState: cachedMessage.localDownloadState
                    )
                } catch {
                    diagnostics.recordDroppedCanonicalMessage(
                        conversationID: cachedMessage.conversationID,
                        messageID: cachedMessage.serverMessageID,
                        reason: String(describing: error)
                    )
                    return nil
                }
            }
            return IMConversation(
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
                messages: restoredMessages,
                pendingMessages: cachedConversation.pendingMessages.map { cachedMessage in
                    IMPendingConversationMessage(
                        localMessageID: cachedMessage.localMessageID,
                        clientMessageID: cachedMessage.clientMessageID,
                        serverMessageID: cachedMessage.serverMessageID,
                        conversationID: cachedMessage.conversationID,
                        senderUserID: cachedMessage.senderUserID,
                        content: cachedMessage.content,
                        createdAt: cachedMessage.createdAt,
                        deliveryState: restoreDeliveryState(cachedMessage.deliveryState),
                        transferTaskID: cachedMessage.transferTaskID,
                        localTransferState: cachedMessage.localTransferState,
                        localDownloadState: cachedMessage.localDownloadState
                    )
                },
                notices: cachedConversation.notices.compactMap { notice in
                    do {
                        return try IMTimelineNotice(
                            id: notice.id,
                            conversationID: notice.conversationID,
                            timelineSequence: notice.timelineSequence,
                            eventType: notice.eventType,
                            actorUserID: notice.actorUserID,
                            targetUserIDs: notice.targetUserIDs,
                            noticeKind: notice.noticeKind,
                            params: notice.params,
                            fallbackText: notice.fallbackText,
                            createdAt: notice.createdAt
                        )
                    } catch {
                        diagnostics.recordDroppedTimelineNotice(
                            conversationID: notice.conversationID,
                            noticeID: notice.id,
                            reason: String(describing: error)
                        )
                        return nil
                    }
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
        let conversationsByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        detailState.loadedConversationIDs = Set(
            snapshot.cursors.compactMap { cursor in
                guard cursor.hasLoadedMessages,
                      let conversation = conversationsByID[cursor.conversationID],
                      shouldRestoreLoadedCursor(for: conversation)
                else {
                    return nil
                }
                return cursor.conversationID
            }
        )
        detailState.latestLoadedTimelineSequences = Dictionary(
            uniqueKeysWithValues: snapshot.conversations.compactMap { conversation in
                let cursor = cursorsByConversationID[conversation.id]
                return (cursor?.latestLoadedTimelineSequence ?? conversation.latestLoadedTimelineSequence)
                    .map { (conversation.id, $0) }
            }
        )
        detailState.oldestLoadedTimelineSequences = Dictionary(
            uniqueKeysWithValues: snapshot.conversations.compactMap { conversation in
                let cursor = cursorsByConversationID[conversation.id]
                return (cursor?.oldestLoadedTimelineSequence ?? conversation.oldestLoadedTimelineSequence)
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
            detailState: detailState,
            diagnostics: diagnostics
        )
    }

    private static func shouldRestoreLoadedCursor(for conversation: IMConversation) -> Bool {
        guard conversation.messages.isEmpty,
              conversation.notices.isEmpty,
              conversation.pendingMessages.isEmpty
        else {
            return true
        }

        if conversation.unreadCount > 0 {
            return false
        }

        let preview = conversation.lastMessagePreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty || preview == "暂无消息"
    }
}
