import Foundation

/// Actor-owned client state used as the single mutation boundary for conversation data.
///
/// Reducers project focused slices out of this value, mutate them, then write the
/// resulting slice back so the main-actor store can consume immutable snapshots.
struct IMConversationClientState: Equatable, Sendable {
    var conversations: [IMConversation]
    var selectedConversationID: String?
    var statusMessage: String?
    var isLoadingConversations: Bool
    var conversationSummaryNextCursor: String?
    var hasMoreConversationSummaries: Bool
    var isLoadingMoreConversationSummaries: Bool
    var detailState: ConversationDetailState
    var outgoingQueueState: OutgoingQueueState
    var conversationSearchState: ConversationSearchState
    var pendingStreamSnapshotTargets: Set<IMActiveMessageStreamTarget>
    var domainEventState: IMConversationDomainEventState
    var deferredDomainEventState: IMConversationDeferredDomainEventState
    var domainEventDebugMetrics: IMDomainEventDebugMetrics

    init(
        conversations: [IMConversation] = [],
        selectedConversationID: String? = nil,
        statusMessage: String? = nil,
        isLoadingConversations: Bool = false,
        conversationSummaryNextCursor: String? = nil,
        hasMoreConversationSummaries: Bool = false,
        isLoadingMoreConversationSummaries: Bool = false,
        detailState: ConversationDetailState = ConversationDetailState(),
        outgoingQueueState: OutgoingQueueState = OutgoingQueueState(),
        conversationSearchState: ConversationSearchState = ConversationSearchState(),
        pendingStreamSnapshotTargets: Set<IMActiveMessageStreamTarget> = [],
        domainEventState: IMConversationDomainEventState = IMConversationDomainEventState(),
        deferredDomainEventState: IMConversationDeferredDomainEventState = IMConversationDeferredDomainEventState(),
        domainEventDebugMetrics: IMDomainEventDebugMetrics = IMDomainEventDebugMetrics()
    ) {
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
        self.statusMessage = statusMessage
        self.isLoadingConversations = isLoadingConversations
        self.conversationSummaryNextCursor = conversationSummaryNextCursor
        self.hasMoreConversationSummaries = hasMoreConversationSummaries
        self.isLoadingMoreConversationSummaries = isLoadingMoreConversationSummaries
        self.detailState = detailState
        self.outgoingQueueState = outgoingQueueState
        self.conversationSearchState = conversationSearchState
        self.pendingStreamSnapshotTargets = pendingStreamSnapshotTargets
        self.domainEventState = domainEventState
        self.deferredDomainEventState = deferredDomainEventState
        self.domainEventDebugMetrics = domainEventDebugMetrics
    }

    var summaryState: IMConversationStoreState {
        IMConversationStoreState(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            statusMessage: statusMessage,
            conversationSummaryNextCursor: conversationSummaryNextCursor,
            hasMoreConversationSummaries: hasMoreConversationSummaries,
            isLoadingMoreConversationSummaries: isLoadingMoreConversationSummaries
        )
    }

    mutating func applySummaryState(_ summaryState: IMConversationStoreState) {
        conversations = summaryState.conversations
        selectedConversationID = summaryState.selectedConversationID
        statusMessage = summaryState.statusMessage
        conversationSummaryNextCursor = summaryState.conversationSummaryNextCursor
        hasMoreConversationSummaries = summaryState.hasMoreConversationSummaries
        isLoadingMoreConversationSummaries = summaryState.isLoadingMoreConversationSummaries
    }

    var loadingState: IMConversationLoadingState {
        IMConversationLoadingState(
            isLoadingConversations: isLoadingConversations,
            isLoadingMoreConversationSummaries: isLoadingMoreConversationSummaries,
            detailState: detailState
        )
    }

    mutating func applyLoadingState(_ loadingState: IMConversationLoadingState) {
        isLoadingConversations = loadingState.isLoadingConversations
        isLoadingMoreConversationSummaries = loadingState.isLoadingMoreConversationSummaries
        detailState = loadingState.detailState
    }

    var messageState: IMConversationMessageState {
        IMConversationMessageState(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            statusMessage: statusMessage,
            pendingStreamSnapshotTargets: pendingStreamSnapshotTargets
        )
    }

    mutating func applyMessageState(_ messageState: IMConversationMessageState) {
        conversations = messageState.conversations
        selectedConversationID = messageState.selectedConversationID
        statusMessage = messageState.statusMessage
        pendingStreamSnapshotTargets = messageState.pendingStreamSnapshotTargets
    }

    var outgoingState: IMConversationOutgoingState {
        IMConversationOutgoingState(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            statusMessage: statusMessage,
            outgoingQueueState: outgoingQueueState
        )
    }

    mutating func applyOutgoingState(_ outgoingState: IMConversationOutgoingState) {
        conversations = outgoingState.conversations
        selectedConversationID = outgoingState.selectedConversationID
        statusMessage = outgoingState.statusMessage
        outgoingQueueState = outgoingState.outgoingQueueState
    }

    var timelineState: IMConversationTimelineState {
        IMConversationTimelineState(
            conversations: conversations,
            statusMessage: statusMessage
        )
    }

    mutating func applyTimelineState(_ timelineState: IMConversationTimelineState) {
        conversations = timelineState.conversations
        statusMessage = timelineState.statusMessage
    }

    var domainEventCursor: UInt64 {
        domainEventState.cursor
    }

    var healthSnapshot: IMConversationHealthSnapshot {
        IMConversationHealthSnapshot(
            domainEventCursor: domainEventState.cursor,
            deferredDomainEventCount: deferredDomainEventState.eventsByMissingKey.values.flatMap { $0 }.count,
            fullRefreshConversationCount: deferredDomainEventState.fullRefreshConversationIDs.count,
            domainEventMetrics: domainEventDebugMetrics
        )
    }
}

/// Serializes conversation mutations and publishes newest-only state snapshots.
///
/// The engine keeps raw conversation state off the SwiftUI rendering path. Callers
/// apply domain, loading, read, member, message, and outgoing mutations through
/// reducer-backed methods, then observe value snapshots through `snapshots()`.
actor IMConversationClientStateEngine {
    private var state: IMConversationClientState
    private var snapshotContinuations: [UUID: AsyncStream<IMConversationClientState>.Continuation] = [:]
    private let conversationStateReducer = IMConversationStoreStateReducer()
    private let conversationMessageStateReducer = IMConversationMessageStateReducer()
    private let conversationOutgoingStateReducer = IMConversationOutgoingStateReducer()
    private let conversationTimelineStateReducer = IMConversationTimelineStateReducer()
    private let conversationLoadingStateReducer = IMConversationLoadingStateReducer()
    private let domainEventStateReducer = IMConversationDomainEventStateReducer()
    private let domainEventDependencyStateReducer = IMConversationDomainEventDependencyStateReducer()
    private let deferredDomainEventStateReducer = IMConversationDeferredDomainEventStateReducer()

    init(state: IMConversationClientState = IMConversationClientState()) {
        self.state = state
    }

    func snapshot() -> IMConversationClientState {
        state
    }

    func replaceState(_ newState: IMConversationClientState) {
        state = newState
        yieldSnapshot()
    }

    /// Returns the current state immediately, then each committed state mutation.
    ///
    /// `bufferingNewest(1)` prevents a slow UI consumer from replaying stale
    /// intermediate states after a burst of realtime or pagination changes.
    func snapshots() -> AsyncStream<IMConversationClientState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: IMConversationClientState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(state)
        snapshotContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else {
                return
            }
            Task { await self.removeSnapshotContinuation(id) }
        }
        return stream
    }

    @discardableResult
    func reduceSummaryState(
        _ event: IMConversationStoreStateEvent,
        replacingSummaryContent: @Sendable (IMConversationSummaryResponseBody, IMConversation?) -> IMConversation,
        summaryContent: @Sendable (IMConversationSummaryResponseBody, IMConversation?) -> IMConversation,
        upsertSummaryContents: @Sendable ([IMConversationSummaryResponseBody], inout [IMConversation]) -> Void,
        upsertSummaryContent: @Sendable (IMConversationSummaryResponseBody, inout [IMConversation]) -> Void,
        ensureConversationIndex: @Sendable (String, inout [IMConversation]) -> Int
    ) -> IMConversationStoreStateEffect {
        var summaryState = state.summaryState
        let effect = conversationStateReducer.reduce(
            event,
            state: &summaryState,
            replacingSummaryContent: replacingSummaryContent,
            summaryContent: summaryContent,
            upsertSummaryContents: upsertSummaryContents,
            upsertSummaryContent: upsertSummaryContent,
            ensureConversationIndex: ensureConversationIndex
        )
        state.applySummaryState(summaryState)
        yieldSnapshot()
        return effect
    }

    func reduceLoadingState(_ event: IMConversationLoadingStateEvent) {
        var loadingState = state.loadingState
        conversationLoadingStateReducer.reduce(event, state: &loadingState)
        state.applyLoadingState(loadingState)
        yieldSnapshot()
    }

    @discardableResult
    func reduceMessageState(
        _ event: IMConversationMessageStateEvent,
        ensureConversationIndex: @Sendable (String, inout [IMConversation]) -> Int,
        latestMessagePreviewText: @Sendable ([IMConversationMessage], String) -> String,
        latestMessageUpdatedAt: @Sendable ([IMConversationMessage], Date) -> Date,
        messageComparator: @Sendable (IMConversationMessage, IMConversationMessage) -> Bool
    ) -> IMConversationMessageStateEffect {
        var messageState = state.messageState
        let effect = conversationMessageStateReducer.reduce(
            event,
            state: &messageState,
            ensureConversationIndex: ensureConversationIndex,
            latestMessagePreviewText: latestMessagePreviewText,
            latestMessageUpdatedAt: latestMessageUpdatedAt,
            messageComparator: messageComparator
        )
        state.applyMessageState(messageState)
        yieldSnapshot()
        return effect
    }

    @discardableResult
    func reduceOutgoingState(
        _ event: IMConversationOutgoingStateEvent,
        ensureConversationIndex: @Sendable (String, inout [IMConversation]) -> Int,
        latestMessagePreviewText: @Sendable ([IMConversationMessage], String) -> String,
        latestMessageUpdatedAt: @Sendable ([IMConversationMessage], Date) -> Date,
        isRetryableFailure: @Sendable (IMPendingConversationMessage) -> Bool
    ) -> IMConversationOutgoingStateEffect {
        var outgoingState = state.outgoingState
        let effect = conversationOutgoingStateReducer.reduce(
            event,
            state: &outgoingState,
            ensureConversationIndex: ensureConversationIndex,
            latestMessagePreviewText: latestMessagePreviewText,
            latestMessageUpdatedAt: latestMessageUpdatedAt,
            isRetryableFailure: isRetryableFailure
        )
        state.applyOutgoingState(outgoingState)
        yieldSnapshot()
        return effect
    }

    @discardableResult
    func reduceTimelineState(
        _ event: IMConversationTimelineStateEvent,
        ensureConversationIndex: @Sendable (String, inout [IMConversation]) -> Int,
        makeMessages: @Sendable ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        makeNotices: @Sendable ([IMTimelineNoticeResponseBody]) -> [IMTimelineNotice],
        mergeMessages: @Sendable ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        hasOlderHistory: @Sendable ([IMConversationMessage]) -> Bool
    ) -> IMConversationTimelineStateEffect {
        var timelineState = state.timelineState
        let effect = conversationTimelineStateReducer.reduce(
            event,
            state: &timelineState,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            makeNotices: makeNotices,
            mergeMessages: mergeMessages,
            hasOlderHistory: hasOlderHistory
        )
        state.applyTimelineState(timelineState)
        yieldSnapshot()
        return effect
    }

    @discardableResult
    func reduceDomainEventState(_ event: IMConversationDomainEventStateEvent) -> IMConversationClientState {
        domainEventStateReducer.reduce(event, state: &state.domainEventState)
        yieldSnapshot()
        return state
    }

    func storeDeferredEvent(_ deferredEvent: IMDeferredDomainEventState) -> IMDeferredDomainEventStoreResult {
        let result = deferredDomainEventStateReducer.store(
            deferredEvent,
            state: &state.deferredDomainEventState
        )
        yieldSnapshot()
        return result
    }

    func storeDeferredDomainEvent(
        payload: IMTCPChatDomainEventPayload,
        missingKey: IMDeferredDomainEventMissingKey?,
        conversationID: String?
    ) -> IMDeferredDomainEventStoreResult {
        let result = deferredDomainEventStateReducer.store(
            payload: payload,
            missingKey: missingKey,
            conversationID: conversationID,
            state: &state.deferredDomainEventState
        )
        switch result {
        case .stored:
            state.domainEventDebugMetrics.deferredStored += 1
            let effect = deferredDomainEventStateReducer.enforceLimits(
                conversationID: conversationID,
                state: &state.deferredDomainEventState
            )
            applyDeferredLimitEffect(effect)
        case .alreadyStored:
            let effect = deferredDomainEventStateReducer.enforceLimits(
                conversationID: conversationID,
                state: &state.deferredDomainEventState
            )
            applyDeferredLimitEffect(effect)
        case .notDeferrable:
            state.domainEventDebugMetrics.deferredNotDeferrable += 1
        case .encodeFailed:
            state.domainEventDebugMetrics.deferredEncodeFailed += 1
        }
        yieldSnapshot()
        return result
    }

    @discardableResult
    func enforceDeferredEventLimits(
        conversationID: String?,
        now: Date = Date()
    ) -> IMConversationDeferredDomainEventStateEffect {
        let effect = deferredDomainEventStateReducer.enforceLimits(
            conversationID: conversationID,
            now: now,
            state: &state.deferredDomainEventState
        )
        applyDeferredLimitEffect(effect)
        if !effect.removedEventIDs.isEmpty || effect.fullRefreshConversationID != nil {
            yieldSnapshot()
        }
        return effect
    }

    @discardableResult
    func markFullRefreshConversation(_ conversationID: String) -> Bool {
        let didMark = deferredDomainEventStateReducer.markFullRefreshConversation(
            conversationID: conversationID,
            state: &state.deferredDomainEventState
        )
        if didMark {
            yieldSnapshot()
        }
        return didMark
    }

    @discardableResult
    func clearFullRefreshConversation(_ conversationID: String) -> Bool {
        let didClear = deferredDomainEventStateReducer.clearFullRefreshConversation(
            conversationID: conversationID,
            state: &state.deferredDomainEventState
        )
        if didClear {
            yieldSnapshot()
        }
        return didClear
    }

    func deferredEventsForSnapshot(now: Date = Date()) -> [IMDeferredDomainEventState] {
        deferredDomainEventStateReducer.snapshotDeferredEvents(
            now: now,
            state: state.deferredDomainEventState
        )
    }

    func pendingDeferredEvents(now: Date = Date()) -> [IMDeferredDomainEventState] {
        deferredDomainEventStateReducer.pendingDeferredEvents(
            now: now,
            state: state.deferredDomainEventState
        )
    }

    func removeExpiredDeferredEvents(now: Date = Date()) -> [IMDeferredDomainEventState] {
        let expiredEvents = deferredDomainEventStateReducer.removeExpiredDeferredEvents(
            now: now,
            state: &state.deferredDomainEventState
        )
        guard !expiredEvents.isEmpty else {
            return []
        }
        state.domainEventDebugMetrics.deferredExpired += expiredEvents.count
        yieldSnapshot()
        return expiredEvents
    }

    func removeDeferredEvent(_ deferredEvent: IMDeferredDomainEventState) {
        deferredDomainEventStateReducer.removeDeferredEvent(
            deferredEvent,
            state: &state.deferredDomainEventState
        )
        yieldSnapshot()
    }

    func bumpDeferredRetryCount(for deferredEvent: IMDeferredDomainEventState) {
        deferredDomainEventStateReducer.bumpDeferredRetryCount(
            for: deferredEvent,
            state: &state.deferredDomainEventState
        )
        yieldSnapshot()
    }

    func hasFullRefreshConversation(_ conversationID: String) -> Bool {
        state.deferredDomainEventState.fullRefreshConversationIDs.contains(conversationID)
    }

    func dependencySnapshot() -> DomainEventProjectionReducer.DependencySnapshot {
        domainEventDependencyStateReducer.snapshot(
            conversations: state.conversations,
            processedEventIDs: state.domainEventState.processedEventIDs,
            ownerAggregateHighWatermarks: state.domainEventState.ownerAggregateHighWatermarks
        )
    }

    func hasMessage(id messageID: String, in conversationID: String) -> Bool {
        state.conversations
            .first(where: { $0.id == conversationID })?
            .messages
            .contains { $0.id == messageID || $0.serverMessageID == messageID } == true
    }

    func activeMessageStreamTargets() -> [IMActiveMessageStreamTarget] {
        state.conversations.flatMap { conversation in
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

    func consumePendingStreamSnapshotTargets() -> [IMActiveMessageStreamTarget] {
        let targets = Array(state.pendingStreamSnapshotTargets)
        guard !targets.isEmpty else {
            return []
        }
        state.pendingStreamSnapshotTargets.removeAll()
        yieldSnapshot()
        return targets
    }

    func removePendingOutgoingRequest(_ requestID: UUID) -> String? {
        let localMessageID = state.outgoingQueueState.removePendingRequest(requestID)
        if localMessageID != nil {
            yieldSnapshot()
        }
        return localMessageID
    }

    func recordInvalidCanonicalMessageDTO(conversationID: String?) {
        state.domainEventDebugMetrics.invalidCanonicalMessageDTOs += 1
        if let conversationID {
            _ = deferredDomainEventStateReducer.markFullRefreshConversation(
                conversationID: conversationID,
                state: &state.deferredDomainEventState
            )
        }
        yieldSnapshot()
    }

    func recordCatchUpCursorGap() {
        state.domainEventDebugMetrics.catchUpCursorGap += 1
        state.domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
        yieldSnapshot()
    }

    func recordCatchUpStoppedBeforeCursorAdvance() {
        state.domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
        yieldSnapshot()
    }

    func recordMissingRequiredNoticeCatchUp() {
        state.domainEventDebugMetrics.missingRequiredNotice += 1
        state.domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
        yieldSnapshot()
    }

    func recordInvalidProjectionCatchUp() {
        state.domainEventDebugMetrics.invalidDomainEventMetadata += 1
        state.domainEventDebugMetrics.invalidProjectionDTOs += 1
        state.domainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance += 1
        yieldSnapshot()
    }

    func recordInvalidDeferredPayload() {
        state.domainEventDebugMetrics.invalidDomainEventMetadata += 1
        state.domainEventDebugMetrics.invalidDeferredPayload += 1
        yieldSnapshot()
    }

    func recordDeferredFullRefreshRequested() {
        state.domainEventDebugMetrics.deferredFullRefreshRequested += 1
        yieldSnapshot()
    }

    func recordDeferredReplayApplied() {
        state.domainEventDebugMetrics.deferredReplayApplied += 1
        yieldSnapshot()
    }

    private func applyDeferredLimitEffect(_ effect: IMConversationDeferredDomainEventStateEffect) {
        guard let conversationID = effect.fullRefreshConversationID else {
            return
        }
        var timelineState = state.timelineState
        conversationTimelineStateReducer.markConversationNeedsFullRefresh(
            conversationID: conversationID,
            state: &timelineState
        )
        state.applyTimelineState(timelineState)
        state.domainEventDebugMetrics.deferredFullRefreshRequested += 1
    }

    private func yieldSnapshot() {
        for continuation in snapshotContinuations.values {
            continuation.yield(state)
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }
}

extension IMConversationDomainEventState {
    init() {
        self.init(
            processedEventIDs: [],
            processedEventIDOrder: [],
            ownerAggregateHighWatermarks: [:],
            cursor: 0
        )
    }
}

extension IMConversationDeferredDomainEventState {
    init() {
        self.init(
            eventsByMissingKey: [:],
            fullRefreshConversationIDs: []
        )
    }
}
