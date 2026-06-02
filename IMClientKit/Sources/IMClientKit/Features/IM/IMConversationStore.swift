import Foundation
import Observation
import OSLog

// Main-actor client read model for IM state. Runtime controllers feed this store
// with HTTP/TCP/cache events; SwiftUI should observe the merged result instead
// of reimplementing sync, read, outgoing, or stream merge rules.
public struct IMActiveMessageStreamTarget: Equatable, Hashable, Sendable {
    public let conversationID: String
    public let messageID: String
    public let streamID: String

    public init(conversationID: String, messageID: String, streamID: String) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.streamID = streamID
    }
}

struct IMOwnerAggregateKey: Hashable, Sendable {
    let aggregateType: String
    let aggregateID: String
}

@MainActor
@Observable
public final class IMConversationStore {
    public internal(set) var conversations: [IMConversation] = []
    public internal(set) var selectedConversationID: String?
    public internal(set) var statusMessage: String?
    public internal(set) var isLoadingConversations = false
    public internal(set) var conversationSummaryNextCursor: String?
    public internal(set) var hasMoreConversationSummaries = false
    public internal(set) var isLoadingMoreConversationSummaries = false
    public internal(set) var isLoadingMembers = false
    public internal(set) var memberPageStates: [String: IMConversationMemberPageState] = [:]
    public internal(set) var receiptSummaries: [String: IMConversationReceiptSummaryResponseBody] = [:]
    public internal(set) var isLoadingMessages = false
    public internal(set) var searchText = ""
    public internal(set) var replyJumpConversationID: String?
    public internal(set) var replyJumpTargetMessageID: String?
    public internal(set) var replyJumpMatchedMessageID: String?
    public internal(set) var replyJumpState: IMReplyJumpState = .idle
    public internal(set) var conversationMutationGeneration: UInt64 = 0

    let listReadModel = ConversationListReadModel()
    private let conversationListStore = ConversationListStore()
    var detailState = ConversationDetailState()
    var outgoingQueueState = OutgoingQueueState()
    var conversationSearchState = ConversationSearchState()
    private let messageTimelineState = MessageTimelineState()
    private let conversationTimelineStore = ConversationTimelineStore()
    private let messageDerivedStateReducer = MessageDerivedStateReducer()
    private let domainEventProjectionReducer = DomainEventProjectionReducer()
    private let deferredDomainEventQueue = DeferredDomainEventQueue()
    private var pendingStreamSnapshotTargets: Set<IMActiveMessageStreamTarget> = []
    private var processedDomainEventIDs: Set<UUID> = []
    private var processedDomainEventIDOrder: [UUID] = []
    private var deferredDomainEventsByMissingKey: [IMDeferredDomainEventMissingKey: [IMDeferredDomainEventState]] = [:]
    private var domainEventFullRefreshConversationIDs: Set<String> = []
    private var ownerAggregateHighWatermarks: [IMOwnerAggregateKey: UInt64] = [:]
    private var domainEventCursor: UInt64 = 0
    public private(set) var domainEventDebugMetrics = IMDomainEventDebugMetrics()

    public init() { }

    public func openConversation(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            statusMessage = "当前没有可用会话。"
            return
        }

        _ = ensureConversationIndex(for: trimmedID)
        selectedConversationID = trimmedID
        statusMessage = nil
        sortConversations()
    }

    public func replaceConversationSummaries(_ responses: [IMConversationSummaryResponseBody]) {
        applyConversationSummaryContents(responses)
    }

    public func applyConversationSummaryPage(_ responses: [IMConversationSummaryResponseBody]) {
        upsertConversationSummaryContents(responses, conversations: &conversations)
        statusMessage = nil
        sortConversations()
    }

    public func applyConversationSummaryChanges(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID]
    ) {
        conversationListStore.applySummaryChanges(
            upserts: upserts,
            removedConversationIDs: removedConversationIDs,
            conversations: &conversations,
            selectedConversationID: &selectedConversationID
        ) { responses, conversations in
            upsertConversationSummaryContents(responses, conversations: &conversations)
        }
        let remainingConversationIDs = Set(conversations.map(\.id))
        for removedConversationID in removedConversationIDs.map(\.uuidString)
            where !remainingConversationIDs.contains(removedConversationID) {
            detailState.removeConversation(id: removedConversationID)
        }
        syncReplyJumpState()
        statusMessage = nil
        sortConversations()
    }

    public func replaceConversationSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) {
        let pagination = conversationListStore.replaceSummaryWindow(
            responses,
            conversations: &conversations,
            selectedConversationID: &selectedConversationID,
            nextCursor: nextCursor,
            hasMore: hasMore
        ) { response, existing in
            conversationSummary(from: response, existing: existing)
        }

        conversationSummaryNextCursor = pagination.nextCursor
        hasMoreConversationSummaries = pagination.hasMore
        isLoadingMoreConversationSummaries = false
        statusMessage = nil
        sortConversations()
    }

    public func appendConversationSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) {
        let pagination = conversationListStore.appendSummaryWindow(
            responses,
            conversations: &conversations,
            nextCursor: nextCursor,
            hasMore: hasMore
        ) { responses, conversations in
            upsertConversationSummaryContents(responses, conversations: &conversations)
        }

        conversationSummaryNextCursor = pagination.nextCursor
        hasMoreConversationSummaries = pagination.hasMore
        isLoadingMoreConversationSummaries = false
        statusMessage = nil
        sortConversations()
    }

    public func removeConversationSummaries(notIn conversationIDs: Set<String>) {
        let trimmedIDs = Set(
            conversationIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        conversations.removeAll { !trimmedIDs.contains($0.id) }

        if let selectedConversationID, !trimmedIDs.contains(selectedConversationID) {
            self.selectedConversationID = conversations.first?.id
        }
    }

    public func applyConversationSummaryContents(_ responses: [IMConversationSummaryResponseBody]) {
        let existingByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let serverIDs = Set(responses.map { $0.id.uuidString })
        let previousSelectedConversationID = selectedConversationID

        var merged = responses.map { response in
            let conversationID = response.id.uuidString
            let existing = existingByID[conversationID]
            let conversationKind = IMConversationKind(rawValue: response.kind) ?? .group
            let directPeer = directPeer(from: response, conversationKind: conversationKind)
            let previewText = messageDerivedStateReducer.mergedSummaryPreviewText(
                existing: existing,
                responseLastMessage: response.lastMessage
            )

            return IMConversation(
                id: conversationID,
                title: normalizedTitle(
                    response.title,
                    conversationID: conversationID,
                    conversationKind: conversationKind,
                    directPeer: directPeer
                ),
                kind: conversationKind,
                directMessagingState: directMessagingState(
                    from: response.directMessagingState,
                    conversationKind: conversationKind
                ),
                directPeer: directPeer,
                notice: response.notice,
                avatarPreset: response.avatarPreset,
                muteAll: response.muteAll,
                memberCount: response.memberCount,
                memberUserIDs: response.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
                members: existing?.members ?? [],
                messages: existing?.messages ?? [],
                lastMessagePreviewText: previewText,
                hasMoreHistory: existing?.hasMoreHistory ?? false,
                serverLastReadSequence: UInt64(response.lastReadSequence),
                serverUnreadCount: response.unreadCount,
                localUnreadDelta: existing?.localUnreadDelta ?? 0,
                isPinned: response.isPinned,
                pinnedAt: response.pinnedAt,
                isMuted: response.isMuted,
                draftText: existing?.draftText ?? "",
                draftUpdatedAt: existing?.draftUpdatedAt,
                updatedAt: response.updatedAt
            )
        }

        merged.append(contentsOf: conversations.filter { !serverIDs.contains($0.id) })
        conversations = merged

        if let previousSelectedConversationID,
           conversations.contains(where: { $0.id == previousSelectedConversationID }) {
            selectedConversationID = previousSelectedConversationID
        } else {
            selectedConversationID = conversations.first?.id
        }

        statusMessage = nil
        sortConversations()
    }

    public func applyConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        upsertConversationSummaryContent(response)
    }

    public func removeConversation(id: String) {
        let previousConversationIDs = Set(conversations.map(\.id))
        conversationListStore.removeConversation(
            id: id,
            conversations: &conversations,
            selectedConversationID: &selectedConversationID
        )
        let removedConversationIDs = previousConversationIDs.subtracting(Set(conversations.map(\.id)))
        for removedConversationID in removedConversationIDs {
            detailState.removeConversation(id: removedConversationID)
        }
        syncReplyJumpState()
        sortConversations()
    }

    public func markConversationRead(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedID })
        else {
            return
        }

        if let latestLoadedSequence = latestLoadedMessageSequence(for: trimmedID) {
            conversations[index].serverLastReadSequence = latestLoadedSequence
        }
        resetUnreadState(for: index)
    }

    public func markConversationUnread(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedID })
        else {
            return
        }

        if conversations[index].unreadCount == 0 {
            conversations[index].localUnreadDelta = 1
        }
    }

    public func applyServerSummaryReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        let hasLatestLoadedServerSequence = latestLoadedMessageSequence(for: conversationID) != nil
        conversationListStore.applyServerSummaryReadState(
            lastReadSequence: lastReadSequence,
            unreadCount: unreadCount,
            for: conversationID,
            conversations: &conversations
        ) { conversationID, previousLastRead, previousUnread, previousDelta, updatedLastRead, updatedUnread in
            reconciledLocalUnreadDelta(
                for: conversationID,
                previousServerLastReadSequence: previousLastRead,
                previousServerUnreadCount: previousUnread,
                previousLocalUnreadDelta: previousDelta,
                updatedServerLastReadSequence: updatedLastRead,
                updatedServerUnreadCount: updatedUnread,
                hasLatestLoadedServerSequence: hasLatestLoadedServerSequence
            )
        }
    }

    public func removeMessages(ids messageIDs: Set<String>, from conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              !messageIDs.isEmpty
        else {
            return
        }
        conversations[index].messages.removeAll { message in
            messageIDs.contains(message.id) ||
                messageIDs.contains(message.serverMessageID)
        }
        conversations[index].lastMessagePreviewText = messageTimelineState.latestPreviewText(
            in: conversations[index].messages,
            fallback: ""
        )
        conversations[index].updatedAt = messageTimelineState.latestUpdatedAt(
            in: conversations[index].messages,
            fallback: conversations[index].updatedAt
        )
    }

    public func clearMessages(in conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }

        conversations[index].messages.removeAll()
        conversations[index].lastMessagePreviewText = ""
        conversations[index].serverUnreadCount = 0
        conversations[index].localUnreadDelta = 0
    }

    public func applyServerSummaryReadStates(_ responses: [IMConversationSummaryResponseBody]) {
        let conversationIndicesByID = Dictionary(
            uniqueKeysWithValues: conversations.indices.map { index in
                (conversations[index].id, index)
            }
        )
        let localLatestSequences = latestLoadedMessageSequencesByConversationID()

        for response in responses {
            let conversationID = response.id.uuidString
            guard let index = conversationIndicesByID[conversationID] else {
                continue
            }
            applyServerSummaryReadState(
                lastReadSequence: UInt64(response.lastReadSequence),
                unreadCount: response.unreadCount,
                for: conversationID,
                at: index,
                hasLatestLoadedServerSequence: localLatestSequences[conversationID] != nil
            )
        }
    }

    public func applyServerSummaryReadState(_ response: IMConversationSummaryResponseBody) {
        applyServerSummaryReadState(
            lastReadSequence: UInt64(response.lastReadSequence),
            unreadCount: response.unreadCount,
            for: response.id.uuidString
        )
    }

    public func applyServerExplicitReadResponse(_ response: IMConversationReadResponseBody) {
        applyServerReadState(
            lastReadSequence: UInt64(response.lastReadSequence),
            unreadCount: response.unreadCount,
            for: response.conversationID.uuidString
        )
    }

    public func applyServerReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverLastReadSequence = lastReadSequence
        conversations[index].serverUnreadCount = max(0, unreadCount)
        conversations[index].localUnreadDelta = 0
    }

    private func applyServerSummaryReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String,
        at index: Int,
        hasLatestLoadedServerSequence: Bool
    ) {
        guard conversations.indices.contains(index),
              conversations[index].id == conversationID
        else {
            return
        }

        let previousServerLastReadSequence = conversations[index].serverLastReadSequence
        let previousServerUnreadCount = conversations[index].serverUnreadCount
        let previousLocalUnreadDelta = conversations[index].localUnreadDelta
        let normalizedUnreadCount = max(0, unreadCount)
        conversations[index].serverLastReadSequence = lastReadSequence
        conversations[index].serverUnreadCount = normalizedUnreadCount
        conversations[index].localUnreadDelta = reconciledLocalUnreadDelta(
            for: conversationID,
            previousServerLastReadSequence: previousServerLastReadSequence,
            previousServerUnreadCount: previousServerUnreadCount,
            previousLocalUnreadDelta: previousLocalUnreadDelta,
            updatedServerLastReadSequence: lastReadSequence,
            updatedServerUnreadCount: normalizedUnreadCount,
            hasLatestLoadedServerSequence: hasLatestLoadedServerSequence
        )
    }

    public func applyRealtimeUnreadIncrement(for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let unreadBefore = conversations.first(where: { $0.id == trimmedConversationID })?.unreadCount ?? -1
        let selectedBefore = selectedConversationID ?? "nil"
        conversationListStore.applyRealtimeUnreadIncrement(
            for: conversationID,
            conversations: &conversations,
            selectedConversationID: selectedConversationID
        ) { index, conversations in
            resetUnreadState(for: index, conversations: &conversations)
        }
        let unreadAfter = conversations.first(where: { $0.id == trimmedConversationID })?.unreadCount ?? -1
        IMClientLog.conversationStore.debug(
            "Realtime unread increment conversationID=\(trimmedConversationID, privacy: .public) selectedBefore=\(selectedBefore, privacy: .public) unreadBefore=\(unreadBefore, privacy: .public) unreadAfter=\(unreadAfter, privacy: .public)"
        )
    }

    public func applyServerUnreadCount(_ unreadCount: Int, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverUnreadCount = max(0, unreadCount)
    }

    public func applyDomainEvent(
        _ payload: IMTCPChatDomainEventPayload,
        currentUserID: UUID
    ) -> IMConversationEventApplyOutcome {
        var dependencies = domainEventDependencySnapshot()
        return applyDomainEvent(
            payload,
            currentUserID: currentUserID,
            dependencies: &dependencies
        )
    }

    private func applyDomainEvent(
        _ payload: IMTCPChatDomainEventPayload,
        currentUserID: UUID,
        dependencies: inout DomainEventProjectionReducer.DependencySnapshot
    ) -> IMConversationEventApplyOutcome {
        let operation = domainEventProjectionReducer.reduce(
            event: payload,
            currentUserID: currentUserID,
            dependencies: dependencies
        )
        let operationName = domainEventOperationDebugName(operation)
        IMClientLog.conversationStore.debug(
            "Domain event reduced eventID=\(payload.eventID.uuidString, privacy: .public) eventType=\(payload.eventType.rawValue, privacy: .public) aggregateID=\(payload.aggregateID.uuidString, privacy: .public) aggregateSequence=\(payload.aggregateSequence, privacy: .public) ownerCursor=\(payload.ownerCursor ?? 0, privacy: .public) ownerAggregateSequence=\(payload.ownerAggregateSequence ?? 0, privacy: .public) operation=\(operationName, privacy: .public) summaryID=\(payload.conversation?.id.uuidString ?? "nil", privacy: .public) summaryPreview=\(payload.conversation?.lastMessage?.previewText ?? "nil", privacy: .public) summaryUnread=\(payload.conversation?.unreadCount ?? -1, privacy: .public)"
        )

        switch operation {
        case .ignoreDuplicate:
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)
        case .requestCatchUp:
            domainEventDebugMetrics.missingRequiredNotice += 1
            domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldFetchDomainEvents: true,
                didConsumeEvent: false
            )
        case .rejectInvalid:
            domainEventDebugMetrics.invalidDomainEventMetadata += 1
            domainEventDebugMetrics.invalidProjectionDTOs += 1
            domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldFetchDomainEvents: true,
                didConsumeEvent: false
            )
        case .deferEvent(let reason, let missingKey, let conversationID):
            IMClientLog.conversationStore.debug(
                "Domain event deferred eventID=\(payload.eventID.uuidString, privacy: .public) eventType=\(payload.eventType.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) missingKey=\(String(describing: missingKey), privacy: .public) conversationID=\(conversationID ?? "nil", privacy: .public)"
            )
            let deferResult = deferDomainEvent(payload, missingKey: missingKey, conversationID: conversationID)
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldFetchDomainEvents: true,
                didConsumeEvent: deferResult.didConsumeEvent
            )
        case .applyMessageCreated(let message, let clientMessageID, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applyCreatedMessage(
                message,
                clientMessageID: clientMessageID,
            )
            applySummaryIfPresent(summary)
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .applyMessageMutation(_, let message, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            if let message {
                applyUpdatedMessage(message)
            }
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .applyVisibility(let conversationID, let messageIDs, let message, let visibilityAction, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            var eventMessageIDs = Set(messageIDs.map(\.uuidString))
            if let message {
                eventMessageIDs.insert(message.serverMessageID)
            }
            if visibilityAction == .messageHidden, !eventMessageIDs.isEmpty {
                removeMessages(ids: eventMessageIDs, from: conversationID)
            }
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .applyMessageFavorite(_, _, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            statusMessage = nil
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .applyMessageStream(let stream, let message, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            applyMessageStreamEvent(stream: stream, message: message)
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .applyConversationChange(let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .removeConversation(let conversationID, let notice):
            if let notice {
                upsertTimelineNotice(notice)
            }
            removeConversation(id: conversationID)
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .applyConversationVisibility(let conversationID, let visibilityAction, let messageIDs, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            switch visibilityAction {
            case .conversationCleared:
                applySummaryIfPresent(summary)
                clearMessages(in: conversationID)
            case .conversationDeleted:
                removeConversation(id: conversationID)
            case .messageHidden:
                removeMessages(ids: Set(messageIDs.map(\.uuidString)), from: conversationID)
            }
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .applyMemberChange(let conversationID, _, let notice, let summary):
            let selectedConversationIDBeforeApply = selectedConversationID
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil
            )

        case .applyContactChange(let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            recordProcessedDomainEvent(payload.eventID)
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)
        }
    }

    public func applyDomainEvents(
        _ envelopes: [SessionClient.IMDomainEventDeliveryEnvelope],
        nextCursor: UInt64,
        currentUserID: UUID
    ) -> IMConversationEventApplyOutcome {
        var shouldReloadMembersForConversationID: String?
        var shouldFetchDomainEvents = false
        var lastConsumedCursor = domainEventCursor
        var dependencies = domainEventDependencySnapshot()
        for envelope in envelopes {
            guard envelope.cursor == lastConsumedCursor + 1 else {
                domainEventDebugMetrics.catchUpCursorGap += 1
                domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
                shouldFetchDomainEvents = true
                break
            }
            let outcome = applyDomainEvent(
                envelope.payload,
                currentUserID: currentUserID,
                dependencies: &dependencies
            )
            shouldReloadMembersForConversationID = outcome.shouldReloadMembersForConversationID
                ?? shouldReloadMembersForConversationID
            shouldFetchDomainEvents = shouldFetchDomainEvents || outcome.shouldFetchDomainEvents
            guard outcome.didConsumeEvent else {
                domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
                break
            }
            lastConsumedCursor = envelope.cursor
        }
        domainEventCursor = lastConsumedCursor
        replayDeferredDomainEvents(currentUserID: currentUserID)
        return IMConversationEventApplyOutcome(
            shouldReloadMembersForConversationID: shouldReloadMembersForConversationID,
            shouldFetchDomainEvents: shouldFetchDomainEvents
        )
    }

    public var domainEventSyncCursor: UInt64 {
        domainEventCursor
    }

    public var healthSnapshot: IMConversationHealthSnapshot {
        IMConversationHealthSnapshot(
            domainEventCursor: domainEventCursor,
            deferredDomainEventCount: deferredDomainEventsForSnapshot().count,
            fullRefreshConversationCount: domainEventFullRefreshConversationIDs.count,
            domainEventMetrics: domainEventDebugMetrics
        )
    }

    private func domainEventDependencySnapshot() -> DomainEventProjectionReducer.DependencySnapshot {
        var existingMessageKeys = Set<DomainEventProjectionReducer.MessageKey>()
        for conversation in conversations {
            for message in conversation.messages {
                existingMessageKeys.formUnion(messageKeys(for: message))
            }
        }
        return DomainEventProjectionReducer.DependencySnapshot(
            processedEventIDs: processedDomainEventIDs,
            ownerAggregateHighWatermarks: ownerAggregateHighWatermarks,
            existingMessageKeys: existingMessageKeys
        )
    }

    private func updateDomainEventDependencySnapshot(
        _ dependencies: inout DomainEventProjectionReducer.DependencySnapshot,
        afterConsuming payload: IMTCPChatDomainEventPayload,
        operation: DomainEventProjectionReducer.Operation
    ) {
        dependencies.processedEventIDs.insert(payload.eventID)
        if let ownerAggregateSequence = payload.ownerAggregateSequence,
           ownerAggregateSequence > 0 {
            let key = IMOwnerAggregateKey(
                aggregateType: payload.aggregateType,
                aggregateID: payload.aggregateID.uuidString
            )
            dependencies.ownerAggregateHighWatermarks[key] = max(
                dependencies.ownerAggregateHighWatermarks[key] ?? 0,
                ownerAggregateSequence
            )
        }

        switch operation {
        case .applyMessageCreated(let message, _, _, _):
            dependencies.existingMessageKeys.formUnion(messageKeys(for: message))
        case .applyMessageMutation(_, let message, _, _):
            if let message {
                dependencies.existingMessageKeys.formUnion(messageKeys(for: message))
            }
        case .applyVisibility(let conversationID, let messageIDs, let message, let action, _, _):
            if let message {
                dependencies.existingMessageKeys.formUnion(messageKeys(for: message))
            }
            if action == .messageHidden {
                removeMessageKeys(
                    conversationID: conversationID,
                    messageIDs: Set(messageIDs.map(\.uuidString)),
                    from: &dependencies.existingMessageKeys
                )
            }
        case .applyMessageStream(_, let message, _, _):
            if let message {
                dependencies.existingMessageKeys.formUnion(messageKeys(for: message))
            }
        case .removeConversation(let conversationID, _):
            removeMessageKeys(conversationID: conversationID, from: &dependencies.existingMessageKeys)
        case .applyConversationVisibility(let conversationID, let action, let messageIDs, _, _):
            switch action {
            case .conversationCleared, .conversationDeleted:
                removeMessageKeys(conversationID: conversationID, from: &dependencies.existingMessageKeys)
            case .messageHidden:
                removeMessageKeys(
                    conversationID: conversationID,
                    messageIDs: Set(messageIDs.map(\.uuidString)),
                    from: &dependencies.existingMessageKeys
                )
            }
        case .ignoreDuplicate,
             .requestCatchUp,
             .rejectInvalid,
             .deferEvent,
             .applyMessageFavorite,
             .applyConversationChange,
             .applyMemberChange,
             .applyContactChange:
            break
        }
    }

    private func messageKeys(for message: IMConversationMessage) -> Set<DomainEventProjectionReducer.MessageKey> {
        var keys: Set<DomainEventProjectionReducer.MessageKey> = [
            DomainEventProjectionReducer.MessageKey(
                conversationID: message.conversationID,
                messageID: message.id
            )
        ]
        keys.insert(
            DomainEventProjectionReducer.MessageKey(
                conversationID: message.conversationID,
                messageID: message.serverMessageID
            )
        )
        return keys
    }

    private func removeMessageKeys(
        conversationID: String,
        messageIDs: Set<String>,
        from keys: inout Set<DomainEventProjectionReducer.MessageKey>
    ) {
        guard !messageIDs.isEmpty else {
            return
        }
        keys = keys.filter { key in
            key.conversationID != conversationID || !messageIDs.contains(key.messageID)
        }
    }

    private func removeMessageKeys(
        conversationID: String,
        from keys: inout Set<DomainEventProjectionReducer.MessageKey>
    ) {
        keys = keys.filter { $0.conversationID != conversationID }
    }

    private func recordProcessedDomainEvent(_ eventID: UUID) {
        guard processedDomainEventIDs.insert(eventID).inserted else {
            return
        }
        processedDomainEventIDOrder.append(eventID)
        let maxAppliedIDs = 1_000
        if processedDomainEventIDOrder.count > maxAppliedIDs {
            let overflow = processedDomainEventIDOrder.count - maxAppliedIDs
            for removedID in processedDomainEventIDOrder.prefix(overflow) {
                processedDomainEventIDs.remove(removedID)
            }
            processedDomainEventIDOrder.removeFirst(overflow)
        }
    }

    private func shouldDeferForOwnerAggregateGap(_ payload: IMTCPChatDomainEventPayload) -> Bool {
        guard let ownerAggregateSequence = payload.ownerAggregateSequence,
              ownerAggregateSequence > 0
        else {
            return false
        }
        let key = IMOwnerAggregateKey(
            aggregateType: payload.aggregateType,
            aggregateID: payload.aggregateID.uuidString
        )
        let highWatermark = ownerAggregateHighWatermarks[key] ?? 0
        return ownerAggregateSequence > highWatermark + 1
    }

    private func recordOwnerAggregateHighWatermark(_ payload: IMTCPChatDomainEventPayload) {
        guard let ownerAggregateSequence = payload.ownerAggregateSequence,
              ownerAggregateSequence > 0
        else {
            return
        }
        let key = IMOwnerAggregateKey(
            aggregateType: payload.aggregateType,
            aggregateID: payload.aggregateID.uuidString
        )
        ownerAggregateHighWatermarks[key] = max(ownerAggregateHighWatermarks[key] ?? 0, ownerAggregateSequence)
    }

    private func deferDomainEvent(
        _ payload: IMTCPChatDomainEventPayload,
        missingKey: IMDeferredDomainEventMissingKey? = nil,
        conversationID: String? = nil
    ) -> IMDeferredDomainEventStoreResult {
        let result = deferredDomainEventQueue.store(
            payload: payload,
            missingKey: missingKey ?? deferredMissingKey(for: payload),
            conversationID: conversationID ?? deferredConversationID(for: payload),
            eventsByMissingKey: &deferredDomainEventsByMissingKey
        )
        switch result {
        case .stored:
            domainEventDebugMetrics.deferredStored += 1
            enforceDeferredDomainEventLimits(conversationID: deferredConversationID(for: payload))
        case .alreadyStored:
            enforceDeferredDomainEventLimits(conversationID: deferredConversationID(for: payload))
        case .notDeferrable:
            domainEventDebugMetrics.deferredNotDeferrable += 1
        case .encodeFailed:
            domainEventDebugMetrics.deferredEncodeFailed += 1
        }
        IMClientLog.conversationStore.debug(
            "Domain event defer store result eventID=\(payload.eventID.uuidString, privacy: .public) eventType=\(payload.eventType.rawValue, privacy: .public) result=\(String(describing: result), privacy: .public) missingKey=\(String(describing: missingKey ?? deferredMissingKey(for: payload)), privacy: .public) conversationID=\(conversationID ?? deferredConversationID(for: payload) ?? "nil", privacy: .public)"
        )
        return result
    }

    private func deferredMissingKey(for payload: IMTCPChatDomainEventPayload) -> IMDeferredDomainEventMissingKey? {
        switch payload.body {
        case .messageEdited(let messageID, _, _, _),
             .messageRevoked(let messageID, _, _, _),
             .messageFavoriteChanged(let messageID, _):
            return .message(messageID.uuidString)
        case .messageVisibilityChanged(let messageIDs, let message, _):
            if let message {
                return .message(message.id.uuidString)
            }
            return messageIDs.first.map { .message($0.uuidString) }
        case .messageStream(let stream, _):
            return .stream(conversationID: stream.conversationID, messageID: stream.messageID)
        case .conversationChanged,
             .conversationRemovedForSelf,
             .conversationVisibilityChanged,
             .memberChanged:
            return .conversation(payload.aggregateID.uuidString)
        case .messageCreated,
             .contactChanged:
            return nil
        }
    }

    @discardableResult
    private func replayDeferredDomainEvents(currentUserID: UUID) -> [IMDeferredDomainEventReplayResult] {
        var results: [IMDeferredDomainEventReplayResult] = []
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)

        let deferredEvents = deferredDomainEventsByMissingKey.values.flatMap { $0 }
        for state in deferredEvents where state.firstSeenAt < cutoff {
            removeDeferredDomainEvent(state)
            domainEventDebugMetrics.deferredExpired += 1
            results.append(.expired(state.eventID))
        }

        let pending = deferredEvents.filter { $0.firstSeenAt >= cutoff }.sorted {
            ($0.ownerCursor ?? 0, $0.ownerAggregateSequence ?? 0, $0.firstSeenAt) <
                ($1.ownerCursor ?? 0, $1.ownerAggregateSequence ?? 0, $1.firstSeenAt)
        }
        var dependencies = domainEventDependencySnapshot()
        for state in pending {
            guard let data = Data(base64Encoded: state.eventPBBase64) else {
                removeDeferredDomainEvent(state)
                domainEventDebugMetrics.invalidDomainEventMetadata += 1
                domainEventDebugMetrics.invalidDeferredPayload += 1
                results.append(.invalidPayload(state.eventID))
                continue
            }

            let payload: IMTCPChatDomainEventPayload
            do {
                payload = try IMTCPProtobufCodec.decodeDomainEvent(data)
            } catch {
                removeDeferredDomainEvent(state)
                domainEventDebugMetrics.invalidDomainEventMetadata += 1
                domainEventDebugMetrics.invalidDeferredPayload += 1
                results.append(.invalidPayload(state.eventID))
                continue
            }

            let outcome = applyDomainEvent(
                payload,
                currentUserID: currentUserID,
                dependencies: &dependencies
            )
            guard processedDomainEventIDs.contains(payload.eventID) else {
                if outcome.shouldFetchDomainEvents {
                    domainEventDebugMetrics.deferredFullRefreshRequested += 1
                }
                if let conversationID = state.conversationID,
                   domainEventFullRefreshConversationIDs.contains(conversationID) {
                    results.append(.requiresFullTimelineRefresh(conversationID))
                } else {
                    bumpDeferredRetryCount(for: state)
                    results.append(.stillMissingDependency(payload.eventID))
                }
                continue
            }

            removeDeferredDomainEvent(state)
            domainEventDebugMetrics.deferredReplayApplied += 1
            results.append(.applied(payload.eventID))
        }
        return results
    }

    private func removeDeferredDomainEvent(_ state: IMDeferredDomainEventState) {
        deferredDomainEventsByMissingKey[state.missingKey]?.removeAll { $0.eventID == state.eventID }
        if deferredDomainEventsByMissingKey[state.missingKey]?.isEmpty == true {
            deferredDomainEventsByMissingKey.removeValue(forKey: state.missingKey)
        }
    }

    private func bumpDeferredRetryCount(for state: IMDeferredDomainEventState) {
        guard var states = deferredDomainEventsByMissingKey[state.missingKey],
              let index = states.firstIndex(where: { $0.eventID == state.eventID })
        else {
            return
        }
        states[index] = IMDeferredDomainEventState(
            eventID: state.eventID,
            conversationID: state.conversationID,
            missingKey: state.missingKey,
            firstSeenAt: state.firstSeenAt,
            retryCount: state.retryCount + 1,
            ownerCursor: state.ownerCursor,
            ownerAggregateSequence: state.ownerAggregateSequence,
            eventPBBase64: state.eventPBBase64
        )
        deferredDomainEventsByMissingKey[state.missingKey] = states
    }

    private func deferredDomainEventsForSnapshot() -> [IMDeferredDomainEventState] {
        let ttl: TimeInterval = 24 * 60 * 60
        let cutoff = Date().addingTimeInterval(-ttl)
        return deferredDomainEventsByMissingKey.values
            .flatMap { $0 }
            .filter { $0.firstSeenAt >= cutoff }
            .sorted {
                if $0.firstSeenAt == $1.firstSeenAt {
                    return $0.eventID.uuidString < $1.eventID.uuidString
                }
                return $0.firstSeenAt < $1.firstSeenAt
            }
    }

    private func enforceDeferredDomainEventLimits(conversationID: String?) {
        let ttl: TimeInterval = 24 * 60 * 60
        let cutoff = Date().addingTimeInterval(-ttl)
        var retained = deferredDomainEventsByMissingKey.mapValues { states in
            states.filter { $0.firstSeenAt >= cutoff }
        }
        retained = retained.filter { !$0.value.isEmpty }

        if let conversationID {
            let conversationStates = retained.values
                .flatMap { $0 }
                .filter { $0.conversationID == conversationID }
                .sorted { $0.firstSeenAt < $1.firstSeenAt }
            let maxPerConversation = 200
            if conversationStates.count > maxPerConversation {
                let overflowIDs = Set(conversationStates.prefix(conversationStates.count - maxPerConversation).map(\.eventID))
                retained = retained.mapValues { states in
                    states.filter { !overflowIDs.contains($0.eventID) }
                }.filter { !$0.value.isEmpty }
                if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[index].hasMoreHistory = true
                }
                domainEventFullRefreshConversationIDs.insert(conversationID)
                domainEventDebugMetrics.deferredFullRefreshRequested += 1
            }
        }

        deferredDomainEventsByMissingKey = retained
    }

    private func deferredConversationID(for payload: IMTCPChatDomainEventPayload) -> String? {
        if let conversationID = payload.conversation?.id.uuidString {
            return conversationID
        }
        switch payload.body {
        case .messageCreated(let message, _):
            return message.conversationID.uuidString
        case .messageEdited(_, _, _, let message),
             .messageRevoked(_, _, _, let message),
             .messageVisibilityChanged(_, let message, _):
            return message?.conversationID.uuidString ?? payload.aggregateID.uuidString
        case .messageStream(let stream, _):
            return stream.conversationID
        case .conversationChanged,
             .conversationRemovedForSelf,
             .conversationVisibilityChanged,
             .memberChanged:
            return payload.aggregateID.uuidString
        case .messageFavoriteChanged,
             .contactChanged:
            return payload.conversation?.id.uuidString
        }
    }

    private func hasMessage(id messageID: String, in conversationID: String) -> Bool {
        conversations
            .first(where: { $0.id == conversationID })?
            .messages
            .contains { $0.id == messageID || $0.serverMessageID == messageID } == true
    }

    private func queueStreamSnapshotTarget(stream: IMTCPMessageStreamPayload) {
        pendingStreamSnapshotTargets.insert(
            IMActiveMessageStreamTarget(
                conversationID: stream.conversationID,
                messageID: stream.messageID,
                streamID: stream.streamID
            )
        )
    }

    private static func domainEventComparator(
        lhs: IMTCPChatDomainEventPayload,
        rhs: IMTCPChatDomainEventPayload
    ) -> Bool {
        if lhs.aggregateSequence == rhs.aggregateSequence {
            if lhs.occurredAt == rhs.occurredAt {
                return lhs.eventID.uuidString < rhs.eventID.uuidString
            }
            return lhs.occurredAt < rhs.occurredAt
        }
        return lhs.aggregateSequence < rhs.aggregateSequence
    }

    private func domainEventOperationDebugName(_ operation: DomainEventProjectionReducer.Operation) -> String {
        switch operation {
        case .ignoreDuplicate:
            return "ignoreDuplicate"
        case .applyMessageCreated:
            return "applyMessageCreated"
        case .applyMessageMutation:
            return "applyMessageMutation"
        case .applyVisibility:
            return "applyVisibility"
        case .applyMessageFavorite:
            return "applyMessageFavorite"
        case .applyMessageStream:
            return "applyMessageStream"
        case .applyConversationChange:
            return "applyConversationChange"
        case .removeConversation:
            return "removeConversation"
        case .applyConversationVisibility:
            return "applyConversationVisibility"
        case .applyMemberChange:
            return "applyMemberChange"
        case .applyContactChange:
            return "applyContactChange"
        case .deferEvent(let reason, let missingKey, let conversationID):
            return "deferEvent(reason=\(reason.rawValue),missingKey=\(String(describing: missingKey)),conversationID=\(conversationID ?? "nil"))"
        case .requestCatchUp(let reason):
            return "requestCatchUp(\(reason))"
        case .rejectInvalid(let reason):
            return "rejectInvalid(\(reason))"
        }
    }

    private func applySummaryIfPresent(_ conversation: IMConversationSummaryResponseBody?) {
        guard let conversation else { return }
        let conversationID = conversation.id.uuidString
        let existingBefore = conversations.first { $0.id == conversationID }
        IMClientLog.conversationStore.debug(
            "Summary applying conversationID=\(conversationID, privacy: .public) summaryPreview=\(conversation.lastMessage?.previewText ?? "nil", privacy: .public) summaryUnread=\(conversation.unreadCount, privacy: .public) summaryUpdated=\(conversation.updatedAt.timeIntervalSince1970, privacy: .public) beforePreview=\(existingBefore?.lastMessagePreviewText ?? "nil", privacy: .public) beforeUnread=\(existingBefore?.unreadCount ?? -1, privacy: .public) beforeUpdated=\(existingBefore?.updatedAt.timeIntervalSince1970 ?? -1, privacy: .public)"
        )
        applyConversationSummaryContent(conversation)
        applyServerSummaryReadState(conversation)
        let existingAfter = conversations.first { $0.id == conversationID }
        IMClientLog.conversationStore.debug(
            "Summary applied conversationID=\(conversationID, privacy: .public) afterPreview=\(existingAfter?.lastMessagePreviewText ?? "nil", privacy: .public) afterUnread=\(existingAfter?.unreadCount ?? -1, privacy: .public) afterUpdated=\(existingAfter?.updatedAt.timeIntervalSince1970 ?? -1, privacy: .public) messages=\(existingAfter?.messages.count ?? -1, privacy: .public) timeline=\(existingAfter?.timelineItems.count ?? -1, privacy: .public)"
        )
    }

    private func upsertTimelineNotice(_ response: IMTimelineNoticeResponseBody) {
        let notice = makeNotices(from: [response])[0]
        upsertTimelineNotice(notice)
    }

    private func upsertTimelineNotice(_ notice: IMTimelineNotice) {
        let index = ensureConversationIndex(for: notice.conversationID)
        if let existingIndex = conversations[index].notices.firstIndex(where: { $0.id == notice.id }) {
            conversations[index].notices[existingIndex] = notice
        } else {
            conversations[index].notices.append(notice)
        }
        conversations[index].notices.sort {
            if $0.timelineSequence == $1.timelineSequence {
                return $0.id < $1.id
            }
            return $0.timelineSequence < $1.timelineSequence
        }
    }

    private func clearDomainEventFullRefreshState(for conversationID: String, currentUserID: UUID) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              domainEventFullRefreshConversationIDs.remove(trimmedConversationID) != nil
        else {
            return
        }
        deferredDomainEventsByMissingKey = deferredDomainEventsByMissingKey.mapValues { states in
            states.filter { $0.conversationID != trimmedConversationID }
        }.filter { !$0.value.isEmpty }
        _ = replayDeferredDomainEvents(currentUserID: currentUserID)
    }

    public func replaceTimelineItems(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        conversationTimelineStore.replaceTimelineMessageItems(
            in: conversationID,
            messages: responses,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            mergeMessages: mergeMessages,
            hasOlderHistory: hasOlderHistory,
            refreshLoadedMessageCursors: refreshLoadedTimelineCursors
        )
        clearDomainEventFullRefreshState(for: conversationID, currentUserID: currentUserID)
        statusMessage = nil
        sortConversations()
    }

    public func replaceTimelineItems(
        in conversationID: String,
        items: [IMTimelineItemResponseBody],
        hasMore: Bool,
        currentUserID: UUID
    ) {
        conversationTimelineStore.replaceTimelineItems(
            in: conversationID,
            items: items,
            hasMore: hasMore,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            makeNotices: makeNotices,
            mergeMessages: mergeMessages,
            refreshLoadedMessageCursors: refreshLoadedTimelineCursors
        )
        clearDomainEventFullRefreshState(for: conversationID, currentUserID: currentUserID)
        statusMessage = nil
        sortConversations()
    }

    public func mergeTimelinePage(
        in conversationID: String,
        response: IMConversationTimelineResponseBody,
        currentUserID: UUID
    ) {
        conversationTimelineStore.replaceTimelineItems(
            in: conversationID,
            items: response.items,
            hasMore: response.hasMore,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            makeNotices: makeNotices,
            mergeMessages: mergeMessages,
            refreshLoadedMessageCursors: refreshLoadedTimelineCursors
        )
        clearDomainEventFullRefreshState(for: conversationID, currentUserID: currentUserID)
        statusMessage = nil
        sortConversations()
    }

    public func appendTimelineItems(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        conversationTimelineStore.appendTimelineMessageItems(
            in: conversationID,
            messages: responses,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            mergeMessages: mergeMessages,
            refreshLatestSyncedCursor: refreshLatestLoadedTimelineCursor
        )
        statusMessage = nil
        sortConversations()
    }

    public func appendTimelineItems(
        in conversationID: String,
        items: [IMTimelineItemResponseBody],
        currentUserID: UUID
    ) {
        conversationTimelineStore.appendTimelineItems(
            in: conversationID,
            items: items,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            makeNotices: makeNotices,
            mergeMessages: mergeMessages,
            refreshLatestSyncedCursor: refreshLatestLoadedTimelineCursor
        )
        statusMessage = nil
        sortConversations()
    }

    public func appendTimelinePage(
        in conversationID: String,
        response: IMConversationTimelineResponseBody,
        currentUserID: UUID
    ) {
        conversationTimelineStore.appendTimelineItems(
            in: conversationID,
            items: response.items,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            makeNotices: makeNotices,
            mergeMessages: mergeMessages,
            refreshLatestSyncedCursor: refreshLatestLoadedTimelineCursor
        )
        statusMessage = nil
        sortConversations()
    }

    public func replaceMembers(
        in conversationID: String,
        members responses: [IMConversationMemberResponseBody]
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let members = Self.members(from: responses)
            .sorted(by: sortMembers)

        conversations[index].members = members
        conversations[index].memberUserIDs = members.map(\.id).sorted { $0.uuidString < $1.uuidString }
        conversations[index].memberCount = members.count
        statusMessage = nil
    }

    public func applyMemberPage(
        _ response: IMConversationMemberPageResponseBody,
        in conversationID: String,
        query: String,
        appending: Bool
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let newMembers = Self.members(from: response.items)
        let previousItems = appending ? memberPageStates[trimmedConversationID]?.items ?? [] : []
        let mergedMembers = Self.uniqueMembers(previousItems + newMembers)

        memberPageStates[trimmedConversationID] = IMConversationMemberPageState(
            items: mergedMembers,
            query: query,
            nextCursor: response.nextCursor,
            total: response.total,
            limit: response.limit,
            isLoading: false,
            isLoadingMore: false
        )

        let index = ensureConversationIndex(for: trimmedConversationID)
        let sortedMembers = mergedMembers.sorted(by: sortMembers)
        conversations[index].members = sortedMembers
        conversations[index].memberUserIDs = sortedMembers.map(\.id).sorted { $0.uuidString < $1.uuidString }
        conversations[index].memberCount = response.total
        statusMessage = nil
    }

    public func setMemberPageLoading(
        conversationID: String,
        query: String,
        isLoading: Bool,
        isLoadingMore: Bool = false
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        var state = memberPageStates[trimmedConversationID] ?? IMConversationMemberPageState(query: query)
        state.query = query
        state.isLoading = isLoading
        state.isLoadingMore = isLoadingMore
        memberPageStates[trimmedConversationID] = state
        setLoadingMembers(isLoading || isLoadingMore)
    }

    public func memberPageState(for conversationID: String) -> IMConversationMemberPageState {
        memberPageStates[conversationID] ?? IMConversationMemberPageState()
    }

    public func setReceiptSummary(
        _ summary: IMConversationReceiptSummaryResponseBody,
        for conversationID: String
    ) {
        receiptSummaries[conversationID] = summary
    }

    public func receiptSummary(for conversationID: String) -> IMConversationReceiptSummaryResponseBody? {
        receiptSummaries[conversationID]
    }

    public func updateDraft(_ text: String, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].draftText = text
        conversations[index].draftUpdatedAt = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Date()
    }

    public func draftText(for conversationID: String) -> String {
        conversations.first(where: { $0.id == conversationID })?.draftText ?? ""
    }

    public func applyConversationPreferences(
        conversationID: String,
        isPinned: Bool,
        pinnedAt: Date?,
        isMuted: Bool
    ) {
        conversationListStore.applyConversationPreferences(
            conversationID: conversationID,
            isPinned: isPinned,
            pinnedAt: pinnedAt,
            isMuted: isMuted,
            conversations: &conversations
        )
        sortConversations()
    }

    public func applyConversationMetadata(
        conversationID: String,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?
    ) {
        conversationListStore.applyConversationMetadata(
            conversationID: conversationID,
            title: title,
            notice: notice,
            avatarPreset: avatarPreset,
            conversations: &conversations
        )
        sortConversations()
    }

    public func prependTimelineItems(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        conversationTimelineStore.prependTimelineMessageItems(
            in: conversationID,
            messages: responses,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            mergeMessages: mergeMessages,
            hasOlderHistory: hasOlderHistory,
            refreshLoadedMessageCursors: refreshLoadedTimelineCursors
        )
        statusMessage = nil
        sortConversations()
    }

    public func prependTimelinePage(
        in conversationID: String,
        response: IMConversationTimelineResponseBody,
        currentUserID: UUID
    ) {
        conversationTimelineStore.prependTimelineItems(
            in: conversationID,
            items: response.items,
            hasMore: response.hasMore,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            makeNotices: makeNotices,
            mergeMessages: mergeMessages,
            refreshLoadedMessageCursors: refreshLoadedTimelineCursors
        )
        statusMessage = nil
        sortConversations()
    }

    public func prepareOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID
    ) -> IMOutgoingMessageRequest? {
        prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        ).request
    }

    @discardableResult
    public func queueOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ).placeholder != nil
    }

    public func prepareOutgoingReply(
        reference: IMReplyReference,
        text: String,
        conversationID: String,
        senderUserID: UUID
    ) -> IMOutgoingMessageRequest? {
        prepareOutgoingMessage(
            .reply(
                reference: reference,
                body: .plain(text.trimmingCharacters(in: .whitespacesAndNewlines))
            ),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        ).request
    }

    @discardableResult
    public func queueOutgoingReply(
        reference: IMReplyReference,
        text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        prepareOutgoingMessage(
            .reply(
                reference: reference,
                body: .plain(text.trimmingCharacters(in: .whitespacesAndNewlines))
            ),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ).placeholder != nil
    }

    public func stageOutgoingMediaUpload(
        asset: IMMediaAsset,
        conversationID: String,
        senderUserID: UUID,
        sourceFileURL: URL
    ) -> IMOutgoingMediaPlaceholder? {
        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return nil
        }

        return appendOutgoingMessage(
            content,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .preparing(message: "正在准备上传附件。"),
            shouldRegisterPendingRequest: false,
            localTransferState: IMMessageLocalTransferState(sourceFilePath: sourceFileURL.path)
        ).placeholder
    }

    public func markOutgoingPreparing(localMessageID: String, message: String, uploadID: String? = nil) {
        mutatePendingMessage(id: localMessageID) { item in
            item.deliveryState = .preparing(message: message)
            if let uploadID, let transferState = item.localTransferState {
                item.localTransferState = transferState.withUploadID(uploadID)
            }
        }
    }

    public func markOutgoingUploading(localMessageID: String, message: String, uploadID: String? = nil) {
        mutatePendingMessage(id: localMessageID) { item in
            item.deliveryState = .uploading(message: message)
            if let uploadID, let transferState = item.localTransferState {
                item.localTransferState = transferState.withUploadID(uploadID)
            }
        }
    }

    public func markOutgoingUploadFailed(localMessageID: String, message: String) {
        mutatePendingMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
        }
        statusMessage = message
    }

    public func abandonRecoverableOutgoingMediaUpload(localMessageID: String, message: String) {
        mutatePendingMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
            item.localTransferState = nil
        }
        statusMessage = message
    }

    public func updateLocalDownloadState(
        messageID: String,
        state: IMMessageLocalDownloadState?
    ) {
        mutateMessage(id: messageID) { item in
            item.localDownloadState = state
            if let taskID = state?.taskID {
                item.transferTaskID = taskID
            }
        }
    }

    public func prepareUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        updateUploadedOutgoingMedia(
            asset: asset,
            localMessageID: localMessageID,
            conversationID: conversationID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        ).request
    }

    @discardableResult
    public func queueUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        updateUploadedOutgoingMedia(
            asset: asset,
            localMessageID: localMessageID,
            conversationID: conversationID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ).didUpdate
    }

    public func recoverableOutgoingMediaUploads() -> [IMRecoverableOutgoingMediaUpload] {
        conversations.flatMap { conversation in
            conversation.pendingMessages.compactMap { message in
                guard let transferState = message.localTransferState,
                      let asset = message.mediaAsset,
                      message.isRecoverableOutgoingMediaUpload
                else {
                    return nil
                }

                return IMRecoverableOutgoingMediaUpload(
                    localMessageID: message.id,
                    conversationID: conversation.id,
                    asset: asset,
                    transferState: transferState,
                    deliveryState: message.deliveryState
                )
            }
        }
    }

    private func prepareOutgoingMessage(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        appendOutgoingMessage(
            content,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: deliveryState,
            shouldRegisterPendingRequest: shouldRegisterPendingRequest,
            localTransferState: localTransferState
        )
    }

    private func prepareOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            statusMessage = "消息内容不能为空。"
            return (nil, nil)
        }

        return prepareOutgoingMessage(
            .richText(.plain(trimmedText)),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: deliveryState,
            shouldRegisterPendingRequest: shouldRegisterPendingRequest
        )
    }

    public func retryOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "消息重试失败：会话或消息无效。"
            return nil
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "消息重试失败：本地消息不存在。"
            return nil
        }

        var message = conversations[conversationIndex].pendingMessages[messageIndex]
        guard message.direction == .outgoing, message.content.isUserComposable else {
            statusMessage = "只能重试自己发送的消息。"
            return nil
        }

        guard isRetryableFailure(message) else {
            statusMessage = "该消息失败原因不可重试。"
            return nil
        }

        let clientMessageID = message.clientMessageID
        let requestID = UUID()
        message.deliveryState = .sending
        conversations[conversationIndex].pendingMessages[messageIndex] = message
        outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: trimmedConversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: message.content
            )
        )
    }

    @discardableResult
    public func queueRetryableOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        message queueMessage: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "消息排队失败：会话或消息无效。"
            return false
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "消息排队失败：本地消息不存在。"
            return false
        }

        var message = conversations[conversationIndex].pendingMessages[messageIndex]
        guard isRetryableFailure(message) else {
            statusMessage = "该消息失败原因不可排队重试。"
            return false
        }

        outgoingQueueState.removePendingRequests(for: message.id)
        message.deliveryState = .queued(message: queueMessage)
        conversations[conversationIndex].pendingMessages[messageIndex] = message
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()
        return true
    }

    @discardableResult
    public func cancelQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "取消发送失败：会话或消息无效。"
            return false
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "取消发送失败：本地消息不存在。"
            return false
        }

        let message = conversations[conversationIndex].pendingMessages[messageIndex]
        guard message.direction == .outgoing, message.content.isUserComposable, message.isQueued else {
            statusMessage = "只能取消尚未发送的消息。"
            return false
        }

        outgoingQueueState.removePendingRequests(for: message.id)
        conversations[conversationIndex].pendingMessages.remove(at: messageIndex)
        refreshConversationPresentationAfterLocalMessageRemoval(at: conversationIndex)
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()
        return true
    }

    public func queuedOutgoingMessageRequests(limit: Int) -> [IMOutgoingMessageRequest] {
        let limitedCount = max(0, limit)
        guard limitedCount > 0 else {
            return []
        }

        var queuedMessages: [(conversationID: String, message: IMPendingConversationMessage)] = []
        for conversation in conversations {
            for message in conversation.pendingMessages
                where message.direction == .outgoing && message.content.isUserComposable && message.isQueued {
                queuedMessages.append((conversation.id, message))
            }
        }

        queuedMessages.sort { left, right in
            if left.message.createdAt == right.message.createdAt {
                return left.message.id < right.message.id
            }
            return left.message.createdAt < right.message.createdAt
        }

        var requests: [IMOutgoingMessageRequest] = []
        for (conversationID, queuedMessage) in queuedMessages.prefix(limitedCount) {
            guard let request = startQueuedOutgoingMessage(
                localMessageID: queuedMessage.id,
                conversationID: conversationID
            ) else {
                continue
            }
            requests.append(request)
        }

        return requests
    }

    public func markOutgoingQueued(requestID: UUID, message: String) {
        guard let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            return
        }

        mutatePendingMessage(id: localMessageID) { item in
            item.deliveryState = .queued(message: message)
        }
    }

    public func isRetryableFailure(_ message: IMPendingConversationMessage) -> Bool {
        guard message.direction == .outgoing else {
            return false
        }

        switch message.deliveryState {
        case .preparing, .uploading, .uploaded:
            return false
        case .queued, .unknown:
            return true
        case .failed(let failureMessage):
            return !Self.nonRetryableOutgoingFailureMessages.contains(failureMessage)
        case .sending, .sent, .received:
            return false
        }
    }

    public func isRetryableFailure(_ message: IMConversationMessage) -> Bool {
        false
    }

    func queueSummary(for messages: [IMPendingConversationMessage]) -> IMConversationQueueSummary {
        var queuedCount = 0
        var sendingCount = 0
        var retryableIssueCount = 0

        for message in messages where message.direction == .outgoing {
            switch message.deliveryState {
            case .preparing, .uploading, .uploaded:
                sendingCount += 1
            case .queued:
                queuedCount += 1
            case .sending:
                sendingCount += 1
            case .unknown:
                retryableIssueCount += 1
            case .failed:
                if isRetryableFailure(message) {
                    retryableIssueCount += 1
                }
            case .sent, .received:
                break
            }
        }

        return IMConversationQueueSummary(
            queuedCount: queuedCount,
            sendingCount: sendingCount,
            retryableIssueCount: retryableIssueCount
        )
    }

    public func applyOutgoingAcknowledgement(requestID: UUID?, payload: IMTCPAckPayload) {
        guard let requestID else {
            IMClientLog.conversationStore.warning(
                "ACK ignored: missing requestID status=\(payload.status, privacy: .public) messageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public)"
            )
            return
        }

        guard let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            IMClientLog.conversationStore.warning(
                "ACK ignored: no pending request requestID=\(requestID.uuidString, privacy: .public) status=\(payload.status, privacy: .public) messageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public)"
            )
            return
        }

        IMClientLog.conversationStore.debug(
            "ACK received requestID=\(requestID.uuidString, privacy: .public) localMessageID=\(localMessageID, privacy: .public) status=\(payload.status, privacy: .public) messageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public)"
        )

        if payload.status == "accepted" {
            applyAcceptedOutgoingAcknowledgement(
                localMessageID: localMessageID,
                payload: payload
            )
            return
        }

        mutatePendingMessage(id: localMessageID) { message in
            let failureMessage = outgoingAcknowledgementFailureMessage(for: payload.status)
            message.deliveryState = .failed(message: failureMessage)
            statusMessage = failureMessage
        }
    }

    public func markOutgoingFailure(requestID: UUID, message: String) {
        guard let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            statusMessage = message
            return
        }

        mutatePendingMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
        }
        statusMessage = message
    }

    public func markAllPendingMessagesFailed(message: String) {
        let pendingMessageIDs = outgoingQueueState.drainPendingMessageIDs()

        for localMessageID in pendingMessageIDs {
            mutatePendingMessage(id: localMessageID) { item in
                item.deliveryState = .failed(message: message)
            }
        }

        if !pendingMessageIDs.isEmpty {
            statusMessage = message
        }
    }

    public func markAllPendingMessagesUnknown(message: String) {
        let pendingMessageIDs = outgoingQueueState.drainPendingMessageIDs()

        for localMessageID in pendingMessageIDs {
            mutatePendingMessage(id: localMessageID) { item in
                item.deliveryState = .unknown(message: message)
            }
        }

        if !pendingMessageIDs.isEmpty {
            statusMessage = message
        }
    }

    private func applyCreatedMessage(
        _ message: IMConversationMessage,
        clientMessageID: String?
    ) {
        let conversationID = message.conversationID
        let serverMessageID = message.serverMessageID
        let index = ensureConversationIndex(for: conversationID)
        let pendingCountBefore = conversations[index].pendingMessages.count
        let messageCountBefore = conversations[index].messages.count
        let unreadBefore = conversations[index].unreadCount
        let previewBefore = conversations[index].lastMessagePreviewText

        if message.direction == .outgoing {
            conversations[index].pendingMessages.removeAll { pendingMessage in
                if pendingMessage.serverMessageID == serverMessageID {
                    return true
                }
                guard let clientMessageID else {
                    return false
                }
                return pendingMessage.clientMessageID == clientMessageID
            }
        }

        if let existingIndex = conversations[index].messages.firstIndex(where: {
            $0.id == serverMessageID
                || $0.serverMessageID == serverMessageID
                || ($0.clientMessageID != nil && $0.clientMessageID == clientMessageID)
        }) {
            conversations[index].messages[existingIndex] = message
        } else {
            conversations[index].messages.append(message)
        }

        conversations[index].messages.sort(by: Self.messageComparator)
        conversations[index].lastMessagePreviewText = message.text
        conversations[index].updatedAt = max(conversations[index].updatedAt, message.createdAt)
        refreshLatestLoadedTimelineCursor(
            for: conversationID,
            timelineItems: conversations[index].timelineItems
        )

        applyIncomingMessageUnreadState(for: conversationID)

        statusMessage = nil
        sortConversations()
        let conversationAfter = conversations.first { $0.id == conversationID }
        let pendingCountAfter = conversationAfter?.pendingMessages.count ?? -1
        let messageCountAfter = conversationAfter?.messages.count ?? -1
        IMClientLog.conversationStore.debug(
            "Canonical message applied conversationID=\(conversationID, privacy: .public) serverMessageID=\(serverMessageID, privacy: .public) clientMessageID=\(clientMessageID ?? "nil", privacy: .public) direction=\(String(describing: message.direction), privacy: .public) text=\(message.text, privacy: .public) unreadBefore=\(unreadBefore, privacy: .public) unreadAfter=\(conversationAfter?.unreadCount ?? -1, privacy: .public) previewBefore=\(previewBefore, privacy: .public) previewAfter=\(conversationAfter?.lastMessagePreviewText ?? "nil", privacy: .public) updatedAfter=\(conversationAfter?.updatedAt.timeIntervalSince1970 ?? -1, privacy: .public) pendingBefore=\(pendingCountBefore, privacy: .public) pendingAfter=\(pendingCountAfter, privacy: .public) messagesBefore=\(messageCountBefore, privacy: .public) messagesAfter=\(messageCountAfter, privacy: .public) timelineAfter=\(conversationAfter?.timelineItems.count ?? -1, privacy: .public)"
        )
    }

    private func applyAcceptedOutgoingAcknowledgement(
        localMessageID: String,
        payload: IMTCPAckPayload
    ) {
        var didApply = false
        mutatePendingMessage(id: localMessageID) { message in
            didApply = true
            message.deliveryState = .sent
            let serverMessageID = payload.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !serverMessageID.isEmpty {
                message.serverMessageID = serverMessageID
            }
            statusMessage = nil
            let clientMessageID = message.clientMessageID
            let conversationID = message.conversationID
            let acknowledgedServerMessageID = message.serverMessageID ?? "nil"
            IMClientLog.conversationStore.debug(
                "ACK accepted kept pending localMessageID=\(localMessageID, privacy: .public) clientMessageID=\(clientMessageID, privacy: .public) conversationID=\(conversationID, privacy: .public) serverMessageID=\(acknowledgedServerMessageID, privacy: .public) state=sent"
            )
        }

        if !didApply {
            IMClientLog.conversationStore.warning(
                "ACK accepted could not find pending localMessageID=\(localMessageID, privacy: .public) serverMessageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public)"
            )
        }
    }

    private func applyUpdatedMessage(_ message: IMConversationMessage) {
        let conversationID = message.conversationID
        let stableMessageID = message.serverMessageID
        let index = ensureConversationIndex(for: conversationID)

        if let messageIndex = conversations[index].messages.firstIndex(where: {
            $0.id == stableMessageID || $0.serverMessageID == stableMessageID
        }) {
            conversations[index].messages[messageIndex] = message
        } else {
            conversations[index].messages.append(message)
        }

        conversations[index].messages.sort(by: Self.messageComparator)
        conversations[index].lastMessagePreviewText = conversations[index].messages.last?.text
            ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = max(conversations[index].updatedAt, message.createdAt)
        sortConversations()
    }

    public func applyUpdatedMessage(
        _ response: IMConversationMessageResponseBody,
        currentUserID: UUID
    ) {
        let conversationID = response.conversationID.uuidString
        let stableMessageID = response.id.uuidString
        let effectiveTimestamp = response.createdAt ?? Date()
        let index = ensureConversationIndex(for: conversationID)

        if let messageIndex = conversations[index].messages.firstIndex(where: {
            $0.id == stableMessageID || $0.serverMessageID == stableMessageID
        }) {
            conversations[index].messages[messageIndex].serverMessageID = stableMessageID
            conversations[index].messages[messageIndex].serverSequence = UInt64(response.serverSequence)
            conversations[index].messages[messageIndex].timelineSequence = UInt64(response.timelineSequence)
            conversations[index].messages[messageIndex].senderUserID = response.senderUserID
            conversations[index].messages[messageIndex].content = response.content
            conversations[index].messages[messageIndex].derivedState = response.derivedState
            conversations[index].messages[messageIndex].createdAt = effectiveTimestamp
            conversations[index].messages[messageIndex].deliveryState =
                conversations[index].messages[messageIndex].direction == .outgoing ? .sent : .received
        } else {
            do {
                let message = try IMConversationMessage(
                    id: stableMessageID,
                    conversationID: conversationID,
                    clientMessageID: response.clientMessageID,
                    serverMessageID: stableMessageID,
                    senderUserID: response.senderUserID,
                    serverSequence: UInt64(response.serverSequence),
                    timelineSequence: UInt64(response.timelineSequence),
                    content: response.content,
                    derivedState: response.derivedState,
                    direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                    createdAt: effectiveTimestamp,
                    deliveryState: response.senderUserID == currentUserID ? .sent : .received
                )
                conversations[index].messages.append(message)
            } catch {
                domainEventDebugMetrics.invalidCanonicalMessageDTOs += 1
                domainEventFullRefreshConversationIDs.insert(conversationID)
            }
        }

        conversations[index].messages.sort(by: Self.messageComparator)
        conversations[index].lastMessagePreviewText = conversations[index].messages.last?.text
            ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = max(conversations[index].updatedAt, effectiveTimestamp)
        sortConversations()
    }

    public func applyMessageStreamEvent(
        stream: IMTCPMessageStreamPayload,
        message: IMConversationMessageResponseBody?,
        currentUserID: UUID
    ) {
        if let message {
            applyUpdatedMessage(message, currentUserID: currentUserID)
        }
        applyMessageStreamState(stream: stream)
    }

    private func applyMessageStreamEvent(
        stream: IMTCPMessageStreamPayload,
        message: IMConversationMessage?
    ) {
        if let message {
            applyUpdatedMessage(message)
        }
        applyMessageStreamState(stream: stream)
    }

    private func applyMessageStreamState(stream: IMTCPMessageStreamPayload) {
        let conversationID = stream.conversationID
        let index = ensureConversationIndex(for: conversationID)
        guard let messageIndex = conversations[index].messages.firstIndex(where: { message in
            message.serverMessageID == stream.messageID ||
                message.id == stream.messageID ||
                message.derivedState.streamState?.streamID == stream.streamID
        }) else {
            return
        }

        var message = conversations[index].messages[messageIndex]
        let existingStreamState = message.derivedState.streamState
        if existingStreamState?.state.isTerminal == true, stream.state == .streaming {
            return
        }
        if let existingStreamState,
           stream.state == .streaming,
           stream.chunkIndex <= existingStreamState.lastChunkIndex {
            return
        }
        if let existingStreamState,
           stream.state == .streaming,
           stream.chunkIndex > existingStreamState.lastChunkIndex + 1 {
            pendingStreamSnapshotTargets.insert(
                IMActiveMessageStreamTarget(
                    conversationID: conversationID,
                    messageID: stream.messageID,
                    streamID: stream.streamID
                )
            )
            return
        }
        if existingStreamState == nil,
           stream.state == .streaming,
           stream.chunkIndex > 1 {
            pendingStreamSnapshotTargets.insert(
                IMActiveMessageStreamTarget(
                    conversationID: conversationID,
                    messageID: stream.messageID,
                    streamID: stream.streamID
                )
            )
            return
        }

        let existingText = message.content.presentation(derivedState: message.derivedState).textValue ?? ""
        let nextText: String
        if let deltaText = stream.deltaText, stream.state == .streaming {
            nextText = existingText + deltaText
        } else {
            nextText = existingText
        }

        message.content = .richText(.plain(nextText))
        message.derivedState = MessageDerivedState(
            recallState: message.derivedState.recallState,
            edits: message.derivedState.edits,
            reactions: message.derivedState.reactions,
            streamState: MessageStreamState(
                streamID: stream.streamID,
                state: stream.state,
                lastChunkIndex: stream.chunkIndex,
                partialText: nextText,
                updatedAt: stream.serverTimestamp
            )
        )
        conversations[index].messages[messageIndex] = message
        conversations[index].lastMessagePreviewText = message.text
        conversations[index].updatedAt = max(conversations[index].updatedAt, stream.serverTimestamp)
        sortConversations()
    }

    public func applyStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        currentUserID: UUID
    ) {
        if !hasMessage(id: payload.stream.messageID, in: payload.stream.conversationID),
           payload.message == nil {
            queueStreamSnapshotTarget(stream: payload.stream)
            return
        }
        applyMessageStreamEvent(
            stream: payload.stream,
            message: payload.message,
            currentUserID: currentUserID
        )
    }

    public func applyMessageStreamSnapshot(
        _ response: IMMessageStreamResponseBody,
        currentUserID: UUID
    ) {
        applyUpdatedMessage(response.message, currentUserID: currentUserID)
        pendingStreamSnapshotTargets.remove(
            IMActiveMessageStreamTarget(
                conversationID: response.message.conversationID.uuidString,
                messageID: response.message.id.uuidString,
                streamID: response.stream.streamID
            )
        )
    }

    public func activeMessageStreamTargets() -> [IMActiveMessageStreamTarget] {
        conversations.flatMap { conversation in
            conversation.messages.compactMap { message in
                guard let streamState = message.derivedState.streamState,
                      streamState.state == .streaming
                else {
                    return nil
                }
                return IMActiveMessageStreamTarget(
                    conversationID: conversation.id,
                    messageID: message.serverMessageID,
                    streamID: streamState.streamID
                )
            }
        }
    }

    public func consumePendingStreamSnapshotTargets() -> [IMActiveMessageStreamTarget] {
        let targets = Array(pendingStreamSnapshotTargets)
        pendingStreamSnapshotTargets.removeAll()
        return targets
    }

    public func hasLoadedMessages(for conversationID: String) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard detailState.hasLoadedMessages(for: trimmedConversationID) else {
            return false
        }

        guard let conversation = conversations.first(where: { $0.id == trimmedConversationID }) else {
            return false
        }

        return !shouldTreatLoadedTimelineAsSummaryOnly(conversation)
    }

    public func canLoadOlderMessages(for conversationID: String) -> Bool {
        conversations.first(where: { $0.id == conversationID })?.hasMoreHistory ?? false
    }

    public func oldestLoadedTimelineSequence(for conversationID: String) -> UInt64? {
        detailState.oldestLoadedTimelineSequence(
            for: conversationID,
            conversations: conversations
        )
    }

    public func syncCursor(for conversationID: String) -> IMSyncCursorState? {
        detailState.syncCursor(
            for: conversationID,
            conversations: conversations
        )
    }

    public func setLatestLoadedTimelineSequence(_ sequence: UInt64?, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        detailState.setLatestLoadedTimelineSequence(sequence, for: trimmedConversationID)
    }

    public func setOldestLoadedTimelineSequence(_ sequence: UInt64?, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        detailState.setOldestLoadedTimelineSequence(sequence, for: trimmedConversationID)
    }

    public func trimCachedMessageWindow(limit: Int = IMConversationCacheSnapshot.cachedMessageLimit) {
        let effectiveLimit = max(0, limit)
        for index in conversations.indices {
            conversations[index].messages = trimmedCachedMessages(
                conversations[index].messages,
                limit: effectiveLimit
            )
            refreshLoadedTimelineCursors(
                for: conversations[index].id,
                timelineItems: conversations[index].timelineItems
            )
        }
    }

    public func latestLoadedTimelineSequence(for conversationID: String) -> UInt64? {
        detailState.latestLoadedTimelineSequence(
            for: conversationID,
            conversations: conversations
        )
    }

    public func latestLoadedMessageSequence(for conversationID: String) -> UInt64? {
        conversations
            .first(where: { $0.id == conversationID })?
            .messages
            .map(\.serverSequence)
            .max()
    }

    public func gapSyncTargets(from summaries: [IMConversationSummaryResponseBody]) -> [String] {
        let localLatestSequences = latestLoadedMessageSequencesByConversationID()

        return summaries.compactMap { summary -> String? in
            let conversationID = summary.id.uuidString
            let serverLatestSequence = summary.lastMessage?.serverSequence ?? 0
            guard
                let localLatestSequence = localLatestSequences[conversationID],
                serverLatestSequence > localLatestSequence
            else {
                return nil
            }

            return conversationID
        }
    }

    private func latestLoadedMessageSequencesByConversationID() -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: conversations.compactMap { conversation -> (String, UInt64)? in
            var latestSequence: UInt64?
            for message in conversation.messages {
                latestSequence = max(latestSequence ?? 0, message.serverSequence)
            }
            guard let latestSequence else {
                return nil
            }
            return (conversation.id, latestSequence)
        })
    }

    public func serverLastReadSequence(for conversationID: String) -> UInt64? {
        conversations.first(where: { $0.id == conversationID })?.serverLastReadSequence
    }

    public func setLoadingConversations(_ isLoading: Bool) {
        isLoadingConversations = isLoading
    }

    public func setLoadingMoreConversationSummaries(_ isLoading: Bool) {
        isLoadingMoreConversationSummaries = isLoading
    }

    public func setLoadingMembers(_ isLoading: Bool) {
        detailState.isLoadingMembers = isLoading
        isLoadingMembers = isLoading
    }

    public func setLoadingMessages(_ isLoading: Bool) {
        detailState.isLoadingMessages = isLoading
        isLoadingMessages = isLoading
    }

    public func setStatusMessage(_ message: String?) {
        statusMessage = message
    }

    public func containsConversation(id conversationID: String) -> Bool {
        conversations.contains { $0.id == conversationID }
    }

    public func localMessageID(
        matchingReferencedMessageID targetMessageID: String,
        in conversationID: String
    ) -> String? {
        conversationTimelineStore.localMessageID(
            matchingReferencedMessageID: targetMessageID,
            in: conversationID,
            conversations: conversations,
            readModel: messageTimelineState
        )
    }

    public func beginReplyJump(
        to targetMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedTargetMessageID.isEmpty else {
            return
        }

        detailState.startReplyJump(in: trimmedConversationID, targetMessageID: trimmedTargetMessageID)
        syncReplyJumpState()
    }

    public func resolveReplyJump(
        matchedMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMatchedMessageID = matchedMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMatchedMessageID.isEmpty else {
            return
        }

        detailState.resolveReplyJump(matchedMessageID: trimmedMatchedMessageID, in: trimmedConversationID)
        syncReplyJumpState()
    }

    public func exhaustReplyJump(
        to targetMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedTargetMessageID.isEmpty else {
            return
        }

        detailState.exhaustReplyJump(in: trimmedConversationID, targetMessageID: trimmedTargetMessageID)
        syncReplyJumpState()
    }

    public func clearReplyJump() {
        detailState.clearReplyJump()
        syncReplyJumpState()
    }

    public func makeCacheSnapshot(
        lastSummaryRefreshAt: Date?,
        summarySyncToken: String? = nil,
        transferSnapshots: [IMTransferSnapshot] = []
    ) -> IMConversationCacheSnapshot {
        let snapshot = ConversationCacheSnapshotMapper.makeSnapshot(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            detailState: detailState,
            lastSummaryRefreshAt: lastSummaryRefreshAt,
            summarySyncToken: summarySyncToken,
            summaryNextCursor: conversationSummaryNextCursor,
            hasMoreConversationSummaries: hasMoreConversationSummaries,
            transferSnapshots: transferSnapshots,
            domainEventState: IMDomainEventCacheState(
                cursor: domainEventCursor,
                appliedEventIDs: processedDomainEventIDOrder,
                ownerAggregateHighWatermarks: ownerAggregateHighWatermarks.map {
                    IMOwnerAggregateHighWatermarkState(
                        aggregateType: $0.key.aggregateType,
                        aggregateID: $0.key.aggregateID,
                        sequence: $0.value
                    )
                },
                deferredEvents: deferredDomainEventsForSnapshot(),
                fullRefreshConversationIDs: Array(domainEventFullRefreshConversationIDs).sorted()
            ),
            trimMessages: { messages, limit in
                trimmedCachedMessages(messages, limit: limit)
            }
        )
        recordCacheDiagnostics(snapshot.diagnostics)
        return snapshot
    }

    public func restoreCacheSnapshot(_ snapshot: IMConversationCacheSnapshot) {
        let restoredState = ConversationCacheSnapshotMapper.restore(
            from: snapshot,
            restoreDeliveryState: Self.restoredDeliveryState(_:)
        )
        conversations = restoredState.conversations
        selectedConversationID = restoredState.selectedConversationID
        detailState = restoredState.detailState
        conversationSummaryNextCursor = snapshot.metadata.summaryNextCursor
        hasMoreConversationSummaries = snapshot.metadata.hasMoreConversationSummaries
        domainEventCursor = snapshot.domainEventState.cursor
        processedDomainEventIDOrder = Array(snapshot.domainEventState.appliedEventIDs.suffix(1_000))
        processedDomainEventIDs = Set(processedDomainEventIDOrder)
        ownerAggregateHighWatermarks = Dictionary(
            uniqueKeysWithValues: snapshot.domainEventState.ownerAggregateHighWatermarks.map {
                (
                    IMOwnerAggregateKey(aggregateType: $0.aggregateType, aggregateID: $0.aggregateID),
                    $0.sequence
                )
            }
        )
        deferredDomainEventsByMissingKey = Dictionary(grouping: snapshot.domainEventState.deferredEvents) { $0.missingKey }
        domainEventFullRefreshConversationIDs = Set(snapshot.domainEventState.fullRefreshConversationIDs)
        recordCacheDiagnostics(restoredState.diagnostics)
        isLoadingMoreConversationSummaries = false
        isLoadingMembers = detailState.isLoadingMembers
        isLoadingMessages = detailState.isLoadingMessages

        statusMessage = nil
        syncReplyJumpState()
        sortConversations()
    }

    private func recordCacheDiagnostics(_ diagnostics: IMCacheRestoreDiagnostics) {
        guard diagnostics.droppedCanonicalMessageCount > 0 || diagnostics.droppedTimelineNoticeCount > 0 else {
            return
        }
        domainEventDebugMetrics.cacheDroppedCanonicalMessages += diagnostics.droppedCanonicalMessageCount
        domainEventDebugMetrics.cacheDroppedTimelineNotices += diagnostics.droppedTimelineNoticeCount
        let conversationIDs = diagnostics.droppedCanonicalMessages.map(\.conversationID)
            + diagnostics.droppedCanonicalMessagesDuringSnapshot.map(\.conversationID)
            + diagnostics.droppedTimelineNotices.map(\.conversationID)
            + diagnostics.droppedTimelineNoticesDuringSnapshot.map(\.conversationID)
        for conversationID in conversationIDs {
            domainEventFullRefreshConversationIDs.insert(conversationID)
        }
    }

    private func ensureConversationIndex(for conversationID: String) -> Int {
        ensureConversationIndex(for: conversationID, conversations: &conversations)
    }

    private func ensureConversationIndex(
        for conversationID: String,
        conversations: inout [IMConversation]
    ) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }

        let conversation = IMConversation(
            id: conversationID,
            title: fallbackTitle(for: conversationID),
            kind: .group,
            directMessagingState: nil,
            directPeer: nil,
            notice: nil,
            avatarPreset: nil,
            memberCount: 0,
            memberUserIDs: [],
            members: [],
            messages: [],
            lastMessagePreviewText: "暂无消息",
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            isPinned: false,
            pinnedAt: nil,
            isMuted: false,
            draftText: "",
            draftUpdatedAt: nil,
            updatedAt: .distantPast
        )
        conversations.append(conversation)
        return conversations.count - 1
    }

    private func upsertConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        upsertConversationSummaryContent(response, conversations: &conversations)
        statusMessage = nil
        sortConversations()
    }

    private func upsertConversationSummaryContent(
        _ response: IMConversationSummaryResponseBody,
        conversations: inout [IMConversation]
    ) {
        let conversationID = response.id.uuidString
        let index = ensureConversationIndex(for: conversationID, conversations: &conversations)
        conversations[index] = conversationSummary(
            from: response,
            existing: conversations[index]
        )
    }

    private func upsertConversationSummaryContents(
        _ responses: [IMConversationSummaryResponseBody],
        conversations: inout [IMConversation]
    ) {
        guard !responses.isEmpty else {
            return
        }

        var indicesByID = Dictionary(
            uniqueKeysWithValues: conversations.indices.map { index in
                (conversations[index].id, index)
            }
        )

        for response in responses {
            let conversationID = response.id.uuidString
            if let index = indicesByID[conversationID],
               conversations.indices.contains(index) {
                conversations[index] = conversationSummary(
                    from: response,
                    existing: conversations[index]
                )
            } else {
                conversations.append(
                    conversationSummary(
                        from: response,
                        existing: nil
                    )
                )
                indicesByID[conversationID] = conversations.count - 1
            }
        }
    }

    private func shouldTreatLoadedTimelineAsSummaryOnly(_ conversation: IMConversation) -> Bool {
        guard conversation.messages.isEmpty,
              conversation.notices.isEmpty,
              conversation.pendingMessages.isEmpty
        else {
            return false
        }

        if conversation.unreadCount > 0 {
            return true
        }

        let preview = conversation.lastMessagePreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !preview.isEmpty && preview != "暂无消息"
    }

    private func conversationSummary(
        from response: IMConversationSummaryResponseBody,
        existing: IMConversation?
    ) -> IMConversation {
        let conversationID = response.id.uuidString
        let conversationKind = IMConversationKind(rawValue: response.kind) ?? .group
        let directPeer = directPeer(from: response, conversationKind: conversationKind)
        let previewText = messageDerivedStateReducer.mergedSummaryPreviewText(
            existing: existing,
            responseLastMessage: response.lastMessage
        )

        return IMConversation(
            id: conversationID,
            title: normalizedTitle(
                response.title,
                conversationID: conversationID,
                conversationKind: conversationKind,
                directPeer: directPeer
            ),
            kind: conversationKind,
            directMessagingState: directMessagingState(
                from: response.directMessagingState,
                conversationKind: conversationKind
            ),
            directPeer: directPeer,
            notice: response.notice,
            avatarPreset: response.avatarPreset,
            muteAll: response.muteAll,
            memberCount: response.memberCount,
            memberUserIDs: response.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            members: (existing?.members ?? []).filter { response.memberUserIDs.contains($0.id) },
            messages: existing?.messages ?? [],
            lastMessagePreviewText: previewText,
            hasMoreHistory: existing?.hasMoreHistory ?? false,
            serverLastReadSequence: UInt64(response.lastReadSequence),
            serverUnreadCount: response.unreadCount,
            localUnreadDelta: existing?.localUnreadDelta ?? 0,
            isPinned: response.isPinned,
            pinnedAt: response.pinnedAt,
            isMuted: response.isMuted,
            draftText: existing?.draftText ?? "",
            draftUpdatedAt: existing?.draftUpdatedAt,
            updatedAt: response.updatedAt
        )
    }

    private func applyIncomingMessageUnreadState(for conversationID: String) {
        if selectedConversationID == nil {
            selectedConversationID = conversationID
        }

        applyRealtimeUnreadIncrement(for: conversationID)
    }

    private func refreshLoadedTimelineCursors(
        for conversationID: String,
        timelineItems: [IMConversationTimelineItem]
    ) {
        detailState.refreshLoadedTimelineCursors(for: conversationID, timelineItems: timelineItems)
    }

    private func refreshLatestLoadedTimelineCursor(
        for conversationID: String,
        timelineItems: [IMConversationTimelineItem]
    ) {
        detailState.refreshLatestLoadedTimelineCursor(for: conversationID, timelineItems: timelineItems)
    }

    private func trimmedCachedMessages(
        _ messages: [IMConversationMessage],
        limit: Int
    ) -> [IMConversationMessage] {
        guard limit > 0, messages.count > limit else {
            return limit == 0 ? [] : messages
        }

        return Array(messages.suffix(limit))
    }

    private func resetUnreadState(for conversationIndex: Int) {
        resetUnreadState(for: conversationIndex, conversations: &conversations)
    }

    private func resetUnreadState(
        for conversationIndex: Int,
        conversations: inout [IMConversation]
    ) {
        conversations[conversationIndex].serverUnreadCount = 0
        conversations[conversationIndex].localUnreadDelta = 0
    }

    func syncReplyJumpState() {
        replyJumpConversationID = detailState.replyJumpConversationID
        replyJumpTargetMessageID = detailState.replyJumpTargetMessageID
        replyJumpMatchedMessageID = detailState.replyJumpMatchedMessageID
        replyJumpState = detailState.replyJumpState
    }

    private func reconciledLocalUnreadDelta(
        for conversationID: String,
        previousServerLastReadSequence: UInt64,
        previousServerUnreadCount: Int,
        previousLocalUnreadDelta: Int,
        updatedServerLastReadSequence: UInt64,
        updatedServerUnreadCount: Int,
        hasLatestLoadedServerSequence: Bool
    ) -> Int {
        guard previousLocalUnreadDelta > 0 else {
            return 0
        }

        guard updatedServerUnreadCount > 0 else {
            return 0
        }

        guard hasLatestLoadedServerSequence else {
            return previousLocalUnreadDelta
        }

        let previousTotalUnreadCount = previousServerUnreadCount + previousLocalUnreadDelta
        if updatedServerLastReadSequence > previousServerLastReadSequence
            || updatedServerUnreadCount >= previousTotalUnreadCount {
            return 0
        }

        return previousLocalUnreadDelta
    }

    private func mutateMessage(id: String, update: (inout IMConversationMessage) -> Void) {
        for conversationIndex in conversations.indices {
            guard let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == id }) else {
                continue
            }

            update(&conversations[conversationIndex].messages[messageIndex])
            conversations[conversationIndex].updatedAt = messageTimelineState.latestUpdatedAt(
                in: conversations[conversationIndex].messages,
                fallback: conversations[conversationIndex].messages[messageIndex].createdAt
            )
            conversations[conversationIndex].lastMessagePreviewText = messageTimelineState.latestPreviewText(
                in: conversations[conversationIndex].messages,
                fallback: conversations[conversationIndex].lastMessagePreviewText
            )
            sortConversations()
            return
        }
    }

    private func mutatePendingMessage(id: String, update: (inout IMPendingConversationMessage) -> Void) {
        for conversationIndex in conversations.indices {
            guard let messageIndex = conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == id }) else {
                continue
            }

            let oldState = conversations[conversationIndex].pendingMessages[messageIndex].deliveryState
            update(&conversations[conversationIndex].pendingMessages[messageIndex])
            let updatedMessage = conversations[conversationIndex].pendingMessages[messageIndex]
            let serverMessageID = updatedMessage.serverMessageID ?? "nil"
            conversations[conversationIndex].updatedAt = conversations[conversationIndex].pendingMessages[messageIndex].createdAt
            conversations[conversationIndex].lastMessagePreviewText = conversations[conversationIndex].pendingMessages[messageIndex].text
            sortConversations()
            let pendingCount = conversations[conversationIndex].pendingMessages.count
            let messageCount = conversations[conversationIndex].messages.count
            IMClientLog.conversationStore.debug(
                "Pending mutated conversationID=\(updatedMessage.conversationID, privacy: .public) localMessageID=\(updatedMessage.id, privacy: .public) clientMessageID=\(updatedMessage.clientMessageID, privacy: .public) serverMessageID=\(serverMessageID, privacy: .public) oldState=\(String(describing: oldState), privacy: .public) newState=\(String(describing: updatedMessage.deliveryState), privacy: .public) pendingCount=\(pendingCount, privacy: .public) messageCount=\(messageCount, privacy: .public)"
            )
            return
        }

        IMClientLog.conversationStore.warning(
            "Pending mutate skipped: localMessageID not found localMessageID=\(id, privacy: .public)"
        )
    }

    private func refreshConversationPresentationAfterLocalMessageRemoval(at conversationIndex: Int) {
        guard conversations.indices.contains(conversationIndex) else {
            return
        }

        if let latestPending = conversations[conversationIndex].pendingMessages.last {
            conversations[conversationIndex].lastMessagePreviewText = latestPending.text
            conversations[conversationIndex].updatedAt = latestPending.createdAt
        } else if let latestMessage = conversations[conversationIndex].messages.last {
            conversations[conversationIndex].lastMessagePreviewText = messageTimelineState.latestPreviewText(
                in: conversations[conversationIndex].messages,
                fallback: latestMessage.text
            )
            conversations[conversationIndex].updatedAt = messageTimelineState.latestUpdatedAt(
                in: conversations[conversationIndex].messages,
                fallback: latestMessage.createdAt
            )
        } else {
            conversations[conversationIndex].lastMessagePreviewText = ""
        }
    }

    private func sortConversations() {
        conversations.sort { left, right in
            if left.isPinned != right.isPinned {
                return left.isPinned && !right.isPinned
            }

            if left.isPinned && right.isPinned {
                switch (left.pinnedAt, right.pinnedAt) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs > rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            }

            if left.updatedAt == right.updatedAt {
                return left.id < right.id
            }
            return left.updatedAt > right.updatedAt
        }
        conversationMutationGeneration &+= 1
        let head = conversations.prefix(5).map { conversation in
            "\(conversation.id)|unread=\(conversation.unreadCount)|preview=\(conversation.lastMessagePreviewText)|updated=\(conversation.updatedAt.timeIntervalSince1970)|pending=\(conversation.pendingMessages.count)|messages=\(conversation.messages.count)|timeline=\(conversation.timelineItems.count)"
        }.joined(separator: " || ")
        let generation = conversationMutationGeneration
        let count = conversations.count
        let selectedConversationID = selectedConversationID ?? "nil"
        IMClientLog.conversationStore.debug(
            "Conversations sorted generation=\(generation, privacy: .public) count=\(count, privacy: .public) selected=\(selectedConversationID, privacy: .public) head=\(head, privacy: .public)"
        )
    }

    private func normalizedTitle(
        _ title: String?,
        conversationID: String,
        conversationKind: IMConversationKind,
        directPeer: IMDirectPeer?
    ) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        if conversationKind == .direct,
           let directPeer,
           !directPeer.email.isEmpty {
            return directPeer.email
        }
        return fallbackTitle(for: conversationID)
    }

    private func makeMessages(
        from responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) -> [IMConversationMessage] {
        responses.compactMap { response in
            do {
                return try IMConversationMessage(
                    id: response.id.uuidString,
                    conversationID: response.conversationID.uuidString,
                    clientMessageID: response.clientMessageID,
                    serverMessageID: response.id.uuidString,
                    senderUserID: response.senderUserID,
                    serverSequence: UInt64(response.serverSequence),
                    timelineSequence: UInt64(response.timelineSequence),
                    content: response.content,
                    derivedState: response.derivedState,
                    direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                    createdAt: response.createdAt ?? .distantPast,
                    deliveryState: response.senderUserID == currentUserID ? .sent : .received
                )
            } catch {
                domainEventDebugMetrics.invalidCanonicalMessageDTOs += 1
                domainEventFullRefreshConversationIDs.insert(response.conversationID.uuidString)
                return nil
            }
        }
    }

    private func makeNotices(
        from responses: [IMTimelineNoticeResponseBody]
    ) -> [IMTimelineNotice] {
        responses.compactMap { response in
            do {
                return try IMTimelineNotice(
                    id: response.id.uuidString,
                    conversationID: response.conversationID.uuidString,
                    timelineSequence: UInt64(response.timelineSequence),
                    eventType: response.eventType,
                    actorUserID: response.actorUserID,
                    targetUserIDs: response.targetUserIDs,
                    noticeKind: response.noticeKind,
                    params: response.params,
                    fallbackText: response.fallbackText,
                    createdAt: response.createdAt
                )
            } catch {
                domainEventDebugMetrics.invalidProjectionDTOs += 1
                domainEventFullRefreshConversationIDs.insert(response.conversationID.uuidString)
                return nil
            }
        }
    }

    private func mergeMessages(
        existing: [IMConversationMessage],
        serverMessages: [IMConversationMessage],
        preserveExistingServerMessages: Bool
    ) -> [IMConversationMessage] {
        var merged = preserveExistingServerMessages
            ? existing
            : []

        for serverMessage in serverMessages {
            if let existingIndex = merged.firstIndex(where: { Self.matches($0, serverMessage) }) {
                merged[existingIndex] = serverMessage
            } else {
                merged.append(serverMessage)
            }
        }

        return merged.sorted(by: Self.messageComparator)
    }

    private func hasOlderHistory(in serverMessages: [IMConversationMessage]) -> Bool {
        guard let oldestSequence = serverMessages.map(\.serverSequence).min() else {
            return false
        }

        return oldestSequence > 1
    }

    private func sortMembers(lhs: IMConversationMember, rhs: IMConversationMember) -> Bool {
        let lhsPriority = memberRolePriority(lhs.role)
        let rhsPriority = memberRolePriority(rhs.role)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        return lhs.email < rhs.email
    }

    private static func members(from responses: [IMConversationMemberResponseBody]) -> [IMConversationMember] {
        responses.map {
            IMConversationMember(
                id: $0.id,
                email: $0.email,
                displayName: $0.displayName,
                avatarPreset: $0.avatarPreset,
                role: $0.role,
                memberNickname: $0.memberNickname,
                displayTitle: $0.displayTitle
            )
        }
    }

    private static func uniqueMembers(_ members: [IMConversationMember]) -> [IMConversationMember] {
        var seenIDs = Set<UUID>()
        var result: [IMConversationMember] = []
        for member in members where seenIDs.insert(member.id).inserted {
            result.append(member)
        }
        return result
    }

    private func memberRolePriority(_ role: IMConversationMemberRole) -> Int {
        switch role {
        case .owner:
            return 0
        case .admin:
            return 1
        case .member:
            return 2
        }
    }

    private func fallbackTitle(for conversationID: String) -> String {
        "会话 \(conversationID.prefix(8).lowercased())"
    }

    private func directMessagingState(
        from rawValue: String?,
        conversationKind: IMConversationKind
    ) -> IMDirectMessagingState? {
        guard conversationKind == .direct else {
            return nil
        }

        guard let rawValue,
              let state = IMDirectMessagingState(rawValue: rawValue)
        else {
            return .active
        }

        return state
    }

    private func directPeer(
        from response: IMConversationSummaryResponseBody,
        conversationKind: IMConversationKind
    ) -> IMDirectPeer? {
        guard conversationKind == .direct,
              let directPeer = response.directPeer
        else {
            return nil
        }

        return IMDirectPeer(
            id: directPeer.id,
            email: directPeer.email,
            displayName: directPeer.displayName,
            avatarPreset: directPeer.avatarPreset
        )
    }

    private func outgoingAcknowledgementFailureMessage(for status: String) -> String {
        switch status {
        case "direct_conversation_frozen":
            return "你们已不是好友，当前会话不能继续发送消息。"
        case "stranger_direct_message_limit_reached":
            return "你们还不是好友，对方回复前只能发送一条消息。"
        case "invalid_conversation_id":
            return "会话 ID 无效。"
        case "conversation_unavailable":
            return "会话不存在或你已不在该会话中。"
        case "unsupported_message_content":
            return "当前消息类型不支持发送。"
        case "empty_text_body":
            return "消息内容不能为空。"
        case "internal_error":
            return "消息发送失败，请稍后重试。"
        default:
            return "消息发送失败：\(status)"
        }
    }

    private static func restoredDeliveryState(_ state: IMMessageDeliveryState) -> IMMessageDeliveryState {
        switch state {
        case .sending:
            return .unknown(message: "发送状态未确认，请重试。")
        case .preparing, .uploading, .uploaded:
            return state
        case .queued, .sent, .received, .unknown, .failed:
            return state
        }
    }

    private func startQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == localMessageID })
        else {
            return nil
        }

        var message = conversations[conversationIndex].pendingMessages[messageIndex]
        guard message.direction == .outgoing, message.isQueued else {
            return nil
        }

        let clientMessageID = message.clientMessageID
        let requestID = UUID()
        message.deliveryState = .sending
        conversations[conversationIndex].pendingMessages[messageIndex] = message
        outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: conversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: message.content
            )
        )
    }

    private static let nonRetryableOutgoingFailureMessages: Set<String> = [
        "你们已不是好友，当前会话不能继续发送消息。",
        "你们还不是好友，对方回复前只能发送一条消息。",
        "会话 ID 无效。",
        "会话不存在或你已不在该会话中。",
        "当前消息类型不支持发送。",
        "消息内容不能为空。",
        "附件上传失败，请稍后重试。"
    ]

    private func appendOutgoingMessage(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            statusMessage = "当前没有可用会话。"
            return (nil, nil)
        }

        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return (nil, nil)
        }

        guard !content.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "消息内容不能为空。"
            return (nil, nil)
        }

        let requestID = UUID()
        let clientMessageID = UUID().uuidString
        let localMessageID = clientMessageID
        let createdAt = Date()
        let index = ensureConversationIndex(for: trimmedConversationID)
        let message = IMPendingConversationMessage(
            localMessageID: localMessageID,
            clientMessageID: clientMessageID,
            conversationID: trimmedConversationID,
            senderUserID: senderUserID,
            content: content,
            createdAt: createdAt,
            deliveryState: deliveryState,
            localTransferState: localTransferState
        )

        conversations[index].pendingMessages.append(message)
        conversations[index].lastMessagePreviewText = content.previewText
        conversations[index].updatedAt = createdAt
        conversations[index].draftText = ""
        conversations[index].draftUpdatedAt = nil
        resetUnreadState(for: index)
        selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            outgoingQueueState.registerPendingRequest(requestID, localMessageID: localMessageID)
        }
        statusMessage = nil
        sortConversations()
        let pendingCount = conversations[index].pendingMessages.count
        let messageCount = conversations[index].messages.count
        IMClientLog.conversationStore.debug(
            "Outgoing pending created conversationID=\(trimmedConversationID, privacy: .public) localMessageID=\(localMessageID, privacy: .public) clientMessageID=\(clientMessageID, privacy: .public) deliveryState=\(String(describing: deliveryState), privacy: .public) previewLength=\(content.previewText.count, privacy: .public) pendingCount=\(pendingCount, privacy: .public) messageCount=\(messageCount, privacy: .public)"
        )

        let payload = IMTCPMessagePayload(
            clientMessageID: clientMessageID,
            messageID: nil,
            conversationID: trimmedConversationID,
            senderUserID: nil,
            serverSequence: nil,
            serverTimestamp: nil,
            content: content
        )
        let request = shouldRegisterPendingRequest
            ? IMOutgoingMessageRequest(
                requestID: requestID,
                localMessageID: localMessageID,
                payload: payload
            )
            : nil
        return (
            IMOutgoingMediaPlaceholder(localMessageID: localMessageID, clientMessageID: clientMessageID),
            request
        )
    }

    private func updateUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) -> (didUpdate: Bool, request: IMOutgoingMessageRequest?) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocalMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedLocalMessageID.isEmpty else {
            return (false, nil)
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].pendingMessages.firstIndex(where: { $0.id == trimmedLocalMessageID })
        else {
            statusMessage = "附件消息不存在。"
            return (false, nil)
        }

        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return (false, nil)
        }

        let requestID = UUID()
        var message = conversations[conversationIndex].pendingMessages[messageIndex]
        message.content = content
        message.deliveryState = deliveryState
        message.localTransferState = nil
        conversations[conversationIndex].pendingMessages[messageIndex] = message
        conversations[conversationIndex].lastMessagePreviewText = content.previewText
        conversations[conversationIndex].updatedAt = message.createdAt
        selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        }
        statusMessage = nil
        sortConversations()

        guard shouldRegisterPendingRequest else {
            return (true, nil)
        }

        let request = IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: message.clientMessageID,
                messageID: nil,
                conversationID: trimmedConversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: content
            )
        )
        return (true, request)
    }

    private func mediaContent(for asset: IMMediaAsset) -> IMMessageContent {
        switch asset.kind {
        case .image:
            return .image(asset)
        case .audio:
            return .audio(asset)
        case .file:
            return .file(asset)
        }
    }

    private static func matches(_ left: IMConversationMessage, _ right: IMConversationMessage) -> Bool {
        if left.serverMessageID == right.serverMessageID {
            return true
        }

        if let leftClientMessageID = left.clientMessageID,
           let rightClientMessageID = right.clientMessageID,
           leftClientMessageID == rightClientMessageID {
            return true
        }

        if left.serverSequence == right.serverSequence,
           left.conversationID == right.conversationID {
            return true
        }

        return false
    }

    private static let messageComparator: (IMConversationMessage, IMConversationMessage) -> Bool = { left, right in
        if left.serverSequence == right.serverSequence {
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }
        return left.serverSequence < right.serverSequence
    }
}

private extension IMPendingConversationMessage {
    var isQueued: Bool {
        if case .queued = deliveryState {
            return true
        }

        return false
    }
}
