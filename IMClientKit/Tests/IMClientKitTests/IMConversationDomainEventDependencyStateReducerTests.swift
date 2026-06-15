import Foundation
import Testing
@testable import IMClientKit

struct IMConversationDomainEventDependencyStateReducerTests {
    @Test func reducerRecordsConsumedEventHighWatermarkAndCreatedMessageKeys() throws {
        let reducer = IMConversationDomainEventDependencyStateReducer()
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-1111-1111-111111111111")!
        let message = try makeMessage(
            id: "message-1",
            serverMessageID: "server-message-1",
            conversationID: conversationID.uuidString
        )
        var state = DomainEventProjectionReducer.DependencySnapshot(
            processedEventIDs: [],
            ownerAggregateHighWatermarks: [:],
            existingMessageKeys: []
        )

        reducer.reduce(
            payload: domainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                ownerAggregateSequence: 3
            ),
            operation: .applyMessageCreated(
                message: message,
                clientMessageID: nil,
                notice: nil,
                summary: nil
            ),
            state: &state
        )

        let highWatermarkKey = IMOwnerAggregateKey(
            aggregateType: "conversation",
            aggregateID: conversationID.uuidString
        )
        #expect(state.processedEventIDs == [eventID])
        #expect(state.ownerAggregateHighWatermarks[highWatermarkKey] == 3)
        #expect(state.existingMessageKeys == [
            DomainEventProjectionReducer.MessageKey(
                conversationID: conversationID.uuidString,
                messageID: "message-1"
            ),
            DomainEventProjectionReducer.MessageKey(
                conversationID: conversationID.uuidString,
                messageID: "server-message-1"
            )
        ])
    }

    @Test func reducerRemovesHiddenMessageKeysAndKeepsOtherConversationKeys() throws {
        let reducer = IMConversationDomainEventDependencyStateReducer()
        let eventID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let conversationID = UUID(uuidString: "bbbbbbbb-1111-1111-1111-111111111111")!
        let hiddenMessageID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        var state = DomainEventProjectionReducer.DependencySnapshot(
            processedEventIDs: [],
            ownerAggregateHighWatermarks: [:],
            existingMessageKeys: [
                DomainEventProjectionReducer.MessageKey(
                    conversationID: conversationID.uuidString,
                    messageID: hiddenMessageID.uuidString
                ),
                DomainEventProjectionReducer.MessageKey(
                    conversationID: conversationID.uuidString,
                    messageID: "kept-message"
                ),
                DomainEventProjectionReducer.MessageKey(
                    conversationID: "other-conversation",
                    messageID: hiddenMessageID.uuidString
                )
            ]
        )

        reducer.reduce(
            payload: domainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                ownerAggregateSequence: nil
            ),
            operation: .applyVisibility(
                conversationID: conversationID.uuidString,
                messageIDs: [hiddenMessageID],
                message: nil,
                action: .messageHidden,
                notice: nil,
                summary: nil
            ),
            state: &state
        )

        #expect(state.processedEventIDs == [eventID])
        #expect(state.ownerAggregateHighWatermarks.isEmpty)
        #expect(state.existingMessageKeys == [
            DomainEventProjectionReducer.MessageKey(
                conversationID: conversationID.uuidString,
                messageID: "kept-message"
            ),
            DomainEventProjectionReducer.MessageKey(
                conversationID: "other-conversation",
                messageID: hiddenMessageID.uuidString
            )
        ])
    }

    @Test func reducerRemovesConversationKeysWhenConversationIsDeleted() {
        let reducer = IMConversationDomainEventDependencyStateReducer()
        let eventID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let conversationID = UUID(uuidString: "cccccccc-1111-1111-1111-111111111111")!
        var state = DomainEventProjectionReducer.DependencySnapshot(
            processedEventIDs: [],
            ownerAggregateHighWatermarks: [:],
            existingMessageKeys: [
                DomainEventProjectionReducer.MessageKey(
                    conversationID: conversationID.uuidString,
                    messageID: "removed-1"
                ),
                DomainEventProjectionReducer.MessageKey(
                    conversationID: conversationID.uuidString,
                    messageID: "removed-2"
                ),
                DomainEventProjectionReducer.MessageKey(
                    conversationID: "other-conversation",
                    messageID: "kept"
                )
            ]
        )

        reducer.reduce(
            payload: domainEventPayload(
                eventID: eventID,
                conversationID: conversationID,
                ownerAggregateSequence: 1
            ),
            operation: .applyConversationVisibility(
                conversationID: conversationID.uuidString,
                action: .conversationDeleted,
                messageIDs: [],
                notice: nil,
                summary: nil
            ),
            state: &state
        )

        #expect(state.processedEventIDs == [eventID])
        #expect(state.existingMessageKeys == [
            DomainEventProjectionReducer.MessageKey(
                conversationID: "other-conversation",
                messageID: "kept"
            )
        ])
    }

    private func domainEventPayload(
        eventID: UUID,
        conversationID: UUID,
        ownerAggregateSequence: UInt64?
    ) -> IMTCPChatDomainEventPayload {
        IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: .conversationSettingsChanged,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: ownerAggregateSequence ?? 1,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            actorUserID: nil,
            conversation: nil,
            ownerCursor: 1,
            ownerAggregateSequence: ownerAggregateSequence,
            body: .conversationChanged
        )
    }

    private func makeMessage(
        id: String,
        serverMessageID: String,
        conversationID: String
    ) throws -> IMConversationMessage {
        try IMConversationMessage(
            id: id,
            conversationID: conversationID,
            clientMessageID: nil,
            serverMessageID: serverMessageID,
            senderUserID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            serverSequence: 1,
            timelineSequence: 1,
            content: .richText(.plain("message")),
            direction: .incoming,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deliveryState: .received
        )
    }
}
