import Foundation
import IMClientKit
import Observation

/// Result of committing a single snapshot stream.
struct IMConversationSnapshotCommitResult: Equatable, Sendable {
    let didCommit: Bool
    let revision: UInt64
}

struct IMConversationSnapshotBatchCommitResult: Equatable, Sendable {
    let list: IMConversationSnapshotCommitResult?
    let chatPages: [String: IMConversationSnapshotCommitResult]

    var didCommit: Bool {
        list?.didCommit == true || chatPages.values.contains { $0.didCommit }
    }
}

struct IMConversationListSnapshotCommitRequest {
    let filter: IMConversationListFilter
    let identityForConversation: (IMConversation) -> IMConversationIdentityPresentation
}

struct IMConversationListSnapshotBuildRequest: Equatable, Sendable {
    let filter: IMConversationListFilter
    let identityPresentationsByConversationID: [String: IMConversationIdentityPresentation]
}

struct IMChatPageSnapshotCommitRequest: Equatable, Sendable {
    let conversationID: String
    let currentUserID: UUID?
    let blockedUserIDs: Set<UUID>
}

/// Snapshot of the main-actor conversation store captured at the projection boundary.
///
/// Builders receive this value instead of reading `IMConversationStore` directly, so
/// CPU work can stay value-based and UI views render only committed snapshots.
struct IMConversationSnapshotBuildState: Equatable, Sendable {
    let filteredConversations: [IMConversation]
    let conversations: [IMConversation]
    let selectedConversationID: String?
    let conversationMutationGeneration: UInt64
    let statusMessage: String?
    let isLoadingConversations: Bool
    let isLoadingMoreConversationSummaries: Bool
    let hasMoreConversationSummaries: Bool
    let searchText: String
    let queueSummariesByConversationID: [String: IMConversationQueueSummary]
    let receiptSummariesByConversationID: [String: IMConversationReceiptSummaryResponseBody]
    let isLoadingMessages: Bool
    let isLoadingMembers: Bool
    let retryableMessageIDs: Set<String>
    let retryablePendingMessageIDs: Set<String>

    static let empty = IMConversationSnapshotBuildState(
        filteredConversations: [],
        conversations: [],
        selectedConversationID: nil,
        conversationMutationGeneration: 0,
        statusMessage: nil,
        isLoadingConversations: false,
        isLoadingMoreConversationSummaries: false,
        hasMoreConversationSummaries: false,
        searchText: "",
        queueSummariesByConversationID: [:],
        receiptSummariesByConversationID: [:],
        isLoadingMessages: false,
        isLoadingMembers: false,
        retryableMessageIDs: [],
        retryablePendingMessageIDs: []
    )

    init(
        filteredConversations: [IMConversation],
        conversations: [IMConversation],
        selectedConversationID: String?,
        conversationMutationGeneration: UInt64,
        statusMessage: String?,
        isLoadingConversations: Bool,
        isLoadingMoreConversationSummaries: Bool,
        hasMoreConversationSummaries: Bool,
        searchText: String,
        queueSummariesByConversationID: [String: IMConversationQueueSummary],
        receiptSummariesByConversationID: [String: IMConversationReceiptSummaryResponseBody],
        isLoadingMessages: Bool,
        isLoadingMembers: Bool,
        retryableMessageIDs: Set<String>,
        retryablePendingMessageIDs: Set<String>
    ) {
        self.filteredConversations = filteredConversations
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
        self.conversationMutationGeneration = conversationMutationGeneration
        self.statusMessage = statusMessage
        self.isLoadingConversations = isLoadingConversations
        self.isLoadingMoreConversationSummaries = isLoadingMoreConversationSummaries
        self.hasMoreConversationSummaries = hasMoreConversationSummaries
        self.searchText = searchText
        self.queueSummariesByConversationID = queueSummariesByConversationID
        self.receiptSummariesByConversationID = receiptSummariesByConversationID
        self.isLoadingMessages = isLoadingMessages
        self.isLoadingMembers = isLoadingMembers
        self.retryableMessageIDs = retryableMessageIDs
        self.retryablePendingMessageIDs = retryablePendingMessageIDs
    }

    @MainActor
    init(conversationStore: IMConversationStore) {
        let conversations = conversationStore.conversations
        self.filteredConversations = conversationStore.filteredConversations
        self.conversations = conversations
        self.selectedConversationID = conversationStore.selectedConversationID
        self.conversationMutationGeneration = conversationStore.conversationMutationGeneration
        self.statusMessage = conversationStore.statusMessage
        self.isLoadingConversations = conversationStore.isLoadingConversations
        self.isLoadingMoreConversationSummaries = conversationStore.isLoadingMoreConversationSummaries
        self.hasMoreConversationSummaries = conversationStore.hasMoreConversationSummaries
        self.searchText = conversationStore.searchText
        self.queueSummariesByConversationID = Dictionary(
            uniqueKeysWithValues: conversations.map { conversation in
                (conversation.id, conversationStore.queueSummary(for: conversation.id))
            }
        )
        self.receiptSummariesByConversationID = conversationStore.receiptSummaries
        self.isLoadingMessages = conversationStore.isLoadingMessages
        self.isLoadingMembers = conversationStore.isLoadingMembers
        self.retryableMessageIDs = Set(
            conversations.flatMap(\.messages)
                .filter { conversationStore.isRetryableFailure($0) }
                .map(\.id)
        )
        self.retryablePendingMessageIDs = Set(
            conversations.flatMap(\.pendingMessages)
                .filter { conversationStore.isRetryableFailure($0) }
                .map(\.id)
        )
    }

    func queueSummary(for conversationID: String) -> IMConversationQueueSummary {
        queueSummariesByConversationID[conversationID] ?? IMConversationQueueSummary(
            queuedCount: 0,
            sendingCount: 0,
            retryableIssueCount: 0
        )
    }
}

/// Coalesced list commit request retained until the next snapshot flush.
struct IMConversationListSnapshotCommitPlan: Equatable, Sendable {
    let filter: IMConversationListFilter
}

/// Separates pending commit batches for independent view scopes.
struct IMConversationSnapshotCommitScopeID: Equatable, Hashable, Sendable {
    private let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Reason a snapshot refresh was requested.
///
/// Reasons are carried into logs and tests so commit coalescing stays auditable
/// without leaking store-level objects into SwiftUI rendering.
enum IMConversationSnapshotInvalidation: Equatable, Sendable, CustomStringConvertible {
    case appear
    case task(String)
    case opened(String)
    case conversationGenerationChanged(UInt64)
    case selectedConversationChanged(String?)
    case searchChanged(String)
    case filterChanged(IMConversationListFilter)
    case listMetadataChanged
    case messagesLoadingChanged(Bool)
    case membersLoadingChanged(Bool)
    case receiptChanged(String)
    case currentUserChanged(UUID?)
    case blockedUsersChanged

    var description: String {
        switch self {
        case .appear:
            return "appear"
        case .task(let id):
            return "task:\(id)"
        case .opened(let id):
            return "opened:\(id)"
        case .conversationGenerationChanged(let generation):
            return "generationChanged:\(generation)"
        case .selectedConversationChanged(let id):
            return "selectedChanged:\(id ?? "nil")"
        case .searchChanged(let text):
            return "searchChanged:\(text)"
        case .filterChanged(let filter):
            return "filterChanged:\(filter.rawValue)"
        case .listMetadataChanged:
            return "listMetadataChanged"
        case .messagesLoadingChanged(let isLoading):
            return "messagesLoadingChanged:\(isLoading)"
        case .membersLoadingChanged(let isLoading):
            return "membersLoadingChanged:\(isLoading)"
        case .receiptChanged(let conversationID):
            return "receiptChanged:\(conversationID)"
        case .currentUserChanged(let id):
            return "currentUserChanged:\(id?.uuidString ?? "nil")"
        case .blockedUsersChanged:
            return "blockedUsersChanged"
        }
    }
}

/// One invalidation event plus the concrete snapshot scopes that should refresh.
struct IMConversationSnapshotCommitEvent: Equatable, Sendable {
    let invalidation: IMConversationSnapshotInvalidation
    let list: IMConversationListSnapshotCommitPlan?
    let chatPages: [IMChatPageSnapshotCommitRequest]

    init(
        _ invalidation: IMConversationSnapshotInvalidation,
        list: IMConversationListSnapshotCommitPlan? = nil,
        chatPages: [IMChatPageSnapshotCommitRequest] = []
    ) {
        self.invalidation = invalidation
        self.list = list
        self.chatPages = chatPages
    }
}

/// Drained set of invalidations after the coordinator has merged a burst.
struct IMConversationSnapshotCommitPlan: Equatable, Sendable {
    let invalidations: [IMConversationSnapshotInvalidation]
    let list: IMConversationListSnapshotCommitPlan?
    let chatPages: [IMChatPageSnapshotCommitRequest]

    var reasonSummary: String {
        invalidations.map(\.description).joined(separator: ",")
    }
}

/// Built snapshots and commit metadata returned to the main-actor view layer.
struct IMConversationSnapshotCommitExecution: Equatable, Sendable {
    let plan: IMConversationSnapshotCommitPlan
    let listSnapshot: IMConversationListSnapshot?
    let chatPageSnapshots: [String: IMChatPageSnapshot]
    let batchCommit: IMConversationSnapshotBatchCommitResult
}

struct IMConversationSnapshotBatchBuildCommitResult: Equatable, Sendable {
    let listSnapshot: IMConversationListSnapshot?
    let chatPageSnapshots: [String: IMChatPageSnapshot]
    let commit: IMConversationSnapshotBatchCommitResult
}

enum IMConversationSnapshotStateEvent: Equatable, Sendable {
    case replaceConversationState(IMConversationSnapshotBuildState)
}

private struct IMConversationSnapshotCommitReducer: Equatable, Sendable {
    private var pendingInvalidations: [IMConversationSnapshotInvalidation] = []
    private var pendingList: IMConversationListSnapshotCommitPlan?
    private var pendingChatPageOrder: [String] = []
    private var pendingChatPages: [String: IMChatPageSnapshotCommitRequest] = [:]
    private var isFlushScheduled = false

    mutating func enqueue(_ event: IMConversationSnapshotCommitEvent) -> Bool {
        pendingInvalidations.append(event.invalidation)
        if let list = event.list {
            pendingList = list
        }
        for chatPage in event.chatPages {
            if pendingChatPages[chatPage.conversationID] == nil {
                pendingChatPageOrder.append(chatPage.conversationID)
            }
            pendingChatPages[chatPage.conversationID] = chatPage
        }

        guard !isFlushScheduled else {
            return false
        }

        isFlushScheduled = true
        return true
    }

    mutating func drain() -> IMConversationSnapshotCommitPlan {
        defer {
            resetPending()
        }

        return IMConversationSnapshotCommitPlan(
            invalidations: pendingInvalidations,
            list: pendingList,
            chatPages: pendingChatPageOrder.compactMap { pendingChatPages[$0] }
        )
    }

    mutating func cancelPending() {
        resetPending()
    }

    private mutating func resetPending() {
        pendingInvalidations = []
        pendingList = nil
        pendingChatPageOrder = []
        pendingChatPages = [:]
        isFlushScheduled = false
    }
}

/// Builds and commits the snapshots described by a drained commit plan.
@MainActor
struct IMConversationSnapshotCommitExecutor {
    func commitListAndChatSnapshots(
        plan: IMConversationSnapshotCommitPlan,
        from conversationStore: IMConversationStore,
        to snapshotStore: IMConversationSnapshotStore,
        identityForConversation: @escaping (IMConversation) -> IMConversationIdentityPresentation
    ) async -> IMConversationSnapshotCommitExecution {
        let listRequest = plan.list.map { listPlan in
            IMConversationListSnapshotCommitRequest(
                filter: listPlan.filter,
                identityForConversation: identityForConversation
            )
        }
        let result = await snapshotStore.commitSnapshotBatchResult(
            from: conversationStore,
            list: listRequest,
            chatPages: plan.chatPages
        )
        return IMConversationSnapshotCommitExecution(
            plan: plan,
            listSnapshot: result.listSnapshot,
            chatPageSnapshots: result.chatPageSnapshots,
            batchCommit: result.commit
        )
    }

    func commitChatSnapshots(
        plan: IMConversationSnapshotCommitPlan,
        from conversationStore: IMConversationStore,
        to snapshotStore: IMConversationSnapshotStore
    ) async -> IMConversationSnapshotCommitExecution {
        let result = await snapshotStore.commitSnapshotBatchResult(
            from: conversationStore,
            chatPages: plan.chatPages
        )
        return IMConversationSnapshotCommitExecution(
            plan: plan,
            listSnapshot: result.listSnapshot,
            chatPageSnapshots: result.chatPageSnapshots,
            batchCommit: result.commit
        )
    }
}

/// Batches invalidations for one run-loop-sized window before committing snapshots.
///
/// The default 16 ms delay lets realtime, loading, receipt, and selection changes
/// collapse into a single UI-visible commit when they arrive together.
@MainActor
final class IMConversationSnapshotCommitCoordinator {
    private let flushDelayNanoseconds: UInt64
    private var flushTask: Task<Void, Never>?

    init(
        flushDelayNanoseconds: UInt64 = 16_000_000
    ) {
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    func schedule(
        _ event: IMConversationSnapshotCommitEvent,
        scopeID: IMConversationSnapshotCommitScopeID,
        to snapshotStore: IMConversationSnapshotStore,
        flush: @escaping @MainActor (IMConversationSnapshotCommitPlan) async -> Void
    ) async {
        let didScheduleFlush = await snapshotStore.enqueueSnapshotCommitEvent(
            event,
            scopeID: scopeID
        )
        guard didScheduleFlush else {
            return
        }

        flushTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: flushDelayNanoseconds)
            guard !Task.isCancelled else {
                await snapshotStore.cancelPendingSnapshotCommitPlan(scopeID: scopeID)
                return
            }

            let plan = await snapshotStore.drainSnapshotCommitPlan(scopeID: scopeID)
            await flush(plan)
            flushTask = nil
        }
    }

    func cancelPending(
        scopeID: IMConversationSnapshotCommitScopeID,
        in snapshotStore: IMConversationSnapshotStore
    ) async {
        flushTask?.cancel()
        flushTask = nil
        await snapshotStore.cancelPendingSnapshotCommitPlan(scopeID: scopeID)
    }
}

/// Main-actor facade used by SwiftUI views to schedule coalesced snapshot commits.
@MainActor
final class IMConversationSnapshotCommitPipeline {
    private let scopeID: IMConversationSnapshotCommitScopeID
    private let coordinator: IMConversationSnapshotCommitCoordinator
    private let executor: IMConversationSnapshotCommitExecutor

    init(
        scopeID: IMConversationSnapshotCommitScopeID = IMConversationSnapshotCommitScopeID(),
        coordinator: IMConversationSnapshotCommitCoordinator = IMConversationSnapshotCommitCoordinator(),
        executor: IMConversationSnapshotCommitExecutor = IMConversationSnapshotCommitExecutor()
    ) {
        self.scopeID = scopeID
        self.coordinator = coordinator
        self.executor = executor
    }

    func scheduleListAndChatCommit(
        _ event: IMConversationSnapshotCommitEvent,
        from conversationStore: IMConversationStore,
        to snapshotStore: IMConversationSnapshotStore,
        identityForConversation: @escaping (IMConversation) -> IMConversationIdentityPresentation,
        didCommit: @escaping @MainActor (IMConversationSnapshotCommitExecution) -> Void
    ) async {
        await coordinator.schedule(
            event,
            scopeID: scopeID,
            to: snapshotStore
        ) { [executor] plan in
            let execution = await executor.commitListAndChatSnapshots(
                plan: plan,
                from: conversationStore,
                to: snapshotStore,
                identityForConversation: identityForConversation
            )
            didCommit(execution)
        }
    }

    func scheduleChatCommit(
        _ event: IMConversationSnapshotCommitEvent,
        from conversationStore: IMConversationStore,
        to snapshotStore: IMConversationSnapshotStore,
        didCommit: @escaping @MainActor (IMConversationSnapshotCommitExecution) -> Void
    ) async {
        await coordinator.schedule(
            event,
            scopeID: scopeID,
            to: snapshotStore
        ) { [executor] plan in
            let execution = await executor.commitChatSnapshots(
                plan: plan,
                from: conversationStore,
                to: snapshotStore
            )
            didCommit(execution)
        }
    }

    func cancelPending(in snapshotStore: IMConversationSnapshotStore) async {
        await coordinator.cancelPending(
            scopeID: scopeID,
            in: snapshotStore
        )
    }
}

struct IMConversationListSnapshotEvent: Equatable, Sendable {
    let snapshot: IMConversationListSnapshot
    let revision: UInt64
}

struct IMChatPageSnapshotEvent: Equatable, Sendable {
    let conversationID: String
    let snapshot: IMChatPageSnapshot
    let revision: UInt64
}

/// Stores committed UI snapshots and publishes newest-only events per snapshot stream.
///
/// The actor owns revision counters and stream continuations. List snapshots and each
/// chat page snapshot are revisioned independently so detail views subscribe only to
/// the conversation they render.
actor IMConversationSnapshotEngine {
    private var conversationState: IMConversationSnapshotBuildState
    private var listSnapshot: IMConversationListSnapshot
    private var listCommitRevision: UInt64
    private var listSnapshotEventContinuations: [UUID: AsyncStream<IMConversationListSnapshotEvent>.Continuation] = [:]
    private var chatPageSnapshots: [String: IMChatPageSnapshot] = [:]
    private var chatPageCommitRevisions: [String: UInt64] = [:]
    private var chatPageSnapshotEventContinuations: [String: [UUID: AsyncStream<IMChatPageSnapshotEvent>.Continuation]] = [:]
    private var commitReducers: [IMConversationSnapshotCommitScopeID: IMConversationSnapshotCommitReducer] = [:]

    init(
        initialListSnapshot: IMConversationListSnapshot,
        initialListCommitRevision: UInt64 = 0,
        initialConversationState: IMConversationSnapshotBuildState = .empty
    ) {
        self.conversationState = initialConversationState
        self.listSnapshot = initialListSnapshot
        self.listCommitRevision = initialListCommitRevision
    }

    func currentConversationState() -> IMConversationSnapshotBuildState {
        conversationState
    }

    func reduceState(_ event: IMConversationSnapshotStateEvent) {
        switch event {
        case .replaceConversationState(let state):
            conversationState = state
        }
    }

    func currentListSnapshot() -> IMConversationListSnapshot {
        listSnapshot
    }

    func currentListCommitRevision() -> UInt64 {
        listCommitRevision
    }

    func currentChatPageSnapshot(
        for conversationID: String,
        defaultSnapshot: IMChatPageSnapshot
    ) -> IMChatPageSnapshot {
        chatPageSnapshots[conversationID] ?? defaultSnapshot
    }

    func currentChatPageCommitRevision(for conversationID: String) -> UInt64 {
        chatPageCommitRevisions[conversationID] ?? 0
    }

    func enqueueCommitEvent(
        _ event: IMConversationSnapshotCommitEvent,
        scopeID: IMConversationSnapshotCommitScopeID
    ) -> Bool {
        var reducer = commitReducers[scopeID] ?? IMConversationSnapshotCommitReducer()
        let didScheduleFlush = reducer.enqueue(event)
        commitReducers[scopeID] = reducer
        return didScheduleFlush
    }

    func drainCommitPlan(scopeID: IMConversationSnapshotCommitScopeID) -> IMConversationSnapshotCommitPlan {
        var reducer = commitReducers[scopeID] ?? IMConversationSnapshotCommitReducer()
        let plan = reducer.drain()
        commitReducers[scopeID] = nil
        return plan
    }

    func cancelPendingCommitPlan(scopeID: IMConversationSnapshotCommitScopeID) {
        commitReducers[scopeID] = nil
    }

    func buildAndCommitListSnapshot(
        state: IMConversationSnapshotBuildState,
        request: IMConversationListSnapshotBuildRequest
    ) -> (snapshot: IMConversationListSnapshot, commit: IMConversationSnapshotCommitResult) {
        reduceState(.replaceConversationState(state))
        return buildAndCommitListSnapshot(request: request)
    }

    func buildAndCommitListSnapshot(
        request: IMConversationListSnapshotBuildRequest
    ) -> (snapshot: IMConversationListSnapshot, commit: IMConversationSnapshotCommitResult) {
        let snapshot = listSnapshot(request: request)
        let commit = commitListSnapshot(snapshot)
        return (snapshot, commit)
    }

    func buildAndCommitChatPageSnapshot(
        state: IMConversationSnapshotBuildState,
        request: IMChatPageSnapshotCommitRequest
    ) -> (snapshot: IMChatPageSnapshot, commit: IMConversationSnapshotCommitResult) {
        reduceState(.replaceConversationState(state))
        return buildAndCommitChatPageSnapshot(request: request)
    }

    func buildAndCommitChatPageSnapshot(
        request: IMChatPageSnapshotCommitRequest
    ) -> (snapshot: IMChatPageSnapshot, commit: IMConversationSnapshotCommitResult) {
        let snapshot = chatPageSnapshot(request: request)
        let commit = commitChatPageSnapshot(
            snapshot,
            conversationID: request.conversationID
        )
        return (snapshot, commit)
    }

    func buildAndCommitSnapshotBatch(
        state: IMConversationSnapshotBuildState,
        list: IMConversationListSnapshotBuildRequest?,
        chatPages: [IMChatPageSnapshotCommitRequest]
    ) -> IMConversationSnapshotBatchBuildCommitResult {
        reduceState(.replaceConversationState(state))
        return buildAndCommitSnapshotBatch(
            list: list,
            chatPages: chatPages
        )
    }

    func buildAndCommitSnapshotBatch(
        list: IMConversationListSnapshotBuildRequest?,
        chatPages: [IMChatPageSnapshotCommitRequest]
    ) -> IMConversationSnapshotBatchBuildCommitResult {
        let builtListSnapshot = list.map { listSnapshot(request: $0) }
        var builtChatSnapshots: [String: IMChatPageSnapshot] = [:]
        var chatPageOrder: [String] = []
        for chatPage in chatPages where builtChatSnapshots[chatPage.conversationID] == nil {
            builtChatSnapshots[chatPage.conversationID] = chatPageSnapshot(request: chatPage)
            chatPageOrder.append(chatPage.conversationID)
        }

        let listCommit = builtListSnapshot.map { applyListSnapshot($0) }
        var chatPageCommits: [String: IMConversationSnapshotCommitResult] = [:]
        for conversationID in chatPageOrder {
            guard let snapshot = builtChatSnapshots[conversationID] else {
                continue
            }
            chatPageCommits[conversationID] = applyChatPageSnapshot(
                snapshot,
                conversationID: conversationID
            )
        }

        if listCommit?.didCommit == true {
            yieldListSnapshotEvent()
        }
        for conversationID in chatPageOrder where chatPageCommits[conversationID]?.didCommit == true {
            yieldChatPageSnapshotEvent(conversationID: conversationID)
        }

        return IMConversationSnapshotBatchBuildCommitResult(
            listSnapshot: builtListSnapshot,
            chatPageSnapshots: builtChatSnapshots,
            commit: IMConversationSnapshotBatchCommitResult(
                list: listCommit,
                chatPages: chatPageCommits
            )
        )
    }

    func commitListSnapshot(_ snapshot: IMConversationListSnapshot) -> IMConversationSnapshotCommitResult {
        let commit = applyListSnapshot(snapshot)
        if commit.didCommit {
            yieldListSnapshotEvent()
        }
        return commit
    }

    func commitChatPageSnapshot(
        _ snapshot: IMChatPageSnapshot,
        conversationID: String
    ) -> IMConversationSnapshotCommitResult {
        let commit = applyChatPageSnapshot(
            snapshot,
            conversationID: conversationID
        )
        if commit.didCommit {
            yieldChatPageSnapshotEvent(conversationID: conversationID)
        }
        return commit
    }

    private func applyListSnapshot(_ snapshot: IMConversationListSnapshot) -> IMConversationSnapshotCommitResult {
        guard snapshot != listSnapshot else {
            return IMConversationSnapshotCommitResult(
                didCommit: false,
                revision: listCommitRevision
            )
        }

        listSnapshot = snapshot
        listCommitRevision += 1
        return IMConversationSnapshotCommitResult(
            didCommit: true,
            revision: listCommitRevision
        )
    }

    private func applyChatPageSnapshot(
        _ snapshot: IMChatPageSnapshot,
        conversationID: String
    ) -> IMConversationSnapshotCommitResult {
        let revision = chatPageCommitRevisions[conversationID] ?? 0
        guard snapshot != chatPageSnapshots[conversationID] else {
            return IMConversationSnapshotCommitResult(
                didCommit: false,
                revision: revision
            )
        }

        chatPageSnapshots[conversationID] = snapshot
        let nextRevision = revision + 1
        chatPageCommitRevisions[conversationID] = nextRevision
        return IMConversationSnapshotCommitResult(
            didCommit: true,
            revision: nextRevision
        )
    }

    /// Emits list snapshot updates with a newest-only buffer for lagging consumers.
    func listSnapshotEvents() -> AsyncStream<IMConversationListSnapshotEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            Task {
                self.addListSnapshotEventContinuation(id, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeListSnapshotEventContinuation(id)
                }
            }
        }
    }

    /// Emits updates only for the requested conversation's chat page snapshot.
    func chatPageSnapshotEvents(
        for conversationID: String,
        defaultSnapshot: IMChatPageSnapshot
    ) -> AsyncStream<IMChatPageSnapshotEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            Task {
                self.addChatPageSnapshotEventContinuation(
                    id,
                    conversationID: conversationID,
                    defaultSnapshot: defaultSnapshot,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeChatPageSnapshotEventContinuation(
                        id: id,
                        conversationID: conversationID
                    )
                }
            }
        }
    }

    private func listSnapshot(request: IMConversationListSnapshotBuildRequest) -> IMConversationListSnapshot {
        IMConversationListSnapshotBuilder().build(
            conversations: conversationState.filteredConversations,
            selectedConversationID: conversationState.selectedConversationID,
            filter: request.filter,
            generation: conversationState.conversationMutationGeneration,
            statusMessage: conversationState.statusMessage,
            isLoadingConversations: conversationState.isLoadingConversations,
            isLoadingMoreConversationSummaries: conversationState.isLoadingMoreConversationSummaries,
            hasMoreConversationSummaries: conversationState.hasMoreConversationSummaries,
            searchText: conversationState.searchText,
            identityForConversation: { conversation in
                request.identityPresentationsByConversationID[conversation.id] ?? IMConversationIdentityPresentation(
                    title: conversation.title,
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            },
            queueSummaryForConversationID: { conversationID in
                conversationState.queueSummary(for: conversationID)
            }
        )
    }

    private func chatPageSnapshot(request: IMChatPageSnapshotCommitRequest) -> IMChatPageSnapshot {
        IMChatPageSnapshotBuilder().build(
            conversationID: request.conversationID,
            generation: conversationState.conversationMutationGeneration,
            conversations: conversationState.conversations,
            queueSummary: conversationState.queueSummary(for: request.conversationID),
            receiptSummary: conversationState.receiptSummariesByConversationID[request.conversationID],
            statusMessage: conversationState.statusMessage,
            isLoadingMessages: conversationState.isLoadingMessages,
            isLoadingMembers: conversationState.isLoadingMembers,
            currentUserID: request.currentUserID,
            blockedUserIDs: request.blockedUserIDs,
            isRetryableMessageFailure: { message in
                conversationState.retryableMessageIDs.contains(message.id)
            },
            isRetryablePendingMessageFailure: { message in
                conversationState.retryablePendingMessageIDs.contains(message.id)
            }
        )
    }

    private func addListSnapshotEventContinuation(
        _ id: UUID,
        continuation: AsyncStream<IMConversationListSnapshotEvent>.Continuation
    ) {
        listSnapshotEventContinuations[id] = continuation
        continuation.yield(currentListSnapshotEvent())
    }

    private func yieldListSnapshotEvent() {
        let event = currentListSnapshotEvent()
        for continuation in listSnapshotEventContinuations.values {
            continuation.yield(event)
        }
    }

    func currentListSnapshotEvent() -> IMConversationListSnapshotEvent {
        IMConversationListSnapshotEvent(
            snapshot: listSnapshot,
            revision: listCommitRevision
        )
    }

    private func removeListSnapshotEventContinuation(_ id: UUID) {
        listSnapshotEventContinuations[id] = nil
    }

    private func addChatPageSnapshotEventContinuation(
        _ id: UUID,
        conversationID: String,
        defaultSnapshot: IMChatPageSnapshot,
        continuation: AsyncStream<IMChatPageSnapshotEvent>.Continuation
    ) {
        var continuations = chatPageSnapshotEventContinuations[conversationID] ?? [:]
        continuations[id] = continuation
        chatPageSnapshotEventContinuations[conversationID] = continuations
        continuation.yield(
            currentChatPageSnapshotEvent(
                conversationID: conversationID,
                defaultSnapshot: defaultSnapshot
            )
        )
    }

    private func yieldChatPageSnapshotEvent(conversationID: String) {
        guard let continuations = chatPageSnapshotEventContinuations[conversationID],
              let snapshot = chatPageSnapshots[conversationID]
        else {
            return
        }
        let event = IMChatPageSnapshotEvent(
            conversationID: conversationID,
            snapshot: snapshot,
            revision: chatPageCommitRevisions[conversationID] ?? 0
        )
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func currentChatPageSnapshotEvent(
        conversationID: String,
        defaultSnapshot: IMChatPageSnapshot
    ) -> IMChatPageSnapshotEvent {
        IMChatPageSnapshotEvent(
            conversationID: conversationID,
            snapshot: chatPageSnapshots[conversationID] ?? defaultSnapshot,
            revision: chatPageCommitRevisions[conversationID] ?? 0
        )
    }

    private func removeChatPageSnapshotEventContinuation(
        id: UUID,
        conversationID: String
    ) {
        chatPageSnapshotEventContinuations[conversationID]?[id] = nil
        if chatPageSnapshotEventContinuations[conversationID]?.isEmpty == true {
            chatPageSnapshotEventContinuations[conversationID] = nil
        }
    }
}

@MainActor
@Observable
final class IMConversationSnapshotStore {
    private static let initialListSnapshot = IMConversationListSnapshot(
        generation: 0,
        filter: .all,
        rows: []
    )

    @ObservationIgnored private let snapshotEngine: IMConversationSnapshotEngine

    init(snapshotEngine: IMConversationSnapshotEngine? = nil) {
        let initialListSnapshot = Self.initialListSnapshot
        self.snapshotEngine = snapshotEngine ?? IMConversationSnapshotEngine(
            initialListSnapshot: initialListSnapshot
        )
    }

    func commitListSnapshot(
        from conversationStore: IMConversationStore,
        filter: IMConversationListFilter,
        identityForConversation: (IMConversation) -> IMConversationIdentityPresentation
    ) async -> IMConversationSnapshotCommitResult {
        let state = IMConversationSnapshotBuildState(conversationStore: conversationStore)
        let request = listSnapshotBuildRequest(
            filter: filter,
            state: state,
            identityForConversation: identityForConversation
        )
        let result = await snapshotEngine.buildAndCommitListSnapshot(
            state: state,
            request: request
        )
        return result.commit
    }

    func commitChatPageSnapshot(
        from conversationStore: IMConversationStore,
        conversationID: String,
        currentUserID: UUID?,
        blockedUserIDs: Set<UUID>
    ) async -> IMConversationSnapshotCommitResult {
        let state = IMConversationSnapshotBuildState(conversationStore: conversationStore)
        let request = IMChatPageSnapshotCommitRequest(
            conversationID: conversationID,
            currentUserID: currentUserID,
            blockedUserIDs: blockedUserIDs
        )
        let result = await snapshotEngine.buildAndCommitChatPageSnapshot(
            state: state,
            request: request
        )
        return result.commit
    }

    func commitSnapshotBatch(
        from conversationStore: IMConversationStore,
        list: IMConversationListSnapshotCommitRequest? = nil,
        chatPages: [IMChatPageSnapshotCommitRequest] = []
    ) async -> IMConversationSnapshotBatchCommitResult {
        let result = await commitSnapshotBatchResult(
            from: conversationStore,
            list: list,
            chatPages: chatPages
        )
        return result.commit
    }

    func commitSnapshotBatchResult(
        from conversationStore: IMConversationStore,
        list: IMConversationListSnapshotCommitRequest? = nil,
        chatPages: [IMChatPageSnapshotCommitRequest] = []
    ) async -> IMConversationSnapshotBatchBuildCommitResult {
        let state = IMConversationSnapshotBuildState(conversationStore: conversationStore)
        let listRequest = list.map {
            listSnapshotBuildRequest(
                filter: $0.filter,
                state: state,
                identityForConversation: $0.identityForConversation
            )
        }
        let result = await snapshotEngine.buildAndCommitSnapshotBatch(
            state: state,
            list: listRequest,
            chatPages: chatPages
        )
        return result
    }

    func enqueueSnapshotCommitEvent(
        _ event: IMConversationSnapshotCommitEvent,
        scopeID: IMConversationSnapshotCommitScopeID
    ) async -> Bool {
        await snapshotEngine.enqueueCommitEvent(
            event,
            scopeID: scopeID
        )
    }

    func drainSnapshotCommitPlan(
        scopeID: IMConversationSnapshotCommitScopeID
    ) async -> IMConversationSnapshotCommitPlan {
        await snapshotEngine.drainCommitPlan(scopeID: scopeID)
    }

    func cancelPendingSnapshotCommitPlan(
        scopeID: IMConversationSnapshotCommitScopeID
    ) async {
        await snapshotEngine.cancelPendingCommitPlan(scopeID: scopeID)
    }

    func currentListSnapshotEvent() async -> IMConversationListSnapshotEvent {
        await snapshotEngine.currentListSnapshotEvent()
    }

    func currentChatPageSnapshotEvent(for conversationID: String) async -> IMChatPageSnapshotEvent {
        await snapshotEngine.currentChatPageSnapshotEvent(
            conversationID: conversationID,
            defaultSnapshot: .empty(conversationID: conversationID)
        )
    }

    func listSnapshotEvents() async -> AsyncStream<IMConversationListSnapshotEvent> {
        await snapshotEngine.listSnapshotEvents()
    }

    func chatPageSnapshotEvents(for conversationID: String) async -> AsyncStream<IMChatPageSnapshotEvent> {
        await snapshotEngine.chatPageSnapshotEvents(
            for: conversationID,
            defaultSnapshot: .empty(conversationID: conversationID)
        )
    }

    private func listSnapshotBuildRequest(
        filter: IMConversationListFilter,
        state: IMConversationSnapshotBuildState,
        identityForConversation: (IMConversation) -> IMConversationIdentityPresentation
    ) -> IMConversationListSnapshotBuildRequest {
        IMConversationListSnapshotBuildRequest(
            filter: filter,
            identityPresentationsByConversationID: Dictionary(
                uniqueKeysWithValues: state.filteredConversations.map { conversation in
                    (conversation.id, identityForConversation(conversation))
                }
            )
        )
    }
}
