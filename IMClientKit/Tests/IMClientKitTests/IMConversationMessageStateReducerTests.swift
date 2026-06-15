import Foundation
import Testing
@testable import IMClientKit

struct IMConversationMessageStateReducerTests {
    private let currentUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peerUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func reducerAppliesCanonicalMessageAndStreamStateWithoutMainActorStore() throws {
        let conversationID = "abababab-abab-abab-abab-abababababab"
        let messageID = "cccccccc-1111-1111-1111-cccccccccccc"
        let clientMessageID = "client-message-id"
        let streamID = "stream-1"
        let reducer = IMConversationMessageStateReducer()
        var state = IMConversationMessageState(
            conversations: [
                Self.makeConversation(
                    id: conversationID,
                    pendingMessages: [
                        IMPendingConversationMessage(
                            localMessageID: clientMessageID,
                            clientMessageID: clientMessageID,
                            conversationID: conversationID,
                            senderUserID: currentUserID,
                            content: .richText(.plain("pending")),
                            createdAt: Date(timeIntervalSince1970: 1),
                            deliveryState: .sending
                        )
                    ]
                )
            ],
            selectedConversationID: nil,
            statusMessage: "loading",
            pendingStreamSnapshotTargets: []
        )

        let canonicalEffect = reducer.reduce(
            .applyCreatedMessage(
                try Self.makeMessage(
                    id: messageID,
                    conversationID: conversationID,
                    clientMessageID: clientMessageID,
                    senderUserID: currentUserID,
                    sequence: 2,
                    text: "",
                    derivedState: MessageDerivedState(
                        streamState: MessageStreamState(
                            streamID: streamID,
                            state: .streaming,
                            updatedAt: Date(timeIntervalSince1970: 2)
                        )
                    ),
                    direction: .outgoing,
                    deliveryState: .sent
                ),
                clientMessageID: clientMessageID
            ),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            messageComparator: Self.messageComparator(_:_:)
        )

        #expect(canonicalEffect.didMutate)
        #expect(canonicalEffect.shouldSortConversations)
        #expect(canonicalEffect.cursorRefreshes.first?.conversationID == conversationID)
        #expect(state.statusMessage == nil)
        #expect(state.selectedConversationID == conversationID)
        #expect(state.conversations[0].pendingMessages.isEmpty)
        #expect(state.conversations[0].messages.count == 1)
        #expect(state.conversations[0].messages.first?.clientMessageID == clientMessageID)

        let firstChunk = IMTCPMessageStreamPayload(
            streamID: streamID,
            messageID: messageID,
            conversationID: conversationID,
            chunkIndex: 1,
            deltaText: "AI",
            partialTextLength: 2,
            state: .streaming,
            serverTimestamp: Date(timeIntervalSince1970: 3)
        )
        _ = reducer.reduce(
            .applyMessageStreamState(firstChunk),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            messageComparator: Self.messageComparator(_:_:)
        )

        #expect(state.conversations[0].messages.first?.text == "AI")
        #expect(state.conversations[0].messages.first?.derivedState.streamState?.lastChunkIndex == 1)

        _ = reducer.reduce(
            .applyMessageStreamState(firstChunk),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            messageComparator: Self.messageComparator(_:_:)
        )
        #expect(state.conversations[0].messages.first?.text == "AI")

        _ = reducer.reduce(
            .applyMessageStreamState(
                IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID,
                    conversationID: conversationID,
                    chunkIndex: 3,
                    deltaText: " gap",
                    partialTextLength: 6,
                    state: .streaming,
                    serverTimestamp: Date(timeIntervalSince1970: 5)
                )
            ),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            messageComparator: Self.messageComparator(_:_:)
        )

        #expect(state.conversations[0].messages.first?.text == "AI")
        #expect(state.pendingStreamSnapshotTargets == [
            IMActiveMessageStreamTarget(
                conversationID: conversationID,
                messageID: messageID,
                streamID: streamID
            )
        ])
    }

    @Test func reducerUpdatesLocalDownloadStateAndPresentation() throws {
        let conversationID = "abababab-abab-abab-abab-abababababab"
        let messageID = "cccccccc-1111-1111-1111-cccccccccccc"
        let reducer = IMConversationMessageStateReducer()
        var state = IMConversationMessageState(
            conversations: [
                Self.makeConversation(
                    id: conversationID,
                    messages: [
                        try Self.makeMessage(
                            id: messageID,
                            conversationID: conversationID,
                            senderUserID: peerUserID,
                            sequence: 2,
                            text: "download me",
                            direction: .incoming,
                            deliveryState: .received
                        )
                    ]
                )
            ],
            selectedConversationID: conversationID,
            statusMessage: nil,
            pendingStreamSnapshotTargets: []
        )
        let taskID = IMTransferTaskID(sessionIdentifier: "download-session", taskIdentifier: 7)

        let effect = reducer.reduce(
            .updateLocalDownloadState(
                messageID: messageID,
                state: IMMessageLocalDownloadState(
                    destinationFilePath: "/tmp/file.png",
                    status: .downloading(progress: nil, backgroundTransfer: nil),
                    taskID: taskID
                )
            ),
            state: &state,
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            messageComparator: Self.messageComparator(_:_:)
        )

        let message = try #require(state.conversations.first?.messages.first)
        #expect(effect.didMutate)
        #expect(effect.shouldSortConversations)
        #expect(message.localDownloadState?.taskID == taskID)
        #expect(message.transferTaskID == taskID)
        #expect(state.conversations.first?.lastMessagePreviewText == "download me")
    }

    private static func makeConversation(
        id: String,
        messages: [IMConversationMessage] = [],
        pendingMessages: [IMPendingConversationMessage] = []
    ) -> IMConversation {
        IMConversation(
            id: id,
            title: "Message State",
            kind: .group,
            memberCount: 2,
            memberUserIDs: [],
            members: [],
            messages: messages,
            pendingMessages: pendingMessages,
            lastMessagePreviewText: messages.last?.text ?? pendingMessages.last?.text ?? "",
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func makeMessage(
        id: String,
        conversationID: String,
        clientMessageID: String? = nil,
        senderUserID: UUID,
        sequence: UInt64,
        text: String,
        derivedState: MessageDerivedState = MessageDerivedState(),
        direction: IMMessageDirection,
        deliveryState: IMMessageDeliveryState
    ) throws -> IMConversationMessage {
        try IMConversationMessage(
            id: id,
            conversationID: conversationID,
            clientMessageID: clientMessageID,
            serverMessageID: id,
            senderUserID: senderUserID,
            serverSequence: sequence,
            timelineSequence: sequence,
            content: .richText(.plain(text)),
            derivedState: derivedState,
            direction: direction,
            createdAt: Date(timeIntervalSince1970: Double(sequence)),
            deliveryState: deliveryState
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

    private static func messageComparator(
        _ left: IMConversationMessage,
        _ right: IMConversationMessage
    ) -> Bool {
        if left.serverSequence == right.serverSequence {
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }
        return left.serverSequence < right.serverSequence
    }
}
