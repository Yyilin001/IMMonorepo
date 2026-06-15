import Fluent
import Foundation
import SQLKit
import Vapor

struct ConversationOutboxService {
    let db: any Database
    let domainEventMetrics: ConversationDomainEventMetrics?

    init(db: any Database, domainEventMetrics: ConversationDomainEventMetrics? = nil) {
        self.db = db
        self.domainEventMetrics = domainEventMetrics
    }

    @discardableResult
    func enqueue(
        type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID? = nil,
        payload: ConversationDomainEventPayload,
        recipientSnapshotUserIDs: [UUID]? = nil,
        recipientSnapshotDeduplicationThreshold: Int = 0,
        preallocatedAggregateSequence: Int? = nil,
        updatesMessageTimelineSequence: Bool = true,
        on database: (any Database)? = nil
    ) async throws -> ConversationDomainEvent {
        let database = database ?? db
        let event: ConversationDomainEvent
        if database.inTransaction {
            event = try await enqueueWrites(
                type: type,
                conversationID: conversationID,
                actorUserID: actorUserID,
                payload: payload,
                recipientSnapshotUserIDs: recipientSnapshotUserIDs,
                recipientSnapshotDeduplicationThreshold: recipientSnapshotDeduplicationThreshold,
                preallocatedAggregateSequence: preallocatedAggregateSequence,
                updatesMessageTimelineSequence: updatesMessageTimelineSequence,
                on: database
            )
            await ConversationOutboxNotification.notifyPendingEvents(on: database)
        } else {
            event = try await database.transaction { tx in
                try await enqueueWrites(
                    type: type,
                    conversationID: conversationID,
                    actorUserID: actorUserID,
                    payload: payload,
                    recipientSnapshotUserIDs: recipientSnapshotUserIDs,
                    recipientSnapshotDeduplicationThreshold: recipientSnapshotDeduplicationThreshold,
                    preallocatedAggregateSequence: preallocatedAggregateSequence,
                    updatesMessageTimelineSequence: updatesMessageTimelineSequence,
                    on: tx
                )
            }
            await ConversationOutboxNotification.notifyPendingEvents(on: database)
        }
        return event
    }

    @discardableResult
    private func enqueueWrites(
        type: ConversationDomainEventType,
        conversationID: UUID,
        actorUserID: UUID?,
        payload: ConversationDomainEventPayload,
        recipientSnapshotUserIDs: [UUID]?,
        recipientSnapshotDeduplicationThreshold: Int,
        preallocatedAggregateSequence: Int?,
        updatesMessageTimelineSequence: Bool,
        on database: any Database
    ) async throws -> ConversationDomainEvent {
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
        if let recipientSnapshotUserIDs,
           let eventID = event.id
        {
            let uniqueRecipientCount = Set(recipientSnapshotUserIDs).count
            let shouldDeduplicateSnapshot = recipientSnapshotDeduplicationThreshold > 0
                && uniqueRecipientCount >= recipientSnapshotDeduplicationThreshold
            if shouldDeduplicateSnapshot {
                try await createRecipientSetIfNeeded(
                    recipientUserIDs: recipientSnapshotUserIDs,
                    createdAt: event.createdAt,
                    on: database
                )
            }
            try await ConversationDomainEventRecipientSnapshot(
                eventID: eventID,
                conversationID: conversationID,
                recipientUserIDs: recipientSnapshotUserIDs,
                createdAt: event.createdAt,
                storesRecipientIDsInline: !shouldDeduplicateSnapshot
            ).create(on: database)
            await domainEventMetrics?.recordRecipientSnapshotStored(
                recipientCount: uniqueRecipientCount,
                deduplicated: shouldDeduplicateSnapshot
            )
        }
        if updatesMessageTimelineSequence, type == .messageCreated, let messageID = payload.messageID,
           let message = try await ConversationMessage.find(messageID, on: database)
        {
            message.timelineSequence = aggregateSequenceValue
            try await message.update(on: database)
        }
        return event
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

private extension ConversationOutboxService {
    @discardableResult
    func createRecipientSetIfNeeded(
        recipientUserIDs: [UUID],
        createdAt: Date,
        on database: any Database
    ) async throws -> String {
        let recipientHash = ConversationDomainEventRecipientSet.recipientHash(for: recipientUserIDs)
        if let sql = database as? any SQLDatabase,
           sql.dialect.name == "postgresql"
        {
            let recipientSet = try ConversationDomainEventRecipientSet(
                recipientHash: recipientHash,
                recipientUserIDs: recipientUserIDs,
                createdAt: createdAt
            )
            let encodedRecipients = try recipientSet.recipientUserIDs()
            let recipientUserIDsJSON = try JSONEncoder().encode(encodedRecipients)
            guard let recipientUserIDsString = String(data: recipientUserIDsJSON, encoding: .utf8) else {
                throw ConversationProjectionCodingError.invalidJSON
            }
            struct InsertedRecipientSetRow: Decodable {
                let recipient_hash: String
            }
            let insertedRows = try await sql.raw("""
                INSERT INTO \(ident: ConversationDomainEventRecipientSet.schema) (
                    \(ident: "recipient_hash"),
                    \(ident: "recipient_user_ids_json"),
                    \(ident: "recipient_count"),
                    \(ident: "created_at")
                )
                VALUES (
                    \(bind: recipientHash),
                    \(bind: recipientUserIDsString),
                    \(bind: recipientSet.recipientCount),
                    \(bind: createdAt)
                )
                ON CONFLICT (\(ident: "recipient_hash")) DO NOTHING
                RETURNING \(ident: "recipient_hash")
                """).all(decoding: InsertedRecipientSetRow.self)
            if !insertedRows.isEmpty {
                try await ConversationDomainEventRecipientSetMember.writeMemberIndex(
                    recipientHash: recipientHash,
                    recipientUserIDs: recipientUserIDs,
                    createdAt: createdAt,
                    on: database
                )
            }
            return recipientHash
        }

        if try await ConversationDomainEventRecipientSet.find(recipientHash, on: database) == nil {
            try await ConversationDomainEventRecipientSet(
                recipientHash: recipientHash,
                recipientUserIDs: recipientUserIDs,
                createdAt: createdAt
            ).create(on: database)
            try await ConversationDomainEventRecipientSetMember.writeMemberIndex(
                recipientHash: recipientHash,
                recipientUserIDs: recipientUserIDs,
                createdAt: createdAt,
                on: database
            )
        }
        return recipientHash
    }
}
