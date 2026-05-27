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
    var latestLoadedTimelineSequences: [String: UInt64] = [:]
    var oldestLoadedTimelineSequences: [String: UInt64] = [:]
    var replyJumpConversationID: String?
    var replyJumpTargetMessageID: String?
    var replyJumpMatchedMessageID: String?
    var replyJumpState: IMReplyJumpState = .idle

    mutating func reset() {
        isLoadingMembers = false
        isLoadingMessages = false
        loadedConversationIDs = []
        latestLoadedTimelineSequences = [:]
        oldestLoadedTimelineSequences = [:]
        clearReplyJump()
    }

    func hasLoadedMessages(for conversationID: String) -> Bool {
        loadedConversationIDs.contains(conversationID)
    }

    func oldestLoadedTimelineSequence(
        for conversationID: String,
        conversations: [IMConversation]
    ) -> UInt64? {
        if let storedSequence = oldestLoadedTimelineSequences[conversationID] {
            return storedSequence
        }

        guard !loadedConversationIDs.contains(conversationID) else {
            return nil
        }

        return conversations.first(where: { $0.id == conversationID })?
            .timelineItems
            .compactMap(\.timelineSequence)
            .min()
    }

    func latestLoadedTimelineSequence(
        for conversationID: String,
        conversations: [IMConversation]
    ) -> UInt64? {
        if let storedSequence = latestLoadedTimelineSequences[conversationID] {
            return storedSequence
        }

        return conversations.first(where: { $0.id == conversationID })?
            .timelineItems
            .compactMap(\.timelineSequence)
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
            latestLoadedTimelineSequence: latestLoadedTimelineSequence(
                for: trimmedConversationID,
                conversations: conversations
            ),
            oldestLoadedTimelineSequence: loadedConversationIDs.contains(trimmedConversationID)
                ? oldestLoadedTimelineSequence(
                    for: trimmedConversationID,
                    conversations: conversations
                )
                : nil
        )
    }

    mutating func setLatestLoadedTimelineSequence(_ sequence: UInt64?, for conversationID: String) {
        latestLoadedTimelineSequences[conversationID] = sequence
    }

    mutating func setOldestLoadedTimelineSequence(_ sequence: UInt64?, for conversationID: String) {
        oldestLoadedTimelineSequences[conversationID] = sequence
    }

    mutating func removeConversation(id conversationID: String) {
        loadedConversationIDs.remove(conversationID)
        latestLoadedTimelineSequences.removeValue(forKey: conversationID)
        oldestLoadedTimelineSequences.removeValue(forKey: conversationID)

        if replyJumpConversationID == conversationID {
            clearReplyJump()
        }
    }

    mutating func refreshLoadedTimelineCursors(
        for conversationID: String,
        timelineItems: [IMConversationTimelineItem]
    ) {
        let timelineSequences = timelineItems.compactMap(\.timelineSequence)
        latestLoadedTimelineSequences[conversationID] = timelineSequences.max()

        if let oldestSequence = timelineSequences.min() {
            oldestLoadedTimelineSequences[conversationID] = oldestSequence
        } else {
            oldestLoadedTimelineSequences.removeValue(forKey: conversationID)
        }

        loadedConversationIDs.insert(conversationID)
    }

    mutating func refreshLatestLoadedTimelineCursor(
        for conversationID: String,
        timelineItems: [IMConversationTimelineItem]
    ) {
        guard let latestSequence = timelineItems.compactMap(\.timelineSequence).max() else {
            return
        }

        let currentLatest = latestLoadedTimelineSequences[conversationID] ?? 0
        latestLoadedTimelineSequences[conversationID] = max(currentLatest, latestSequence)
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
