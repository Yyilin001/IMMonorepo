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
            let envelope = ConversationEventStreamEnvelope(
                eventID: record.eventID,
                conversationID: record.conversationID,
                eventType: record.eventType,
                payload: record.payload,
                occurredAt: record.createdAt,
                producerShard: record.producerShard
            )
            try await app.conversationEventStreamProducer.publish(envelope)
            record.replayedAt = Date()
            record.updatedAt = record.replayedAt ?? Date()
            record.statusEnum = .replayed
            try await record.update(on: app.imWriteDB)
            replayedCount += 1
        }

        return replayedCount
    }
}
