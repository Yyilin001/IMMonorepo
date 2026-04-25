import Foundation

struct ConversationSearchState: Sendable, Equatable {
    var text = ""

    mutating func reset() {
        text = ""
    }

    mutating func setText(_ value: String) {
        text = value
    }

    func filteredConversations(from conversations: [IMConversation]) -> [IMConversation] {
        let trimmedQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return conversations
        }

        let normalizedQuery = trimmedQuery.lowercased()
        return conversations.filter { conversation in
            let fields = [
                conversation.title,
                conversation.directPeer?.email ?? "",
                conversation.lastMessagePreview,
                conversation.notice ?? ""
            ]
            return fields.contains { $0.lowercased().contains(normalizedQuery) }
        }
    }
}
