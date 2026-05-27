import Foundation
import Testing
@testable import IMClientKit

extension IMConversationStoreTests {
    @Test func failedNetworkMessageCanBeRetriedWithSameClientMessageID() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let originalRequest = try #require(
            store.prepareOutgoingText(
                "retry me",
                conversationID: conversationID,
                senderUserID: Self.currentUserID
            )
        )
        let originalClientMessageID = try #require(originalRequest.payload.clientMessageID)

        store.markOutgoingFailure(
            requestID: originalRequest.requestID,
            message: "IM 长连接未建立，消息没有发送出去。"
        )

        let failedMessage = try #require(store.selectedConversation?.pendingMessages.first)
        #expect(store.isRetryableFailure(failedMessage))

        let retryRequest = try #require(
            store.retryOutgoingMessage(
                localMessageID: failedMessage.id,
                conversationID: conversationID
            )
        )

        #expect(retryRequest.localMessageID == failedMessage.id)
        #expect(retryRequest.payload.clientMessageID == originalClientMessageID)
        #expect(retryRequest.payload.body["text"] == "retry me")
        #expect(store.selectedConversation?.pendingMessages.count == 1)
        #expect(store.selectedConversation?.pendingMessages.first?.deliveryState == .sending)
    }


    @Test func restoredUnknownMessageCanBeRetriedWithSameClientMessageID() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let originalRequest = try #require(
            store.prepareOutgoingText(
                "retry after restart",
                conversationID: conversationID,
                senderUserID: Self.currentUserID
            )
        )
        let originalClientMessageID = try #require(originalRequest.payload.clientMessageID)

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        let restoredMessage = try #require(restoredStore.selectedConversation?.pendingMessages.first)
        #expect(restoredMessage.deliveryState == .unknown(message: "发送状态未确认，请重试。"))
        #expect(restoredStore.isRetryableFailure(restoredMessage))

        let retryRequest = try #require(
            restoredStore.retryOutgoingMessage(
                localMessageID: restoredMessage.id,
                conversationID: conversationID
            )
        )

        #expect(retryRequest.localMessageID == restoredMessage.id)
        #expect(retryRequest.payload.clientMessageID == originalClientMessageID)
        #expect(restoredStore.selectedConversation?.pendingMessages.first?.deliveryState == .sending)
    }


    @Test func queuedOutgoingTextFlushesWithSameClientMessageID() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"

        let didQueue = store.queueOutgoingText(
            "queued text",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        )

        #expect(didQueue)
        let queuedMessage = try #require(store.selectedConversation?.pendingMessages.first)
        let clientMessageID = queuedMessage.clientMessageID
        #expect(queuedMessage.deliveryState == .queued(message: "等待 IM 长连接恢复后发送。"))
        #expect(store.isRetryableFailure(queuedMessage))

        let requests = store.queuedOutgoingMessageRequests(limit: 1)

        #expect(requests.count == 1)
        #expect(requests[0].localMessageID == queuedMessage.id)
        #expect(requests[0].payload.clientMessageID == clientMessageID)
        #expect(requests[0].payload.body["text"] == "queued text")
        #expect(store.selectedConversation?.pendingMessages.first?.deliveryState == .sending)

        store.applyOutgoingAcknowledgement(
            requestID: requests[0].requestID,
            payload: IMTCPAckPayload(
                messageID: "server-queued-1",
                conversationID: conversationID,
                status: "accepted"
            )
        )

        #expect(store.selectedConversation?.pendingMessages.first?.deliveryState == .sending)
    }


    @Test func duplicateOutgoingAcknowledgementDoesNotMutateSentMessageAgain() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let request = try #require(
            store.prepareOutgoingText(
                "hello duplicate ack",
                conversationID: conversationID,
                senderUserID: Self.currentUserID
            )
        )

        store.applyOutgoingAcknowledgement(
            requestID: request.requestID,
            payload: IMTCPAckPayload(
                messageID: "server-1",
                conversationID: conversationID,
                status: "accepted"
            )
        )
        store.applyOutgoingAcknowledgement(
            requestID: request.requestID,
            payload: IMTCPAckPayload(
                messageID: "server-2",
                conversationID: conversationID,
                status: "internal_error"
            )
        )

        let message = try #require(store.selectedConversation?.pendingMessages.first)
        #expect(message.deliveryState == .sending)
        #expect(store.statusMessage == nil)
    }


    @Test func lateOutgoingAcknowledgementDoesNotReviveMessageAfterFailure() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let request = try #require(
            store.prepareOutgoingText(
                "late ack after failure",
                conversationID: conversationID,
                senderUserID: Self.currentUserID
            )
        )

        store.markOutgoingFailure(requestID: request.requestID, message: "TCP 连接已关闭。")
        store.applyOutgoingAcknowledgement(
            requestID: request.requestID,
            payload: IMTCPAckPayload(
                messageID: "server-late",
                conversationID: conversationID,
                status: "accepted"
            )
        )

        let message = try #require(store.selectedConversation?.pendingMessages.first)
        #expect(message.deliveryState == .failed(message: "TCP 连接已关闭。"))
        #expect(store.statusMessage == "TCP 连接已关闭。")
    }


    @Test func queuedOutgoingMessagesFlushInCreatedOrderWithLimit() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        store.restoreCacheSnapshot(
            IMConversationCacheSnapshot(
                metadata: IMCacheMetadataState(selectedConversationID: conversationID, lastSummaryRefreshAt: nil),
                conversations: [
                    IMCachedConversationState(
                        id: conversationID,
                        title: "Queued",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.currentUserID, Self.peerUserID],
                        messages: [],
                        pendingMessages: [
                            Self.cachedQueuedMessage(id: "queued-2", conversationID: conversationID, text: "second", createdAt: 2),
                            Self.cachedQueuedMessage(id: "queued-1", conversationID: conversationID, text: "first", createdAt: 1),
                            Self.cachedQueuedMessage(id: "queued-3", conversationID: conversationID, text: "third", createdAt: 3)
                        ],
                        hasLoadedMessages: false,
                        lastMessagePreviewText: "third",
                        hasMoreHistory: false,
                        latestLoadedTimelineSequence: nil,
                        oldestLoadedTimelineSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 3)
                    )
                ],
                cursors: []
            )
        )

        let requests = store.queuedOutgoingMessageRequests(limit: 2)

        #expect(requests.map { $0.payload.body["text"] } == ["first", "second"])
        #expect(store.selectedConversation?.pendingMessages.map(\.deliveryState) == [
            .sending,
            .sending,
            .queued(message: "等待 IM 长连接恢复后发送。")
        ])
    }


    @Test func markAllPendingMessagesUnknownLeavesQueuedMessagesFlushable() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let inFlightRequest = try #require(store.prepareOutgoingText(
            "in flight",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        ))
        let inFlightClientMessageID = try #require(inFlightRequest.payload.clientMessageID)
        store.queueOutgoingText("still queued", conversationID: conversationID, senderUserID: Self.currentUserID)

        store.markAllPendingMessagesUnknown(message: "发送状态未确认，请重试。")

        let messagesAfterDisconnect = try #require(store.selectedConversation?.pendingMessages)
        #expect(messagesAfterDisconnect.map(\.deliveryState) == [
            .unknown(message: "发送状态未确认，请重试。"),
            .queued(message: "等待 IM 长连接恢复后发送。")
        ])
        #expect(store.queueSummary(for: conversationID).queuedCount == 1)
        #expect(store.queueSummary(for: conversationID).retryableIssueCount == 1)

        let queuedRequests = store.queuedOutgoingMessageRequests(limit: 10)
        #expect(queuedRequests.count == 1)
        #expect(queuedRequests.first?.payload.body["text"] == "still queued")

        let retryRequest = try #require(store.retryOutgoingMessage(
            localMessageID: inFlightRequest.localMessageID,
            conversationID: conversationID
        ))
        #expect(retryRequest.payload.clientMessageID == inFlightClientMessageID)
        #expect(retryRequest.payload.body["text"] == "in flight")
    }


    @Test func unknownMessageMergesWithServerGapResultWithoutDuplication() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let request = try #require(store.prepareOutgoingText(
            "unknown and merged",
            conversationID: conversationIDString,
            senderUserID: Self.currentUserID
        ))
        let clientMessageID = try #require(request.payload.clientMessageID)
        store.markAllPendingMessagesUnknown(message: "发送状态未确认，请重试。")

        store.appendTimelineItems(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: clientMessageID,
                    serverSequence: 7,
                    kind: "rich_text",
                    body: ["text": "unknown and merged"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_007)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.count == 1)
        #expect(store.selectedConversation?.messages.first?.clientMessageID == clientMessageID)
        #expect(store.selectedConversation?.messages.first?.serverSequence == 7)
        #expect(store.selectedConversation?.messages.first?.deliveryState == .sent)
    }

    @Test func canonicalEchoBeforeAckMergesWithSendingMessageWithoutDuplication() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let request = try #require(store.prepareOutgoingText(
            "echo before ack",
            conversationID: conversationIDString,
            senderUserID: Self.currentUserID
        ))
        let clientMessageID = try #require(request.payload.clientMessageID)

        store.applyTestDomainMessage(
            IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: "11111111-2222-3333-4444-555555555555",
                conversationID: conversationIDString,
                senderUserID: Self.currentUserID,
                serverSequence: 8,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_400_008),
                kind: "rich_text",
                body: ["text": "echo before ack"]
            ),
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.count == 1)
        #expect(store.selectedConversation?.messages.first?.clientMessageID == clientMessageID)
        #expect(store.selectedConversation?.messages.first?.serverSequence == 8)
        #expect(store.selectedConversation?.messages.first?.deliveryState == .sent)
    }


    @Test func cancelQueuedOutgoingMessageRemovesMessageAndUpdatesSummaryAndPreview() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        store.queueOutgoingText("first queued", conversationID: conversationID, senderUserID: Self.currentUserID)
        store.queueOutgoingText("second queued", conversationID: conversationID, senderUserID: Self.currentUserID)

        let messages = try #require(store.selectedConversation?.pendingMessages)
        #expect(messages.count == 2)
        #expect(store.selectedConversation?.lastMessagePreview == "second queued")

        let didCancelLatest = store.cancelQueuedOutgoingMessage(
            localMessageID: messages[1].id,
            conversationID: conversationID
        )

        #expect(didCancelLatest)
        #expect(store.selectedConversation?.pendingMessages.map(\.text) == ["first queued"])
        #expect(store.selectedConversation?.lastMessagePreview == "first queued")
        #expect(store.queueSummary(for: conversationID).queuedCount == 1)
        #expect(store.totalQueueSummary().queuedCount == 1)

        let didCancelRemaining = store.cancelQueuedOutgoingMessage(
            localMessageID: messages[0].id,
            conversationID: conversationID
        )

        #expect(didCancelRemaining)
        #expect(store.selectedConversation?.pendingMessages.isEmpty == true)
        #expect(store.selectedConversation?.lastMessagePreview == "")
        #expect(!store.queueSummary(for: conversationID).hasPendingWork)
        #expect(store.queuedOutgoingMessageRequests(limit: 10).isEmpty)

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)
        #expect(restoredStore.selectedConversation?.pendingMessages.isEmpty == true)
    }


    @Test func cancelQueuedOutgoingMessageRejectsNonQueuedMessages() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let sentRequest = try #require(store.prepareOutgoingText(
            "sent",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        ))
        store.applyOutgoingAcknowledgement(
            requestID: sentRequest.requestID,
            payload: IMTCPAckPayload(
                messageID: "server-sent",
                conversationID: conversationID,
                status: "accepted"
            )
        )
        let sendingRequest = try #require(store.prepareOutgoingText(
            "sending",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        ))
        store.queueOutgoingText("queued", conversationID: conversationID, senderUserID: Self.currentUserID)
        let failedRequest = try #require(store.prepareOutgoingText(
            "failed",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        ))
        store.markOutgoingFailure(requestID: failedRequest.requestID, message: "TCP 连接已关闭。")

        let pendingMessages = try #require(store.selectedConversation?.pendingMessages)
        let sendingMessage = try #require(pendingMessages.first(where: { $0.id == sendingRequest.localMessageID }))
        let failedMessage = try #require(pendingMessages.first(where: { $0.text == "failed" }))

        #expect(store.selectedConversation?.pendingMessages.first(where: { $0.text == "sent" })?.deliveryState == .sending)
        #expect(!store.cancelQueuedOutgoingMessage(localMessageID: sendingMessage.id, conversationID: conversationID))
        #expect(!store.cancelQueuedOutgoingMessage(localMessageID: failedMessage.id, conversationID: conversationID))
        #expect(store.selectedConversation?.pendingMessages.count == 4)
    }


    @Test func queuedBusinessRejectedMessageBecomesNonRetryableFailure() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        store.queueOutgoingText(
            "second stranger message",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        )
        let request = try #require(store.queuedOutgoingMessageRequests(limit: 1).first)

        store.applyOutgoingAcknowledgement(
            requestID: request.requestID,
            payload: IMTCPAckPayload(
                messageID: "rejected",
                conversationID: conversationID,
                status: "stranger_direct_message_limit_reached"
            )
        )

        let failedMessage = try #require(store.selectedConversation?.pendingMessages.first)
        #expect(failedMessage.deliveryState == .failed(
            message: "你们还不是好友，对方回复前只能发送一条消息。"
        ))
        #expect(!store.isRetryableFailure(failedMessage))
    }


    @Test func frozenDirectAcknowledgementBecomesNonRetryableFailure() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        store.queueOutgoingText(
            "frozen direct message",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        )
        let request = try #require(store.queuedOutgoingMessageRequests(limit: 1).first)

        store.applyOutgoingAcknowledgement(
            requestID: request.requestID,
            payload: IMTCPAckPayload(
                messageID: "frozen",
                conversationID: conversationID,
                status: "direct_conversation_frozen"
            )
        )

        let failedMessage = try #require(store.selectedConversation?.pendingMessages.first)
        #expect(failedMessage.deliveryState == .failed(
            message: "你们已不是好友，当前会话不能继续发送消息。"
        ))
        #expect(!store.isRetryableFailure(failedMessage))
    }


    @Test func queueSummaryCountsPendingWorkAndSkipsBusinessFailures() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let otherConversationID = "CCCCCCCC-1111-2222-3333-DDDDDDDDDDDD"

        #expect(!store.queueSummary(for: conversationID).hasPendingWork)

        store.queueOutgoingText("sending", conversationID: conversationID, senderUserID: Self.currentUserID)
        store.queueOutgoingText("business failed", conversationID: conversationID, senderUserID: Self.currentUserID)
        store.queueOutgoingText("retryable failed", conversationID: conversationID, senderUserID: Self.currentUserID)
        store.queueOutgoingText("still queued", conversationID: conversationID, senderUserID: Self.currentUserID)
        let requests = store.queuedOutgoingMessageRequests(limit: 3)
        #expect(requests.count == 3)

        store.applyOutgoingAcknowledgement(
            requestID: requests[1].requestID,
            payload: IMTCPAckPayload(
                messageID: "business-rejected",
                conversationID: conversationID,
                status: "stranger_direct_message_limit_reached"
            )
        )
        store.markOutgoingFailure(requestID: requests[2].requestID, message: "TCP 连接已关闭。")

        let summary = store.queueSummary(for: conversationID)
        #expect(summary.queuedCount == 1)
        #expect(summary.sendingCount == 1)
        #expect(summary.retryableIssueCount == 1)
        #expect(summary.hasPendingWork)

        store.queueOutgoingText("other queued", conversationID: otherConversationID, senderUserID: Self.currentUserID)
        let totalSummary = store.totalQueueSummary()
        #expect(totalSummary.queuedCount == 2)
        #expect(totalSummary.sendingCount == 1)
        #expect(totalSummary.retryableIssueCount == 1)
        #expect(totalSummary.hasPendingWork)
    }


    @Test func queuedMessageMergesWithServerGapResultWithoutDuplication() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        store.queueOutgoingText(
            "queued and merged",
            conversationID: conversationIDString,
            senderUserID: Self.currentUserID
        )
        let queuedMessage = try #require(store.selectedConversation?.pendingMessages.first)
        let clientMessageID = queuedMessage.clientMessageID

        store.appendTimelineItems(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: clientMessageID,
                    serverSequence: 1,
                    kind: "rich_text",
                    body: ["text": "queued and merged"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_001)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.count == 1)
        #expect(store.selectedConversation?.messages.first?.clientMessageID == clientMessageID)
        #expect(store.selectedConversation?.messages.first?.serverSequence == 1)
        #expect(store.selectedConversation?.messages.first?.deliveryState == .sent)
    }


    @Test func businessRejectedMessageIsNotRetryable() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let request = try #require(
            store.prepareOutgoingText(
                "second stranger message",
                conversationID: conversationID,
                senderUserID: Self.currentUserID
            )
        )

        store.applyOutgoingAcknowledgement(
            requestID: request.requestID,
            payload: IMTCPAckPayload(
                messageID: "rejected",
                conversationID: conversationID,
                status: "stranger_direct_message_limit_reached"
            )
        )

        let failedMessage = try #require(store.selectedConversation?.pendingMessages.first)
        #expect(!store.isRetryableFailure(failedMessage))
        #expect(
            store.retryOutgoingMessage(
                localMessageID: failedMessage.id,
                conversationID: conversationID
            ) == nil
        )
        #expect(store.selectedConversation?.pendingMessages.first?.deliveryState == .failed(
            message: "你们还不是好友，对方回复前只能发送一条消息。"
        ))
    }


    @Test func frozenDirectMessageIsNotRetryable() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let request = try #require(
            store.prepareOutgoingText(
                "frozen direct message",
                conversationID: conversationID,
                senderUserID: Self.currentUserID
            )
        )

        store.applyOutgoingAcknowledgement(
            requestID: request.requestID,
            payload: IMTCPAckPayload(
                messageID: "frozen",
                conversationID: conversationID,
                status: "direct_conversation_frozen"
            )
        )

        let failedMessage = try #require(store.selectedConversation?.pendingMessages.first)
        #expect(!store.isRetryableFailure(failedMessage))
        #expect(
            store.retryOutgoingMessage(
                localMessageID: failedMessage.id,
                conversationID: conversationID
            ) == nil
        )
        #expect(store.selectedConversation?.pendingMessages.first?.deliveryState == .failed(
            message: "你们已不是好友，当前会话不能继续发送消息。"
        ))
    }


    @Test func retriedMessageMergesWithServerGapResultWithoutDuplication() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let originalRequest = try #require(
            store.prepareOutgoingText(
                "retry and merge",
                conversationID: conversationIDString,
                senderUserID: Self.currentUserID
            )
        )
        let clientMessageID = try #require(originalRequest.payload.clientMessageID)

        store.markOutgoingFailure(requestID: originalRequest.requestID, message: "IM 连接已断开。")
        let failedMessage = try #require(store.selectedConversation?.pendingMessages.first)
        _ = store.retryOutgoingMessage(
            localMessageID: failedMessage.id,
            conversationID: conversationIDString
        )

        store.appendTimelineItems(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: clientMessageID,
                    serverSequence: 1,
                    kind: "rich_text",
                    body: ["text": "retry and merge"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_001)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.count == 1)
        #expect(store.selectedConversation?.messages.first?.clientMessageID == clientMessageID)
        #expect(store.selectedConversation?.messages.first?.serverSequence == 1)
        #expect(store.selectedConversation?.messages.first?.deliveryState == .sent)
    }


    @Test func latestLoadedServerSequenceHandlesEmptyPendingAndLoadedMessages() {
        let store = IMConversationStore()
        let emptyConversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let pendingConversationID = "CCCCCCCC-1111-2222-3333-DDDDDDDDDDDD"
        let loadedConversationID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        let loadedConversationIDString = loadedConversationID.uuidString

        store.openConversation(id: emptyConversationID)
        #expect(store.latestLoadedMessageSequence(for: emptyConversationID) == nil)

        store.openConversation(id: pendingConversationID)
        _ = store.prepareOutgoingText(
            "pending only",
            conversationID: pendingConversationID,
            senderUserID: Self.currentUserID
        )
        #expect(store.latestLoadedMessageSequence(for: pendingConversationID) == nil)

        store.openConversation(id: loadedConversationIDString)
        store.replaceTimelineItems(
            in: loadedConversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    conversationID: loadedConversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 7,
                    kind: "rich_text",
                    body: ["text": "seven"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_007)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    conversationID: loadedConversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: nil,
                    serverSequence: 9,
                    kind: "rich_text",
                    body: ["text": "nine"],
                    createdAt: Date(timeIntervalSince1970: 1_700_400_009)
                )
            ],
            currentUserID: Self.currentUserID
        )

        #expect(store.latestLoadedMessageSequence(for: loadedConversationIDString) == 9)
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

        store.replaceTimelineItems(
            in: equalConversationID.uuidString,
            messages: [Self.messageResponse(conversationID: equalConversationID, serverSequence: 3)],
            currentUserID: Self.currentUserID
        )
        store.replaceTimelineItems(
            in: staleConversationID.uuidString,
            messages: [Self.messageResponse(conversationID: staleConversationID, serverSequence: 4)],
            currentUserID: Self.currentUserID
        )
        store.replaceTimelineItems(
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

}
