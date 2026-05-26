import Foundation
import Testing
@testable import IMClientKit

extension IMConversationStoreTests {
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
                kind: "rich_text",
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
                kind: "rich_text",
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
                    kind: "rich_text",
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
                    kind: "rich_text",
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


    @Test func prepareOutgoingReplyAppendsQuotedMessageAndPreview() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.openConversation(id: conversationIDString)
        let request = store.prepareOutgoingReply(
            reference: IMReplyReference(
                messageID: "server-message-1",
                senderUserID: Self.peerUserID,
                previewText: "quoted source"
            ),
            text: "reply body",
            conversationID: conversationIDString,
            senderUserID: Self.currentUserID
        )

        let selectedConversation = try #require(store.selectedConversation)
        let localMessage = try #require(selectedConversation.messages.last)
        #expect(request?.payload.content == .reply(
            reference: IMReplyReference(
                messageID: "server-message-1",
                senderUserID: Self.peerUserID,
                previewText: "quoted source"
            ),
            body: .plain("reply body")
        ))
        #expect(localMessage.content == .reply(
            reference: IMReplyReference(
                messageID: "server-message-1",
                senderUserID: Self.peerUserID,
                previewText: "quoted source"
            ),
            body: .plain("reply body")
        ))
        #expect(localMessage.text == "reply body")
        #expect(selectedConversation.lastMessagePreview == "reply body")
    }


    @Test func replyResolutionFallsBackToStoredPreviewWhenReferencedMessageIsUnavailable() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.openConversation(id: conversationIDString)
        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 10,
                    kind: "reply",
                    body: [
                        "text": "latest reply",
                        "referenceMessageID": "missing-message-id",
                        "referenceSenderUserID": Self.currentUserID.uuidString,
                        "referencePreviewText": "quoted snapshot"
                    ],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_100)
                )
            ],
            currentUserID: Self.currentUserID
        )

        let selectedConversation = try #require(store.selectedConversation)
        let replyMessage = try #require(selectedConversation.messages.last)
        #expect(replyMessage.resolvedReplyReference(in: selectedConversation.messages) == IMReplyReferenceResolution(
            state: .unavailable,
            text: "quoted snapshot"
        ))
    }


    @Test func replyResolutionUsesLoadedReferencedMessageFromHistory() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let referencedMessageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let replyMessageID = UUID(uuidString: "66666666-2222-3333-4444-555555555555")!

        store.openConversation(id: conversationIDString)
        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: referencedMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 1,
                    kind: "rich_text",
                    body: ["text": "referenced from history"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_000)
                ),
                IMConversationMessageResponseBody(
                    id: replyMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: "client-reply-history",
                    serverSequence: 2,
                    kind: "reply",
                    body: [
                        "text": "reply from history",
                        "referenceMessageID": referencedMessageID.uuidString,
                        "referenceSenderUserID": Self.peerUserID.uuidString,
                        "referencePreviewText": "stale preview"
                    ],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_100)
                )
            ],
            currentUserID: Self.currentUserID
        )

        let selectedConversation = try #require(store.selectedConversation)
        let replyMessage = try #require(selectedConversation.messages.last)
        #expect(replyMessage.resolvedReplyReference(in: selectedConversation.messages) == IMReplyReferenceResolution(
            state: .loaded,
            text: "referenced from history"
        ))
    }


    @Test func realtimeRecallUpdatesReplyResolutionToRecalledPlaceholder() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let referencedMessageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let replyMessageID = UUID(uuidString: "66666666-2222-3333-4444-555555555555")!

        store.openConversation(id: conversationIDString)
        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: referencedMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 1,
                    kind: "rich_text",
                    body: ["text": "will be recalled"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_000)
                ),
                IMConversationMessageResponseBody(
                    id: replyMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: "client-reply-realtime",
                    serverSequence: 2,
                    kind: "reply",
                    body: [
                        "text": "reply before recall",
                        "referenceMessageID": referencedMessageID.uuidString,
                        "referenceSenderUserID": Self.peerUserID.uuidString,
                        "referencePreviewText": "will be recalled"
                    ],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_100)
                )
            ],
            currentUserID: Self.currentUserID
        )

        store.applyRecalledMessage(
            IMConversationMessageResponseBody(
                id: referencedMessageID,
                conversationID: conversationID,
                senderUserID: Self.peerUserID,
                clientMessageID: nil,
                serverSequence: 1,
                kind: "recalled",
                body: [:],
                createdAt: Date(timeIntervalSince1970: 1_700_400_000)
            ),
            currentUserID: Self.currentUserID
        )

        let selectedConversation = try #require(store.selectedConversation)
        let replyMessage = try #require(selectedConversation.messages.last)
        #expect(replyMessage.resolvedReplyReference(in: selectedConversation.messages) == IMReplyReferenceResolution(
            state: .recalled,
            text: "原消息已撤回"
        ))
    }


    @Test func gapSyncRecallUpdateKeepsReplyResolutionConsistent() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let referencedMessageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let replyMessageID = UUID(uuidString: "66666666-2222-3333-4444-555555555555")!

        store.openConversation(id: conversationIDString)
        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: referencedMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 1,
                    kind: "rich_text",
                    body: ["text": "gap target"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_000)
                ),
                IMConversationMessageResponseBody(
                    id: replyMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: "client-reply-gap",
                    serverSequence: 2,
                    kind: "reply",
                    body: [
                        "text": "gap reply",
                        "referenceMessageID": referencedMessageID.uuidString,
                        "referenceSenderUserID": Self.peerUserID.uuidString,
                        "referencePreviewText": "gap target"
                    ],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_100)
                )
            ],
            currentUserID: Self.currentUserID
        )

        store.appendMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: referencedMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 1,
                    kind: "recalled",
                    body: [:],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_000)
                )
            ],
            currentUserID: Self.currentUserID
        )

        let selectedConversation = try #require(store.selectedConversation)
        let replyMessage = try #require(selectedConversation.messages.last)
        #expect(replyMessage.resolvedReplyReference(in: selectedConversation.messages) == IMReplyReferenceResolution(
            state: .recalled,
            text: "原消息已撤回"
        ))
    }


    @Test func replyJumpStateResolvesLoadedReferencedMessageID() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-9999-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let referencedMessageID = UUID(uuidString: "11111111-9999-3333-4444-555555555555")!
        let replyMessageID = UUID(uuidString: "66666666-9999-3333-4444-555555555555")!

        store.openConversation(id: conversationIDString)
        store.replaceMessages(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: referencedMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 2,
                    content: .recalled,
                    createdAt: Date(timeIntervalSince1970: 1_700_450_000)
                ),
                IMConversationMessageResponseBody(
                    id: replyMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: "client-reply-jump",
                    serverSequence: 3,
                    content: .reply(
                        reference: IMReplyReference(
                            messageID: referencedMessageID.uuidString,
                            senderUserID: Self.peerUserID,
                            previewText: "quoted snapshot"
                        ),
                        body: .plain("jump reply")
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_450_100)
                )
            ],
            currentUserID: Self.currentUserID
        )

        let matchedMessageID = try #require(
            store.localMessageID(
                matchingReferencedMessageID: referencedMessageID.uuidString,
                in: conversationIDString
            )
        )
        store.beginReplyJump(to: referencedMessageID.uuidString, in: conversationIDString)
        store.resolveReplyJump(matchedMessageID: matchedMessageID, in: conversationIDString)

        #expect(store.replyJumpConversationID == conversationIDString)
        #expect(store.replyJumpTargetMessageID == referencedMessageID.uuidString)
        #expect(store.replyJumpMatchedMessageID == referencedMessageID.uuidString)
        #expect(store.replyJumpState == .found)
    }


    @Test func replyJumpStateClearsWhenConversationIsRemoved() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-aaaa-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Jump conversation",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_450_200),
                    updatedAt: Date(timeIntervalSince1970: 1_700_450_200)
                )
            ]
        )

        store.beginReplyJump(to: "missing-target", in: conversationIDString)
        store.removeConversation(id: conversationIDString)

        #expect(store.replyJumpConversationID == nil)
        #expect(store.replyJumpTargetMessageID == nil)
        #expect(store.replyJumpMatchedMessageID == nil)
        #expect(store.replyJumpState == .idle)
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
                    kind: "rich_text",
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
                    kind: "rich_text",
                    body: ["text": "third"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_003)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    serverSequence: 4,
                    kind: "rich_text",
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
                    kind: "rich_text",
                    body: ["text": "first"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_001)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    serverSequence: 2,
                    kind: "rich_text",
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
                    kind: "rich_text",
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
                    kind: "rich_text",
                    body: ["text": "pending local"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_004)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 5,
                    kind: "rich_text",
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

}
