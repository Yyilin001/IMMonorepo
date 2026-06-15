import Foundation

@MainActor
extension IMConversationStore {
    public var selectedConversation: IMConversation? {
        listReadModel.selectedConversation(
            in: conversations,
            selectedConversationID: selectedConversationID
        )
    }

    public var totalUnreadCount: Int {
        listReadModel.totalUnreadCount(in: conversations.filter { !$0.isMuted })
    }

    public var conversationSummaryPaginationAnchorID: String? {
        conversations.last?.id
    }

    public func queueSummary(for conversationID: String) -> IMConversationQueueSummary {
        listReadModel.queueSummary(
            in: conversations,
            for: conversationID,
            summarize: { self.queueSummary(for: $0) }
        )
    }

    public func totalQueueSummary() -> IMConversationQueueSummary {
        listReadModel.totalQueueSummary(
            in: conversations,
            summarize: { self.queueSummary(for: $0) }
        )
    }

    public func setConversationSearchText(_ value: String) {
        conversationSearchState.setText(value)
        searchText = conversationSearchState.text
    }

    public var filteredConversations: [IMConversation] {
        conversationSearchState.filteredConversations(from: conversations)
    }
}
