import Foundation

public enum IMReplyJumpState: Equatable, Sendable {
    case idle
    case loading
    case found
    case exhausted
}

struct ConversationDetailState: Sendable, Equatable {
    var isLoadingMembers = false
    var isLoadingMessages = false
    var loadedConversationIDs: Set<String> = []
    var latestSyncedServerSequences: [String: UInt64] = [:]
    var oldestLoadedServerSequences: [String: UInt64] = [:]
    var replyJumpConversationID: String?
    var replyJumpTargetMessageID: String?
    var replyJumpMatchedMessageID: String?
    var replyJumpState: IMReplyJumpState = .idle

    mutating func reset() {
        isLoadingMembers = false
        isLoadingMessages = false
        loadedConversationIDs = []
        latestSyncedServerSequences = [:]
        oldestLoadedServerSequences = [:]
        clearReplyJump()
    }

    func hasLoadedMessages(for conversationID: String) -> Bool {
        loadedConversationIDs.contains(conversationID)
    }

    func oldestLoadedServerSequence(
        for conversationID: String,
        conversations: [IMConversation]
    ) -> UInt64? {
        if let storedSequence = oldestLoadedServerSequences[conversationID] {
            return storedSequence
        }

        guard !loadedConversationIDs.contains(conversationID) else {
            return nil
        }

        return conversations.first(where: { $0.id == conversationID })?
            .messages
            .compactMap(\.serverSequence)
            .min()
    }

    func latestLoadedServerSequence(
        for conversationID: String,
        conversations: [IMConversation]
    ) -> UInt64? {
        if let storedSequence = latestSyncedServerSequences[conversationID] {
            return storedSequence
        }

        return conversations.first(where: { $0.id == conversationID })?
            .messages
            .compactMap(\.serverSequence)
            .max()
    }

    func syncCursor(
        for conversationID: String,
        conversations: [IMConversation]
    ) -> IMSyncCursorState? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              conversations.contains(where: { $0.id == trimmedConversationID })
        else {
            return nil
        }

        return IMSyncCursorState(
            conversationID: trimmedConversationID,
            hasLoadedMessages: loadedConversationIDs.contains(trimmedConversationID),
            latestSyncedServerSequence: latestLoadedServerSequence(
                for: trimmedConversationID,
                conversations: conversations
            ),
            oldestLoadedServerSequence: loadedConversationIDs.contains(trimmedConversationID)
                ? oldestLoadedServerSequence(
                    for: trimmedConversationID,
                    conversations: conversations
                )
                : nil
        )
    }

    mutating func setLatestSyncedServerSequence(_ sequence: UInt64?, for conversationID: String) {
        latestSyncedServerSequences[conversationID] = sequence
    }

    mutating func setOldestLoadedServerSequence(_ sequence: UInt64?, for conversationID: String) {
        oldestLoadedServerSequences[conversationID] = sequence
    }

    mutating func removeConversation(id conversationID: String) {
        loadedConversationIDs.remove(conversationID)
        latestSyncedServerSequences.removeValue(forKey: conversationID)
        oldestLoadedServerSequences.removeValue(forKey: conversationID)

        if replyJumpConversationID == conversationID {
            clearReplyJump()
        }
    }

    mutating func refreshLoadedMessageCursors(
        for conversationID: String,
        messages: [IMConversationMessage]
    ) {
        let serverSequences = messages.compactMap(\.serverSequence)
        latestSyncedServerSequences[conversationID] = serverSequences.max()

        if let oldestSequence = serverSequences.min() {
            oldestLoadedServerSequences[conversationID] = oldestSequence
        } else {
            oldestLoadedServerSequences.removeValue(forKey: conversationID)
        }

        loadedConversationIDs.insert(conversationID)
    }

    mutating func refreshLatestSyncedCursor(
        for conversationID: String,
        messages: [IMConversationMessage]
    ) {
        guard let latestSequence = messages.compactMap(\.serverSequence).max() else {
            return
        }

        let currentLatest = latestSyncedServerSequences[conversationID] ?? 0
        latestSyncedServerSequences[conversationID] = max(currentLatest, latestSequence)
    }

    mutating func startReplyJump(
        in conversationID: String,
        targetMessageID: String
    ) {
        replyJumpConversationID = conversationID
        replyJumpTargetMessageID = targetMessageID
        replyJumpMatchedMessageID = nil
        replyJumpState = .loading
    }

    mutating func resolveReplyJump(matchedMessageID: String, in conversationID: String) {
        replyJumpConversationID = conversationID
        replyJumpMatchedMessageID = matchedMessageID
        replyJumpState = .found
    }

    mutating func exhaustReplyJump(in conversationID: String, targetMessageID: String) {
        replyJumpConversationID = conversationID
        replyJumpTargetMessageID = targetMessageID
        replyJumpMatchedMessageID = nil
        replyJumpState = .exhausted
    }

    mutating func clearReplyJump() {
        replyJumpConversationID = nil
        replyJumpTargetMessageID = nil
        replyJumpMatchedMessageID = nil
        replyJumpState = .idle
    }
}
