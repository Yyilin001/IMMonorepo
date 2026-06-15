import Foundation

struct IMConversationTimelineState: Equatable, Sendable {
    var conversations: [IMConversation]
    var statusMessage: String?
}

enum IMConversationTimelineStateEvent: Equatable, Sendable {
    case upsertNotice(IMTimelineNotice)
    case replaceMessageItems(
        conversationID: String,
        messages: [IMConversationMessageResponseBody],
        currentUserID: UUID
    )
    case replaceTimelineItems(
        conversationID: String,
        items: [IMTimelineItemResponseBody],
        hasMore: Bool,
        currentUserID: UUID
    )
    case appendMessageItems(
        conversationID: String,
        messages: [IMConversationMessageResponseBody],
        currentUserID: UUID
    )
    case appendTimelineItems(
        conversationID: String,
        items: [IMTimelineItemResponseBody],
        currentUserID: UUID
    )
    case prependMessageItems(
        conversationID: String,
        messages: [IMConversationMessageResponseBody],
        currentUserID: UUID
    )
    case prependTimelineItems(
        conversationID: String,
        items: [IMTimelineItemResponseBody],
        hasMore: Bool,
        currentUserID: UUID
    )
}

struct IMConversationTimelineFullRefreshClear: Equatable, Sendable {
    let conversationID: String
    let currentUserID: UUID
}

struct IMConversationTimelineCursorRefresh: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case loadedRange
        case latestOnly
    }

    let conversationID: String
    let timelineItems: [IMConversationTimelineItem]
    let kind: Kind
}

struct IMConversationTimelineStateEffect: Equatable, Sendable {
    var cursorRefreshes: [IMConversationTimelineCursorRefresh] = []
    var fullRefreshClears: [IMConversationTimelineFullRefreshClear] = []
    var shouldSortConversations = false
}

struct IMConversationTimelineStateReducer: Sendable {
    private let timelineStore = ConversationTimelineStore()

    func reduce(
        _ event: IMConversationTimelineStateEvent,
        state: inout IMConversationTimelineState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int,
        makeMessages: ([IMConversationMessageResponseBody], UUID) -> [IMConversationMessage],
        makeNotices: ([IMTimelineNoticeResponseBody]) -> [IMTimelineNotice],
        mergeMessages: ([IMConversationMessage], [IMConversationMessage], Bool) -> [IMConversationMessage],
        hasOlderHistory: ([IMConversationMessage]) -> Bool
    ) -> IMConversationTimelineStateEffect {
        var effect = IMConversationTimelineStateEffect()
        switch event {
        case .upsertNotice(let notice):
            upsertNotice(
                notice,
                state: &state,
                ensureConversationIndex: ensureConversationIndex
            )
            return effect
        case .replaceMessageItems(let conversationID, let messages, let currentUserID):
            timelineStore.replaceTimelineMessageItems(
                in: conversationID,
                messages: messages,
                currentUserID: currentUserID,
                conversations: &state.conversations,
                ensureConversationIndex: ensureConversationIndex,
                makeMessages: makeMessages,
                mergeMessages: mergeMessages,
                hasOlderHistory: hasOlderHistory,
                refreshLoadedMessageCursors: { refreshedConversationID, timelineItems in
                    effect.cursorRefreshes.append(
                        IMConversationTimelineCursorRefresh(
                            conversationID: refreshedConversationID,
                            timelineItems: timelineItems,
                            kind: .loadedRange
                        )
                    )
                }
            )
            effect.fullRefreshClears.append(
                IMConversationTimelineFullRefreshClear(
                    conversationID: conversationID,
                    currentUserID: currentUserID
                )
            )
        case .replaceTimelineItems(let conversationID, let items, let hasMore, let currentUserID):
            timelineStore.replaceTimelineItems(
                in: conversationID,
                items: items,
                hasMore: hasMore,
                currentUserID: currentUserID,
                conversations: &state.conversations,
                ensureConversationIndex: ensureConversationIndex,
                makeMessages: makeMessages,
                makeNotices: makeNotices,
                mergeMessages: mergeMessages,
                refreshLoadedMessageCursors: { refreshedConversationID, timelineItems in
                    effect.cursorRefreshes.append(
                        IMConversationTimelineCursorRefresh(
                            conversationID: refreshedConversationID,
                            timelineItems: timelineItems,
                            kind: .loadedRange
                        )
                    )
                }
            )
            effect.fullRefreshClears.append(
                IMConversationTimelineFullRefreshClear(
                    conversationID: conversationID,
                    currentUserID: currentUserID
                )
            )
        case .appendMessageItems(let conversationID, let messages, let currentUserID):
            timelineStore.appendTimelineMessageItems(
                in: conversationID,
                messages: messages,
                currentUserID: currentUserID,
                conversations: &state.conversations,
                ensureConversationIndex: ensureConversationIndex,
                makeMessages: makeMessages,
                mergeMessages: mergeMessages,
                refreshLatestSyncedCursor: { refreshedConversationID, timelineItems in
                    effect.cursorRefreshes.append(
                        IMConversationTimelineCursorRefresh(
                            conversationID: refreshedConversationID,
                            timelineItems: timelineItems,
                            kind: .latestOnly
                        )
                    )
                }
            )
        case .appendTimelineItems(let conversationID, let items, let currentUserID):
            timelineStore.appendTimelineItems(
                in: conversationID,
                items: items,
                currentUserID: currentUserID,
                conversations: &state.conversations,
                ensureConversationIndex: ensureConversationIndex,
                makeMessages: makeMessages,
                makeNotices: makeNotices,
                mergeMessages: mergeMessages,
                refreshLatestSyncedCursor: { refreshedConversationID, timelineItems in
                    effect.cursorRefreshes.append(
                        IMConversationTimelineCursorRefresh(
                            conversationID: refreshedConversationID,
                            timelineItems: timelineItems,
                            kind: .latestOnly
                        )
                    )
                }
            )
        case .prependMessageItems(let conversationID, let messages, let currentUserID):
            timelineStore.prependTimelineMessageItems(
                in: conversationID,
                messages: messages,
                currentUserID: currentUserID,
                conversations: &state.conversations,
                ensureConversationIndex: ensureConversationIndex,
                makeMessages: makeMessages,
                mergeMessages: mergeMessages,
                hasOlderHistory: hasOlderHistory,
                refreshLoadedMessageCursors: { refreshedConversationID, timelineItems in
                    effect.cursorRefreshes.append(
                        IMConversationTimelineCursorRefresh(
                            conversationID: refreshedConversationID,
                            timelineItems: timelineItems,
                            kind: .loadedRange
                        )
                    )
                }
            )
        case .prependTimelineItems(let conversationID, let items, let hasMore, let currentUserID):
            timelineStore.prependTimelineItems(
                in: conversationID,
                items: items,
                hasMore: hasMore,
                currentUserID: currentUserID,
                conversations: &state.conversations,
                ensureConversationIndex: ensureConversationIndex,
                makeMessages: makeMessages,
                makeNotices: makeNotices,
                mergeMessages: mergeMessages,
                refreshLoadedMessageCursors: { refreshedConversationID, timelineItems in
                    effect.cursorRefreshes.append(
                        IMConversationTimelineCursorRefresh(
                            conversationID: refreshedConversationID,
                            timelineItems: timelineItems,
                            kind: .loadedRange
                        )
                    )
                }
            )
        }
        state.statusMessage = nil
        effect.shouldSortConversations = true
        return effect
    }

    func markConversationNeedsFullRefresh(
        conversationID: String,
        state: inout IMConversationTimelineState
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = state.conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        state.conversations[index].hasMoreHistory = true
    }

    func trimCachedMessageWindow(
        limit: Int,
        state: inout IMConversationTimelineState,
        trimMessages: ([IMConversationMessage], Int) -> [IMConversationMessage]
    ) -> IMConversationTimelineStateEffect {
        let effectiveLimit = max(0, limit)
        var effect = IMConversationTimelineStateEffect()
        for index in state.conversations.indices {
            state.conversations[index].messages = trimMessages(
                state.conversations[index].messages,
                effectiveLimit
            )
            effect.cursorRefreshes.append(
                IMConversationTimelineCursorRefresh(
                    conversationID: state.conversations[index].id,
                    timelineItems: state.conversations[index].timelineItems,
                    kind: .loadedRange
                )
            )
        }
        return effect
    }

    private func upsertNotice(
        _ notice: IMTimelineNotice,
        state: inout IMConversationTimelineState,
        ensureConversationIndex: (String, inout [IMConversation]) -> Int
    ) {
        let index = ensureConversationIndex(notice.conversationID, &state.conversations)
        if let existingIndex = state.conversations[index].notices.firstIndex(where: { $0.id == notice.id }) {
            state.conversations[index].notices[existingIndex] = notice
        } else {
            state.conversations[index].notices.append(notice)
        }
        state.conversations[index].notices.sort {
            if $0.timelineSequence == $1.timelineSequence {
                return $0.id < $1.id
            }
            return $0.timelineSequence < $1.timelineSequence
        }
    }
}
