import Foundation

enum IMDeferredDomainEventStoreResult: Equatable, Sendable {
    case stored
    case alreadyStored
    case notDeferrable
    case encodeFailed

    var didConsumeEvent: Bool {
        switch self {
        case .stored, .alreadyStored:
            true
        case .notDeferrable, .encodeFailed:
            false
        }
    }
}

struct DeferredDomainEventQueue: Sendable {
    func store(
        payload: IMTCPChatDomainEventPayload,
        missingKey: IMDeferredDomainEventMissingKey?,
        conversationID: String?,
        eventsByMissingKey: inout [IMDeferredDomainEventMissingKey: [IMDeferredDomainEventState]]
    ) -> IMDeferredDomainEventStoreResult {
        guard let missingKey else {
            return .notDeferrable
        }

        let encodedEvent: String
        do {
            encodedEvent = try IMTCPProtobufCodec.encodeDomainEvent(payload).base64EncodedString()
        } catch {
            return .encodeFailed
        }

        var events = eventsByMissingKey[missingKey, default: []]
        if let existingIndex = events.firstIndex(where: { $0.eventID == payload.eventID }) {
            let existing = events[existingIndex]
            events[existingIndex] = IMDeferredDomainEventState(
                eventID: existing.eventID,
                conversationID: existing.conversationID,
                missingKey: existing.missingKey,
                firstSeenAt: existing.firstSeenAt,
                retryCount: existing.retryCount + 1,
                ownerCursor: payload.ownerCursor,
                ownerAggregateSequence: payload.ownerAggregateSequence,
                eventPBBase64: encodedEvent
            )
            eventsByMissingKey[missingKey] = events
            return .alreadyStored
        }

        events.append(
            IMDeferredDomainEventState(
                eventID: payload.eventID,
                conversationID: conversationID,
                missingKey: missingKey,
                firstSeenAt: Date(),
                retryCount: 0,
                ownerCursor: payload.ownerCursor,
                ownerAggregateSequence: payload.ownerAggregateSequence,
                eventPBBase64: encodedEvent
            )
        )
        eventsByMissingKey[missingKey] = events
        return .stored
    }
}
