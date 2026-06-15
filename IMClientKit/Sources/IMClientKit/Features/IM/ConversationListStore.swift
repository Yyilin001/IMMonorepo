import Foundation

struct ConversationListStore: Sendable {
    func replaceSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        conversations: inout [IMConversation],
        selectedConversationID: inout String?,
        nextCursor: String?,
        hasMore: Bool,
        buildConversation: (IMConversationSummaryResponseBody, IMConversation?) -> IMConversation
    ) -> (nextCursor: String?, hasMore: Bool) {
        let existingByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let previousSelectedConversationID = selectedConversationID

        conversations = responses.map { response in
            let conversationID = response.id.uuidString
            return buildConversation(response, existingByID[conversationID])
        }

        if let previousSelectedConversationID,
           conversations.contains(where: { $0.id == previousSelectedConversationID }) {
            selectedConversationID = previousSelectedConversationID
        } else {
            selectedConversationID = conversations.first?.id
        }

        return (nextCursor, hasMore)
    }

    func appendSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        conversations: inout [IMConversation],
        nextCursor: String?,
        hasMore: Bool,
        upsert: ([IMConversationSummaryResponseBody], inout [IMConversation]) -> Void
    ) -> (nextCursor: String?, hasMore: Bool) {
        upsert(responses, &conversations)
        return (nextCursor, hasMore)
    }

    func applySummaryChanges(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID],
        conversations: inout [IMConversation],
        selectedConversationID: inout String?,
        upsert: ([IMConversationSummaryResponseBody], inout [IMConversation]) -> Void
    ) {
        upsert(upserts, &conversations)

        let removedIDs = Set(removedConversationIDs.map(\.uuidString))
        guard !removedIDs.isEmpty else {
            return
        }

        conversations.removeAll { removedIDs.contains($0.id) }

        if let currentSelectedConversationID = selectedConversationID,
           removedIDs.contains(currentSelectedConversationID) {
            selectedConversationID = conversations.first?.id
        } else if selectedConversationID == nil
                    || !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations.first?.id
        }
    }

    func removeConversation(
        id: String,
        conversations: inout [IMConversation],
        selectedConversationID: inout String?
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return
        }

        conversations.removeAll { $0.id == trimmedID }

        if selectedConversationID == trimmedID {
            selectedConversationID = conversations.first?.id
        } else if selectedConversationID == nil
                    || !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations.first?.id
        }
    }

    func applyConversationPreferences(
        conversationID: String,
        isPinned: Bool,
        pinnedAt: Date?,
        isMuted: Bool,
        conversations: inout [IMConversation]
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].isPinned = isPinned
        conversations[index].pinnedAt = pinnedAt
        conversations[index].isMuted = isMuted
    }

    func applyConversationMetadata(
        conversationID: String,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        conversations: inout [IMConversation]
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            conversations[index].title = trimmedTitle
        }
        conversations[index].notice = notice?.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].avatarPreset = avatarPreset
    }
}
