import Foundation
import Testing
@testable import IMClientKit

struct IMConversationOutgoingStateReducerTests {
    @Test func reducerAppliesOutgoingLifecycleWithoutMainActorStore() throws {
        let conversationID = "abababab-abab-abab-abab-abababababab"
        let requestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let retryRequestID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let clientMessageID = "local-client-message-id"
        let reducer = IMConversationOutgoingStateReducer()
        var state = IMConversationOutgoingState(
            conversations: [
                Self.makeConversation(id: conversationID)
            ],
            selectedConversationID: nil,
            statusMessage: "loading",
            outgoingQueueState: OutgoingQueueState()
        )

        let appendEffect = reducer.reduce(
            .appendOutgoingMessage(
                content: .richText(.plain("queued text")),
                conversationID: conversationID,
                senderUserID: UUID(uuidString: "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa")!,
                deliveryState: .queued(message: "queued"),
                shouldRegisterPendingRequest: false,
                localTransferState: nil,
                requestID: requestID,
                clientMessageID: clientMessageID,
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            isRetryableFailure: Self.isRetryableFailure(_:)
        )

        #expect(appendEffect.didApply)
        #expect(appendEffect.shouldSortConversations)
        #expect(appendEffect.placeholder?.localMessageID == clientMessageID)
        #expect(appendEffect.request == nil)
        #expect(state.selectedConversationID == conversationID)
        #expect(state.statusMessage == nil)
        #expect(state.conversations[0].pendingMessages.map { $0.clientMessageID } == [clientMessageID])
        #expect(state.conversations[0].pendingMessages.first?.deliveryState == .queued(message: "queued"))
        #expect(state.conversations[0].lastMessagePreviewText == "queued text")
        #expect(state.conversations[0].unreadCount == 0)
        #expect(state.conversations[0].draftText == "")

        let startEffect = reducer.reduce(
            .startQueuedOutgoingMessage(
                localMessageID: clientMessageID,
                conversationID: conversationID,
                requestID: requestID
            ),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            isRetryableFailure: Self.isRetryableFailure(_:)
        )

        #expect(startEffect.request?.requestID == requestID)
        #expect(startEffect.request?.localMessageID == clientMessageID)
        #expect(startEffect.request?.payload.clientMessageID == clientMessageID)
        #expect(startEffect.request?.payload.body["text"] == "queued text")
        #expect(state.conversations[0].pendingMessages.first?.deliveryState == .sending)

        let failureEffect = reducer.reduce(
            .markOutgoingFailure(requestID: requestID, message: "network failed"),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            isRetryableFailure: Self.isRetryableFailure(_:)
        )

        #expect(failureEffect.didApply)
        #expect(state.statusMessage == "network failed")
        #expect(state.conversations[0].pendingMessages.first?.deliveryState == .failed(message: "network failed"))

        let retryEffect = reducer.reduce(
            .retryOutgoingMessage(
                localMessageID: clientMessageID,
                conversationID: conversationID,
                requestID: retryRequestID
            ),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            isRetryableFailure: Self.isRetryableFailure(_:)
        )

        #expect(retryEffect.request?.requestID == retryRequestID)
        #expect(retryEffect.request?.payload.clientMessageID == clientMessageID)
        #expect(state.statusMessage == nil)
        #expect(state.conversations[0].pendingMessages.first?.deliveryState == .sending)
    }

    private static func makeConversation(id: String) -> IMConversation {
        IMConversation(
            id: id,
            title: "Outgoing",
            kind: .group,
            memberCount: 2,
            memberUserIDs: [],
            members: [],
            messages: [],
            lastMessagePreviewText: "old preview",
            hasMoreHistory: false,
            serverLastReadSequence: 1,
            serverUnreadCount: 2,
            localUnreadDelta: 1,
            draftText: "draft",
            draftUpdatedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func ensureConversationIndex(
        for conversationID: String,
        conversations: inout [IMConversation]
    ) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }
        conversations.append(makeConversation(id: conversationID))
        return conversations.count - 1
    }

    private static func latestPreviewText(
        in messages: [IMConversationMessage],
        fallback: String
    ) -> String {
        messages.last?.text ?? fallback
    }

    private static func latestUpdatedAt(
        in messages: [IMConversationMessage],
        fallback: Date
    ) -> Date {
        messages.last?.createdAt ?? fallback
    }

    private static func isRetryableFailure(_ message: IMPendingConversationMessage) -> Bool {
        switch message.deliveryState {
        case .queued, .unknown, .failed:
            return true
        case .preparing, .uploading, .uploaded, .sending, .sent, .received:
            return false
        }
    }
}
