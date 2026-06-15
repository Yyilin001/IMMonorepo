import Foundation
import Testing
@testable import IMClientKit

struct IMConversationTimelineStateReducerTests {
    private let currentUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peerUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func reducerAppliesTimelineEventsAndReturnsCursorEffectsWithoutMainActorStore() throws {
        let conversationID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let reducer = IMConversationTimelineStateReducer()
        var state = IMConversationTimelineState(
            conversations: [],
            statusMessage: "loading"
        )

        let replaceEffect = reducer.reduce(
            .replaceMessageItems(
                conversationID: conversationID.uuidString,
                messages: [
                    makeMessageResponse(
                        id: UUID(uuidString: "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa")!,
                        conversationID: conversationID,
                        senderUserID: peerUserID,
                        sequence: 2,
                        text: "first"
                    )
                ],
                currentUserID: currentUserID
            ),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            makeMessages: Self.makeMessages(from:currentUserID:),
            makeNotices: { _ in [] },
            mergeMessages: Self.mergeMessages(existing:serverMessages:preserveExistingServerMessages:),
            hasOlderHistory: Self.hasOlderHistory(in:)
        )

        #expect(state.statusMessage == nil)
        #expect(state.conversations.map(\.id) == [conversationID.uuidString])
        #expect(state.conversations.first?.messages.map(\.text) == ["first"])
        #expect(state.conversations.first?.hasMoreHistory == true)
        #expect(replaceEffect.shouldSortConversations)
        #expect(replaceEffect.fullRefreshClears == [
            IMConversationTimelineFullRefreshClear(
                conversationID: conversationID.uuidString,
                currentUserID: currentUserID
            )
        ])
        let replaceCursor = try #require(replaceEffect.cursorRefreshes.first)
        #expect(replaceCursor.conversationID == conversationID.uuidString)
        #expect(replaceCursor.kind == .loadedRange)
        #expect(replaceCursor.timelineItems.compactMap(\.timelineSequence) == [2])

        let appendEffect = reducer.reduce(
            .appendMessageItems(
                conversationID: conversationID.uuidString,
                messages: [
                    makeMessageResponse(
                        id: UUID(uuidString: "bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb")!,
                        conversationID: conversationID,
                        senderUserID: peerUserID,
                        sequence: 3,
                        text: "second"
                    )
                ],
                currentUserID: currentUserID
            ),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            makeMessages: Self.makeMessages(from:currentUserID:),
            makeNotices: { _ in [] },
            mergeMessages: Self.mergeMessages(existing:serverMessages:preserveExistingServerMessages:),
            hasOlderHistory: Self.hasOlderHistory(in:)
        )

        #expect(state.conversations.first?.messages.map(\.text) == ["first", "second"])
        #expect(appendEffect.fullRefreshClears.isEmpty)
        #expect(appendEffect.cursorRefreshes.first?.kind == .latestOnly)
        #expect(appendEffect.cursorRefreshes.first?.timelineItems.compactMap(\.timelineSequence) == [2, 3])
    }

    @Test func reducerMarksExistingConversationAsNeedingFullRefreshWithoutCreatingPlaceholder() {
        let reducer = IMConversationTimelineStateReducer()
        var state = IMConversationTimelineState(
            conversations: [
                Self.makeConversation(id: "conversation-1")
            ],
            statusMessage: "loaded"
        )

        reducer.markConversationNeedsFullRefresh(
            conversationID: " conversation-1 ",
            state: &state
        )
        reducer.markConversationNeedsFullRefresh(
            conversationID: "missing-conversation",
            state: &state
        )

        #expect(state.conversations.map(\.id) == ["conversation-1"])
        #expect(state.conversations.first?.hasMoreHistory == true)
        #expect(state.statusMessage == "loaded")
    }

    @Test func reducerTrimsCachedMessageWindowAndReturnsLoadedCursorRefreshes() {
        let conversationID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let reducer = IMConversationTimelineStateReducer()
        let messages = Self.makeMessages(
            from: (1...4).map { sequence in
                makeMessageResponse(
                    id: UUID(uuidString: String(format: "dddddddd-dddd-dddd-dddd-%012d", sequence))!,
                    conversationID: conversationID,
                    senderUserID: peerUserID,
                    sequence: UInt64(sequence),
                    text: "message \(sequence)"
                )
            },
            currentUserID: currentUserID
        )
        var state = IMConversationTimelineState(
            conversations: [
                Self.makeConversation(id: conversationID.uuidString, messages: messages)
            ],
            statusMessage: "loaded"
        )

        let effect = reducer.trimCachedMessageWindow(
            limit: 2,
            state: &state,
            trimMessages: { messages, limit in
                Array(messages.suffix(limit))
            }
        )

        #expect(state.conversations.first?.messages.map(\.text) == ["message 3", "message 4"])
        #expect(state.statusMessage == "loaded")
        #expect(effect.cursorRefreshes.map(\.conversationID) == [conversationID.uuidString])
        #expect(effect.cursorRefreshes.first?.kind == .loadedRange)
        #expect(effect.cursorRefreshes.first?.timelineItems.compactMap(\.timelineSequence) == [3, 4])
    }

    private func makeMessageResponse(
        id: UUID,
        conversationID: UUID,
        senderUserID: UUID,
        sequence: UInt64,
        text: String
    ) -> IMConversationMessageResponseBody {
        IMConversationMessageResponseBody(
            id: id,
            conversationID: conversationID,
            senderUserID: senderUserID,
            serverSequence: sequence,
            timelineSequence: sequence,
            content: testMessageContent(kind: "rich_text", body: ["text": text]),
            createdAt: Date(timeIntervalSince1970: Double(sequence))
        )
    }

    private static func ensureConversationIndex(
        for conversationID: String,
        conversations: inout [IMConversation]
    ) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }
        conversations.append(
            IMConversation(
                id: conversationID,
                title: conversationID,
                kind: .group,
                memberCount: 0,
                memberUserIDs: [],
                members: [],
                messages: [],
                lastMessagePreviewText: "",
                hasMoreHistory: false,
                serverLastReadSequence: 0,
                serverUnreadCount: 0,
                localUnreadDelta: 0,
                updatedAt: .distantPast
            )
        )
        return conversations.count - 1
    }

    private static func makeConversation(
        id: String,
        messages: [IMConversationMessage] = []
    ) -> IMConversation {
        IMConversation(
            id: id,
            title: id,
            kind: .group,
            memberCount: 0,
            memberUserIDs: [],
            members: [],
            messages: messages,
            lastMessagePreviewText: "",
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func makeMessages(
        from responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) -> [IMConversationMessage] {
        responses.compactMap { response in
            try? IMConversationMessage(
                id: response.id.uuidString,
                conversationID: response.conversationID.uuidString,
                clientMessageID: response.clientMessageID,
                serverMessageID: response.id.uuidString,
                senderUserID: response.senderUserID,
                serverSequence: UInt64(response.serverSequence),
                timelineSequence: UInt64(response.timelineSequence),
                content: response.content,
                derivedState: response.derivedState,
                direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                createdAt: response.createdAt ?? .distantPast,
                deliveryState: response.senderUserID == currentUserID ? .sent : .received
            )
        }
    }

    private static func mergeMessages(
        existing: [IMConversationMessage],
        serverMessages: [IMConversationMessage],
        preserveExistingServerMessages: Bool
    ) -> [IMConversationMessage] {
        var merged = preserveExistingServerMessages ? existing : []
        for serverMessage in serverMessages {
            if let index = merged.firstIndex(where: { existingMessage in
                if existingMessage.serverMessageID == serverMessage.serverMessageID {
                    return true
                }
                if let existingClientMessageID = existingMessage.clientMessageID,
                   let serverClientMessageID = serverMessage.clientMessageID,
                   existingClientMessageID == serverClientMessageID {
                    return true
                }
                return existingMessage.serverSequence == serverMessage.serverSequence
                    && existingMessage.conversationID == serverMessage.conversationID
            }) {
                merged[index] = serverMessage
            } else {
                merged.append(serverMessage)
            }
        }
        return merged.sorted { left, right in
            if left.timelineSequence == right.timelineSequence {
                return left.id < right.id
            }
            return left.timelineSequence < right.timelineSequence
        }
    }

    private static func hasOlderHistory(in serverMessages: [IMConversationMessage]) -> Bool {
        guard let oldestSequence = serverMessages.map(\.serverSequence).min() else {
            return false
        }
        return oldestSequence > 1
    }
}
