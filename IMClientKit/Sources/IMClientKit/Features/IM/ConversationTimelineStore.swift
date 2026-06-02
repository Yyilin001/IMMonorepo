import Foundation
import OSLog

struct ConversationTimelineStore {
    func replaceTimelineItems(
        in conversationID: String,
        items: [IMTimelineItemResponseBody],
        hasMore: Bool,
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        makeNotices: ([IMTimelineNoticeResponseBody]) -> [IMTimelineNotice],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        refreshLoadedMessageCursors: (String, [IMConversationTimelineItem]) -> Void
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &conversations)
        let pendingBefore = conversations[index].pendingMessages.count
        let messagesBefore = conversations[index].messages.count
        let serverMessages = makeMessages(items.compactMap(\.message), currentUserID)
        let serverNotices = makeNotices(items.compactMap(\.notice))
        let mergedMessages = mergeMessages(conversations[index].messages, serverMessages, false)

        conversations[index].messages = mergedMessages
        removeCanonicalizedPendingMessages(from: &conversations[index], serverMessages: serverMessages)
        conversations[index].notices = serverNotices.sorted(by: Self.noticeComparator)
        conversations[index].lastMessagePreviewText = latestPreviewText(
            messages: mergedMessages,
            pendingMessages: conversations[index].pendingMessages,
            fallback: conversations[index].lastMessagePreviewText
        )
        conversations[index].updatedAt = latestTimelineDate(
            messages: mergedMessages,
            pendingMessages: conversations[index].pendingMessages,
            notices: conversations[index].notices,
            fallback: conversations[index].updatedAt
        )
        conversations[index].hasMoreHistory = hasMore
        refreshLoadedMessageCursors(trimmedConversationID, conversations[index].timelineItems)
        let pendingAfter = conversations[index].pendingMessages.count
        let messagesAfter = conversations[index].messages.count
        let timelineAfter = conversations[index].timelineItems.count
        IMClientLog.timeline.debug(
            "Timeline replace items conversationID=\(trimmedConversationID, privacy: .public) serverMessages=\(serverMessages.count, privacy: .public) serverNotices=\(serverNotices.count, privacy: .public) pendingBefore=\(pendingBefore, privacy: .public) pendingAfter=\(pendingAfter, privacy: .public) messagesBefore=\(messagesBefore, privacy: .public) messagesAfter=\(messagesAfter, privacy: .public) timelineAfter=\(timelineAfter, privacy: .public) hasMore=\(hasMore, privacy: .public)"
        )
    }

    func appendTimelineItems(
        in conversationID: String,
        items: [IMTimelineItemResponseBody],
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        makeNotices: ([IMTimelineNoticeResponseBody]) -> [IMTimelineNotice],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        refreshLatestSyncedCursor: (String, [IMConversationTimelineItem]) -> Void
    ) {
        mergeTimeline(
            in: conversationID,
            items: items,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            makeNotices: makeNotices,
            mergeMessages: mergeMessages,
            refreshCursor: refreshLatestSyncedCursor
        )
    }

    func prependTimelineItems(
        in conversationID: String,
        items: [IMTimelineItemResponseBody],
        hasMore: Bool,
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        makeNotices: ([IMTimelineNoticeResponseBody]) -> [IMTimelineNotice],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        refreshLoadedMessageCursors: (String, [IMConversationTimelineItem]) -> Void
    ) {
        mergeTimeline(
            in: conversationID,
            items: items,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            makeNotices: makeNotices,
            mergeMessages: mergeMessages,
            refreshCursor: refreshLoadedMessageCursors
        )

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = conversations.firstIndex(where: { $0.id == trimmedConversationID }) else {
            return
        }
        conversations[index].hasMoreHistory = hasMore
    }

    func replaceTimelineMessageItems(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        hasOlderHistory: ([IMConversationMessage]) -> Bool,
        refreshLoadedMessageCursors: (String, [IMConversationTimelineItem]) -> Void
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &conversations)
        let pendingBefore = conversations[index].pendingMessages.count
        let messagesBefore = conversations[index].messages.count
        let serverMessages = makeMessages(responses, currentUserID)
        let mergedMessages = mergeMessages(conversations[index].messages, serverMessages, false)
        conversations[index].messages = mergedMessages
        removeCanonicalizedPendingMessages(from: &conversations[index], serverMessages: serverMessages)
        conversations[index].lastMessagePreviewText = latestPreviewText(
            messages: mergedMessages,
            pendingMessages: conversations[index].pendingMessages,
            fallback: conversations[index].lastMessagePreviewText
        )
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        conversations[index].hasMoreHistory = hasOlderHistory(serverMessages)
        refreshLoadedMessageCursors(trimmedConversationID, mergedMessages.map(IMConversationTimelineItem.message))
        let pendingAfter = conversations[index].pendingMessages.count
        let messagesAfter = conversations[index].messages.count
        IMClientLog.timeline.debug(
            "Timeline replace messages conversationID=\(trimmedConversationID, privacy: .public) serverMessages=\(serverMessages.count, privacy: .public) pendingBefore=\(pendingBefore, privacy: .public) pendingAfter=\(pendingAfter, privacy: .public) messagesBefore=\(messagesBefore, privacy: .public) messagesAfter=\(messagesAfter, privacy: .public)"
        )
    }

    func appendTimelineMessageItems(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        refreshLatestSyncedCursor: (String, [IMConversationTimelineItem]) -> Void
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &conversations)
        let pendingBefore = conversations[index].pendingMessages.count
        let messagesBefore = conversations[index].messages.count
        let serverMessages = makeMessages(responses, currentUserID)
        let mergedMessages = mergeMessages(conversations[index].messages, serverMessages, true)
        conversations[index].messages = mergedMessages
        removeCanonicalizedPendingMessages(from: &conversations[index], serverMessages: serverMessages)
        conversations[index].lastMessagePreviewText = latestPreviewText(
            messages: mergedMessages,
            pendingMessages: conversations[index].pendingMessages,
            fallback: conversations[index].lastMessagePreviewText
        )
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        refreshLatestSyncedCursor(trimmedConversationID, mergedMessages.map(IMConversationTimelineItem.message))
        let pendingAfter = conversations[index].pendingMessages.count
        let messagesAfter = conversations[index].messages.count
        IMClientLog.timeline.debug(
            "Timeline append messages conversationID=\(trimmedConversationID, privacy: .public) serverMessages=\(serverMessages.count, privacy: .public) pendingBefore=\(pendingBefore, privacy: .public) pendingAfter=\(pendingAfter, privacy: .public) messagesBefore=\(messagesBefore, privacy: .public) messagesAfter=\(messagesAfter, privacy: .public)"
        )
    }

    func prependTimelineMessageItems(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        hasOlderHistory: ([IMConversationMessage]) -> Bool,
        refreshLoadedMessageCursors: (String, [IMConversationTimelineItem]) -> Void
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &conversations)
        let serverMessages = makeMessages(responses, currentUserID)
        let mergedMessages = mergeMessages(conversations[index].messages, serverMessages, true)
        conversations[index].messages = mergedMessages
        removeCanonicalizedPendingMessages(from: &conversations[index], serverMessages: serverMessages)
        conversations[index].lastMessagePreviewText = latestPreviewText(
            messages: mergedMessages,
            pendingMessages: conversations[index].pendingMessages,
            fallback: conversations[index].lastMessagePreviewText
        )
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        conversations[index].hasMoreHistory = hasOlderHistory(serverMessages)
        refreshLoadedMessageCursors(trimmedConversationID, mergedMessages.map(IMConversationTimelineItem.message))
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

    private func mergeTimeline(
        in conversationID: String,
        items: [IMTimelineItemResponseBody],
        currentUserID: UUID,
        conversations: inout [IMConversation],
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        makeNotices: ([IMTimelineNoticeResponseBody]) -> [IMTimelineNotice],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        refreshCursor: (String, [IMConversationTimelineItem]) -> Void
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(trimmedConversationID, &conversations)
        let pendingBefore = conversations[index].pendingMessages.count
        let messagesBefore = conversations[index].messages.count
        let serverMessages = makeMessages(items.compactMap(\.message), currentUserID)
        let serverNotices = makeNotices(items.compactMap(\.notice))
        let mergedMessages = mergeMessages(conversations[index].messages, serverMessages, true)

        conversations[index].messages = mergedMessages
        removeCanonicalizedPendingMessages(from: &conversations[index], serverMessages: serverMessages)
        conversations[index].notices = mergeNotices(conversations[index].notices, serverNotices)
        conversations[index].lastMessagePreviewText = latestPreviewText(
            messages: mergedMessages,
            pendingMessages: conversations[index].pendingMessages,
            fallback: conversations[index].lastMessagePreviewText
        )
        conversations[index].updatedAt = latestTimelineDate(
            messages: mergedMessages,
            pendingMessages: conversations[index].pendingMessages,
            notices: conversations[index].notices,
            fallback: conversations[index].updatedAt
        )
        refreshCursor(trimmedConversationID, conversations[index].timelineItems)
        let pendingAfter = conversations[index].pendingMessages.count
        let messagesAfter = conversations[index].messages.count
        let timelineAfter = conversations[index].timelineItems.count
        IMClientLog.timeline.debug(
            "Timeline merge items conversationID=\(trimmedConversationID, privacy: .public) serverMessages=\(serverMessages.count, privacy: .public) serverNotices=\(serverNotices.count, privacy: .public) pendingBefore=\(pendingBefore, privacy: .public) pendingAfter=\(pendingAfter, privacy: .public) messagesBefore=\(messagesBefore, privacy: .public) messagesAfter=\(messagesAfter, privacy: .public) timelineAfter=\(timelineAfter, privacy: .public)"
        )
    }

    private func mergeNotices(
        _ existing: [IMTimelineNotice],
        _ serverNotices: [IMTimelineNotice]
    ) -> [IMTimelineNotice] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for notice in serverNotices {
            merged[notice.id] = notice
        }
        return merged.values.sorted(by: Self.noticeComparator)
    }

    private func removeCanonicalizedPendingMessages(
        from conversation: inout IMConversation,
        serverMessages: [IMConversationMessage]
    ) {
        guard !serverMessages.isEmpty else {
            return
        }

        let serverMessageIDs = Set(serverMessages.map(\.serverMessageID))
        let clientMessageIDs = Set(serverMessages.compactMap(\.clientMessageID))
        conversation.pendingMessages.removeAll { pendingMessage in
            if let pendingServerMessageID = pendingMessage.serverMessageID,
               serverMessageIDs.contains(pendingServerMessageID) {
                return true
            }
            return clientMessageIDs.contains(pendingMessage.clientMessageID)
        }
    }

    private func latestTimelineDate(
        messages: [IMConversationMessage],
        pendingMessages: [IMPendingConversationMessage],
        notices: [IMTimelineNotice],
        fallback: Date
    ) -> Date {
        let latestMessageDate = messages.map(\.createdAt).max()
        let latestPendingDate = pendingMessages.map(\.createdAt).max()
        let latestNoticeDate = notices.map(\.createdAt).max()
        return [latestMessageDate, latestPendingDate, latestNoticeDate, fallback].compactMap { $0 }.max() ?? fallback
    }

    private func latestPreviewText(
        messages: [IMConversationMessage],
        pendingMessages: [IMPendingConversationMessage],
        fallback: String
    ) -> String {
        if let latestPending = pendingMessages.max(by: { left, right in
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }) {
            return latestPending.text
        }
        return messages.last?.text ?? fallback
    }

    private static func noticeComparator(_ lhs: IMTimelineNotice, _ rhs: IMTimelineNotice) -> Bool {
        if lhs.timelineSequence == rhs.timelineSequence {
            return lhs.id < rhs.id
        }
        return lhs.timelineSequence < rhs.timelineSequence
    }
}
