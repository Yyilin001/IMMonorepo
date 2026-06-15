import Foundation

struct IMConversationStoreState: Equatable, Sendable {
    var conversations: [IMConversation]
    var selectedConversationID: String?
    var statusMessage: String?
    var conversationSummaryNextCursor: String?
    var hasMoreConversationSummaries: Bool
    var isLoadingMoreConversationSummaries: Bool
}

enum IMConversationStoreStateEvent: Equatable, Sendable {
    case replaceConversationSummaries([IMConversationSummaryResponseBody])
    case applyConversationSummaryPage([IMConversationSummaryResponseBody])
    case applyConversationSummaryChanges(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID]
    )
    case replaceConversationSummaryWindow(
        [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    )
    case appendConversationSummaryWindow(
        [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    )
    case removeConversationSummariesNotIn(Set<String>)
    case applyConversationSummaryContent(IMConversationSummaryResponseBody)
    case markConversationRead(
        conversationID: String,
        latestLoadedSequence: UInt64?
    )
    case markConversationUnread(conversationID: String)
    case replaceMembers(
        conversationID: String,
        members: [IMConversationMember]
    )
    case applyMemberSnapshot(
        conversationID: String,
        members: [IMConversationMember],
        total: Int
    )
    case updateDraft(
        conversationID: String,
        text: String,
        updatedAt: Date
    )
    case applyServerSummaryReadState(
        conversationID: String,
        lastReadSequence: UInt64,
        unreadCount: Int
    )
    case applyServerReadState(
        conversationID: String,
        lastReadSequence: UInt64,
        unreadCount: Int
    )
    case applyRealtimeUnreadIncrement(conversationID: String)
    case applyServerUnreadCount(
        conversationID: String,
        unreadCount: Int
    )
    case setStatusMessage(String?)
    case removeConversation(id: String)
}

struct IMConversationStoreStateEffect: Equatable, Sendable {
    var removedConversationIDs: Set<String> = []
    var shouldSyncReplyJumpState = false
    var shouldSortConversations = false

    static let none = IMConversationStoreStateEffect()
}

struct IMConversationStoreStateReducer: Sendable {
    private let conversationListStore = ConversationListStore()

    func reduce(
        _ event: IMConversationStoreStateEvent,
        state: inout IMConversationStoreState,
        replacingSummaryContent: (IMConversationSummaryResponseBody, IMConversation?) -> IMConversation,
        summaryContent: (IMConversationSummaryResponseBody, IMConversation?) -> IMConversation,
        upsertSummaryContents: ([IMConversationSummaryResponseBody], inout [IMConversation]) -> Void,
        upsertSummaryContent: (IMConversationSummaryResponseBody, inout [IMConversation]) -> Void,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int
    ) -> IMConversationStoreStateEffect {
        switch event {
        case .replaceConversationSummaries(let responses):
            return replaceConversationSummaries(
                responses,
                state: &state,
                replacingSummaryContent: replacingSummaryContent
            )
        case .applyConversationSummaryPage(let responses):
            upsertSummaryContents(responses, &state.conversations)
            state.statusMessage = nil
            return IMConversationStoreStateEffect(shouldSortConversations: true)
        case .applyConversationSummaryChanges(let upserts, let removedConversationIDs):
            return applyConversationSummaryChanges(
                upserts: upserts,
                removedConversationIDs: removedConversationIDs,
                state: &state,
                upsertSummaryContents: upsertSummaryContents
            )
        case .replaceConversationSummaryWindow(let responses, let nextCursor, let hasMore):
            let pagination = conversationListStore.replaceSummaryWindow(
                responses,
                conversations: &state.conversations,
                selectedConversationID: &state.selectedConversationID,
                nextCursor: nextCursor,
                hasMore: hasMore,
                buildConversation: summaryContent
            )
            state.conversationSummaryNextCursor = pagination.nextCursor
            state.hasMoreConversationSummaries = pagination.hasMore
            state.isLoadingMoreConversationSummaries = false
            state.statusMessage = nil
            return IMConversationStoreStateEffect(shouldSortConversations: true)
        case .appendConversationSummaryWindow(let responses, let nextCursor, let hasMore):
            let pagination = conversationListStore.appendSummaryWindow(
                responses,
                conversations: &state.conversations,
                nextCursor: nextCursor,
                hasMore: hasMore,
                upsert: upsertSummaryContents
            )
            state.conversationSummaryNextCursor = pagination.nextCursor
            state.hasMoreConversationSummaries = pagination.hasMore
            state.isLoadingMoreConversationSummaries = false
            state.statusMessage = nil
            return IMConversationStoreStateEffect(shouldSortConversations: true)
        case .removeConversationSummariesNotIn(let conversationIDs):
            removeConversationSummaries(notIn: conversationIDs, state: &state)
            return .none
        case .applyConversationSummaryContent(let response):
            upsertSummaryContent(response, &state.conversations)
            state.statusMessage = nil
            return IMConversationStoreStateEffect(shouldSortConversations: true)
        case .markConversationRead(let conversationID, let latestLoadedSequence):
            markConversationRead(
                conversationID: conversationID,
                latestLoadedSequence: latestLoadedSequence,
                state: &state
            )
            return .none
        case .markConversationUnread(let conversationID):
            markConversationUnread(conversationID: conversationID, state: &state)
            return .none
        case .replaceMembers(let conversationID, let members):
            replaceMembers(
                conversationID: conversationID,
                members: members,
                state: &state,
                ensureConversationIndex: ensureConversationIndex
            )
            return .none
        case .applyMemberSnapshot(let conversationID, let members, let total):
            applyMemberSnapshot(
                conversationID: conversationID,
                members: members,
                total: total,
                state: &state,
                ensureConversationIndex: ensureConversationIndex
            )
            return .none
        case .updateDraft(let conversationID, let text, let updatedAt):
            updateDraft(
                conversationID: conversationID,
                text: text,
                updatedAt: updatedAt,
                state: &state
            )
            return .none
        case .applyServerSummaryReadState(let conversationID, let lastReadSequence, let unreadCount):
            applyServerSummaryReadState(
                conversationID: conversationID,
                lastReadSequence: lastReadSequence,
                unreadCount: unreadCount,
                state: &state
            )
            return .none
        case .applyServerReadState(let conversationID, let lastReadSequence, let unreadCount):
            applyServerReadState(
                conversationID: conversationID,
                lastReadSequence: lastReadSequence,
                unreadCount: unreadCount,
                state: &state
            )
            return .none
        case .applyRealtimeUnreadIncrement(let conversationID):
            applyRealtimeUnreadIncrement(conversationID: conversationID, state: &state)
            return .none
        case .applyServerUnreadCount(let conversationID, let unreadCount):
            applyServerUnreadCount(
                conversationID: conversationID,
                unreadCount: unreadCount,
                state: &state
            )
            return .none
        case .setStatusMessage(let message):
            state.statusMessage = message
            return .none
        case .removeConversation(let id):
            let previousConversationIDs = Set(state.conversations.map(\.id))
            conversationListStore.removeConversation(
                id: id,
                conversations: &state.conversations,
                selectedConversationID: &state.selectedConversationID
            )
            let removedConversationIDs = previousConversationIDs.subtracting(Set(state.conversations.map(\.id)))
            return IMConversationStoreStateEffect(
                removedConversationIDs: removedConversationIDs,
                shouldSyncReplyJumpState: true,
                shouldSortConversations: true
            )
        }
    }

    private func replaceMembers(
        conversationID: String,
        members: [IMConversationMember],
        state: inout IMConversationStoreState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &state.conversations)
        state.conversations[index].members = members
        state.conversations[index].memberUserIDs = members.map(\.id).sorted { $0.uuidString < $1.uuidString }
        state.conversations[index].memberCount = members.count
        state.statusMessage = nil
    }

    private func applyMemberSnapshot(
        conversationID: String,
        members: [IMConversationMember],
        total: Int,
        state: inout IMConversationStoreState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &state.conversations)
        state.conversations[index].members = members
        state.conversations[index].memberUserIDs = members.map(\.id).sorted { $0.uuidString < $1.uuidString }
        state.conversations[index].memberCount = total
        state.statusMessage = nil
    }

    private func updateDraft(
        conversationID: String,
        text: String,
        updatedAt: Date,
        state: inout IMConversationStoreState
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = state.conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        state.conversations[index].draftText = text
        state.conversations[index].draftUpdatedAt = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : updatedAt
    }

    private func replaceConversationSummaries(
        _ responses: [IMConversationSummaryResponseBody],
        state: inout IMConversationStoreState,
        replacingSummaryContent: (IMConversationSummaryResponseBody, IMConversation?) -> IMConversation
    ) -> IMConversationStoreStateEffect {
        let existingByID = Dictionary(uniqueKeysWithValues: state.conversations.map { ($0.id, $0) })
        let serverIDs = Set(responses.map { $0.id.uuidString })
        let previousSelectedConversationID = state.selectedConversationID

        var merged = responses.map { response in
            let conversationID = response.id.uuidString
            return replacingSummaryContent(response, existingByID[conversationID])
        }
        merged.append(contentsOf: state.conversations.filter { !serverIDs.contains($0.id) })
        state.conversations = merged

        if let previousSelectedConversationID,
           state.conversations.contains(where: { $0.id == previousSelectedConversationID }) {
            state.selectedConversationID = previousSelectedConversationID
        } else {
            state.selectedConversationID = state.conversations.first?.id
        }

        state.statusMessage = nil
        return IMConversationStoreStateEffect(shouldSortConversations: true)
    }

    private func applyConversationSummaryChanges(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID],
        state: inout IMConversationStoreState,
        upsertSummaryContents: ([IMConversationSummaryResponseBody], inout [IMConversation]) -> Void
    ) -> IMConversationStoreStateEffect {
        let previousConversationIDs = Set(state.conversations.map(\.id))
        conversationListStore.applySummaryChanges(
            upserts: upserts,
            removedConversationIDs: removedConversationIDs,
            conversations: &state.conversations,
            selectedConversationID: &state.selectedConversationID,
            upsert: upsertSummaryContents
        )
        let removedIDs = previousConversationIDs.subtracting(Set(state.conversations.map(\.id)))
        state.statusMessage = nil
        return IMConversationStoreStateEffect(
            removedConversationIDs: removedIDs,
            shouldSyncReplyJumpState: true,
            shouldSortConversations: true
        )
    }

    private func removeConversationSummaries(
        notIn conversationIDs: Set<String>,
        state: inout IMConversationStoreState
    ) {
        let trimmedIDs = Set(
            conversationIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        state.conversations.removeAll { !trimmedIDs.contains($0.id) }

        if let selectedConversationID = state.selectedConversationID,
           !trimmedIDs.contains(selectedConversationID) {
            state.selectedConversationID = state.conversations.first?.id
        }
    }

    private func markConversationRead(
        conversationID: String,
        latestLoadedSequence: UInt64?,
        state: inout IMConversationStoreState
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = state.conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        if let latestLoadedSequence {
            state.conversations[index].serverLastReadSequence = latestLoadedSequence
        }
        resetUnreadState(for: index, conversations: &state.conversations)
    }

    private func markConversationUnread(
        conversationID: String,
        state: inout IMConversationStoreState
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = state.conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        if state.conversations[index].unreadCount == 0 {
            state.conversations[index].localUnreadDelta = 1
        }
    }

    private func applyServerSummaryReadState(
        conversationID: String,
        lastReadSequence: UInt64,
        unreadCount: Int,
        state: inout IMConversationStoreState
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = state.conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        let hasLatestLoadedServerSequence = state.conversations[index].messages.map(\.serverSequence).max() != nil
        let previousServerLastReadSequence = state.conversations[index].serverLastReadSequence
        let previousServerUnreadCount = state.conversations[index].serverUnreadCount
        let previousLocalUnreadDelta = state.conversations[index].localUnreadDelta
        let normalizedUnreadCount = max(0, unreadCount)

        state.conversations[index].serverLastReadSequence = lastReadSequence
        state.conversations[index].serverUnreadCount = normalizedUnreadCount
        state.conversations[index].localUnreadDelta = reconciledLocalUnreadDelta(
            previousServerLastReadSequence: previousServerLastReadSequence,
            previousServerUnreadCount: previousServerUnreadCount,
            previousLocalUnreadDelta: previousLocalUnreadDelta,
            updatedServerLastReadSequence: lastReadSequence,
            updatedServerUnreadCount: normalizedUnreadCount,
            hasLatestLoadedServerSequence: hasLatestLoadedServerSequence
        )
    }

    private func applyServerReadState(
        conversationID: String,
        lastReadSequence: UInt64,
        unreadCount: Int,
        state: inout IMConversationStoreState
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = state.conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        state.conversations[index].serverLastReadSequence = lastReadSequence
        state.conversations[index].serverUnreadCount = max(0, unreadCount)
        state.conversations[index].localUnreadDelta = 0
    }

    private func applyRealtimeUnreadIncrement(
        conversationID: String,
        state: inout IMConversationStoreState
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = state.conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        guard state.selectedConversationID != trimmedConversationID else {
            resetUnreadState(for: index, conversations: &state.conversations)
            return
        }

        state.conversations[index].localUnreadDelta += 1
    }

    private func applyServerUnreadCount(
        conversationID: String,
        unreadCount: Int,
        state: inout IMConversationStoreState
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = state.conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        state.conversations[index].serverUnreadCount = max(0, unreadCount)
    }

    private func resetUnreadState(
        for conversationIndex: Int,
        conversations: inout [IMConversation]
    ) {
        conversations[conversationIndex].serverUnreadCount = 0
        conversations[conversationIndex].localUnreadDelta = 0
    }

    private func reconciledLocalUnreadDelta(
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
}
