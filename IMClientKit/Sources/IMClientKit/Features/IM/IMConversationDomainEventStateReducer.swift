import Foundation

struct IMConversationDomainEventState: Equatable, Sendable {
    var processedEventIDs: Set<UUID>
    var processedEventIDOrder: [UUID]
    var ownerAggregateHighWatermarks: [IMOwnerAggregateKey: UInt64]
    var cursor: UInt64
}

enum IMConversationDomainEventStateEvent: Equatable, Sendable {
    case recordProcessedEvent(UUID)
    case recordOwnerAggregateHighWatermark(
        aggregateType: String,
        aggregateID: String,
        ownerAggregateSequence: UInt64?
    )
    case recordConsumedEvent(
        eventID: UUID,
        aggregateType: String,
        aggregateID: String,
        ownerAggregateSequence: UInt64?
    )
    case advanceCursor(UInt64)
}

struct IMConversationDomainEventStateReducer: Sendable {
    private let maxProcessedEventIDs = 1_000

    func reduce(
        _ event: IMConversationDomainEventStateEvent,
        state: inout IMConversationDomainEventState
    ) {
        switch event {
        case .recordProcessedEvent(let eventID):
            recordProcessedEvent(eventID, state: &state)
        case let .recordOwnerAggregateHighWatermark(aggregateType, aggregateID, ownerAggregateSequence):
            recordOwnerAggregateHighWatermark(
                aggregateType: aggregateType,
                aggregateID: aggregateID,
                ownerAggregateSequence: ownerAggregateSequence,
                state: &state
            )
        case let .recordConsumedEvent(eventID, aggregateType, aggregateID, ownerAggregateSequence):
            recordProcessedEvent(eventID, state: &state)
            recordOwnerAggregateHighWatermark(
                aggregateType: aggregateType,
                aggregateID: aggregateID,
                ownerAggregateSequence: ownerAggregateSequence,
                state: &state
            )
        case .advanceCursor(let cursor):
            state.cursor = cursor
        }
    }

    private func recordProcessedEvent(
        _ eventID: UUID,
        state: inout IMConversationDomainEventState
    ) {
        guard state.processedEventIDs.insert(eventID).inserted else {
            return
        }

        state.processedEventIDOrder.append(eventID)
        if state.processedEventIDOrder.count > maxProcessedEventIDs {
            let overflow = state.processedEventIDOrder.count - maxProcessedEventIDs
            for removedID in state.processedEventIDOrder.prefix(overflow) {
                state.processedEventIDs.remove(removedID)
            }
            state.processedEventIDOrder.removeFirst(overflow)
        }
    }

    private func recordOwnerAggregateHighWatermark(
        aggregateType: String,
        aggregateID: String,
        ownerAggregateSequence: UInt64?,
        state: inout IMConversationDomainEventState
    ) {
        guard let ownerAggregateSequence,
              ownerAggregateSequence > 0
        else {
            return
        }

        let key = IMOwnerAggregateKey(
            aggregateType: aggregateType,
            aggregateID: aggregateID
        )
        state.ownerAggregateHighWatermarks[key] = max(
            state.ownerAggregateHighWatermarks[key] ?? 0,
            ownerAggregateSequence
        )
    }
}
