import Foundation
import Testing
@testable import IMClientKit

@MainActor
struct IMConversationStoreTests {
    private static let currentUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let peerUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private static func gapSummary(
        conversationID: UUID,
        latestServerSequence: Int?
    ) -> IMConversationSummaryResponseBody {
        let updatedAt = latestServerSequence.map {
            Date(timeIntervalSince1970: 1_700_400_000 + Double($0))
        } ?? Date(timeIntervalSince1970: 1_700_400_000)

        return IMConversationSummaryResponseBody(
            id: conversationID,
            title: nil,
            kind: IMConversationKind.direct.rawValue,
            memberCount: 2,
            memberUserIDs: [Self.currentUserID, Self.peerUserID],
            lastMessage: latestServerSequence.map { sequence in
                IMMessagePreviewResponseBody(
                    id: UUID(),
                    senderUserID: Self.peerUserID,
                    serverSequence: sequence,
                    kind: "text",
                    body: ["text": "summary \(sequence)"],
                    createdAt: updatedAt
                )
            },
            createdAt: Date(timeIntervalSince1970: 1_700_300_000),
            updatedAt: updatedAt
        )
    }

    private static func messageResponse(
        conversationID: UUID,
        serverSequence: Int
    ) -> IMConversationMessageResponseBody {
        IMConversationMessageResponseBody(
            id: UUID(),
            conversationID: conversationID,
            senderUserID: Self.peerUserID,
            clientMessageID: nil,
            serverSequence: serverSequence,
            kind: "text",
            body: ["text": "local \(serverSequence)"],
            createdAt: Date(timeIntervalSince1970: 1_700_500_000 + Double(serverSequence))
        )
    }

    @Test func replaceConversationSummariesImportsServerPreview() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: nil,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 10,
                        kind: "text",
                        body: ["text": "preview text"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )

        #expect(store.conversations.count == 1)
        #expect(store.selectedConversation?.lastMessagePreview == "preview text")
        #expect(store.selectedConversation?.title == "会话 aaaaaaaa")
        #expect(store.selectedConversation?.kind == .group)
        #expect(store.selectedConversation?.memberCount == 2)
        #expect(store.selectedConversation?.memberUserIDs.count == 2)
    }

    @Test func replaceConversationSummariesRefreshesKindAndMemberCount() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: nil,
                    kind: IMConversationKind.direct.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Study Group",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )

        #expect(store.selectedConversation?.kind == .group)
        #expect(store.selectedConversation?.memberCount == 3)
        #expect(store.selectedConversation?.title == "Study Group")
    }

    @Test func replaceConversationSummariesPreservesUnreadCounts() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )

        store.receiveIncomingMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-unread-1",
                conversationID: backgroundConversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 10,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "text",
                body: ["text": "live unread"]
            ),
            currentUserID: Self.currentUserID
        )

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 10,
                        kind: "text",
                        body: ["text": "server preview"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        let unreadConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(store.selectedConversationID == selectedConversationID.uuidString)
        #expect(unreadConversation?.unreadCount == 1)
        #expect(store.totalUnreadCount == 1)
    }

    @Test func replaceConversationSummariesOnlyCorrectsPreviewAndOrdering() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "before",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 3,
                        kind: "text",
                        body: ["text": "old preview"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )
        store.applyServerSummaryReadState(
            lastReadSequence: 8,
            unreadCount: 2,
            for: conversationID.uuidString
        )

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "after",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 9,
                        kind: "text",
                        body: ["text": "new preview"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_100)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 7,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_100)
                )
            ]
        )

        let conversation = store.selectedConversation
        #expect(conversation?.title == "after")
        #expect(conversation?.lastMessagePreview == "new preview")
        #expect(conversation?.updatedAt == Date(timeIntervalSince1970: 1_700_300_100))
        #expect(conversation?.serverLastReadSequence == 8)
        #expect(conversation?.serverUnreadCount == 2)
    }

    @Test func conversationCreatedEventUpsertsSummaryUsingAuthoritativeReadState() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let outcome = store.applyConversationEvent(
            IMTCPConversationEventPayload(
                eventType: .conversationCreated,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "New Group",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    lastReadSequence: 12,
                    unreadCount: 4,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                actorUserID: Self.peerUserID,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_001)
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = store.selectedConversation
        #expect(outcome.shouldReloadMembersForConversationID == nil)
        #expect(conversation?.id == conversationID.uuidString)
        #expect(conversation?.title == "New Group")
        #expect(conversation?.kind == .group)
        #expect(conversation?.memberCount == 3)
        #expect(conversation?.serverLastReadSequence == 12)
        #expect(conversation?.serverUnreadCount == 4)
        #expect(conversation?.localUnreadDelta == 0)
    }

    @Test func summaryUpdatedEventClearsRealtimeUnreadDelta() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )
        store.receiveIncomingMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-msg-1",
                conversationID: conversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 2,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "text",
                body: ["text": "live unread"]
            ),
            currentUserID: Self.currentUserID
        )

        _ = store.applyConversationEvent(
            IMTCPConversationEventPayload(
                eventType: .summaryUpdated,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 2,
                        kind: "text",
                        body: ["text": "live unread"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    lastReadSequence: 0,
                    unreadCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                actorUserID: Self.peerUserID,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_001)
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = store.selectedConversation
        #expect(conversation?.serverUnreadCount == 1)
        #expect(conversation?.localUnreadDelta == 0)
        #expect(conversation?.unreadCount == 1)
    }

    @Test func conversationRemovedForSelfEventRemovesConversationAndFallsBackSelection() {
        let store = IMConversationStore()
        let removedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: removedConversationID,
                    title: "Current",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                ),
                IMConversationSummaryResponseBody(
                    id: fallbackConversationID,
                    title: "Fallback",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )
        store.openConversation(id: removedConversationID.uuidString)

        _ = store.applyConversationEvent(
            IMTCPConversationEventPayload(
                eventType: .conversationRemovedForSelf,
                conversation: IMConversationSummaryResponseBody(
                    id: removedConversationID,
                    title: "Current",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                ),
                actorUserID: Self.currentUserID,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_100)
            ),
            currentUserID: Self.currentUserID
        )

        #expect(store.conversations.count == 1)
        #expect(store.conversations.first?.id == fallbackConversationID.uuidString)
        #expect(store.selectedConversationID == fallbackConversationID.uuidString)
    }

    @Test func openConversationOnlyChangesSelection() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let unreadConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                ),
                IMConversationSummaryResponseBody(
                    id: unreadConversationID,
                    title: "unread",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )

        store.receiveIncomingMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-unread-1",
                conversationID: unreadConversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 1,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "text",
                body: ["text": "unread"]
            ),
            currentUserID: Self.currentUserID
        )

        #expect(store.totalUnreadCount == 1)

        store.openConversation(id: unreadConversationID.uuidString)

        #expect(store.selectedConversationID == unreadConversationID.uuidString)
        #expect(store.selectedConversation?.unreadCount == 1)
        #expect(store.totalUnreadCount == 1)

        store.markConversationRead(id: unreadConversationID.uuidString)

        #expect(store.selectedConversation?.unreadCount == 0)
        #expect(store.totalUnreadCount == 0)
    }

    @Test func applyRealtimeUnreadIncrementOnlyAffectsBackgroundConversation() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )

        store.applyRealtimeUnreadIncrement(for: backgroundConversationID.uuidString)

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.unreadCount == 1)
        #expect(store.totalUnreadCount == 1)

        store.applyRealtimeUnreadIncrement(for: selectedConversationID.uuidString)

        let selectedConversation = store.conversations.first { $0.id == selectedConversationID.uuidString }
        #expect(selectedConversation?.unreadCount == 0)
        #expect(store.totalUnreadCount == 1)
    }

    @Test func applyServerUnreadCountMergesWithLocalRealtimeUnreadDelta() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )

        store.applyServerUnreadCount(2, for: backgroundConversationID.uuidString)
        store.applyRealtimeUnreadIncrement(for: backgroundConversationID.uuidString)

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.serverUnreadCount == 2)
        #expect(backgroundConversation?.localUnreadDelta == 1)
        #expect(backgroundConversation?.unreadCount == 3)
        #expect(store.totalUnreadCount == 3)
    }

    @Test func applyServerSummaryReadStatesKeepsLocalRealtimeUnreadDelta() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )

        store.applyRealtimeUnreadIncrement(for: backgroundConversationID.uuidString)
        store.applyServerSummaryReadStates(
            [
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    lastReadSequence: 8,
                    unreadCount: 2,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_010)
                )
            ]
        )

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.serverLastReadSequence == 8)
        #expect(backgroundConversation?.serverUnreadCount == 2)
        #expect(backgroundConversation?.localUnreadDelta == 1)
        #expect(backgroundConversation?.unreadCount == 3)
    }

    @Test func applyServerExplicitReadResponseResetsLocalRealtimeUnreadDelta() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )

        store.applyRealtimeUnreadIncrement(for: backgroundConversationID.uuidString)
        store.applyServerExplicitReadResponse(
            IMConversationReadResponseBody(
                conversationID: backgroundConversationID,
                lastReadSequence: 9,
                unreadCount: 0
            )
        )

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.serverLastReadSequence == 9)
        #expect(backgroundConversation?.serverUnreadCount == 0)
        #expect(backgroundConversation?.localUnreadDelta == 0)
        #expect(backgroundConversation?.unreadCount == 0)
    }

    @Test func receiveIncomingMessageAutoSelectsFirstConversationWithoutUnreadIncrement() {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"

        store.receiveIncomingMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-first-1",
                conversationID: conversationID,
                senderUserID: Self.peerUserID,
                serverSequence: 1,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "text",
                body: ["text": "first live message"]
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = store.selectedConversation
        #expect(store.selectedConversationID == conversationID)
        #expect(conversation?.serverUnreadCount == 0)
        #expect(conversation?.localUnreadDelta == 0)
        #expect(conversation?.unreadCount == 0)
        #expect(store.totalUnreadCount == 0)
    }

    @Test func replaceMessagesDoesNotClearUnreadForBackgroundConversation() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )

        store.receiveIncomingMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-unread-1",
                conversationID: backgroundConversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 1,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "text",
                body: ["text": "unread"]
            ),
            currentUserID: Self.currentUserID
        )

        store.replaceMessages(
            in: backgroundConversationID.uuidString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: backgroundConversationID,
                    senderUserID: Self.peerUserID,
                    serverSequence: 1,
                    kind: "text",
                    body: ["text": "unread"],
                    createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ],
            currentUserID: Self.currentUserID
        )

        let unreadConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(store.selectedConversationID == selectedConversationID.uuidString)
        #expect(unreadConversation?.unreadCount == 1)
        #expect(store.totalUnreadCount == 1)
    }

    @Test func replaceMessagesMergesServerHistoryWithPendingOutgoingMessage() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.openConversation(id: conversationIDString)
        let request = store.prepareOutgoingText(
            "pending local",
            conversationID: conversationIDString,
            senderUserID: Self.currentUserID
        )
        #expect(request != nil)

        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    serverSequence: 1,
                    kind: "text",
                    body: ["text": "from server"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_000)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.count == 2)
        #expect(store.selectedConversation?.messages.map(\.text) == ["from server", "pending local"])
        #expect(store.selectedConversation?.lastMessagePreview == "pending local")
    }

    @Test func replaceMessagesUsesClientMessageIDToMergePendingOutgoingMessage() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.openConversation(id: conversationIDString)
        let request = store.prepareOutgoingText(
            "pending local",
            conversationID: conversationIDString,
            senderUserID: Self.currentUserID
        )

        guard let clientMessageID = request?.payload.clientMessageID else {
            Issue.record("缺少本地 clientMessageID")
            return
        }

        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: clientMessageID,
                    serverSequence: 1,
                    kind: "text",
                    body: ["text": "pending local"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_000)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.count == 1)
        #expect(store.selectedConversation?.messages.first?.clientMessageID == clientMessageID)
        #expect(store.selectedConversation?.messages.first?.serverSequence == 1)
        #expect(store.selectedConversation?.messages.first?.deliveryState == .sent)
    }

    @Test func prependMessagesAddsOlderHistoryPage() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.openConversation(id: conversationIDString)
        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    serverSequence: 3,
                    kind: "text",
                    body: ["text": "third"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_003)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    serverSequence: 4,
                    kind: "text",
                    body: ["text": "fourth"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_004)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.hasMoreHistory == true)
        #expect(store.oldestLoadedServerSequence(for: conversationIDString) == 3)

        store.prependMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    serverSequence: 1,
                    kind: "text",
                    body: ["text": "first"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_001)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    serverSequence: 2,
                    kind: "text",
                    body: ["text": "second"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_002)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.map(\.text) == ["first", "second", "third", "fourth"])
        #expect(store.selectedConversation?.hasMoreHistory == false)
        #expect(store.oldestLoadedServerSequence(for: conversationIDString) == 1)
    }

    @Test func appendMessagesMergesIncrementalGapResults() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.openConversation(id: conversationIDString)
        let request = store.prepareOutgoingText(
            "pending local",
            conversationID: conversationIDString,
            senderUserID: Self.currentUserID
        )

        guard let clientMessageID = request?.payload.clientMessageID else {
            Issue.record("缺少本地 clientMessageID")
            return
        }

        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 3,
                    kind: "text",
                    body: ["text": "third"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_003)
                )
            ],
            currentUserID: Self.currentUserID
        )

        store.appendMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: clientMessageID,
                    serverSequence: 4,
                    kind: "text",
                    body: ["text": "pending local"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_004)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 5,
                    kind: "text",
                    body: ["text": "fifth"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_005)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.map(\.text) == ["third", "pending local", "fifth"])
        #expect(store.selectedConversation?.messages.map(\.serverSequence) == [3, 4, 5])
        #expect(store.selectedConversation?.messages.filter { $0.text == "pending local" }.count == 1)
    }

    @Test func latestLoadedServerSequenceHandlesEmptyPendingAndLoadedMessages() {
        let store = IMConversationStore()
        let emptyConversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let pendingConversationID = "CCCCCCCC-1111-2222-3333-DDDDDDDDDDDD"
        let loadedConversationID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        let loadedConversationIDString = loadedConversationID.uuidString

        store.openConversation(id: emptyConversationID)
        #expect(store.latestLoadedServerSequence(for: emptyConversationID) == nil)

        store.openConversation(id: pendingConversationID)
        _ = store.prepareOutgoingText(
            "pending only",
            conversationID: pendingConversationID,
            senderUserID: Self.currentUserID
        )
        #expect(store.latestLoadedServerSequence(for: pendingConversationID) == nil)

        store.openConversation(id: loadedConversationIDString)
        store.replaceMessages(
            in: loadedConversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    conversationID: loadedConversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 7,
                    kind: "text",
                    body: ["text": "seven"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_007)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    conversationID: loadedConversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: nil,
                    serverSequence: 9,
                    kind: "text",
                    body: ["text": "nine"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_009)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.latestLoadedServerSequence(for: loadedConversationIDString) == 9)
    }

    @Test func gapSyncTargetsOnlyReturnsLoadedConversationsBehindSummaryInSummaryOrder() {
        let store = IMConversationStore()
        let equalConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let staleConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let unloadedConversationID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let laterStaleConversationID = UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!
        let emptySummaryConversationID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!

        let summaries = [
            Self.gapSummary(conversationID: equalConversationID, latestServerSequence: 3),
            Self.gapSummary(conversationID: staleConversationID, latestServerSequence: 5),
            Self.gapSummary(conversationID: unloadedConversationID, latestServerSequence: 8),
            Self.gapSummary(conversationID: laterStaleConversationID, latestServerSequence: 9),
            Self.gapSummary(conversationID: emptySummaryConversationID, latestServerSequence: nil)
        ]
        store.replaceConversationSummaries(summaries)

        store.replaceMessages(
            in: equalConversationID.uuidString,
            messages: [Self.messageResponse(conversationID: equalConversationID, serverSequence: 3)],
            currentUserID: Self.currentUserID
        )
        store.replaceMessages(
            in: staleConversationID.uuidString,
            messages: [Self.messageResponse(conversationID: staleConversationID, serverSequence: 4)],
            currentUserID: Self.currentUserID
        )
        store.replaceMessages(
            in: laterStaleConversationID.uuidString,
            messages: [Self.messageResponse(conversationID: laterStaleConversationID, serverSequence: 7)],
            currentUserID: Self.currentUserID
        )

        #expect(
            store.gapSyncTargets(from: summaries) == [
                staleConversationID.uuidString,
                laterStaleConversationID.uuidString
            ]
        )
    }

    @Test func replaceMembersStoresConversationParticipants() {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"

        store.openConversation(id: conversationID)
        store.replaceMembers(
            in: conversationID,
            members: [
                IMConversationMemberResponseBody(id: Self.peerUserID, email: "peer@example.com"),
                IMConversationMemberResponseBody(id: Self.currentUserID, email: "self@example.com")
            ]
        )

        #expect(store.selectedConversation?.members.map(\.email) == ["peer@example.com", "self@example.com"])
        #expect(store.selectedConversation?.memberUserIDs.count == 2)
        #expect(store.selectedConversation?.memberCount == 2)
    }

    @Test func removeConversationRemovesSelectionAndFallsBackToRemainingConversation() {
        let store = IMConversationStore()
        let currentConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: currentConversationID,
                    title: "Current",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                IMConversationSummaryResponseBody(
                    id: fallbackConversationID,
                    title: "Fallback",
                    kind: IMConversationKind.direct.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                )
            ]
        )

        store.openConversation(id: currentConversationID.uuidString)
        store.removeConversation(id: currentConversationID.uuidString)

        #expect(store.conversations.count == 1)
        #expect(store.conversations.first?.id == fallbackConversationID.uuidString)
        #expect(store.selectedConversationID == fallbackConversationID.uuidString)
    }

    @Test func cacheSnapshotRoundTripsConversationMessagesAndSelection() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let updatedAt = Date(timeIntervalSince1970: 1_700_500_000)
        let lastSummaryRefreshAt = Date(timeIntervalSince1970: 1_700_500_100)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Cache Target",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_400_000),
                    updatedAt: updatedAt
                )
            ]
        )
        store.applyServerSummaryReadState(
            lastReadSequence: 3,
            unreadCount: 2,
            for: conversationIDString
        )
        store.openConversation(id: conversationIDString)
        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 3,
                    kind: "text",
                    body: ["text": "cached message"],
                    createdAt: updatedAt
                )
            ],
            currentUserID: Self.currentUserID
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: lastSummaryRefreshAt)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        #expect(snapshot.lastSummaryRefreshAt == lastSummaryRefreshAt)
        #expect(restoredStore.selectedConversationID == conversationIDString)
        #expect(restoredStore.hasLoadedMessages(for: conversationIDString))
        #expect(restoredStore.selectedConversation?.title == "Cache Target")
        #expect(restoredStore.selectedConversation?.kind == .group)
        #expect(restoredStore.selectedConversation?.serverLastReadSequence == 3)
        #expect(restoredStore.selectedConversation?.serverUnreadCount == 2)
        #expect(restoredStore.selectedConversation?.messages.map(\.text) == ["cached message"])
        #expect(restoredStore.selectedConversation?.hasMoreHistory == true)
        #expect(restoredStore.latestLoadedServerSequence(for: conversationIDString) == 3)
        #expect(restoredStore.oldestLoadedServerSequence(for: conversationIDString) == 3)
        #expect(snapshot.metadata.selectedConversationID == conversationIDString)
        #expect(snapshot.cursors == [
            IMSyncCursorState(
                conversationID: conversationIDString,
                hasLoadedMessages: true,
                latestSyncedServerSequence: 3,
                oldestLoadedServerSequence: 3
            )
        ])
    }

    @Test func cacheSnapshotDoesNotMarkSummaryOnlyConversationAsLoadedForGapSync() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let summaries = [
            Self.gapSummary(conversationID: conversationID, latestServerSequence: 20)
        ]
        store.replaceConversationSummaries(summaries)

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        #expect(restoredStore.hasLoadedMessages(for: conversationID.uuidString) == false)
        #expect(restoredStore.latestLoadedServerSequence(for: conversationID.uuidString) == nil)
        #expect(restoredStore.gapSyncTargets(from: summaries).isEmpty)
    }

    @Test func cacheSnapshotTrimsMessagesToRecentWindowAndPreservesWindowCursor() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.replaceConversationSummaries([Self.gapSummary(conversationID: conversationID, latestServerSequence: 205)])
        store.replaceMessages(
            in: conversationIDString,
            messages: (1...205).map { sequence in
                Self.messageResponse(conversationID: conversationID, serverSequence: sequence)
            },
            currentUserID: Self.currentUserID
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let cachedConversation = try #require(snapshot.conversations.first)
        let cursor = try #require(snapshot.cursors.first)

        #expect(cachedConversation.messages.count == IMConversationCacheSnapshot.cachedMessageLimit)
        #expect(cachedConversation.messages.first?.serverSequence == 6)
        #expect(cachedConversation.messages.last?.serverSequence == 205)
        #expect(cursor.latestSyncedServerSequence == 205)
        #expect(cursor.oldestLoadedServerSequence == 6)
    }

    @Test func cacheRestoreKeepsPendingAndFailedMessagesWithoutRestoringPendingQueue() {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let failedRequest = store.prepareOutgoingText(
            "failed draft",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        )
        if let failedRequest {
            store.markOutgoingFailure(requestID: failedRequest.requestID, message: "send failed")
        }
        _ = store.prepareOutgoingText(
            "pending draft",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)
        restoredStore.markAllPendingMessagesFailed(message: "should not apply")

        #expect(restoredStore.selectedConversation?.messages.map(\.text) == ["failed draft", "pending draft"])
        #expect(restoredStore.selectedConversation?.messages.map(\.deliveryState) == [
            .failed(message: "send failed"),
            .sending
        ])
    }
}
