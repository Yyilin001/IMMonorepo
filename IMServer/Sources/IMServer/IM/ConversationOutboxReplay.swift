import Fluent
import Foundation
import Vapor

struct RepairReplayConsumer: ConversationEventConsumer {
    let db: any Database
    let consumerGroupID: String

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard let eventID = envelope.eventID,
              let deliveryContext = envelope.deliveryContext
        else {
            return
        }

        let recordID = ConversationReplayRecord.recordID(
            consumerGroupID: consumerGroupID,
            eventID: eventID
        )
        let now = Date()
        let record: ConversationReplayRecord
        let isExisting: Bool
        if let existing = try await ConversationReplayRecord.find(recordID, on: db) {
            record = existing
            isExisting = true
        } else {
            record = try ConversationReplayRecord(
                eventID: eventID,
                consumerGroupID: consumerGroupID,
                sourceTopic: deliveryContext.sourceTopic,
                conversationID: envelope.conversationID,
                eventType: envelope.event.eventType,
                producerShard: deliveryContext.producerShard,
                payload: envelope.payload,
                lastError: deliveryContext.deadLetterError,
                createdAt: envelope.event.createdAt,
                updatedAt: now
            )
            isExisting = false
        }

        record.eventID = eventID
        record.consumerGroupID = consumerGroupID
        record.sourceTopic = deliveryContext.sourceTopic
        record.conversationID = envelope.conversationID
        record.eventType = envelope.event.eventType
        record.producerShard = deliveryContext.producerShard
        record.payload = envelope.payload
        record.statusEnum = .pending
        record.lastError = deliveryContext.deadLetterError
        record.receiveCount = isExisting ? record.receiveCount + 1 : 1
        record.updatedAt = now

        if isExisting {
            try await record.update(on: db)
        } else {
            try await record.create(on: db)
        }
    }
}

struct ConversationOutboxRetryService {
    let db: any Database

    @discardableResult
    func requeueFailedEvents(
        maxRetryCount: Int? = nil,
        eventTypes: Set<ConversationDomainEventType> = []
    ) async throws -> Int {
        let failedEvents = try await ConversationDomainEvent.query(on: db)
            .filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
            .sort(\.$createdAt, .ascending)
            .all()

        var requeuedCount = 0
        for event in failedEvents {
            if let maxRetryCount, event.retryCount > maxRetryCount {
                continue
            }
            if !eventTypes.isEmpty, !eventTypes.contains(event.eventTypeEnum) {
                continue
            }

            event.statusEnum = .pending
            event.retryCount = 0
            event.processingStartedAt = nil
            event.processedAt = nil
            event.errorMessage = nil
            try await event.update(on: db)
            requeuedCount += 1
        }

        return requeuedCount
    }
}
