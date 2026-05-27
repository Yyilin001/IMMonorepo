import Fluent
import Foundation
import Vapor

struct ConversationReplayService {
    let app: Application

    @discardableResult
    func replayPendingEvents(limit: Int) async throws -> Int {
        guard app.eventStreamConfiguration.driver == .kafka else {
            return 0
        }

        let records = try await ConversationReplayRecord.query(on: app.imWriteDB)
            .filter(\.$status == ConversationReplayStatus.pending.rawValue)
            .sort(\.$updatedAt, .ascending)
            .limit(max(1, limit))
            .all()

        guard !records.isEmpty else {
            return 0
        }

        var replayedCount = 0
        for record in records {
            do {
                let payload = try record.decodedPayload()
                let envelope = ConversationEventStreamEnvelope(
                    eventID: record.eventID,
                    conversationID: record.conversationID,
                    aggregateSequence: record.aggregateSequence,
                    eventType: record.eventType,
                    payload: payload,
                    occurredAt: record.createdAt,
                    producerShard: record.producerShard
                )
                try await app.conversationEventStreamProducer.publish(envelope)
                record.replayedAt = Date()
                record.updatedAt = record.replayedAt ?? Date()
                record.lastError = nil
                record.receiveCount += 1
                record.statusEnum = .replayed
                try await record.update(on: app.imWriteDB)
                replayedCount += 1
            } catch {
                record.updatedAt = Date()
                record.lastError = String(describing: error)
                record.receiveCount += 1
                record.statusEnum = .failed
                try? await record.update(on: app.imWriteDB)
                app.logger.warning(
                    "Conversation dead-letter replay failed",
                    metadata: [
                        "event_id": .string(record.eventID.uuidString),
                        "consumer_group_id": .string(record.consumerGroupID),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }

        return replayedCount
    }

    @discardableResult
    func requeueFailedEvents(limit: Int) async throws -> Int {
        let records = try await ConversationReplayRecord.query(on: app.imWriteDB)
            .filter(\.$status == ConversationReplayStatus.failed.rawValue)
            .sort(\.$updatedAt, .ascending)
            .limit(max(1, limit))
            .all()

        var requeuedCount = 0
        for record in records {
            record.statusEnum = .pending
            record.lastError = nil
            record.updatedAt = Date()
            try await record.update(on: app.imWriteDB)
            requeuedCount += 1
        }
        return requeuedCount
    }
}
