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

struct IMConversationDeferredDomainEventState: Equatable, Sendable {
    var eventsByMissingKey: [IMDeferredDomainEventMissingKey: [IMDeferredDomainEventState]]
    var fullRefreshConversationIDs: Set<String>
}

struct IMConversationDeferredDomainEventStateEffect: Equatable, Sendable {
    var fullRefreshConversationID: String?
    var removedEventIDs: [UUID] = []
}

struct IMConversationDeferredDomainEventStateReducer: Sendable {
    private let ttl: TimeInterval = 24 * 60 * 60
    private let maxDeferredEventsPerConversation = 200

    func store(
        payload: IMTCPChatDomainEventPayload,
        missingKey: IMDeferredDomainEventMissingKey?,
        conversationID: String?,
        firstSeenAt: Date = Date(),
        state: inout IMConversationDeferredDomainEventState
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

        return store(
            IMDeferredDomainEventState(
                eventID: payload.eventID,
                conversationID: conversationID,
                missingKey: missingKey,
                firstSeenAt: firstSeenAt,
                retryCount: 0,
                ownerCursor: payload.ownerCursor,
                ownerAggregateSequence: payload.ownerAggregateSequence,
                eventPBBase64: encodedEvent
            ),
            state: &state
        )
    }

    func store(
        _ deferredEvent: IMDeferredDomainEventState,
        state: inout IMConversationDeferredDomainEventState
    ) -> IMDeferredDomainEventStoreResult {
        var events = state.eventsByMissingKey[deferredEvent.missingKey, default: []]
        if let existingIndex = events.firstIndex(where: { $0.eventID == deferredEvent.eventID }) {
            let existing = events[existingIndex]
            events[existingIndex] = IMDeferredDomainEventState(
                eventID: existing.eventID,
                conversationID: existing.conversationID,
                missingKey: existing.missingKey,
                firstSeenAt: existing.firstSeenAt,
                retryCount: existing.retryCount + 1,
                ownerCursor: deferredEvent.ownerCursor,
                ownerAggregateSequence: deferredEvent.ownerAggregateSequence,
                eventPBBase64: deferredEvent.eventPBBase64
            )
            state.eventsByMissingKey[deferredEvent.missingKey] = events
            return .alreadyStored
        }

        events.append(deferredEvent)
        state.eventsByMissingKey[deferredEvent.missingKey] = events
        return .stored
    }

    func removeExpiredDeferredEvents(
        now: Date = Date(),
        state: inout IMConversationDeferredDomainEventState
    ) -> [IMDeferredDomainEventState] {
        let cutoff = now.addingTimeInterval(-ttl)
        let expired = state.eventsByMissingKey.values
            .flatMap { $0 }
            .filter { $0.firstSeenAt < cutoff }

        guard !expired.isEmpty else {
            return []
        }

        let expiredIDs = Set(expired.map(\.eventID))
        removeDeferredEvents(eventIDs: expiredIDs, state: &state)
        return expired
    }

    func pendingDeferredEvents(
        now: Date = Date(),
        state: IMConversationDeferredDomainEventState
    ) -> [IMDeferredDomainEventState] {
        let cutoff = now.addingTimeInterval(-ttl)
        return state.eventsByMissingKey.values
            .flatMap { $0 }
            .filter { $0.firstSeenAt >= cutoff }
            .sorted {
                ($0.ownerCursor ?? 0, $0.ownerAggregateSequence ?? 0, $0.firstSeenAt) <
                    ($1.ownerCursor ?? 0, $1.ownerAggregateSequence ?? 0, $1.firstSeenAt)
            }
    }

    func snapshotDeferredEvents(
        now: Date = Date(),
        state: IMConversationDeferredDomainEventState
    ) -> [IMDeferredDomainEventState] {
        let cutoff = now.addingTimeInterval(-ttl)
        return state.eventsByMissingKey.values
            .flatMap { $0 }
            .filter { $0.firstSeenAt >= cutoff }
            .sorted {
                if $0.firstSeenAt == $1.firstSeenAt {
                    return $0.eventID.uuidString < $1.eventID.uuidString
                }
                return $0.firstSeenAt < $1.firstSeenAt
            }
    }

    func enforceLimits(
        conversationID: String?,
        now: Date = Date(),
        state: inout IMConversationDeferredDomainEventState
    ) -> IMConversationDeferredDomainEventStateEffect {
        var effect = IMConversationDeferredDomainEventStateEffect()
        let cutoff = now.addingTimeInterval(-ttl)
        let expiredIDs = Set(
            state.eventsByMissingKey.values
                .flatMap { $0 }
                .filter { $0.firstSeenAt < cutoff }
                .map(\.eventID)
        )
        if !expiredIDs.isEmpty {
            removeDeferredEvents(eventIDs: expiredIDs, state: &state)
            effect.removedEventIDs.append(contentsOf: expiredIDs.sorted { $0.uuidString < $1.uuidString })
        }

        guard let conversationID else {
            return effect
        }

        let conversationStates = state.eventsByMissingKey.values
            .flatMap { $0 }
            .filter { $0.conversationID == conversationID }
            .sorted { $0.firstSeenAt < $1.firstSeenAt }
        guard conversationStates.count > maxDeferredEventsPerConversation else {
            return effect
        }

        let overflowIDs = Set(
            conversationStates
                .prefix(conversationStates.count - maxDeferredEventsPerConversation)
                .map(\.eventID)
        )
        removeDeferredEvents(eventIDs: overflowIDs, state: &state)
        state.fullRefreshConversationIDs.insert(conversationID)
        effect.fullRefreshConversationID = conversationID
        effect.removedEventIDs.append(contentsOf: overflowIDs.sorted { $0.uuidString < $1.uuidString })
        return effect
    }

    func removeDeferredEvent(
        _ deferredEvent: IMDeferredDomainEventState,
        state: inout IMConversationDeferredDomainEventState
    ) {
        removeDeferredEvents(eventIDs: [deferredEvent.eventID], state: &state)
    }

    func bumpDeferredRetryCount(
        for deferredEvent: IMDeferredDomainEventState,
        state: inout IMConversationDeferredDomainEventState
    ) {
        guard var events = state.eventsByMissingKey[deferredEvent.missingKey],
              let index = events.firstIndex(where: { $0.eventID == deferredEvent.eventID })
        else {
            return
        }

        events[index] = IMDeferredDomainEventState(
            eventID: deferredEvent.eventID,
            conversationID: deferredEvent.conversationID,
            missingKey: deferredEvent.missingKey,
            firstSeenAt: deferredEvent.firstSeenAt,
            retryCount: deferredEvent.retryCount + 1,
            ownerCursor: deferredEvent.ownerCursor,
            ownerAggregateSequence: deferredEvent.ownerAggregateSequence,
            eventPBBase64: deferredEvent.eventPBBase64
        )
        state.eventsByMissingKey[deferredEvent.missingKey] = events
    }

    func clearFullRefreshConversation(
        conversationID: String,
        state: inout IMConversationDeferredDomainEventState
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              state.fullRefreshConversationIDs.remove(trimmedConversationID) != nil
        else {
            return false
        }

        state.eventsByMissingKey = state.eventsByMissingKey.mapValues { events in
            events.filter { $0.conversationID != trimmedConversationID }
        }.filter { !$0.value.isEmpty }
        return true
    }

    func markFullRefreshConversation(
        conversationID: String,
        state: inout IMConversationDeferredDomainEventState
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }
        return state.fullRefreshConversationIDs.insert(trimmedConversationID).inserted
    }

    private func removeDeferredEvents(
        eventIDs: Set<UUID>,
        state: inout IMConversationDeferredDomainEventState
    ) {
        state.eventsByMissingKey = state.eventsByMissingKey.mapValues { events in
            events.filter { !eventIDs.contains($0.eventID) }
        }.filter { !$0.value.isEmpty }
    }
}
