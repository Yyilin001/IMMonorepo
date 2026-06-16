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
    private let clientStateEngine = IMConversationClientStateEngine()
    private let conversationListStore = ConversationListStore()
    private let conversationStateReducer = IMConversationStoreStateReducer()
    var detailState = ConversationDetailState()
    var outgoingQueueState = OutgoingQueueState()
    private let conversationOutgoingStateReducer = IMConversationOutgoingStateReducer()
    var conversationSearchState = ConversationSearchState()
    private let messageTimelineState = MessageTimelineState()
    private let conversationMessageStateReducer = IMConversationMessageStateReducer()
    private let conversationTimelineStore = ConversationTimelineStore()
    private let conversationTimelineStateReducer = IMConversationTimelineStateReducer()
    private let conversationLoadingStateReducer = IMConversationLoadingStateReducer()
    private let messageDerivedStateReducer = MessageDerivedStateReducer()
    private let domainEventProjectionReducer = DomainEventProjectionReducer()
    private let domainEventStateReducer = IMConversationDomainEventStateReducer()
    private let domainEventDependencyStateReducer = IMConversationDomainEventDependencyStateReducer()
    private let deferredDomainEventStateReducer = IMConversationDeferredDomainEventStateReducer()
    private var pendingStreamSnapshotTargets: Set<IMActiveMessageStreamTarget> = []
    private var processedDomainEventIDs: Set<UUID> = []
    private var processedDomainEventIDOrder: [UUID] = []
    private var deferredDomainEventsByMissingKey: [IMDeferredDomainEventMissingKey: [IMDeferredDomainEventState]] = [:]
    private var domainEventFullRefreshConversationIDs: Set<String> = []
    private var ownerAggregateHighWatermarks: [IMOwnerAggregateKey: UInt64] = [:]
    private var domainEventCursor: UInt64 = 0
    public private(set) var domainEventDebugMetrics = IMDomainEventDebugMetrics()
    public private(set) var timelineCatchUpDiagnostics = IMTimelineCatchUpDiagnostics()
    private var pendingTimelineCatchUpHints: [String: Date] = [:]
    private var pendingTimelineCatchUpRequests: [String: Date] = [:]

    public init() { }

    public func reset() {
        conversationMutationGeneration &+= 1
        var snapshot = clientStateSnapshot()
        snapshot.conversations = []
        snapshot.selectedConversationID = nil
        snapshot.statusMessage = nil
        snapshot.isLoadingConversations = false
        snapshot.conversationSummaryNextCursor = nil
        snapshot.hasMoreConversationSummaries = false
        snapshot.isLoadingMoreConversationSummaries = false
        snapshot.detailState = ConversationDetailState()
        snapshot.outgoingQueueState = OutgoingQueueState()
        snapshot.conversationSearchState = ConversationSearchState()
        applyClientStateSnapshot(snapshot)
        timelineCatchUpDiagnostics = IMTimelineCatchUpDiagnostics()
        pendingTimelineCatchUpHints = [:]
        pendingTimelineCatchUpRequests = [:]
    }

    public func recordTimelineCatchUpHintQueued(
        conversationID: String,
        targetTimelineSequence: UInt64?,
        queuedAt: Date = Date()
    ) {
        let conversationID = normalizedConversationID(conversationID)
        guard !conversationID.isEmpty else { return }
        pendingTimelineCatchUpHints[conversationID] = queuedAt
        timelineCatchUpDiagnostics.hintQueuedCount += 1
        timelineCatchUpDiagnostics.lastConversationID = conversationID
        timelineCatchUpDiagnostics.lastTargetTimelineSequence = targetTimelineSequence
        timelineCatchUpDiagnostics.lastFailureReason = nil
    }

    public func recordTimelineCatchUpSkippedAlreadyLoaded(
        conversationID: String,
        targetTimelineSequence: UInt64?
    ) {
        let conversationID = normalizedConversationID(conversationID)
        guard !conversationID.isEmpty else { return }
        pendingTimelineCatchUpHints.removeValue(forKey: conversationID)
        pendingTimelineCatchUpRequests.removeValue(forKey: conversationID)
        timelineCatchUpDiagnostics.hintSkippedAlreadyLoadedCount += 1
        timelineCatchUpDiagnostics.lastConversationID = conversationID
        timelineCatchUpDiagnostics.lastTargetTimelineSequence = targetTimelineSequence
        timelineCatchUpDiagnostics.lastFailureReason = nil
    }

    public func recordTimelineCatchUpDeferred(
        conversationID: String,
        targetTimelineSequence: UInt64?,
        reason: String
    ) {
        let conversationID = normalizedConversationID(conversationID)
        guard !conversationID.isEmpty else { return }
        timelineCatchUpDiagnostics.deferredCount += 1
        timelineCatchUpDiagnostics.lastConversationID = conversationID
        timelineCatchUpDiagnostics.lastTargetTimelineSequence = targetTimelineSequence
        timelineCatchUpDiagnostics.lastFailureReason = reason
    }

    public func recordTimelineCatchUpSinceRequestStarted(
        conversationID: String,
        afterSequence: UInt64,
        targetTimelineSequence: UInt64?,
        startedAt: Date = Date()
    ) {
        let conversationID = normalizedConversationID(conversationID)
        guard !conversationID.isEmpty else { return }
        pendingTimelineCatchUpRequests[conversationID] = startedAt
        timelineCatchUpDiagnostics.sinceRequestCount += 1
        timelineCatchUpDiagnostics.lastConversationID = conversationID
        timelineCatchUpDiagnostics.lastAfterSequence = afterSequence
        timelineCatchUpDiagnostics.lastTargetTimelineSequence = targetTimelineSequence
        timelineCatchUpDiagnostics.lastFailureReason = nil
        if let hintQueuedAt = pendingTimelineCatchUpHints[conversationID] {
            timelineCatchUpDiagnostics.lastHintToRequestMilliseconds = elapsedMilliseconds(
                from: hintQueuedAt,
                to: startedAt
            )
        }
    }

    public func recordTimelineCatchUpSinceRequestFinished(
        conversationID: String,
        success: Bool,
        finishedAt: Date = Date(),
        failureReason: String? = nil
    ) {
        let conversationID = normalizedConversationID(conversationID)
        guard !conversationID.isEmpty else { return }
        if success {
            timelineCatchUpDiagnostics.sinceSuccessCount += 1
        } else {
            timelineCatchUpDiagnostics.sinceFailureCount += 1
        }
        if let startedAt = pendingTimelineCatchUpRequests.removeValue(forKey: conversationID) {
            timelineCatchUpDiagnostics.lastRequestMilliseconds = elapsedMilliseconds(
                from: startedAt,
                to: finishedAt
            )
        }
        timelineCatchUpDiagnostics.lastConversationID = conversationID
        timelineCatchUpDiagnostics.lastFailureReason = failureReason
    }

    public func recordTimelineCatchUpPageApplied(
        conversationID: String,
        itemCount: Int,
        latestTimelineSequence: UInt64?,
        appliedAt: Date = Date()
    ) {
        let conversationID = normalizedConversationID(conversationID)
        guard !conversationID.isEmpty else { return }
        timelineCatchUpDiagnostics.appliedPageCount += 1
        timelineCatchUpDiagnostics.appliedItemCount += max(itemCount, 0)
        timelineCatchUpDiagnostics.lastConversationID = conversationID
        timelineCatchUpDiagnostics.lastAppliedLatestTimelineSequence = latestTimelineSequence
        timelineCatchUpDiagnostics.lastFailureReason = nil
        if let hintQueuedAt = pendingTimelineCatchUpHints.removeValue(forKey: conversationID) {
            timelineCatchUpDiagnostics.lastHintToApplyMilliseconds = elapsedMilliseconds(
                from: hintQueuedAt,
                to: appliedAt
            )
        }
    }

    public func openConversation(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            setStatusMessage("当前没有可用会话。")
            return
        }

        _ = ensureConversationIndex(for: trimmedID)
        selectedConversationID = trimmedID
        setStatusMessage(nil)
        sortConversations()
    }

    public func replaceConversationSummaries(_ responses: [IMConversationSummaryResponseBody]) {
        reduceConversationState(.replaceConversationSummaries(responses))
    }

    public func applyConversationSummaryPage(_ responses: [IMConversationSummaryResponseBody]) {
        reduceConversationState(.applyConversationSummaryPage(responses))
    }

    public func applyConversationSummaryChanges(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID]
    ) {
        reduceConversationState(
            .applyConversationSummaryChanges(
                upserts: upserts,
                removedConversationIDs: removedConversationIDs
            )
        )
    }

    public func replaceConversationSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) {
        reduceConversationState(
            .replaceConversationSummaryWindow(
                responses,
                nextCursor: nextCursor,
                hasMore: hasMore
            )
        )
    }

    public func replaceConversationSummaryWindowAsync(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) async {
        await reduceConversationStateUsingClientEngine(
            .replaceConversationSummaryWindow(
                responses,
                nextCursor: nextCursor,
                hasMore: hasMore
            )
        )
    }

    public func appendConversationSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) {
        reduceConversationState(
            .appendConversationSummaryWindow(
                responses,
                nextCursor: nextCursor,
                hasMore: hasMore
            )
        )
    }

    public func appendConversationSummaryWindowAsync(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) async {
        await reduceConversationStateUsingClientEngine(
            .appendConversationSummaryWindow(
                responses,
                nextCursor: nextCursor,
                hasMore: hasMore
            )
        )
    }

    public func removeConversationSummaries(notIn conversationIDs: Set<String>) {
        reduceConversationState(.removeConversationSummariesNotIn(conversationIDs))
    }

    public func applyConversationSummaryContents(_ responses: [IMConversationSummaryResponseBody]) {
        reduceConversationState(.replaceConversationSummaries(responses))
    }

    public func applyConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        reduceConversationState(.applyConversationSummaryContent(response))
    }

    public func removeConversation(id: String) {
        reduceConversationState(.removeConversation(id: id))
    }

    public func removeConversationAsync(id: String) async {
        await reduceConversationStateUsingClientEngine(.removeConversation(id: id))
    }

    public func markConversationRead(id: String) {
        reduceConversationState(
            .markConversationRead(
                conversationID: id,
                latestLoadedSequence: latestLoadedMessageSequence(for: id)
            )
        )
    }

    public func markConversationReadAsync(id: String) async {
        await reduceConversationStateUsingClientEngine(
            .markConversationRead(
                conversationID: id,
                latestLoadedSequence: latestLoadedMessageSequence(for: id)
            )
        )
    }

    public func markConversationUnread(id: String) {
        reduceConversationState(.markConversationUnread(conversationID: id))
    }

    public func markConversationUnreadAsync(id: String) async {
        await reduceConversationStateUsingClientEngine(.markConversationUnread(conversationID: id))
    }

    public func applyServerSummaryReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        reduceConversationState(
            .applyServerSummaryReadState(
                conversationID: conversationID,
                lastReadSequence: lastReadSequence,
                unreadCount: unreadCount
            )
        )
    }

    public func applyServerSummaryReadStateAsync(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) async {
        await reduceConversationStateUsingClientEngine(
            .applyServerSummaryReadState(
                conversationID: conversationID,
                lastReadSequence: lastReadSequence,
                unreadCount: unreadCount
            )
        )
    }

    public func removeMessages(ids messageIDs: Set<String>, from conversationID: String) {
        reduceMessageState(
            .removeMessages(
                ids: messageIDs,
                conversationID: conversationID
            )
        )
    }

    public func removeMessagesAsync(ids messageIDs: Set<String>, from conversationID: String) async {
        await reduceMessageStateUsingClientEngine(
            .removeMessages(
                ids: messageIDs,
                conversationID: conversationID
            )
        )
    }

    public func clearMessages(in conversationID: String) {
        reduceMessageState(.clearMessages(conversationID: conversationID))
    }

    public func clearMessagesAsync(in conversationID: String) async {
        await reduceMessageStateUsingClientEngine(.clearMessages(conversationID: conversationID))
    }

    public func applyServerSummaryReadStates(_ responses: [IMConversationSummaryResponseBody]) {
        for response in responses {
            applyServerSummaryReadState(
                lastReadSequence: UInt64(response.lastReadSequence),
                unreadCount: response.unreadCount,
                for: response.id.uuidString
            )
        }
    }

    public func applyServerSummaryReadStatesAsync(_ responses: [IMConversationSummaryResponseBody]) async {
        for response in responses {
            await applyServerSummaryReadStateAsync(
                lastReadSequence: UInt64(response.lastReadSequence),
                unreadCount: response.unreadCount,
                for: response.id.uuidString
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

    public func applyServerSummaryReadStateAsync(_ response: IMConversationSummaryResponseBody) async {
        await applyServerSummaryReadStateAsync(
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

    public func applyServerExplicitReadResponseAsync(_ response: IMConversationReadResponseBody) async {
        await applyServerReadStateAsync(
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
        reduceConversationState(
            .applyServerReadState(
                conversationID: conversationID,
                lastReadSequence: lastReadSequence,
                unreadCount: unreadCount
            )
        )
    }

    public func applyServerReadStateAsync(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) async {
        await reduceConversationStateUsingClientEngine(
            .applyServerReadState(
                conversationID: conversationID,
                lastReadSequence: lastReadSequence,
                unreadCount: unreadCount
            )
        )
    }

    public func applyRealtimeUnreadIncrement(for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let unreadBefore = conversations.first(where: { $0.id == trimmedConversationID })?.unreadCount ?? -1
        let selectedBefore = selectedConversationID ?? "nil"
        reduceConversationState(.applyRealtimeUnreadIncrement(conversationID: conversationID))
        let unreadAfter = conversations.first(where: { $0.id == trimmedConversationID })?.unreadCount ?? -1
        IMClientLog.conversationStore.debug(
            "Realtime unread increment conversationID=\(trimmedConversationID, privacy: .public) selectedBefore=\(selectedBefore, privacy: .public) unreadBefore=\(unreadBefore, privacy: .public) unreadAfter=\(unreadAfter, privacy: .public)"
        )
    }

    public func applyRealtimeUnreadIncrementAsync(for conversationID: String) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let unreadBefore = conversations.first(where: { $0.id == trimmedConversationID })?.unreadCount ?? -1
        let selectedBefore = selectedConversationID ?? "nil"
        await reduceConversationStateUsingClientEngine(.applyRealtimeUnreadIncrement(conversationID: conversationID))
        let unreadAfter = conversations.first(where: { $0.id == trimmedConversationID })?.unreadCount ?? -1
        IMClientLog.conversationStore.debug(
            "Realtime unread increment async conversationID=\(trimmedConversationID, privacy: .public) selectedBefore=\(selectedBefore, privacy: .public) unreadBefore=\(unreadBefore, privacy: .public) unreadAfter=\(unreadAfter, privacy: .public)"
        )
    }

    public func applyServerUnreadCount(_ unreadCount: Int, for conversationID: String) {
        reduceConversationState(
            .applyServerUnreadCount(
                conversationID: conversationID,
                unreadCount: unreadCount
            )
        )
    }

    public func applyServerUnreadCountAsync(_ unreadCount: Int, for conversationID: String) async {
        await reduceConversationStateUsingClientEngine(
            .applyServerUnreadCount(
                conversationID: conversationID,
                unreadCount: unreadCount
            )
        )
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

    public func applyDomainEventAsync(
        _ payload: IMTCPChatDomainEventPayload,
        currentUserID: UUID
    ) async -> IMConversationEventApplyOutcome {
        await clientStateEngine.replaceState(clientStateSnapshot())
        var dependencies = await clientStateEngine.dependencySnapshot()
        return await applyDomainEventAsync(
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
        let shouldRefreshConversationSummaries = shouldRefreshConversationSummariesAfterConsuming(payload)

        switch operation {
        case .ignoreDuplicate:
            recordOwnerAggregateHighWatermark(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
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
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyMessageMutation(_, let message, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            if let message {
                applyUpdatedMessage(message)
            }
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

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
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyMessageFavorite(_, _, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            reduceConversationState(.setStatusMessage(nil))
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyMessageStream(let stream, let message, let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            applyMessageStreamEvent(stream: stream, message: message)
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyConversationChange(let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            let isActivityOnlySummaryHint = isActivityOnlyConversationSummaryHint(payload)
            let shouldApplyActivitySummary = shouldApplyActivityOnlyConversationSummary(
                payload,
                isActivityOnlySummaryHint: isActivityOnlySummaryHint
            )
            let timelineSyncTarget = selectedConversationTimelineSyncTarget(
                for: payload,
                isActivityOnlySummaryHint: isActivityOnlySummaryHint
            )
            if shouldApplyActivitySummary {
                applySummaryIfPresent(summary, applyReadState: !isActivityOnlySummaryHint)
            }
            applyActivityOnlyConversationHintUnreadIfNeeded(
                payload,
                currentUserID: currentUserID,
                isActivityOnlySummaryHint: isActivityOnlySummaryHint
            )
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldSyncTimelineForConversationID: timelineSyncTarget?.conversationID,
                timelineSyncTargetSequence: timelineSyncTarget?.targetTimelineSequence,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .removeConversation(let conversationID, let notice):
            if let notice {
                upsertTimelineNotice(notice)
            }
            removeConversation(id: conversationID)
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

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
            recordConsumedDomainEvent(payload)
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
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyContactChange(let notice, let summary):
            if let notice {
                upsertTimelineNotice(notice)
            }
            applySummaryIfPresent(summary)
            recordConsumedDomainEvent(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )
        }
    }

    private func applyDomainEventAsync(
        _ payload: IMTCPChatDomainEventPayload,
        currentUserID: UUID,
        dependencies: inout DomainEventProjectionReducer.DependencySnapshot
    ) async -> IMConversationEventApplyOutcome {
        let operation = domainEventProjectionReducer.reduce(
            event: payload,
            currentUserID: currentUserID,
            dependencies: dependencies
        )
        let operationName = domainEventOperationDebugName(operation)
        IMClientLog.conversationStore.debug(
            "Domain event reduced async eventID=\(payload.eventID.uuidString, privacy: .public) eventType=\(payload.eventType.rawValue, privacy: .public) aggregateID=\(payload.aggregateID.uuidString, privacy: .public) aggregateSequence=\(payload.aggregateSequence, privacy: .public) ownerCursor=\(payload.ownerCursor ?? 0, privacy: .public) ownerAggregateSequence=\(payload.ownerAggregateSequence ?? 0, privacy: .public) operation=\(operationName, privacy: .public) summaryID=\(payload.conversation?.id.uuidString ?? "nil", privacy: .public) summaryPreview=\(payload.conversation?.lastMessage?.previewText ?? "nil", privacy: .public) summaryUnread=\(payload.conversation?.unreadCount ?? -1, privacy: .public)"
        )
        let shouldRefreshConversationSummaries = shouldRefreshConversationSummariesAfterConsuming(payload)

        switch operation {
        case .ignoreDuplicate:
            await recordOwnerAggregateHighWatermarkAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)
        case .requestCatchUp:
            await clientStateEngine.replaceState(clientStateSnapshot())
            await clientStateEngine.recordMissingRequiredNoticeCatchUp()
            applyClientStateSnapshot(await clientStateEngine.snapshot())
            await clientStateEngine.replaceState(clientStateSnapshot())
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldFetchDomainEvents: true,
                didConsumeEvent: false
            )
        case .rejectInvalid:
            await clientStateEngine.replaceState(clientStateSnapshot())
            await clientStateEngine.recordInvalidProjectionCatchUp()
            applyClientStateSnapshot(await clientStateEngine.snapshot())
            await clientStateEngine.replaceState(clientStateSnapshot())
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldFetchDomainEvents: true,
                didConsumeEvent: false
            )
        case .deferEvent(let reason, let missingKey, let conversationID):
            IMClientLog.conversationStore.debug(
                "Domain event deferred async eventID=\(payload.eventID.uuidString, privacy: .public) eventType=\(payload.eventType.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) missingKey=\(String(describing: missingKey), privacy: .public) conversationID=\(conversationID ?? "nil", privacy: .public)"
            )
            let deferResult = await deferDomainEventAsync(
                payload,
                missingKey: missingKey,
                conversationID: conversationID
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldFetchDomainEvents: true,
                didConsumeEvent: deferResult.didConsumeEvent
            )
        case .applyMessageCreated(let message, let clientMessageID, let notice, let summary):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            await applyCreatedMessageAsync(
                message,
                clientMessageID: clientMessageID
            )
            await applySummaryIfPresentAsync(summary)
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyMessageMutation(_, let message, let notice, let summary):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            await applySummaryIfPresentAsync(summary)
            if let message {
                await applyUpdatedMessageAsync(message)
            }
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyVisibility(let conversationID, let messageIDs, let message, let visibilityAction, let notice, let summary):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            await applySummaryIfPresentAsync(summary)
            var eventMessageIDs = Set(messageIDs.map(\.uuidString))
            if let message {
                eventMessageIDs.insert(message.serverMessageID)
            }
            if visibilityAction == .messageHidden, !eventMessageIDs.isEmpty {
                await removeMessagesAsync(ids: eventMessageIDs, from: conversationID)
            }
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyMessageFavorite(_, _, let notice, let summary):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            await applySummaryIfPresentAsync(summary)
            await reduceConversationStateUsingClientEngine(.setStatusMessage(nil))
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyMessageStream(let stream, let message, let notice, let summary):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            await applySummaryIfPresentAsync(summary)
            await applyMessageStreamEventAsync(stream: stream, message: message)
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyConversationChange(let notice, let summary):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            let isActivityOnlySummaryHint = isActivityOnlyConversationSummaryHint(payload)
            let shouldApplyActivitySummary = shouldApplyActivityOnlyConversationSummary(
                payload,
                isActivityOnlySummaryHint: isActivityOnlySummaryHint
            )
            let timelineSyncTarget = selectedConversationTimelineSyncTarget(
                for: payload,
                isActivityOnlySummaryHint: isActivityOnlySummaryHint
            )
            if isActivityOnlySummaryHint {
                if shouldApplyActivitySummary {
                    applySummaryIfPresent(summary, applyReadState: false)
                }
                applyActivityOnlyConversationHintUnreadIfNeeded(
                    payload,
                    currentUserID: currentUserID,
                    isActivityOnlySummaryHint: true
                )
                await clientStateEngine.replaceState(clientStateSnapshot())
            } else {
                await applySummaryIfPresentAsync(summary)
                await applyActivityOnlyConversationHintUnreadIfNeededAsync(
                    payload,
                    currentUserID: currentUserID,
                    isActivityOnlySummaryHint: false
                )
            }
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldSyncTimelineForConversationID: timelineSyncTarget?.conversationID,
                timelineSyncTargetSequence: timelineSyncTarget?.targetTimelineSequence,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .removeConversation(let conversationID, let notice):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            await removeConversationAsync(id: conversationID)
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyConversationVisibility(let conversationID, let visibilityAction, let messageIDs, let notice, let summary):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            switch visibilityAction {
            case .conversationCleared:
                await applySummaryIfPresentAsync(summary)
                await clearMessagesAsync(in: conversationID)
            case .conversationDeleted:
                await removeConversationAsync(id: conversationID)
            case .messageHidden:
                await removeMessagesAsync(ids: Set(messageIDs.map(\.uuidString)), from: conversationID)
            }
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .applyMemberChange(let conversationID, _, let notice, let summary):
            let selectedConversationIDBeforeApply = selectedConversationID
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            await applySummaryIfPresentAsync(summary)
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )

        case .applyContactChange(let notice, let summary):
            if let notice {
                await upsertTimelineNoticeAsync(notice)
            }
            await applySummaryIfPresentAsync(summary)
            await recordConsumedDomainEventAsync(payload)
            updateDomainEventDependencySnapshot(
                &dependencies,
                afterConsuming: payload,
                operation: operation
            )
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: nil,
                shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
            )
        }
    }

    public func applyDomainEvents(
        _ envelopes: [SessionClient.IMDomainEventDeliveryEnvelope],
        nextCursor: UInt64,
        currentUserID: UUID
    ) -> IMConversationEventApplyOutcome {
        var shouldReloadMembersForConversationID: String?
        var shouldSyncTimelineForConversationID: String?
        var timelineSyncTargetSequence: UInt64?
        var shouldFetchDomainEvents = false
        var shouldRefreshConversationSummaries = false
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
            if let conversationID = outcome.shouldSyncTimelineForConversationID {
                shouldSyncTimelineForConversationID = conversationID
                timelineSyncTargetSequence = outcome.timelineSyncTargetSequence
            }
            shouldFetchDomainEvents = shouldFetchDomainEvents || outcome.shouldFetchDomainEvents
            shouldRefreshConversationSummaries = shouldRefreshConversationSummaries
                || outcome.shouldRefreshConversationSummaries
            guard outcome.didConsumeEvent else {
                domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
                break
            }
            lastConsumedCursor = envelope.cursor
        }
        reduceDomainEventState(.advanceCursor(lastConsumedCursor))
        replayDeferredDomainEvents(currentUserID: currentUserID)
        return IMConversationEventApplyOutcome(
            shouldReloadMembersForConversationID: shouldReloadMembersForConversationID,
            shouldSyncTimelineForConversationID: shouldSyncTimelineForConversationID,
            timelineSyncTargetSequence: timelineSyncTargetSequence,
            shouldFetchDomainEvents: shouldFetchDomainEvents,
            shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
        )
    }

    public func applyDomainEventsAsync(
        _ envelopes: [SessionClient.IMDomainEventDeliveryEnvelope],
        nextCursor: UInt64,
        currentUserID: UUID
    ) async -> IMConversationEventApplyOutcome {
        await clientStateEngine.replaceState(clientStateSnapshot())
        var shouldReloadMembersForConversationID: String?
        var shouldSyncTimelineForConversationID: String?
        var timelineSyncTargetSequence: UInt64?
        var shouldFetchDomainEvents = false
        var shouldRefreshConversationSummaries = false
        var lastConsumedCursor = (await clientStateEngine.snapshot()).domainEventCursor
        var dependencies = await clientStateEngine.dependencySnapshot()
        for envelope in envelopes {
            guard envelope.cursor == lastConsumedCursor + 1 else {
                await clientStateEngine.recordCatchUpCursorGap()
                await applyClientStateEngineSnapshotAndResynchronize()
                shouldFetchDomainEvents = true
                break
            }
            let outcome = await applyDomainEventAsync(
                envelope.payload,
                currentUserID: currentUserID,
                dependencies: &dependencies
            )
            shouldReloadMembersForConversationID = outcome.shouldReloadMembersForConversationID
                ?? shouldReloadMembersForConversationID
            if let conversationID = outcome.shouldSyncTimelineForConversationID {
                shouldSyncTimelineForConversationID = conversationID
                timelineSyncTargetSequence = outcome.timelineSyncTargetSequence
            }
            shouldFetchDomainEvents = shouldFetchDomainEvents || outcome.shouldFetchDomainEvents
            shouldRefreshConversationSummaries = shouldRefreshConversationSummaries
                || outcome.shouldRefreshConversationSummaries
            guard outcome.didConsumeEvent else {
                await clientStateEngine.recordCatchUpStoppedBeforeCursorAdvance()
                await applyClientStateEngineSnapshotAndResynchronize()
                break
            }
            lastConsumedCursor = envelope.cursor
        }
        await reduceDomainEventStateUsingClientEngine(.advanceCursor(lastConsumedCursor))
        await replayDeferredDomainEventsAsync(currentUserID: currentUserID)
        return IMConversationEventApplyOutcome(
            shouldReloadMembersForConversationID: shouldReloadMembersForConversationID,
            shouldSyncTimelineForConversationID: shouldSyncTimelineForConversationID,
            timelineSyncTargetSequence: timelineSyncTargetSequence,
            shouldFetchDomainEvents: shouldFetchDomainEvents,
            shouldRefreshConversationSummaries: shouldRefreshConversationSummaries
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
            domainEventMetrics: domainEventDebugMetrics,
            timelineCatchUpDiagnostics: timelineCatchUpDiagnostics
        )
    }

    private func normalizedConversationID(_ conversationID: String) -> String {
        conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private func domainEventDependencySnapshot() -> DomainEventProjectionReducer.DependencySnapshot {
        domainEventDependencyStateReducer.snapshot(
            conversations: conversations,
            processedEventIDs: processedDomainEventIDs,
            ownerAggregateHighWatermarks: ownerAggregateHighWatermarks
        )
    }

    private func shouldRefreshConversationSummariesAfterConsuming(_ payload: IMTCPChatDomainEventPayload) -> Bool {
        if isActivityOnlyConversationSummaryHint(payload) {
            return payload.eventType == .conversationUpdated
        }

        guard payload.aggregateType == "conversation",
              payload.conversation == nil
        else {
            return false
        }

        switch payload.body {
        case .conversationActivityHint:
            return false
        case .messageCreated(let message, _):
            return message.conversationID.uuidString != selectedConversationID
        case .messageEdited,
             .messageRevoked,
             .messageVisibilityChanged,
             .messageFavoriteChanged,
             .messageStream,
             .conversationChanged,
             .conversationVisibilityChanged,
             .memberChanged:
            return true
        case .conversationRemovedForSelf,
             .contactChanged:
            return false
        }
    }

    private func isActivityOnlyConversationSummaryHint(_ payload: IMTCPChatDomainEventPayload) -> Bool {
        guard payload.aggregateType == "conversation",
              payload.ownerCursor == nil,
              payload.ownerAggregateSequence == nil
        else {
            return false
        }

        if payload.eventType == .conversationActivityHint,
           case .conversationActivityHint = payload.body {
            return true
        }

        if payload.eventType == .conversationUpdated,
           let conversation = payload.conversation,
           Self.isActivityOnlySummaryContent(conversation),
           case .conversationChanged = payload.body {
            return true
        }
        return false
    }

    private func selectedConversationTimelineSyncTarget(
        for payload: IMTCPChatDomainEventPayload,
        isActivityOnlySummaryHint: Bool
    ) -> (conversationID: String, targetTimelineSequence: UInt64?)? {
        guard isActivityOnlySummaryHint,
              payload.aggregateID.uuidString == selectedConversationID
        else {
            return nil
        }

        switch payload.body {
        case .conversationActivityHint(let hint):
            return (
                conversationID: payload.aggregateID.uuidString,
                targetTimelineSequence: UInt64(hint.timelineSequence)
            )
        case .conversationChanged:
            return (
                conversationID: payload.aggregateID.uuidString,
                targetTimelineSequence: payload.conversation?.lastMessage?.timelineSequence
            )
        default:
            return nil
        }
    }

    private func shouldApplyActivityOnlyConversationSummary(
        _ payload: IMTCPChatDomainEventPayload,
        isActivityOnlySummaryHint: Bool
    ) -> Bool {
        guard isActivityOnlySummaryHint else {
            return true
        }
        return !isEmptyPreviewConversationActivityHint(payload)
    }

    private func applyActivityOnlyConversationHintUnreadIfNeeded(
        _ payload: IMTCPChatDomainEventPayload,
        currentUserID: UUID,
        isActivityOnlySummaryHint: Bool
    ) {
        guard isActivityOnlySummaryHint,
              !isEmptyPreviewConversationActivityHint(payload),
              payload.actorUserID != currentUserID
        else {
            return
        }

        applyRealtimeUnreadIncrement(for: payload.aggregateID.uuidString)
    }

    private func applyActivityOnlyConversationHintUnreadIfNeededAsync(
        _ payload: IMTCPChatDomainEventPayload,
        currentUserID: UUID,
        isActivityOnlySummaryHint: Bool
    ) async {
        guard isActivityOnlySummaryHint,
              !isEmptyPreviewConversationActivityHint(payload),
              payload.actorUserID != currentUserID
        else {
            return
        }

        await applyRealtimeUnreadIncrementAsync(for: payload.aggregateID.uuidString)
    }

    private func isEmptyPreviewConversationActivityHint(_ payload: IMTCPChatDomainEventPayload) -> Bool {
        guard payload.eventType == .conversationActivityHint,
              case .conversationActivityHint(let hint) = payload.body
        else {
            return false
        }
        return hint.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateDomainEventDependencySnapshot(
        _ dependencies: inout DomainEventProjectionReducer.DependencySnapshot,
        afterConsuming payload: IMTCPChatDomainEventPayload,
        operation: DomainEventProjectionReducer.Operation
    ) {
        domainEventDependencyStateReducer.reduce(
            payload: payload,
            operation: operation,
            state: &dependencies
        )
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

    private func recordConsumedDomainEvent(_ payload: IMTCPChatDomainEventPayload) {
        reduceDomainEventState(
            .recordConsumedEvent(
                eventID: payload.eventID,
                aggregateType: payload.aggregateType,
                aggregateID: payload.aggregateID.uuidString,
                ownerAggregateSequence: payload.ownerAggregateSequence
            )
        )
    }

    private func recordConsumedDomainEventAsync(_ payload: IMTCPChatDomainEventPayload) async {
        await reduceDomainEventStateUsingClientEngine(
            .recordConsumedEvent(
                eventID: payload.eventID,
                aggregateType: payload.aggregateType,
                aggregateID: payload.aggregateID.uuidString,
                ownerAggregateSequence: payload.ownerAggregateSequence
            )
        )
    }

    private func recordOwnerAggregateHighWatermark(_ payload: IMTCPChatDomainEventPayload) {
        reduceDomainEventState(
            .recordOwnerAggregateHighWatermark(
                aggregateType: payload.aggregateType,
                aggregateID: payload.aggregateID.uuidString,
                ownerAggregateSequence: payload.ownerAggregateSequence
            )
        )
    }

    private func recordOwnerAggregateHighWatermarkAsync(_ payload: IMTCPChatDomainEventPayload) async {
        await reduceDomainEventStateUsingClientEngine(
            .recordOwnerAggregateHighWatermark(
                aggregateType: payload.aggregateType,
                aggregateID: payload.aggregateID.uuidString,
                ownerAggregateSequence: payload.ownerAggregateSequence
            )
        )
    }

    private func deferDomainEvent(
        _ payload: IMTCPChatDomainEventPayload,
        missingKey: IMDeferredDomainEventMissingKey? = nil,
        conversationID: String? = nil
    ) -> IMDeferredDomainEventStoreResult {
        var state = deferredDomainEventState()
        let result = deferredDomainEventStateReducer.store(
            payload: payload,
            missingKey: missingKey ?? deferredMissingKey(for: payload),
            conversationID: conversationID ?? deferredConversationID(for: payload),
            state: &state
        )
        applyDeferredDomainEventState(state)
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

    private func deferDomainEventAsync(
        _ payload: IMTCPChatDomainEventPayload,
        missingKey: IMDeferredDomainEventMissingKey? = nil,
        conversationID: String? = nil
    ) async -> IMDeferredDomainEventStoreResult {
        await clientStateEngine.replaceState(clientStateSnapshot())
        let result = await clientStateEngine.storeDeferredDomainEvent(
            payload: payload,
            missingKey: missingKey ?? deferredMissingKey(for: payload),
            conversationID: conversationID ?? deferredConversationID(for: payload)
        )
        applyClientStateSnapshot(await clientStateEngine.snapshot())
        await clientStateEngine.replaceState(clientStateSnapshot())
        IMClientLog.conversationStore.debug(
            "Domain event defer async store result eventID=\(payload.eventID.uuidString, privacy: .public) eventType=\(payload.eventType.rawValue, privacy: .public) result=\(String(describing: result), privacy: .public) missingKey=\(String(describing: missingKey ?? deferredMissingKey(for: payload)), privacy: .public) conversationID=\(conversationID ?? deferredConversationID(for: payload) ?? "nil", privacy: .public)"
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
             .conversationActivityHint,
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
        let now = Date()

        var deferredState = deferredDomainEventState()
        let expiredEvents = deferredDomainEventStateReducer.removeExpiredDeferredEvents(
            now: now,
            state: &deferredState
        )
        applyDeferredDomainEventState(deferredState)
        for state in expiredEvents {
            domainEventDebugMetrics.deferredExpired += 1
            results.append(.expired(state.eventID))
        }

        let pending = deferredDomainEventStateReducer.pendingDeferredEvents(
            now: now,
            state: deferredDomainEventState()
        )
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

    @discardableResult
    private func replayDeferredDomainEventsAsync(currentUserID: UUID) async -> [IMDeferredDomainEventReplayResult] {
        var results: [IMDeferredDomainEventReplayResult] = []
        let now = Date()

        await clientStateEngine.replaceState(clientStateSnapshot())
        let expiredEvents = await clientStateEngine.removeExpiredDeferredEvents(now: now)
        await applyClientStateEngineSnapshotAndResynchronize()
        for state in expiredEvents {
            results.append(.expired(state.eventID))
        }

        let pending = await clientStateEngine.pendingDeferredEvents(now: now)
        var dependencies = await clientStateEngine.dependencySnapshot()
        for state in pending {
            guard let data = Data(base64Encoded: state.eventPBBase64) else {
                await clientStateEngine.removeDeferredEvent(state)
                await clientStateEngine.recordInvalidDeferredPayload()
                await applyClientStateEngineSnapshotAndResynchronize()
                results.append(.invalidPayload(state.eventID))
                continue
            }

            let payload: IMTCPChatDomainEventPayload
            do {
                payload = try IMTCPProtobufCodec.decodeDomainEvent(data)
            } catch {
                await clientStateEngine.removeDeferredEvent(state)
                await clientStateEngine.recordInvalidDeferredPayload()
                await applyClientStateEngineSnapshotAndResynchronize()
                results.append(.invalidPayload(state.eventID))
                continue
            }

            let outcome = await applyDomainEventAsync(
                payload,
                currentUserID: currentUserID,
                dependencies: &dependencies
            )
            guard processedDomainEventIDs.contains(payload.eventID) else {
                if outcome.shouldFetchDomainEvents {
                    await clientStateEngine.recordDeferredFullRefreshRequested()
                    await applyClientStateEngineSnapshotAndResynchronize()
                }
                if let conversationID = state.conversationID,
                   await clientStateEngine.hasFullRefreshConversation(conversationID) {
                    results.append(.requiresFullTimelineRefresh(conversationID))
                } else {
                    await clientStateEngine.bumpDeferredRetryCount(for: state)
                    await applyClientStateEngineSnapshotAndResynchronize()
                    results.append(.stillMissingDependency(payload.eventID))
                }
                continue
            }

            await clientStateEngine.removeDeferredEvent(state)
            await clientStateEngine.recordDeferredReplayApplied()
            await applyClientStateEngineSnapshotAndResynchronize()
            results.append(.applied(payload.eventID))
        }
        return results
    }

    private func removeDeferredDomainEvent(_ state: IMDeferredDomainEventState) {
        var deferredState = deferredDomainEventState()
        deferredDomainEventStateReducer.removeDeferredEvent(state, state: &deferredState)
        applyDeferredDomainEventState(deferredState)
    }

    private func bumpDeferredRetryCount(for state: IMDeferredDomainEventState) {
        var deferredState = deferredDomainEventState()
        deferredDomainEventStateReducer.bumpDeferredRetryCount(for: state, state: &deferredState)
        applyDeferredDomainEventState(deferredState)
    }

    private func deferredDomainEventsForSnapshot() -> [IMDeferredDomainEventState] {
        deferredDomainEventStateReducer.snapshotDeferredEvents(state: deferredDomainEventState())
    }

    private func enforceDeferredDomainEventLimits(conversationID: String?) {
        var state = deferredDomainEventState()
        let effect = deferredDomainEventStateReducer.enforceLimits(
            conversationID: conversationID,
            state: &state
        )
        applyDeferredDomainEventState(state)
        if let conversationID = effect.fullRefreshConversationID {
            markConversationNeedsFullRefresh(conversationID)
            domainEventDebugMetrics.deferredFullRefreshRequested += 1
        }
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
             .conversationActivityHint,
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
        reduceMessageState(
            .queueStreamSnapshotTarget(
                IMActiveMessageStreamTarget(
                    conversationID: stream.conversationID,
                    messageID: stream.messageID,
                    streamID: stream.streamID
                )
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

    private func applySummaryIfPresent(
        _ conversation: IMConversationSummaryResponseBody?,
        applyReadState: Bool = true
    ) {
        guard let conversation else { return }
        let conversationID = conversation.id.uuidString
        let existingBefore = conversations.first { $0.id == conversationID }
        IMClientLog.conversationStore.debug(
            "Summary applying conversationID=\(conversationID, privacy: .public) summaryPreview=\(conversation.lastMessage?.previewText ?? "nil", privacy: .public) summaryUnread=\(conversation.unreadCount, privacy: .public) summaryUpdated=\(conversation.updatedAt.timeIntervalSince1970, privacy: .public) beforePreview=\(existingBefore?.lastMessagePreviewText ?? "nil", privacy: .public) beforeUnread=\(existingBefore?.unreadCount ?? -1, privacy: .public) beforeUpdated=\(existingBefore?.updatedAt.timeIntervalSince1970 ?? -1, privacy: .public)"
        )
        applyConversationSummaryContent(conversation)
        if applyReadState {
            applyServerSummaryReadState(conversation)
        }
        let existingAfter = conversations.first { $0.id == conversationID }
        IMClientLog.conversationStore.debug(
            "Summary applied conversationID=\(conversationID, privacy: .public) afterPreview=\(existingAfter?.lastMessagePreviewText ?? "nil", privacy: .public) afterUnread=\(existingAfter?.unreadCount ?? -1, privacy: .public) afterUpdated=\(existingAfter?.updatedAt.timeIntervalSince1970 ?? -1, privacy: .public) messages=\(existingAfter?.messages.count ?? -1, privacy: .public) timeline=\(existingAfter?.timelineItems.count ?? -1, privacy: .public)"
        )
    }

    private func applySummaryIfPresentAsync(
        _ conversation: IMConversationSummaryResponseBody?,
        applyReadState: Bool = true
    ) async {
        guard let conversation else { return }
        await reduceConversationStateUsingClientEngine(.applyConversationSummaryContent(conversation))
        if applyReadState {
            await reduceConversationStateUsingClientEngine(
                .applyServerSummaryReadState(
                    conversationID: conversation.id.uuidString,
                    lastReadSequence: UInt64(conversation.lastReadSequence),
                    unreadCount: conversation.unreadCount
                )
            )
        }
    }

    private func upsertTimelineNotice(_ response: IMTimelineNoticeResponseBody) {
        let notice = makeNotices(from: [response])[0]
        upsertTimelineNotice(notice)
    }

    private func upsertTimelineNotice(_ notice: IMTimelineNotice) {
        reduceTimelineState(.upsertNotice(notice))
    }

    private func upsertTimelineNoticeAsync(_ notice: IMTimelineNotice) async {
        await reduceTimelineStateUsingClientEngine(.upsertNotice(notice))
    }

    private func clearDomainEventFullRefreshState(for conversationID: String, currentUserID: UUID) {
        var state = deferredDomainEventState()
        guard deferredDomainEventStateReducer.clearFullRefreshConversation(
            conversationID: conversationID,
            state: &state
        ) else {
            return
        }
        applyDeferredDomainEventState(state)
        _ = replayDeferredDomainEvents(currentUserID: currentUserID)
    }

    public func replaceTimelineItems(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        reduceTimelineState(
            .replaceMessageItems(
                conversationID: conversationID,
                messages: responses,
                currentUserID: currentUserID
            )
        )
    }

    public func replaceTimelineItems(
        in conversationID: String,
        items: [IMTimelineItemResponseBody],
        hasMore: Bool,
        currentUserID: UUID
    ) {
        reduceTimelineState(
            .replaceTimelineItems(
                conversationID: conversationID,
                items: items,
                hasMore: hasMore,
                currentUserID: currentUserID
            )
        )
    }

    public func mergeTimelinePage(
        in conversationID: String,
        response: IMConversationTimelineResponseBody,
        currentUserID: UUID
    ) {
        reduceTimelineState(
            .replaceTimelineItems(
                conversationID: conversationID,
                items: response.items,
                hasMore: response.hasMore,
                currentUserID: currentUserID
            )
        )
    }

    public func appendTimelineItems(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        reduceTimelineState(
            .appendMessageItems(
                conversationID: conversationID,
                messages: responses,
                currentUserID: currentUserID
            )
        )
    }

    public func appendTimelineItems(
        in conversationID: String,
        items: [IMTimelineItemResponseBody],
        currentUserID: UUID
    ) {
        reduceTimelineState(
            .appendTimelineItems(
                conversationID: conversationID,
                items: items,
                currentUserID: currentUserID
            )
        )
    }

    public func appendTimelinePage(
        in conversationID: String,
        response: IMConversationTimelineResponseBody,
        currentUserID: UUID
    ) {
        reduceTimelineState(
            .appendTimelineItems(
                conversationID: conversationID,
                items: response.items,
                currentUserID: currentUserID
            )
        )
    }

    public func replaceMembers(
        in conversationID: String,
        members responses: [IMConversationMemberResponseBody]
    ) {
        let members = Self.members(from: responses)
            .sorted(by: sortMembers)
        reduceConversationState(
            .replaceMembers(
                conversationID: conversationID,
                members: members
            )
        )
    }

    public func replaceMembersAsync(
        in conversationID: String,
        members responses: [IMConversationMemberResponseBody]
    ) async {
        let members = Self.members(from: responses)
            .sorted(by: sortMembers)
        await reduceConversationStateUsingClientEngine(
            .replaceMembers(
                conversationID: conversationID,
                members: members
            )
        )
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

        let sortedMembers = mergedMembers.sorted(by: sortMembers)
        reduceConversationState(
            .applyMemberSnapshot(
                conversationID: trimmedConversationID,
                members: sortedMembers,
                total: response.total
            )
        )
    }

    public func applyMemberPageAsync(
        _ response: IMConversationMemberPageResponseBody,
        in conversationID: String,
        query: String,
        appending: Bool
    ) async {
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

        let sortedMembers = mergedMembers.sorted(by: sortMembers)
        await reduceConversationStateUsingClientEngine(
            .applyMemberSnapshot(
                conversationID: trimmedConversationID,
                members: sortedMembers,
                total: response.total
            )
        )
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
        reduceConversationState(
            .updateDraft(
                conversationID: conversationID,
                text: text,
                updatedAt: Date()
            )
        )
    }

    public func updateDraftAsync(_ text: String, for conversationID: String) async {
        await reduceConversationStateUsingClientEngine(
            .updateDraft(
                conversationID: conversationID,
                text: text,
                updatedAt: Date()
            )
        )
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
        reduceTimelineState(
            .prependMessageItems(
                conversationID: conversationID,
                messages: responses,
                currentUserID: currentUserID
            )
        )
    }

    public func prependTimelinePage(
        in conversationID: String,
        response: IMConversationTimelineResponseBody,
        currentUserID: UUID
    ) {
        reduceTimelineState(
            .prependTimelineItems(
                conversationID: conversationID,
                items: response.items,
                hasMore: response.hasMore,
                currentUserID: currentUserID
            )
        )
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

    public func prepareOutgoingTextAsync(
        _ text: String,
        conversationID: String,
        senderUserID: UUID
    ) async -> IMOutgoingMessageRequest? {
        await prepareOutgoingTextUsingClientEngine(
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

    @discardableResult
    public func queueOutgoingTextAsync(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) async -> Bool {
        await prepareOutgoingTextUsingClientEngine(
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

    public func prepareOutgoingReplyAsync(
        reference: IMReplyReference,
        text: String,
        conversationID: String,
        senderUserID: UUID
    ) async -> IMOutgoingMessageRequest? {
        await prepareOutgoingMessageUsingClientEngine(
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

    @discardableResult
    public func queueOutgoingReplyAsync(
        reference: IMReplyReference,
        text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) async -> Bool {
        await prepareOutgoingMessageUsingClientEngine(
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
            setStatusMessage("当前消息类型不支持发送。")
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

    public func stageOutgoingMediaUploadAsync(
        asset: IMMediaAsset,
        conversationID: String,
        senderUserID: UUID,
        sourceFileURL: URL
    ) async -> IMOutgoingMediaPlaceholder? {
        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            await setStatusMessageAsync("当前消息类型不支持发送。")
            return nil
        }

        return await appendOutgoingMessageUsingClientEngine(
            content,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .preparing(message: "正在准备上传附件。"),
            shouldRegisterPendingRequest: false,
            localTransferState: IMMessageLocalTransferState(sourceFilePath: sourceFileURL.path)
        ).placeholder
    }

    public func markOutgoingPreparing(localMessageID: String, message: String, uploadID: String? = nil) {
        reduceOutgoingState(
            .markOutgoingPreparing(
                localMessageID: localMessageID,
                message: message,
                uploadID: uploadID
            )
        )
    }

    public func markOutgoingPreparingAsync(localMessageID: String, message: String, uploadID: String? = nil) async {
        await reduceOutgoingStateUsingClientEngine(
            .markOutgoingPreparing(
                localMessageID: localMessageID,
                message: message,
                uploadID: uploadID
            )
        )
    }

    public func markOutgoingUploading(localMessageID: String, message: String, uploadID: String? = nil) {
        reduceOutgoingState(
            .markOutgoingUploading(
                localMessageID: localMessageID,
                message: message,
                uploadID: uploadID
            )
        )
    }

    public func markOutgoingUploadingAsync(localMessageID: String, message: String, uploadID: String? = nil) async {
        await reduceOutgoingStateUsingClientEngine(
            .markOutgoingUploading(
                localMessageID: localMessageID,
                message: message,
                uploadID: uploadID
            )
        )
    }

    public func markOutgoingUploadFailed(localMessageID: String, message: String) {
        reduceOutgoingState(
            .markOutgoingUploadFailed(
                localMessageID: localMessageID,
                message: message
            )
        )
    }

    public func markOutgoingUploadFailedAsync(localMessageID: String, message: String) async {
        await reduceOutgoingStateUsingClientEngine(
            .markOutgoingUploadFailed(
                localMessageID: localMessageID,
                message: message
            )
        )
    }

    public func abandonRecoverableOutgoingMediaUpload(localMessageID: String, message: String) {
        reduceOutgoingState(
            .abandonRecoverableOutgoingMediaUpload(
                localMessageID: localMessageID,
                message: message
            )
        )
    }

    public func abandonRecoverableOutgoingMediaUploadAsync(localMessageID: String, message: String) async {
        await reduceOutgoingStateUsingClientEngine(
            .abandonRecoverableOutgoingMediaUpload(
                localMessageID: localMessageID,
                message: message
            )
        )
    }

    public func updateLocalDownloadState(
        messageID: String,
        state: IMMessageLocalDownloadState?
    ) {
        reduceMessageState(
            .updateLocalDownloadState(
                messageID: messageID,
                state: state
            )
        )
    }

    public func updateLocalDownloadStateAsync(
        messageID: String,
        state: IMMessageLocalDownloadState?
    ) async {
        await reduceMessageStateUsingClientEngine(
            .updateLocalDownloadState(
                messageID: messageID,
                state: state
            )
        )
    }

    public func activeMessageStreamTargetsAsync() async -> [IMActiveMessageStreamTarget] {
        await clientStateEngine.replaceState(clientStateSnapshot())
        return await clientStateEngine.activeMessageStreamTargets()
    }

    public func consumePendingStreamSnapshotTargetsAsync() async -> [IMActiveMessageStreamTarget] {
        await clientStateEngine.replaceState(clientStateSnapshot())
        let targets = await clientStateEngine.consumePendingStreamSnapshotTargets()
        applyClientStateSnapshot(await clientStateEngine.snapshot())
        await clientStateEngine.replaceState(clientStateSnapshot())
        return targets
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

    public func prepareUploadedOutgoingMediaAsync(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String
    ) async -> IMOutgoingMessageRequest? {
        await updateUploadedOutgoingMediaAsync(
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

    @discardableResult
    public func queueUploadedOutgoingMediaAsync(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String,
        message: String = "等待 IM 长连接恢复后发送。"
    ) async -> Bool {
        await updateUploadedOutgoingMediaAsync(
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

    private func prepareOutgoingMessageUsingClientEngine(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) async -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        await appendOutgoingMessageUsingClientEngine(
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
            setStatusMessage("消息内容不能为空。")
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

    private func prepareOutgoingTextUsingClientEngine(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) async -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            await setStatusMessageAsync("消息内容不能为空。")
            return (nil, nil)
        }

        return await prepareOutgoingMessageUsingClientEngine(
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
        reduceOutgoingState(
            .retryOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID,
                requestID: UUID()
            )
        ).request
    }

    public func retryOutgoingMessageAsync(
        localMessageID: String,
        conversationID: String
    ) async -> IMOutgoingMessageRequest? {
        await reduceOutgoingStateUsingClientEngine(
            .retryOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID,
                requestID: UUID()
            )
        ).request
    }

    @discardableResult
    public func queueRetryableOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        message queueMessage: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        reduceOutgoingState(
            .queueRetryableOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID,
                message: queueMessage
            )
        ).didApply
    }

    @discardableResult
    public func queueRetryableOutgoingMessageAsync(
        localMessageID: String,
        conversationID: String,
        message queueMessage: String = "等待 IM 长连接恢复后发送。"
    ) async -> Bool {
        await reduceOutgoingStateUsingClientEngine(
            .queueRetryableOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID,
                message: queueMessage
            )
        ).didApply
    }

    @discardableResult
    public func cancelQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> Bool {
        reduceOutgoingState(
            .cancelQueuedOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID
            )
        ).didApply
    }

    @discardableResult
    public func cancelQueuedOutgoingMessageAsync(
        localMessageID: String,
        conversationID: String
    ) async -> Bool {
        await reduceOutgoingStateUsingClientEngine(
            .cancelQueuedOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID
            )
        ).didApply
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
            guard let request = reduceOutgoingState(
                .startQueuedOutgoingMessage(
                    localMessageID: queuedMessage.id,
                    conversationID: conversationID,
                    requestID: UUID()
                )
            ).request else {
                continue
            }
            requests.append(request)
        }

        return requests
    }

    public func queuedOutgoingMessageRequestsAsync(limit: Int) async -> [IMOutgoingMessageRequest] {
        let limitedCount = max(0, limit)
        guard limitedCount > 0 else {
            return []
        }

        await clientStateEngine.replaceState(clientStateSnapshot())
        let snapshot = await clientStateEngine.snapshot()
        var queuedMessages: [(conversationID: String, message: IMPendingConversationMessage)] = []
        for conversation in snapshot.conversations {
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
            let effect = await reduceOutgoingStateUsingClientEngine(
                .startQueuedOutgoingMessage(
                    localMessageID: queuedMessage.id,
                    conversationID: conversationID,
                    requestID: UUID()
                ),
                synchronizeBeforeReduce: false
            )
            if let request = effect.request {
                requests.append(request)
            }
        }
        return requests
    }

    public func markOutgoingQueued(requestID: UUID, message: String) {
        reduceOutgoingState(.markOutgoingQueued(requestID: requestID, message: message))
    }

    public func markOutgoingQueuedAsync(requestID: UUID, message: String) async {
        await reduceOutgoingStateUsingClientEngine(.markOutgoingQueued(requestID: requestID, message: message))
    }

    public func isRetryableFailure(_ message: IMPendingConversationMessage) -> Bool {
        Self.isRetryablePendingFailure(message)
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

        reduceOutgoingState(
            .applyRejectedOutgoingAcknowledgement(
                localMessageID: localMessageID,
                message: outgoingAcknowledgementFailureMessage(for: payload.status)
            )
        )
    }

    public func applyOutgoingAcknowledgementAsync(requestID: UUID?, payload: IMTCPAckPayload) async {
        guard let requestID else {
            IMClientLog.conversationStore.warning(
                "ACK ignored: missing requestID status=\(payload.status, privacy: .public) messageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public)"
            )
            return
        }

        await clientStateEngine.replaceState(clientStateSnapshot())
        guard let localMessageID = await clientStateEngine.removePendingOutgoingRequest(requestID) else {
            IMClientLog.conversationStore.warning(
                "ACK ignored: no pending request requestID=\(requestID.uuidString, privacy: .public) status=\(payload.status, privacy: .public) messageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public)"
            )
            return
        }

        IMClientLog.conversationStore.debug(
            "ACK received requestID=\(requestID.uuidString, privacy: .public) localMessageID=\(localMessageID, privacy: .public) status=\(payload.status, privacy: .public) messageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public)"
        )

        if payload.status == "accepted" {
            await reduceOutgoingStateUsingClientEngine(
                .applyAcceptedOutgoingAcknowledgement(
                    localMessageID: localMessageID,
                    serverMessageID: payload.messageID
                ),
                synchronizeBeforeReduce: false
            )
            return
        }

        await reduceOutgoingStateUsingClientEngine(
            .applyRejectedOutgoingAcknowledgement(
                localMessageID: localMessageID,
                message: outgoingAcknowledgementFailureMessage(for: payload.status)
            ),
            synchronizeBeforeReduce: false
        )
    }

    public func markOutgoingFailure(requestID: UUID, message: String) {
        reduceOutgoingState(.markOutgoingFailure(requestID: requestID, message: message))
    }

    public func markOutgoingFailureAsync(requestID: UUID, message: String) async {
        await reduceOutgoingStateUsingClientEngine(.markOutgoingFailure(requestID: requestID, message: message))
    }

    public func markAllPendingMessagesFailed(message: String) {
        reduceOutgoingState(.markAllPendingMessagesFailed(message: message))
    }

    public func markAllPendingMessagesFailedAsync(message: String) async {
        await reduceOutgoingStateUsingClientEngine(.markAllPendingMessagesFailed(message: message))
    }

    public func markAllPendingMessagesUnknown(message: String) {
        reduceOutgoingState(.markAllPendingMessagesUnknown(message: message))
    }

    public func markAllPendingMessagesUnknownAsync(message: String) async {
        await reduceOutgoingStateUsingClientEngine(.markAllPendingMessagesUnknown(message: message))
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

        reduceMessageState(.applyCreatedMessage(message, clientMessageID: clientMessageID))
        let conversationAfter = conversations.first { $0.id == conversationID }
        let pendingCountAfter = conversationAfter?.pendingMessages.count ?? -1
        let messageCountAfter = conversationAfter?.messages.count ?? -1
        IMClientLog.conversationStore.debug(
            "Canonical message applied conversationID=\(conversationID, privacy: .public) serverMessageID=\(serverMessageID, privacy: .public) clientMessageID=\(clientMessageID ?? "nil", privacy: .public) direction=\(String(describing: message.direction), privacy: .public) text=\(message.text, privacy: .public) unreadBefore=\(unreadBefore, privacy: .public) unreadAfter=\(conversationAfter?.unreadCount ?? -1, privacy: .public) previewBefore=\(previewBefore, privacy: .public) previewAfter=\(conversationAfter?.lastMessagePreviewText ?? "nil", privacy: .public) updatedAfter=\(conversationAfter?.updatedAt.timeIntervalSince1970 ?? -1, privacy: .public) pendingBefore=\(pendingCountBefore, privacy: .public) pendingAfter=\(pendingCountAfter, privacy: .public) messagesBefore=\(messageCountBefore, privacy: .public) messagesAfter=\(messageCountAfter, privacy: .public) timelineAfter=\(conversationAfter?.timelineItems.count ?? -1, privacy: .public)"
        )
    }

    private func applyCreatedMessageAsync(
        _ message: IMConversationMessage,
        clientMessageID: String?
    ) async {
        await reduceMessageStateUsingClientEngine(
            .applyCreatedMessage(message, clientMessageID: clientMessageID)
        )
    }

    private func applyAcceptedOutgoingAcknowledgement(
        localMessageID: String,
        payload: IMTCPAckPayload
    ) {
        let effect = reduceOutgoingState(
            .applyAcceptedOutgoingAcknowledgement(
                localMessageID: localMessageID,
                serverMessageID: payload.messageID
            )
        )

        if !effect.didApply {
            IMClientLog.conversationStore.warning(
                "ACK accepted could not find pending localMessageID=\(localMessageID, privacy: .public) serverMessageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public)"
            )
        }
    }

    private func applyUpdatedMessage(_ message: IMConversationMessage) {
        reduceMessageState(.applyUpdatedMessage(message))
    }

    private func applyUpdatedMessageAsync(_ message: IMConversationMessage) async {
        await reduceMessageStateUsingClientEngine(.applyUpdatedMessage(message))
    }

    public func applyUpdatedMessage(
        _ response: IMConversationMessageResponseBody,
        currentUserID: UUID
    ) {
        let conversationID = response.conversationID.uuidString
        let stableMessageID = response.id.uuidString
        let effectiveTimestamp = response.createdAt ?? Date()
        let index = ensureConversationIndex(for: conversationID)
        let existingIndex = conversations[index].messages.firstIndex(where: {
            $0.id == stableMessageID || $0.serverMessageID == stableMessageID
        })
        let message: IMConversationMessage
        if let existingIndex {
            var existing = conversations[index].messages[existingIndex]
            existing.serverMessageID = stableMessageID
            existing.serverSequence = UInt64(response.serverSequence)
            existing.timelineSequence = UInt64(response.timelineSequence)
            existing.senderUserID = response.senderUserID
            existing.content = response.content
            existing.derivedState = response.derivedState
            existing.createdAt = effectiveTimestamp
            existing.deliveryState = existing.direction == .outgoing ? .sent : .received
            message = existing
        } else {
            do {
                message = try IMConversationMessage(
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
            } catch {
                domainEventDebugMetrics.invalidCanonicalMessageDTOs += 1
                markDomainEventFullRefreshConversation(conversationID)
                return
            }
        }

        reduceMessageState(.applyUpdatedMessage(message))
    }

    public func applyUpdatedMessageAsync(
        _ response: IMConversationMessageResponseBody,
        currentUserID: UUID
    ) async {
        do {
            let message = try updatedMessage(from: response, currentUserID: currentUserID)
            await reduceMessageStateUsingClientEngine(.applyUpdatedMessage(message))
        } catch {
            await clientStateEngine.replaceState(clientStateSnapshot())
            await clientStateEngine.recordInvalidCanonicalMessageDTO(
                conversationID: response.conversationID.uuidString
            )
            applyClientStateSnapshot(await clientStateEngine.snapshot())
            await clientStateEngine.replaceState(clientStateSnapshot())
        }
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

    public func applyMessageStreamEventAsync(
        stream: IMTCPMessageStreamPayload,
        message: IMConversationMessageResponseBody?,
        currentUserID: UUID
    ) async {
        if let message {
            await applyUpdatedMessageAsync(message, currentUserID: currentUserID)
        }
        await applyMessageStreamStateAsync(stream: stream)
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

    private func applyMessageStreamEventAsync(
        stream: IMTCPMessageStreamPayload,
        message: IMConversationMessage?
    ) async {
        if let message {
            await applyUpdatedMessageAsync(message)
        }
        await applyMessageStreamStateAsync(stream: stream)
    }

    private func applyMessageStreamState(stream: IMTCPMessageStreamPayload) {
        reduceMessageState(.applyMessageStreamState(stream))
    }

    private func applyMessageStreamStateAsync(stream: IMTCPMessageStreamPayload) async {
        await reduceMessageStateUsingClientEngine(.applyMessageStreamState(stream))
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

    public func applyStreamSignalAsync(
        _ payload: IMTCPMessageStreamSignalPayload,
        currentUserID: UUID
    ) async {
        await clientStateEngine.replaceState(clientStateSnapshot())
        let hasMessage = await clientStateEngine.hasMessage(
            id: payload.stream.messageID,
            in: payload.stream.conversationID
        )
        let shouldQueueSnapshotTarget = !hasMessage && payload.message == nil

        if shouldQueueSnapshotTarget {
            await reduceMessageStateUsingClientEngine(
                .queueStreamSnapshotTarget(
                    IMActiveMessageStreamTarget(
                        conversationID: payload.stream.conversationID,
                        messageID: payload.stream.messageID,
                        streamID: payload.stream.streamID
                    )
                ),
                synchronizeBeforeReduce: false
            )
            return
        }

        await applyMessageStreamEventAsync(
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
        reduceMessageState(
            .removePendingStreamSnapshotTarget(
                IMActiveMessageStreamTarget(
                    conversationID: response.message.conversationID.uuidString,
                    messageID: response.message.id.uuidString,
                    streamID: response.stream.streamID
                )
            )
        )
    }

    public func applyMessageStreamSnapshotAsync(
        _ response: IMMessageStreamResponseBody,
        currentUserID: UUID
    ) async {
        await applyUpdatedMessageAsync(response.message, currentUserID: currentUserID)
        await reduceMessageStateUsingClientEngine(
            .removePendingStreamSnapshotTarget(
                IMActiveMessageStreamTarget(
                    conversationID: response.message.conversationID.uuidString,
                    messageID: response.message.id.uuidString,
                    streamID: response.stream.streamID
                )
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
        var state = IMConversationTimelineState(
            conversations: conversations,
            statusMessage: statusMessage
        )
        let effect = conversationTimelineStateReducer.trimCachedMessageWindow(
            limit: limit,
            state: &state,
            trimMessages: { [self] messages, limit in
                trimmedCachedMessages(messages, limit: limit)
            }
        )
        conversations = state.conversations
        statusMessage = state.statusMessage
        applyTimelineStateEffect(effect)
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
        let localLatestTimelineSequences = latestLoadedTimelineSequencesByConversationID()

        return summaries.compactMap { summary -> String? in
            let conversationID = summary.id.uuidString
            let serverLatestTimelineSequence = summary.lastMessage?.timelineSequence ?? 0
            guard
                let localLatestTimelineSequence = localLatestTimelineSequences[conversationID],
                serverLatestTimelineSequence > localLatestTimelineSequence
            else {
                return nil
            }

            return conversationID
        }
    }

    private func latestLoadedTimelineSequencesByConversationID() -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: conversations.compactMap { conversation -> (String, UInt64)? in
            var latestSequence: UInt64?
            for item in conversation.timelineItems {
                guard let timelineSequence = item.timelineSequence else {
                    continue
                }
                latestSequence = max(latestSequence ?? 0, timelineSequence)
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
        reduceLoadingState(.setLoadingConversations(isLoading))
    }

    public func setLoadingConversationsAsync(_ isLoading: Bool) async {
        await reduceLoadingStateUsingClientEngine(.setLoadingConversations(isLoading))
    }

    public func setLoadingMoreConversationSummaries(_ isLoading: Bool) {
        reduceLoadingState(.setLoadingMoreConversationSummaries(isLoading))
    }

    public func setLoadingMoreConversationSummariesAsync(_ isLoading: Bool) async {
        await reduceLoadingStateUsingClientEngine(.setLoadingMoreConversationSummaries(isLoading))
    }

    public func setLoadingMembers(_ isLoading: Bool) {
        reduceLoadingState(.setLoadingMembers(isLoading))
    }

    public func setLoadingMembersAsync(_ isLoading: Bool) async {
        await reduceLoadingStateUsingClientEngine(.setLoadingMembers(isLoading))
    }

    public func setLoadingMessages(_ isLoading: Bool) {
        reduceLoadingState(.setLoadingMessages(isLoading))
    }

    public func setLoadingMessagesAsync(_ isLoading: Bool) async {
        await reduceLoadingStateUsingClientEngine(.setLoadingMessages(isLoading))
    }

    public func setStatusMessage(_ message: String?) {
        reduceConversationState(.setStatusMessage(message))
    }

    public func setStatusMessageAsync(_ message: String?) async {
        await reduceConversationStateUsingClientEngine(.setStatusMessage(message))
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
        applyClientStateSnapshot(
            restoredClientStateSnapshot(
                from: snapshot,
                restoredState: restoredState
            )
        )
        recordCacheDiagnostics(restoredState.diagnostics)
        sortConversations()
    }

    private func restoredClientStateSnapshot(
        from snapshot: IMConversationCacheSnapshot,
        restoredState: RestoredConversationCacheState
    ) -> IMConversationClientState {
        let processedEventIDOrder = Array(snapshot.domainEventState.appliedEventIDs.suffix(1_000))
        let ownerHighWatermarks = Dictionary(
            uniqueKeysWithValues: snapshot.domainEventState.ownerAggregateHighWatermarks.map {
                (
                    IMOwnerAggregateKey(aggregateType: $0.aggregateType, aggregateID: $0.aggregateID),
                    $0.sequence
                )
            }
        )

        return IMConversationClientState(
            conversations: restoredState.conversations,
            selectedConversationID: restoredState.selectedConversationID,
            statusMessage: nil,
            isLoadingConversations: isLoadingConversations,
            conversationSummaryNextCursor: snapshot.metadata.summaryNextCursor,
            hasMoreConversationSummaries: snapshot.metadata.hasMoreConversationSummaries,
            isLoadingMoreConversationSummaries: false,
            detailState: restoredState.detailState,
            outgoingQueueState: outgoingQueueState,
            conversationSearchState: conversationSearchState,
            pendingStreamSnapshotTargets: pendingStreamSnapshotTargets,
            domainEventState: IMConversationDomainEventState(
                processedEventIDs: Set(processedEventIDOrder),
                processedEventIDOrder: processedEventIDOrder,
                ownerAggregateHighWatermarks: ownerHighWatermarks,
                cursor: snapshot.domainEventState.cursor
            ),
            deferredDomainEventState: IMConversationDeferredDomainEventState(
                eventsByMissingKey: Dictionary(grouping: snapshot.domainEventState.deferredEvents) { $0.missingKey },
                fullRefreshConversationIDs: Set(snapshot.domainEventState.fullRefreshConversationIDs)
            ),
            domainEventDebugMetrics: domainEventDebugMetrics
        )
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
            markDomainEventFullRefreshConversation(conversationID)
        }
    }

    private func reduceConversationState(_ event: IMConversationStoreStateEvent) {
        var state = IMConversationStoreState(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            statusMessage: statusMessage,
            conversationSummaryNextCursor: conversationSummaryNextCursor,
            hasMoreConversationSummaries: hasMoreConversationSummaries,
            isLoadingMoreConversationSummaries: isLoadingMoreConversationSummaries
        )
        let effect = conversationStateReducer.reduce(
            event,
            state: &state,
            replacingSummaryContent: Self.replacementConversationSummary(from:existing:),
            summaryContent: Self.conversationSummary(from:existing:),
            upsertSummaryContents: Self.upsertConversationSummaryContents(_:conversations:),
            upsertSummaryContent: Self.upsertConversationSummaryContent(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )

        conversations = state.conversations
        selectedConversationID = state.selectedConversationID
        statusMessage = state.statusMessage
        conversationSummaryNextCursor = state.conversationSummaryNextCursor
        hasMoreConversationSummaries = state.hasMoreConversationSummaries
        isLoadingMoreConversationSummaries = state.isLoadingMoreConversationSummaries

        for removedConversationID in effect.removedConversationIDs {
            detailState.removeConversation(id: removedConversationID)
        }
        if effect.shouldSyncReplyJumpState {
            syncReplyJumpState()
        }
        if effect.shouldSortConversations {
            sortConversations()
        }
    }

    private func reduceConversationStateUsingClientEngine(_ event: IMConversationStoreStateEvent) async {
        await clientStateEngine.replaceState(clientStateSnapshot())
        let effect = await clientStateEngine.reduceSummaryState(
            event,
            replacingSummaryContent: Self.replacementConversationSummary(from:existing:),
            summaryContent: Self.conversationSummary(from:existing:),
            upsertSummaryContents: Self.upsertConversationSummaryContents(_:conversations:),
            upsertSummaryContent: Self.upsertConversationSummaryContent(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        applyClientStateSnapshot(await clientStateEngine.snapshot())

        for removedConversationID in effect.removedConversationIDs {
            detailState.removeConversation(id: removedConversationID)
        }
        if effect.shouldSyncReplyJumpState {
            syncReplyJumpState()
        }
        if effect.shouldSortConversations {
            sortConversations()
        }
        await clientStateEngine.replaceState(clientStateSnapshot())
    }

    private func clientStateSnapshot() -> IMConversationClientState {
        IMConversationClientState(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            statusMessage: statusMessage,
            isLoadingConversations: isLoadingConversations,
            conversationSummaryNextCursor: conversationSummaryNextCursor,
            hasMoreConversationSummaries: hasMoreConversationSummaries,
            isLoadingMoreConversationSummaries: isLoadingMoreConversationSummaries,
            detailState: detailState,
            outgoingQueueState: outgoingQueueState,
            conversationSearchState: conversationSearchState,
            pendingStreamSnapshotTargets: pendingStreamSnapshotTargets,
            domainEventState: IMConversationDomainEventState(
                processedEventIDs: processedDomainEventIDs,
                processedEventIDOrder: processedDomainEventIDOrder,
                ownerAggregateHighWatermarks: ownerAggregateHighWatermarks,
                cursor: domainEventCursor
            ),
            deferredDomainEventState: deferredDomainEventState(),
            domainEventDebugMetrics: domainEventDebugMetrics
        )
    }

    private func applyClientStateSnapshot(_ snapshot: IMConversationClientState) {
        conversations = snapshot.conversations
        selectedConversationID = snapshot.selectedConversationID
        statusMessage = snapshot.statusMessage
        isLoadingConversations = snapshot.isLoadingConversations
        conversationSummaryNextCursor = snapshot.conversationSummaryNextCursor
        hasMoreConversationSummaries = snapshot.hasMoreConversationSummaries
        isLoadingMoreConversationSummaries = snapshot.isLoadingMoreConversationSummaries
        detailState = snapshot.detailState
        outgoingQueueState = snapshot.outgoingQueueState
        conversationSearchState = snapshot.conversationSearchState
        searchText = snapshot.conversationSearchState.text
        pendingStreamSnapshotTargets = snapshot.pendingStreamSnapshotTargets
        processedDomainEventIDs = snapshot.domainEventState.processedEventIDs
        processedDomainEventIDOrder = snapshot.domainEventState.processedEventIDOrder
        ownerAggregateHighWatermarks = snapshot.domainEventState.ownerAggregateHighWatermarks
        domainEventCursor = snapshot.domainEventState.cursor
        applyDeferredDomainEventState(snapshot.deferredDomainEventState)
        domainEventDebugMetrics = snapshot.domainEventDebugMetrics
        isLoadingMembers = detailState.isLoadingMembers
        isLoadingMessages = detailState.isLoadingMessages
        syncReplyJumpState()
    }

    private func applyClientStateEngineSnapshotAndResynchronize() async {
        applyClientStateSnapshot(await clientStateEngine.snapshot())
        await clientStateEngine.replaceState(clientStateSnapshot())
    }

    private func reduceLoadingState(_ event: IMConversationLoadingStateEvent) {
        var state = IMConversationLoadingState(
            isLoadingConversations: isLoadingConversations,
            isLoadingMoreConversationSummaries: isLoadingMoreConversationSummaries,
            detailState: detailState
        )
        conversationLoadingStateReducer.reduce(event, state: &state)
        applyLoadingState(state)
    }

    private func reduceLoadingStateUsingClientEngine(_ event: IMConversationLoadingStateEvent) async {
        await clientStateEngine.replaceState(clientStateSnapshot())
        await clientStateEngine.reduceLoadingState(event)
        applyClientStateSnapshot(await clientStateEngine.snapshot())
        await clientStateEngine.replaceState(clientStateSnapshot())
    }

    private func applyLoadingState(_ state: IMConversationLoadingState) {
        isLoadingConversations = state.isLoadingConversations
        isLoadingMoreConversationSummaries = state.isLoadingMoreConversationSummaries
        detailState = state.detailState
        isLoadingMembers = detailState.isLoadingMembers
        isLoadingMessages = detailState.isLoadingMessages
    }

    @discardableResult
    private func reduceOutgoingState(_ event: IMConversationOutgoingStateEvent) -> IMConversationOutgoingStateEffect {
        var state = IMConversationOutgoingState(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            statusMessage: statusMessage,
            outgoingQueueState: outgoingQueueState
        )
        let effect = conversationOutgoingStateReducer.reduce(
            event,
            state: &state,
            ensureConversationIndex: { conversationID, conversations in
                Self.ensureConversationIndex(for: conversationID, conversations: &conversations)
            },
            latestMessagePreviewText: { [self] messages, fallback in
                messageTimelineState.latestPreviewText(in: messages, fallback: fallback)
            },
            latestMessageUpdatedAt: { [self] messages, fallback in
                messageTimelineState.latestUpdatedAt(in: messages, fallback: fallback)
            },
            isRetryableFailure: { [self] message in
                isRetryableFailure(message)
            }
        )

        conversations = state.conversations
        selectedConversationID = state.selectedConversationID
        statusMessage = state.statusMessage
        outgoingQueueState = state.outgoingQueueState

        if effect.shouldSortConversations {
            sortConversations()
        }
        if let missingPendingMessageID = effect.missingPendingMessageID {
            IMClientLog.conversationStore.warning(
                "Pending mutate skipped: localMessageID not found localMessageID=\(missingPendingMessageID, privacy: .public)"
            )
        }

        return effect
    }

    @discardableResult
    private func reduceOutgoingStateUsingClientEngine(
        _ event: IMConversationOutgoingStateEvent,
        synchronizeBeforeReduce: Bool = true
    ) async -> IMConversationOutgoingStateEffect {
        if synchronizeBeforeReduce {
            await clientStateEngine.replaceState(clientStateSnapshot())
        }
        let effect = await clientStateEngine.reduceOutgoingState(
            event,
            ensureConversationIndex: { conversationID, conversations in
                Self.ensureConversationIndex(for: conversationID, conversations: &conversations)
            },
            latestMessagePreviewText: { messages, fallback in
                MessageTimelineState().latestPreviewText(in: messages, fallback: fallback)
            },
            latestMessageUpdatedAt: { messages, fallback in
                MessageTimelineState().latestUpdatedAt(in: messages, fallback: fallback)
            },
            isRetryableFailure: { message in
                Self.isRetryablePendingFailure(message)
            }
        )

        applyClientStateSnapshot(await clientStateEngine.snapshot())
        if effect.shouldSortConversations {
            sortConversations()
        }
        if let missingPendingMessageID = effect.missingPendingMessageID {
            IMClientLog.conversationStore.warning(
                "Pending mutate skipped: localMessageID not found localMessageID=\(missingPendingMessageID, privacy: .public)"
            )
        }
        await clientStateEngine.replaceState(clientStateSnapshot())

        return effect
    }

    private func reduceDomainEventState(_ event: IMConversationDomainEventStateEvent) {
        var state = IMConversationDomainEventState(
            processedEventIDs: processedDomainEventIDs,
            processedEventIDOrder: processedDomainEventIDOrder,
            ownerAggregateHighWatermarks: ownerAggregateHighWatermarks,
            cursor: domainEventCursor
        )
        domainEventStateReducer.reduce(event, state: &state)
        processedDomainEventIDs = state.processedEventIDs
        processedDomainEventIDOrder = state.processedEventIDOrder
        ownerAggregateHighWatermarks = state.ownerAggregateHighWatermarks
        domainEventCursor = state.cursor
    }

    private func reduceDomainEventStateUsingClientEngine(_ event: IMConversationDomainEventStateEvent) async {
        await clientStateEngine.replaceState(clientStateSnapshot())
        let snapshot = await clientStateEngine.reduceDomainEventState(event)
        applyClientStateSnapshot(snapshot)
        await clientStateEngine.replaceState(clientStateSnapshot())
    }

    private func deferredDomainEventState() -> IMConversationDeferredDomainEventState {
        IMConversationDeferredDomainEventState(
            eventsByMissingKey: deferredDomainEventsByMissingKey,
            fullRefreshConversationIDs: domainEventFullRefreshConversationIDs
        )
    }

    private func applyDeferredDomainEventState(_ state: IMConversationDeferredDomainEventState) {
        deferredDomainEventsByMissingKey = state.eventsByMissingKey
        domainEventFullRefreshConversationIDs = state.fullRefreshConversationIDs
    }

    @discardableResult
    private func markDomainEventFullRefreshConversation(_ conversationID: String) -> Bool {
        var state = deferredDomainEventState()
        let didMark = deferredDomainEventStateReducer.markFullRefreshConversation(
            conversationID: conversationID,
            state: &state
        )
        applyDeferredDomainEventState(state)
        return didMark
    }

    @discardableResult
    private func reduceMessageState(_ event: IMConversationMessageStateEvent) -> IMConversationMessageStateEffect {
        var state = IMConversationMessageState(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            statusMessage: statusMessage,
            pendingStreamSnapshotTargets: pendingStreamSnapshotTargets
        )
        let effect = conversationMessageStateReducer.reduce(
            event,
            state: &state,
            ensureConversationIndex: { conversationID, conversations in
                Self.ensureConversationIndex(for: conversationID, conversations: &conversations)
            },
            latestMessagePreviewText: { [self] messages, fallback in
                messageTimelineState.latestPreviewText(in: messages, fallback: fallback)
            },
            latestMessageUpdatedAt: { [self] messages, fallback in
                messageTimelineState.latestUpdatedAt(in: messages, fallback: fallback)
            },
            messageComparator: { left, right in
                Self.messageComparator(left, right)
            }
        )

        conversations = state.conversations
        selectedConversationID = state.selectedConversationID
        statusMessage = state.statusMessage
        pendingStreamSnapshotTargets = state.pendingStreamSnapshotTargets

        for cursorRefresh in effect.cursorRefreshes {
            refreshLatestLoadedTimelineCursor(
                for: cursorRefresh.conversationID,
                timelineItems: cursorRefresh.timelineItems
            )
        }
        if effect.shouldSortConversations {
            sortConversations()
        }

        return effect
    }

    @discardableResult
    private func reduceMessageStateUsingClientEngine(
        _ event: IMConversationMessageStateEvent,
        synchronizeBeforeReduce: Bool = true
    ) async -> IMConversationMessageStateEffect {
        if synchronizeBeforeReduce {
            await clientStateEngine.replaceState(clientStateSnapshot())
        }
        let effect = await clientStateEngine.reduceMessageState(
            event,
            ensureConversationIndex: { conversationID, conversations in
                Self.ensureConversationIndex(for: conversationID, conversations: &conversations)
            },
            latestMessagePreviewText: { messages, fallback in
                MessageTimelineState().latestPreviewText(in: messages, fallback: fallback)
            },
            latestMessageUpdatedAt: { messages, fallback in
                MessageTimelineState().latestUpdatedAt(in: messages, fallback: fallback)
            },
            messageComparator: { left, right in
                Self.messageComparator(left, right)
            }
        )
        applyClientStateSnapshot(await clientStateEngine.snapshot())

        for cursorRefresh in effect.cursorRefreshes {
            refreshLatestLoadedTimelineCursor(
                for: cursorRefresh.conversationID,
                timelineItems: cursorRefresh.timelineItems
            )
        }
        if effect.shouldSortConversations {
            sortConversations()
        }
        await clientStateEngine.replaceState(clientStateSnapshot())

        return effect
    }

    private func reduceTimelineState(_ event: IMConversationTimelineStateEvent) {
        var state = IMConversationTimelineState(
            conversations: conversations,
            statusMessage: statusMessage
        )
        let effect = conversationTimelineStateReducer.reduce(
            event,
            state: &state,
            ensureConversationIndex: { conversationID, conversations in
                Self.ensureConversationIndex(for: conversationID, conversations: &conversations)
            },
            makeMessages: { [self] responses, currentUserID in
                makeMessages(from: responses, currentUserID: currentUserID)
            },
            makeNotices: { [self] responses in
                makeNotices(from: responses)
            },
            mergeMessages: { [self] existing, serverMessages, preserveExistingServerMessages in
                mergeMessages(
                    existing: existing,
                    serverMessages: serverMessages,
                    preserveExistingServerMessages: preserveExistingServerMessages
                )
            },
            hasOlderHistory: { [self] serverMessages in
                hasOlderHistory(in: serverMessages)
            }
        )

        conversations = state.conversations
        statusMessage = state.statusMessage
        applyTimelineStateEffect(effect)
    }

    private func reduceTimelineStateUsingClientEngine(_ event: IMConversationTimelineStateEvent) async {
        await clientStateEngine.replaceState(clientStateSnapshot())
        let effect = await clientStateEngine.reduceTimelineState(
            event,
            ensureConversationIndex: { conversationID, conversations in
                Self.ensureConversationIndex(for: conversationID, conversations: &conversations)
            },
            makeMessages: { responses, currentUserID in
                Self.makeMessagesForClientEngine(from: responses, currentUserID: currentUserID)
            },
            makeNotices: { responses in
                Self.makeNoticesForClientEngine(from: responses)
            },
            mergeMessages: { existing, serverMessages, preserveExistingServerMessages in
                Self.mergeMessagesForClientEngine(
                    existing: existing,
                    serverMessages: serverMessages,
                    preserveExistingServerMessages: preserveExistingServerMessages
                )
            },
            hasOlderHistory: { serverMessages in
                Self.hasOlderHistoryForClientEngine(in: serverMessages)
            }
        )

        applyClientStateSnapshot(await clientStateEngine.snapshot())
        applyTimelineStateEffect(effect)
        await clientStateEngine.replaceState(clientStateSnapshot())
    }

    private func applyTimelineStateEffect(_ effect: IMConversationTimelineStateEffect) {
        for cursorRefresh in effect.cursorRefreshes {
            switch cursorRefresh.kind {
            case .loadedRange:
                refreshLoadedTimelineCursors(
                    for: cursorRefresh.conversationID,
                    timelineItems: cursorRefresh.timelineItems
                )
            case .latestOnly:
                refreshLatestLoadedTimelineCursor(
                    for: cursorRefresh.conversationID,
                    timelineItems: cursorRefresh.timelineItems
                )
            }
        }

        for fullRefreshClear in effect.fullRefreshClears {
            clearDomainEventFullRefreshState(
                for: fullRefreshClear.conversationID,
                currentUserID: fullRefreshClear.currentUserID
            )
        }

        if effect.shouldSortConversations {
            sortConversations()
        }
    }

    private func markConversationNeedsFullRefresh(_ conversationID: String) {
        var state = IMConversationTimelineState(
            conversations: conversations,
            statusMessage: statusMessage
        )
        conversationTimelineStateReducer.markConversationNeedsFullRefresh(
            conversationID: conversationID,
            state: &state
        )
        conversations = state.conversations
        statusMessage = state.statusMessage
    }

    private func ensureConversationIndex(for conversationID: String) -> Int {
        Self.ensureConversationIndex(for: conversationID, conversations: &conversations)
    }

    nonisolated private static func ensureConversationIndex(
        for conversationID: String,
        conversations: inout [IMConversation]
    ) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }

        let conversation = IMConversation(
            id: conversationID,
            title: Self.fallbackTitle(for: conversationID),
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
        reduceConversationState(.applyConversationSummaryContent(response))
    }

    nonisolated private static func upsertConversationSummaryContent(
        _ response: IMConversationSummaryResponseBody,
        conversations: inout [IMConversation]
    ) {
        let conversationID = response.id.uuidString
        let index = ensureConversationIndex(for: conversationID, conversations: &conversations)
        conversations[index] = Self.conversationSummary(
            from: response,
            existing: conversations[index]
        )
    }

    nonisolated private static func upsertConversationSummaryContents(
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
                conversations[index] = Self.conversationSummary(
                    from: response,
                    existing: conversations[index]
                )
            } else {
                conversations.append(
                    Self.conversationSummary(
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

    nonisolated private static func conversationSummary(
        from response: IMConversationSummaryResponseBody,
        existing: IMConversation?
    ) -> IMConversation {
        let conversationID = response.id.uuidString
        let isActivityOnlySummary = isActivityOnlySummaryContent(response)
        let conversationKind = isActivityOnlySummary
            ? existing?.kind ?? (IMConversationKind(rawValue: response.kind) ?? .group)
            : IMConversationKind(rawValue: response.kind) ?? .group
        let directPeer = Self.directPeer(from: response, conversationKind: conversationKind)
        let previewText = MessageDerivedStateReducer().mergedSummaryPreviewText(
            existing: existing,
            responseLastMessage: response.lastMessage
        )
        let responseMemberUserIDs = response.memberUserIDs.sorted { $0.uuidString < $1.uuidString }
        let shouldPreserveExistingMembers = isActivityOnlySummary || (responseMemberUserIDs.isEmpty && response.memberCount > 0)
        let memberUserIDs = shouldPreserveExistingMembers
            ? existing?.memberUserIDs ?? []
            : responseMemberUserIDs
        let members = shouldPreserveExistingMembers
            ? existing?.members ?? []
            : (existing?.members ?? []).filter { responseMemberUserIDs.contains($0.id) }
        let resolvedDirectPeer = isActivityOnlySummary ? existing?.directPeer ?? directPeer : directPeer

        return IMConversation(
            id: conversationID,
            title: Self.normalizedTitle(
                isActivityOnlySummary ? existing?.title ?? response.title : response.title,
                conversationID: conversationID,
                conversationKind: conversationKind,
                directPeer: resolvedDirectPeer
            ),
            kind: conversationKind,
            directMessagingState: Self.directMessagingState(
                from: isActivityOnlySummary ? existing?.directMessagingState?.rawValue ?? response.directMessagingState : response.directMessagingState,
                conversationKind: conversationKind
            ),
            directPeer: resolvedDirectPeer,
            notice: isActivityOnlySummary ? existing?.notice ?? response.notice : response.notice,
            avatarPreset: isActivityOnlySummary ? existing?.avatarPreset ?? response.avatarPreset : response.avatarPreset,
            muteAll: isActivityOnlySummary ? existing?.muteAll ?? response.muteAll : response.muteAll,
            memberCount: isActivityOnlySummary ? existing?.memberCount ?? response.memberCount : response.memberCount,
            memberUserIDs: memberUserIDs,
            members: members,
            messages: existing?.messages ?? [],
            notices: existing?.notices ?? [],
            lastMessagePreviewText: previewText,
            hasMoreHistory: existing?.hasMoreHistory ?? false,
            serverLastReadSequence: isActivityOnlySummary
                ? existing?.serverLastReadSequence ?? UInt64(response.lastReadSequence)
                : UInt64(response.lastReadSequence),
            serverUnreadCount: isActivityOnlySummary
                ? existing?.serverUnreadCount ?? response.unreadCount
                : response.unreadCount,
            localUnreadDelta: existing?.localUnreadDelta ?? 0,
            isPinned: isActivityOnlySummary ? existing?.isPinned ?? response.isPinned : response.isPinned,
            pinnedAt: isActivityOnlySummary ? existing?.pinnedAt ?? response.pinnedAt : response.pinnedAt,
            isMuted: isActivityOnlySummary ? existing?.isMuted ?? response.isMuted : response.isMuted,
            draftText: existing?.draftText ?? "",
            draftUpdatedAt: existing?.draftUpdatedAt,
            updatedAt: response.updatedAt
        )
    }

    nonisolated private static func isActivityOnlySummaryContent(
        _ response: IMConversationSummaryResponseBody
    ) -> Bool {
        response.title == nil
            && response.directMessagingState == nil
            && response.directPeer == nil
            && response.notice == nil
            && response.avatarPreset == nil
            && response.memberCount == 0
            && response.memberUserIDs.isEmpty
            && response.lastMessage != nil
            && response.lastReadSequence == 0
            && response.unreadCount == 0
            && response.isPinned == false
            && response.pinnedAt == nil
            && response.isMuted == false
            && response.createdAt == nil
    }

    nonisolated private static func replacementConversationSummary(
        from response: IMConversationSummaryResponseBody,
        existing: IMConversation?
    ) -> IMConversation {
        let conversationID = response.id.uuidString
        let conversationKind = IMConversationKind(rawValue: response.kind) ?? .group
        let directPeer = Self.directPeer(from: response, conversationKind: conversationKind)
        let previewText = MessageDerivedStateReducer().mergedSummaryPreviewText(
            existing: existing,
            responseLastMessage: response.lastMessage
        )

        return IMConversation(
            id: conversationID,
            title: Self.normalizedTitle(
                response.title,
                conversationID: conversationID,
                conversationKind: conversationKind,
                directPeer: directPeer
            ),
            kind: conversationKind,
            directMessagingState: Self.directMessagingState(
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
            notices: existing?.notices ?? [],
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

    func syncReplyJumpState() {
        replyJumpConversationID = detailState.replyJumpConversationID
        replyJumpTargetMessageID = detailState.replyJumpTargetMessageID
        replyJumpMatchedMessageID = detailState.replyJumpMatchedMessageID
        replyJumpState = detailState.replyJumpState
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

    nonisolated private static func normalizedTitle(
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
        return Self.fallbackTitle(for: conversationID)
    }

    private func updatedMessage(
        from response: IMConversationMessageResponseBody,
        currentUserID: UUID
    ) throws -> IMConversationMessage {
        let conversationID = response.conversationID.uuidString
        let stableMessageID = response.id.uuidString
        let effectiveTimestamp = response.createdAt ?? Date()
        var snapshotConversations = conversations
        let index = Self.ensureConversationIndex(
            for: conversationID,
            conversations: &snapshotConversations
        )
        let existingIndex = snapshotConversations[index].messages.firstIndex(where: {
            $0.id == stableMessageID || $0.serverMessageID == stableMessageID
        })

        if let existingIndex {
            var existing = snapshotConversations[index].messages[existingIndex]
            existing.serverMessageID = stableMessageID
            existing.serverSequence = UInt64(response.serverSequence)
            existing.timelineSequence = UInt64(response.timelineSequence)
            existing.senderUserID = response.senderUserID
            existing.content = response.content
            existing.derivedState = response.derivedState
            existing.createdAt = effectiveTimestamp
            existing.deliveryState = existing.direction == .outgoing ? .sent : .received
            return existing
        }

        return try IMConversationMessage(
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
                markDomainEventFullRefreshConversation(response.conversationID.uuidString)
                return nil
            }
        }
    }

    nonisolated private static func makeMessagesForClientEngine(
        from responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) -> [IMConversationMessage] {
        responses.compactMap { response in
            try? IMConversationMessage(
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
                markDomainEventFullRefreshConversation(response.conversationID.uuidString)
                return nil
            }
        }
    }

    nonisolated private static func makeNoticesForClientEngine(
        from responses: [IMTimelineNoticeResponseBody]
    ) -> [IMTimelineNotice] {
        responses.compactMap { response in
            try? IMTimelineNotice(
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

    nonisolated private static func mergeMessagesForClientEngine(
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

    nonisolated private static func hasOlderHistoryForClientEngine(in serverMessages: [IMConversationMessage]) -> Bool {
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

    nonisolated private static func fallbackTitle(for conversationID: String) -> String {
        "会话 \(conversationID.prefix(8).lowercased())"
    }

    nonisolated private static func directMessagingState(
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

    nonisolated private static func directPeer(
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

    nonisolated private static let nonRetryableOutgoingFailureMessages: Set<String> = [
        "你们已不是好友，当前会话不能继续发送消息。",
        "你们还不是好友，对方回复前只能发送一条消息。",
        "会话 ID 无效。",
        "会话不存在或你已不在该会话中。",
        "当前消息类型不支持发送。",
        "消息内容不能为空。",
        "附件上传失败，请稍后重试。"
    ]

    nonisolated private static func isRetryablePendingFailure(_ message: IMPendingConversationMessage) -> Bool {
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

    private func appendOutgoingMessage(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        let effect = reduceOutgoingState(
            .appendOutgoingMessage(
                content: content,
                conversationID: conversationID,
                senderUserID: senderUserID,
                deliveryState: deliveryState,
                shouldRegisterPendingRequest: shouldRegisterPendingRequest,
                localTransferState: localTransferState,
                requestID: UUID(),
                clientMessageID: UUID().uuidString,
                createdAt: Date()
            )
        )
        return (effect.placeholder, effect.request)
    }

    private func appendOutgoingMessageUsingClientEngine(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) async -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        let effect = await reduceOutgoingStateUsingClientEngine(
            .appendOutgoingMessage(
                content: content,
                conversationID: conversationID,
                senderUserID: senderUserID,
                deliveryState: deliveryState,
                shouldRegisterPendingRequest: shouldRegisterPendingRequest,
                localTransferState: localTransferState,
                requestID: UUID(),
                clientMessageID: UUID().uuidString,
                createdAt: Date()
            )
        )
        return (effect.placeholder, effect.request)
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
              conversations[conversationIndex].pendingMessages.contains(where: { $0.id == trimmedLocalMessageID })
        else {
            setStatusMessage("附件消息不存在。")
            return (false, nil)
        }

        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            setStatusMessage("当前消息类型不支持发送。")
            return (false, nil)
        }

        let effect = reduceOutgoingState(
            .updateUploadedOutgoingMedia(
                content: content,
                localMessageID: trimmedLocalMessageID,
                conversationID: trimmedConversationID,
                deliveryState: deliveryState,
                shouldRegisterPendingRequest: shouldRegisterPendingRequest,
                requestID: UUID()
            )
        )
        return (effect.didApply, effect.request)
    }

    private func updateUploadedOutgoingMediaAsync(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) async -> (didUpdate: Bool, request: IMOutgoingMessageRequest?) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocalMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedLocalMessageID.isEmpty else {
            return (false, nil)
        }
        guard conversations.first(where: { $0.id == trimmedConversationID })?
            .pendingMessages
            .contains(where: { $0.id == trimmedLocalMessageID }) == true
        else {
            await setStatusMessageAsync("附件消息不存在。")
            return (false, nil)
        }

        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            await setStatusMessageAsync("当前消息类型不支持发送。")
            return (false, nil)
        }

        let effect = await reduceOutgoingStateUsingClientEngine(
            .updateUploadedOutgoingMedia(
                content: content,
                localMessageID: trimmedLocalMessageID,
                conversationID: trimmedConversationID,
                deliveryState: deliveryState,
                shouldRegisterPendingRequest: shouldRegisterPendingRequest,
                requestID: UUID()
            )
        )
        return (effect.didApply, effect.request)
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

    nonisolated private static func matches(_ left: IMConversationMessage, _ right: IMConversationMessage) -> Bool {
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

    nonisolated private static func messageComparator(
        _ left: IMConversationMessage,
        _ right: IMConversationMessage
    ) -> Bool {
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
