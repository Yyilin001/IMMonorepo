import Foundation
import Testing
@testable import IMClientKit

struct IMConversationDomainEventStateReducerTests {
    @Test func reducerRecordsConsumedEventsAndKeepsProcessedWindowBounded() {
        let reducer = IMConversationDomainEventStateReducer()
        var state = IMConversationDomainEventState(
            processedEventIDs: [],
            processedEventIDOrder: [],
            ownerAggregateHighWatermarks: [:],
            cursor: 0
        )
        let firstEventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        reducer.reduce(
            .recordConsumedEvent(
                eventID: firstEventID,
                aggregateType: "conversation",
                aggregateID: "conversation-1",
                ownerAggregateSequence: 3
            ),
            state: &state
        )
        reducer.reduce(
            .recordConsumedEvent(
                eventID: firstEventID,
                aggregateType: "conversation",
                aggregateID: "conversation-1",
                ownerAggregateSequence: 2
            ),
            state: &state
        )

        let key = IMOwnerAggregateKey(aggregateType: "conversation", aggregateID: "conversation-1")
        #expect(state.processedEventIDOrder == [firstEventID])
        #expect(state.processedEventIDs == [firstEventID])
        #expect(state.ownerAggregateHighWatermarks[key] == 3)

        for offset in 0..<1_001 {
            reducer.reduce(
                .recordProcessedEvent(UUID(uuidString: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012d", offset))!),
                state: &state
            )
        }

        #expect(state.processedEventIDOrder.count == 1_000)
        #expect(state.processedEventIDs.count == 1_000)
        #expect(!state.processedEventIDs.contains(firstEventID))

        reducer.reduce(.advanceCursor(42), state: &state)
        #expect(state.cursor == 42)
    }

    @Test func reducerIgnoresMissingOrZeroOwnerAggregateSequence() {
        let reducer = IMConversationDomainEventStateReducer()
        var state = IMConversationDomainEventState(
            processedEventIDs: [],
            processedEventIDOrder: [],
            ownerAggregateHighWatermarks: [:],
            cursor: 0
        )

        reducer.reduce(
            .recordOwnerAggregateHighWatermark(
                aggregateType: "message",
                aggregateID: "message-1",
                ownerAggregateSequence: nil
            ),
            state: &state
        )
        reducer.reduce(
            .recordOwnerAggregateHighWatermark(
                aggregateType: "message",
                aggregateID: "message-1",
                ownerAggregateSequence: 0
            ),
            state: &state
        )

        #expect(state.ownerAggregateHighWatermarks.isEmpty)
    }
}
