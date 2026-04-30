import Foundation

struct ConversationTimelineStore {
    func replaceMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        hasOlderHistory: ([IMConversationMessage]) -> Bool,
        refreshLoadedMessageCursors: (String, [IMConversationMessage]) -> Void
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &conversations)
        let serverMessages = makeMessages(responses, currentUserID)
        let mergedMessages = mergeMessages(conversations[index].messages, serverMessages, false)
        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        conversations[index].hasMoreHistory = hasOlderHistory(serverMessages)
        refreshLoadedMessageCursors(trimmedConversationID, mergedMessages)
    }

    func appendMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        refreshLatestSyncedCursor: (String, [IMConversationMessage]) -> Void
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &conversations)
        let serverMessages = makeMessages(responses, currentUserID)
        let mergedMessages = mergeMessages(conversations[index].messages, serverMessages, true)
        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        refreshLatestSyncedCursor(trimmedConversationID, mergedMessages)
    }

    func prependMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        hasOlderHistory: ([IMConversationMessage]) -> Bool,
        refreshLoadedMessageCursors: (String, [IMConversationMessage]) -> Void
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &conversations)
        let serverMessages = makeMessages(responses, currentUserID)
        let mergedMessages = mergeMessages(conversations[index].messages, serverMessages, true)
        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        conversations[index].hasMoreHistory = hasOlderHistory(serverMessages)
        refreshLoadedMessageCursors(trimmedConversationID, mergedMessages)
    }

    func localMessageID(
        matchingReferencedMessageID targetMessageID: String,
        in conversationID: String,
        conversations: [IMConversation],
        readModel: MessageTimelineState
    ) -> String? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              !trimmedTargetMessageID.isEmpty,
              let conversation = conversations.first(where: { $0.id == trimmedConversationID })
        else {
            return nil
        }

        return readModel.localMessageID(
            matchingReferencedMessageID: trimmedTargetMessageID,
            in: conversation.messages
        )
    }
}
