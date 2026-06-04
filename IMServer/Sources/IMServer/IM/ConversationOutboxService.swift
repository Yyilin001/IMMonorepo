import Fluent
import Foundation
import Vapor

struct ConversationOutboxService {
    let db: any Database

    func enqueue(
        type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID? = nil,
        payload: ConversationDomainEventPayload,
        preallocatedAggregateSequence: Int? = nil,
        updatesMessageTimelineSequence: Bool = true,
        on database: (any Database)? = nil
    ) async throws {
        let database = database ?? db
        let aggregateSequenceValue: Int
        if let preallocatedAggregateSequence {
            aggregateSequenceValue = try imIntSequence(
                UInt64(preallocatedAggregateSequence),
                field: "aggregate_sequence"
            )
        } else {
            let aggregateSequence = try await ConversationDomainEventSequenceAllocator(db: database).allocate(
                conversationID: conversationID,
                on: database
            )
            aggregateSequenceValue = try imIntSequence(aggregateSequence.rawValue, field: "aggregate_sequence")
        }
        let event = try ConversationDomainEvent(
            conversationID: conversationID,
            eventType: type,
            aggregateSequence: aggregateSequenceValue,
            actorUserID: actorUserID,
            payload: payload
        )
        try await event.create(on: database)
        if updatesMessageTimelineSequence, type == .messageCreated, let messageID = payload.messageID,
           let message = try await ConversationMessage.find(messageID, on: database)
        {
            message.timelineSequence = aggregateSequenceValue
            try await message.update(on: database)
        }
        await ConversationOutboxNotification.notifyPendingEvents(on: database)
    }

    @discardableResult
    func enqueueOnce(
        sideEffectKey: String,
        type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID? = nil,
        payload: ConversationDomainEventPayload,
        on database: (any Database)? = nil
    ) async throws -> ConversationDomainEvent {
        let database = database ?? db
        let normalizedKey = sideEffectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw Abort(.internalServerError, reason: "幂等事件缺少 side effect key。")
        }

        return try await database.transaction { tx in
            if let existingClaim = try await ConversationDomainEventSideEffect.find(normalizedKey, on: tx),
               let existingEvent = try await ConversationDomainEvent.find(existingClaim.eventID, on: tx)
            {
                return existingEvent
            }

            let eventID = UUID()
            do {
                try await ConversationDomainEventSideEffect(
                    sideEffectKey: normalizedKey,
                    eventID: eventID
                ).create(on: tx)
            } catch {
                if let existingClaim = try await ConversationDomainEventSideEffect.find(normalizedKey, on: tx),
                   let existingEvent = try await ConversationDomainEvent.find(existingClaim.eventID, on: tx)
                {
                    return existingEvent
                }
                throw error
            }

            let aggregateSequence = try await ConversationDomainEventSequenceAllocator(db: tx).allocate(
                conversationID: conversationID,
                on: tx
            )
            let aggregateSequenceValue = try imIntSequence(aggregateSequence.rawValue, field: "aggregate_sequence")
            let event = try ConversationDomainEvent(
                id: eventID,
                conversationID: conversationID,
                eventType: type,
                aggregateSequence: aggregateSequenceValue,
                sideEffectKey: normalizedKey,
                actorUserID: actorUserID,
                payload: payload
            )
            try await event.create(on: tx)
            await ConversationOutboxNotification.notifyPendingEvents(on: tx)
            return event
        }
    }

    @discardableResult
    func processPendingBatch(
        app: Application,
        configuration: ConversationOutboxConfiguration? = nil
    ) async throws -> Int {
        try await ConversationOutboxProcessor(db: db).processPendingBatch(
            app: app,
            configuration: configuration
        )
    }

    @discardableResult
    func requeueFailedEvents(
        maxRetryCount: Int? = nil,
        eventTypes: Set<ConversationDomainEventType> = []
    ) async throws -> Int {
        try await ConversationOutboxRetryService(db: db).requeueFailedEvents(
            maxRetryCount: maxRetryCount,
            eventTypes: eventTypes
        )
    }
}
