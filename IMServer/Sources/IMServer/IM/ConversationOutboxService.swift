import Fluent
import Foundation
import SQLKit
import Vapor

struct ConversationMessageCreatedOutboxItem: Sendable {
    let actorUserID: UUID
    let messageID: UUID
    let aggregateSequence: Int
    let preview: ConversationMessageCreatedPreview
}

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
            let recipientHash: String?
            if shouldDeduplicateSnapshot {
                let recipientSet = try await createRecipientSetIfNeeded(
                    conversationID: conversationID,
                    recipientUserIDs: recipientSnapshotUserIDs,
                    createdAt: event.createdAt,
                    on: database
                )
                recipientHash = recipientSet.recipientHash
            } else {
                recipientHash = nil
            }
            if let recipientHash {
                try await ConversationDomainEventRecipientSnapshot(
                    eventID: eventID,
                    conversationID: conversationID,
                    recipientCount: uniqueRecipientCount,
                    recipientHash: recipientHash,
                    createdAt: event.createdAt
                ).create(on: database)
            } else {
                try await ConversationDomainEventRecipientSnapshot(
                    eventID: eventID,
                    conversationID: conversationID,
                    recipientUserIDs: recipientSnapshotUserIDs,
                    createdAt: event.createdAt,
                    storesRecipientIDsInline: true
                ).create(on: database)
            }
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
    func enqueueMessageCreatedBatch(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        items: [ConversationMessageCreatedOutboxItem],
        recipientSnapshotDeduplicationThreshold: Int = 0,
        on database: (any Database)? = nil
    ) async throws -> Int {
        guard !items.isEmpty else {
            return 0
        }
        let database = database ?? db
        let insertedCount: Int
        if let sql = database as? any SQLDatabase,
           sql.dialect.name == "postgresql"
        {
            insertedCount = try await enqueueMessageCreatedBatchPostgres(
                conversationID: conversationID,
                recipientUserIDs: recipientUserIDs,
                items: items,
                recipientSnapshotDeduplicationThreshold: recipientSnapshotDeduplicationThreshold,
                sql: sql,
                database: database
            )
        } else {
            for item in items {
                try await enqueue(
                    type: .messageCreated,
                    conversationID: conversationID,
                    actorUserID: item.actorUserID,
                    payload: .messageCreated(
                        messageID: item.messageID,
                        recipientUserIDs: recipientUserIDs,
                        preview: item.preview
                    ),
                    recipientSnapshotUserIDs: nil,
                    preallocatedAggregateSequence: item.aggregateSequence,
                    updatesMessageTimelineSequence: false,
                    on: database
                )
            }
            insertedCount = items.count
        }
        await ConversationOutboxNotification.notifyPendingEvents(on: database)
        return insertedCount
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
    func enqueueMessageCreatedBatchPostgres(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        items: [ConversationMessageCreatedOutboxItem],
        recipientSnapshotDeduplicationThreshold: Int,
        sql: any SQLDatabase,
        database: any Database
    ) async throws -> Int {
        let shouldDeduplicateSnapshot = recipientSnapshotDeduplicationThreshold > 0
            && recipientUserIDs.count >= recipientSnapshotDeduplicationThreshold
        let createdAt = Date()
        let uniqueRecipientCount: Int
        let recipientHash: String?
        if shouldDeduplicateSnapshot {
            let recipientSet = try await createRecipientSetIfNeeded(
                conversationID: conversationID,
                recipientUserIDs: recipientUserIDs,
                createdAt: createdAt,
                on: database
            )
            recipientHash = recipientSet.recipientHash
            uniqueRecipientCount = recipientSet.recipientCount
        } else {
            recipientHash = nil
            uniqueRecipientCount = Set(recipientUserIDs).count
        }

        let rows = try items.map { item -> (eventID: UUID, payloadJSON: String, item: ConversationMessageCreatedOutboxItem) in
            let payload: ConversationDomainEventPayload = .messageCreated(
                messageID: item.messageID,
                recipientUserIDs: recipientHash == nil ? recipientUserIDs : [],
                preview: item.preview
            )
            try payload.validate(for: .messageCreated)
            return (UUID(), try ConversationDomainEvent.encodePayload(payload), item)
        }

        let eventValues = rows.map { row -> SQLQueryString in
            """
            (
                \(bind: row.eventID),
                \(bind: conversationID),
                \(bind: ConversationDomainEventType.messageCreated.rawValue),
                \(bind: row.item.actorUserID),
                \(bind: row.item.aggregateSequence),
                \(bind: row.payloadJSON),
                \(bind: ConversationDomainEventStatus.pending.rawValue),
                \(bind: createdAt),
                \(bind: 0)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")
        try await sql.raw("""
            INSERT INTO \(ident: ConversationDomainEvent.schema) (
                \(ident: "id"),
                \(ident: "conversation_id"),
                \(ident: "event_type"),
                \(ident: "actor_user_id"),
                \(ident: "aggregate_sequence"),
                \(ident: "payload_json"),
                \(ident: "status"),
                \(ident: "created_at"),
                \(ident: "retry_count")
            )
            VALUES \(eventValues)
            """).run()

        if shouldDeduplicateSnapshot, let recipientHash {
            let snapshotValues = rows.map { row -> SQLQueryString in
                """
                (
                    \(bind: row.eventID),
                    \(bind: conversationID),
                    \(bind: "[]"),
                    \(bind: uniqueRecipientCount),
                    \(bind: recipientHash),
                    \(bind: createdAt)
                )
                """ as SQLQueryString
            }.joined(separator: ", ")
            try await sql.raw("""
                INSERT INTO \(ident: ConversationDomainEventRecipientSnapshot.schema) (
                    \(ident: "event_id"),
                    \(ident: "conversation_id"),
                    \(ident: "recipient_user_ids_json"),
                    \(ident: "recipient_count"),
                    \(ident: "recipient_hash"),
                    \(ident: "created_at")
                )
                VALUES \(snapshotValues)
                """).run()
        } else {
            let encodedRecipients = try ConversationDomainEventRecipientSet.encode(
                ConversationDomainEventRecipientSet.uniqueSorted(recipientUserIDs)
            )
            let snapshotValues = rows.map { row -> SQLQueryString in
                """
                (
                    \(bind: row.eventID),
                    \(bind: conversationID),
                    \(bind: encodedRecipients),
                    \(bind: uniqueRecipientCount),
                    \(bind: nil as String?),
                    \(bind: createdAt)
                )
                """ as SQLQueryString
            }.joined(separator: ", ")
            try await sql.raw("""
                INSERT INTO \(ident: ConversationDomainEventRecipientSnapshot.schema) (
                    \(ident: "event_id"),
                    \(ident: "conversation_id"),
                    \(ident: "recipient_user_ids_json"),
                    \(ident: "recipient_count"),
                    \(ident: "recipient_hash"),
                    \(ident: "created_at")
                )
                VALUES \(snapshotValues)
                """).run()
        }

        for _ in rows {
            await domainEventMetrics?.recordRecipientSnapshotStored(
                recipientCount: uniqueRecipientCount,
                deduplicated: shouldDeduplicateSnapshot
            )
        }
        return rows.count
    }

    @discardableResult
    func createRecipientSetIfNeeded(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        createdAt: Date,
        on database: any Database
    ) async throws -> (recipientHash: String, recipientCount: Int) {
        if let cached = await ConversationRecipientSetExistenceCache.shared.cachedRecipientSet(
            conversationID: conversationID,
            recipientCount: recipientUserIDs.count
        ) {
            return (cached.recipientHash, cached.recipientCount)
        }

        let uniqueRecipients = ConversationDomainEventRecipientSet.uniqueSorted(recipientUserIDs)
        let recipientHash = ConversationDomainEventRecipientSet.recipientHash(forUniqueSorted: uniqueRecipients)
        let recipientCount = uniqueRecipients.count
        if await ConversationRecipientSetExistenceCache.shared.contains(recipientHash) {
            await ConversationRecipientSetExistenceCache.shared.storeRecipientSet(
                conversationID: conversationID,
                recipientCount: recipientCount,
                recipientHash: recipientHash
            )
            return (recipientHash, recipientCount)
        }
        if let sql = database as? any SQLDatabase,
           sql.dialect.name == "postgresql"
        {
            struct ExistingRecipientSetRow: Decodable {
                let recipient_hash: String
            }
            let existingRows = try await sql.raw("""
                SELECT \(ident: "recipient_hash")
                FROM \(ident: ConversationDomainEventRecipientSet.schema)
                WHERE \(ident: "recipient_hash") = \(bind: recipientHash)
                LIMIT 1
            """).all(decoding: ExistingRecipientSetRow.self)
            if !existingRows.isEmpty {
                await ConversationRecipientSetExistenceCache.shared.insert(recipientHash)
                await ConversationRecipientSetExistenceCache.shared.storeRecipientSet(
                    conversationID: conversationID,
                    recipientCount: recipientCount,
                    recipientHash: recipientHash
                )
                return (recipientHash, recipientCount)
            }

            let recipientSet = try ConversationDomainEventRecipientSet(
                recipientHash: recipientHash,
                recipientUserIDs: uniqueRecipients,
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
                    recipientUserIDs: uniqueRecipients,
                    createdAt: createdAt,
                    on: database
                )
            }
            await ConversationRecipientSetExistenceCache.shared.insert(recipientHash)
            await ConversationRecipientSetExistenceCache.shared.storeRecipientSet(
                conversationID: conversationID,
                recipientCount: recipientCount,
                recipientHash: recipientHash
            )
            return (recipientHash, recipientCount)
        }

        if try await ConversationDomainEventRecipientSet.find(recipientHash, on: database) == nil {
            try await ConversationDomainEventRecipientSet(
                recipientHash: recipientHash,
                recipientUserIDs: uniqueRecipients,
                createdAt: createdAt
            ).create(on: database)
            try await ConversationDomainEventRecipientSetMember.writeMemberIndex(
                recipientHash: recipientHash,
                recipientUserIDs: uniqueRecipients,
                createdAt: createdAt,
                on: database
            )
        }
        await ConversationRecipientSetExistenceCache.shared.insert(recipientHash)
        await ConversationRecipientSetExistenceCache.shared.storeRecipientSet(
            conversationID: conversationID,
            recipientCount: recipientCount,
            recipientHash: recipientHash
        )
        return (recipientHash, recipientCount)
    }
}

actor ConversationRecipientSetExistenceCache {
    struct CachedRecipientSet: Sendable {
        let recipientHash: String
        let recipientCount: Int
    }

    static let shared = ConversationRecipientSetExistenceCache()

    private var recipientHashes: Set<String> = []
    private var recipientSetsByConversationID: [UUID: CachedRecipientSet] = [:]

    func contains(_ recipientHash: String) -> Bool {
        recipientHashes.contains(recipientHash)
    }

    func insert(_ recipientHash: String) {
        recipientHashes.insert(recipientHash)
    }

    func cachedRecipientSet(conversationID: UUID, recipientCount: Int) -> CachedRecipientSet? {
        guard let cached = recipientSetsByConversationID[conversationID],
              cached.recipientCount == recipientCount
        else {
            return nil
        }
        return cached
    }

    func storeRecipientSet(conversationID: UUID, recipientCount: Int, recipientHash: String) {
        recipientSetsByConversationID[conversationID] = CachedRecipientSet(
            recipientHash: recipientHash,
            recipientCount: recipientCount
        )
        recipientHashes.insert(recipientHash)
    }

    func invalidateConversation(_ conversationID: UUID) {
        recipientSetsByConversationID[conversationID] = nil
    }
}
