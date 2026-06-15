import Fluent
import Foundation
import SQLKit
import Vapor

struct DatabaseOutboxConversationEventBus: ConversationEventBus {
    let db: any Database
    let domainEventMetrics: ConversationDomainEventMetrics?

    init(db: any Database, domainEventMetrics: ConversationDomainEventMetrics? = nil) {
        self.db = db
        self.domainEventMetrics = domainEventMetrics
    }

    func publish(
        type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID?,
        payload: ConversationDomainEventPayload,
        recipientSnapshotUserIDs: [UUID]? = nil,
        recipientSnapshotDeduplicationThreshold: Int = 0,
        on database: (any Database)? = nil
    ) async throws -> ConversationDomainEvent {
        try await ConversationOutboxService(db: db, domainEventMetrics: domainEventMetrics).enqueue(
            type: type,
            conversationID: conversationID,
            actorUserID: actorUserID,
            payload: payload,
            recipientSnapshotUserIDs: recipientSnapshotUserIDs,
            recipientSnapshotDeduplicationThreshold: recipientSnapshotDeduplicationThreshold,
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
    let logger: Logger

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
        self.logger = app.logger
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
                let envelope: ConversationEventStreamEnvelope
                do {
                    let payload = try event.decodedPayload()
                    let shardID = try await conversationDirectory.shardID(for: event.conversationID)
                    envelope = ConversationEventStreamEnvelope(
                        eventID: eventID,
                        conversationID: event.conversationID,
                        actorUserID: event.actorUserID,
                        aggregateSequence: event.aggregateSequence,
                        eventType: event.eventType,
                        payload: payload,
                        occurredAt: event.createdAt,
                        producerShard: shardID
                    )
                    try await producer.publish(envelope)
                    event.streamPublishedAt = Date()
                    event.streamPublishError = nil
                    event.streamPublishStartedAt = nil
                    event.streamPublishClaimedBy = nil
                    try await event.update(on: routedDatabase.database)
                    relayedCount += 1
                    remaining -= 1
                } catch {
                    if isNonRetryableOutboxRelayError(error) {
                        event.statusEnum = .failed
                        event.retryCount += 1
                        event.errorMessage = "Stream relay rejected non-retryable event payload: \(String(describing: error))"
                        event.streamPublishError = String(describing: error)
                        event.streamPublishStartedAt = nil
                        event.streamPublishClaimedBy = nil
                        try await event.update(on: routedDatabase.database)
                        logger.warning("Conversation outbox relay isolated non-retryable event.", metadata: [
                            "event_id": .string(eventID.uuidString),
                            "conversation_id": .string(event.conversationID.uuidString),
                            "event_type": .string(event.eventType),
                            "retry_count": .stringConvertible(event.retryCount),
                            "error": .string(String(describing: error))
                        ])
                        relayedCount += 1
                        remaining -= 1
                        continue
                    }
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

    private func isNonRetryableOutboxRelayError(_ error: any Error) -> Bool {
        switch error {
        case is DecodingError:
            return true
        case is EncodingError:
            return true
        default:
            return false
        }
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
