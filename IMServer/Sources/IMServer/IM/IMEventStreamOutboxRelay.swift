import Fluent
import Foundation
import SQLKit
import Vapor

struct DatabaseOutboxConversationEventBus: ConversationEventBus {
    let db: any Database

    func publish(
        type: ConversationDomainEventType,
        conversationID: UUID,
        payload: ConversationDomainEventPayload,
        on database: (any Database)? = nil
    ) async throws {
        try await ConversationOutboxService(db: db).enqueue(
            type: type,
            conversationID: conversationID,
            payload: payload,
            on: database
        )
    }
}

struct ConversationOutboxRelay {
    let shardRouter: any ConversationShardRouter
    let producer: any ConversationEventStreamProducer
    let conversationDirectory: any ConversationDirectory
    let nodeID: String
    let claimTimeoutSeconds: Int

    init(app: Application, db: (any Database)? = nil) {
        if let db {
            self.shardRouter = ExplicitDatabaseConversationShardRouter(database: db)
        } else {
            self.shardRouter = app.conversationShardRouter
        }
        self.producer = app.conversationEventStreamProducer
        self.conversationDirectory = app.conversationDirectory
        self.nodeID = app.imNodeID
        self.claimTimeoutSeconds = app.conversationOutboxConfiguration.claimTimeoutSeconds
    }

    func drainPendingEvents(app: Application) async throws -> Int {
        var processed = 0
        for routedDatabase in shardRouter.allCommandDatabases() {
            processed += try await ConversationOutboxService(db: routedDatabase.database).processPendingBatch(app: app)
        }
        return processed
    }

    @discardableResult
    func relayPendingEvents(limit: Int = 200) async throws -> Int {
        var relayedCount = 0
        var remaining = max(0, limit)

        for routedDatabase in shardRouter.allCommandDatabases() {
            guard remaining > 0 else {
                break
            }

            let events = try await claimPendingEvents(
                on: routedDatabase.database,
                limit: remaining,
                nodeID: nodeID
            )

            for event in events {
                guard let eventID = event.id else {
                    continue
                }
                let payload = try event.decodedPayload()
                let shardID = try await conversationDirectory.shardID(for: event.conversationID)
                let envelope = ConversationEventStreamEnvelope(
                    eventID: eventID,
                    conversationID: event.conversationID,
                    eventType: event.eventType,
                    payload: payload,
                    occurredAt: event.createdAt,
                    producerShard: shardID
                )
                do {
                    try await producer.publish(envelope)
                    event.streamPublishedAt = Date()
                    event.streamPublishError = nil
                    event.streamPublishStartedAt = nil
                    event.streamPublishClaimedBy = nil
                    try await event.update(on: routedDatabase.database)
                    relayedCount += 1
                    remaining -= 1
                } catch {
                    event.streamPublishError = String(describing: error)
                    event.streamPublishStartedAt = nil
                    event.streamPublishClaimedBy = nil
                    try await event.update(on: routedDatabase.database)
                    throw error
                }
            }
        }

        return relayedCount
    }

    private func claimPendingEvents(
        on database: any Database,
        limit: Int,
        nodeID: String
    ) async throws -> [ConversationDomainEvent] {
        guard limit > 0 else {
            return []
        }

        let now = Date()
        let cutoff = Date(timeIntervalSinceNow: -Double(claimTimeoutSeconds))
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            struct ClaimedRow: Decodable {
                let id: UUID
            }

            let rows = try await sql.raw(
                """
                UPDATE \(ident: ConversationDomainEvent.schema)
                SET \(ident: "stream_publish_started_at") = \(bind: now),
                    \(ident: "stream_publish_claimed_by") = \(bind: nodeID),
                    \(ident: "stream_publish_error") = NULL
                WHERE \(ident: "id") IN (
                    SELECT \(ident: "id")
                    FROM \(ident: ConversationDomainEvent.schema)
                    WHERE \(ident: "status") = \(bind: ConversationDomainEventStatus.pending.rawValue)
                      AND \(ident: "stream_published_at") IS NULL
                      AND (
                          \(ident: "stream_publish_started_at") IS NULL
                          OR \(ident: "stream_publish_started_at") <= \(bind: cutoff)
                      )
                    ORDER BY \(ident: "created_at") ASC, \(ident: "id") ASC
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                RETURNING \(ident: "id")
                """
            ).all(decoding: ClaimedRow.self)
            guard !rows.isEmpty else {
                return []
            }
            return try await ConversationDomainEvent.query(on: database)
                .filter(\.$id ~~ rows.map(\.id))
                .sort(\.$createdAt, .ascending)
                .all()
        }

        return try await database.transaction { transaction in
            let events = try await ConversationDomainEvent.query(on: transaction)
                .filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                .filter(\.$streamPublishedAt == nil)
                .sort(\.$createdAt, .ascending)
                .all()
                .filter { event in
                    guard let startedAt = event.streamPublishStartedAt else {
                        return true
                    }
                    return startedAt <= cutoff
                }
                .prefix(limit)

            for event in events {
                event.streamPublishStartedAt = now
                event.streamPublishClaimedBy = nodeID
                event.streamPublishError = nil
                try await event.update(on: transaction)
            }

            return Array(events)
        }
    }
}
