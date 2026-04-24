import Foundation

struct ConversationListReadModel {
    func selectedConversation(
        in conversations: [IMConversation],
        selectedConversationID: String?
    ) -> IMConversation? {
        guard let selectedConversationID else {
            return conversations.first
        }

        return conversations.first { $0.id == selectedConversationID } ?? conversations.first
    }

    func totalUnreadCount(in conversations: [IMConversation]) -> Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    func queueSummary(
        in conversations: [IMConversation],
        for conversationID: String,
        summarize: ([IMConversationMessage]) -> IMConversationQueueSummary
    ) -> IMConversationQueueSummary {
        let trimmedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let conversation = conversations.first(where: { $0.id == trimmedID })
        else {
            return IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0)
        }

        return summarize(conversation.messages)
    }

    func totalQueueSummary(
        in conversations: [IMConversation],
        summarize: ([IMConversationMessage]) -> IMConversationQueueSummary
    ) -> IMConversationQueueSummary {
        conversations.reduce(IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0)) {
            let next = summarize($1.messages)
            return IMConversationQueueSummary(
                queuedCount: $0.queuedCount + next.queuedCount,
                sendingCount: $0.sendingCount + next.sendingCount,
                retryableIssueCount: $0.retryableIssueCount + next.retryableIssueCount
            )
        }
    }
}
