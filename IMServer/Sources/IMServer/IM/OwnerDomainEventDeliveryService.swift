import Fluent
import Foundation
import SQLKit
import Vapor

struct IMCanonicalDomainEventDelivery: Sendable {
    let ownerUserID: UUID
    let eventID: UUID
    let payload: IMTCPChatDomainEventPayload

    init(
        ownerUserID: UUID,
        eventID: UUID,
        payload: IMTCPChatDomainEventPayload
    ) {
        self.ownerUserID = ownerUserID
        self.eventID = eventID
        self.payload = payload
    }
}

struct OwnerDomainEventDeliveryService {
    let db: any Database

    struct RecordRequest: Sendable {
        let ownerUserID: UUID
        let payload: IMTCPChatDomainEventPayload
        let sourceType: DomainEventSourceType
        let sourceEventID: UUID
        let createdAt: Date

        init(
            ownerUserID: UUID,
            payload: IMTCPChatDomainEventPayload,
            sourceType: DomainEventSourceType,
            sourceEventID: UUID,
            createdAt: Date = Date()
        ) {
            self.ownerUserID = ownerUserID
            self.payload = payload
            self.sourceType = sourceType
            self.sourceEventID = sourceEventID
            self.createdAt = createdAt
        }
    }

    @discardableResult
    func record(
        payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        sourceType: DomainEventSourceType,
        sourceEventID: UUID,
        createdAt: Date = Date()
    ) async throws -> OwnerDomainEventDelivery {
        let recordID = OwnerDomainEventDelivery.recordID(ownerUserID: ownerUserID, eventID: payload.eventID)
        return try await db.transaction { tx in
            if let existing = try await OwnerDomainEventDelivery.find(recordID, on: tx) {
                return existing
            }

            let cursor = try await OwnerDomainEventDeliveryCursorAllocator(db: tx).allocate(ownerUserID: ownerUserID, on: tx)
            let ownerAggregateSequence = try await OwnerDomainEventAggregateSequenceAllocator(db: tx).allocate(
                ownerUserID: ownerUserID,
                aggregateType: payload.aggregateType,
                aggregateID: payload.aggregateID,
                on: tx
            )
            let deliveryPayload = IMTCPChatDomainEventPayload(
                eventID: payload.eventID,
                eventType: payload.eventType,
                aggregateType: payload.aggregateType,
                aggregateID: payload.aggregateID,
                aggregateSequence: payload.aggregateSequence,
                occurredAt: payload.occurredAt,
                actorUserID: payload.actorUserID,
                conversation: payload.conversation,
                timelineNotice: payload.timelineNotice,
                requiresTimelineNotice: payload.requiresTimelineNotice,
                ownerCursor: cursor.rawValue,
                ownerAggregateSequence: ownerAggregateSequence.rawValue,
                body: payload.body
            )
            let bytes = try IMTCPProtobufCodec.encodeDomainEvent(deliveryPayload)
            let row = OwnerDomainEventDelivery(
                ownerUserID: ownerUserID,
                ownerCursor: cursor.rawValue,
                ownerAggregateSequence: ownerAggregateSequence.rawValue,
                aggregateType: payload.aggregateType,
                aggregateID: payload.aggregateID,
                eventID: payload.eventID,
                sourceType: sourceType,
                sourceEventID: sourceEventID,
                eventPBBase64: bytes.base64EncodedString(),
                createdAt: createdAt
            )
            try await row.create(on: tx)
            return row
        }
    }

    func recordBatch(
        _ requests: [RecordRequest],
        returningRows: Bool = true
    ) async throws -> [OwnerDomainEventDelivery] {
        guard !requests.isEmpty else {
            return []
        }
        guard db is any SQLDatabase,
              hasUniqueOwnerAndAggregateKeys(requests)
        else {
            var deliveries: [OwnerDomainEventDelivery] = []
            deliveries.reserveCapacity(requests.count)
            for request in requests {
                let delivery = try await record(
                    payload: request.payload,
                    ownerUserID: request.ownerUserID,
                    sourceType: request.sourceType,
                    sourceEventID: request.sourceEventID,
                    createdAt: request.createdAt
                )
                if returningRows {
                    deliveries.append(delivery)
                }
            }
            return deliveries
        }

        let recordIDs = requests.map {
            OwnerDomainEventDelivery.recordID(ownerUserID: $0.ownerUserID, eventID: $0.payload.eventID)
        }

        return try await db.transaction { tx in
            let existing = try await OwnerDomainEventDelivery.query(on: tx)
                .filter(\.$id ~~ recordIDs)
                .all()
            let existingByID = Dictionary(uniqueKeysWithValues: existing.compactMap { row in
                row.id.map { ($0, row) }
            })
            let missingRequests = requests.filter { request in
                let recordID = OwnerDomainEventDelivery.recordID(
                    ownerUserID: request.ownerUserID,
                    eventID: request.payload.eventID
                )
                return existingByID[recordID] == nil
            }

            if !missingRequests.isEmpty {
                guard let txSQL = tx as? any SQLDatabase else {
                    throw Abort(.internalServerError, reason: "Owner delivery batch write requires SQL transaction database.")
                }
                let cursorsByOwner = try await allocateOwnerCursors(
                    for: missingRequests.map(\.ownerUserID),
                    on: txSQL
                )
                let aggregateSequencesByID = try await allocateOwnerAggregateSequences(
                    for: missingRequests,
                    on: txSQL
                )
                let rows = try missingRequests.map { request -> OwnerDomainEventDelivery in
                    let aggregateSequenceID = OwnerDomainEventAggregateSequence.sequenceID(
                        ownerUserID: request.ownerUserID,
                        aggregateType: request.payload.aggregateType,
                        aggregateID: request.payload.aggregateID
                    )
                    guard let cursor = cursorsByOwner[request.ownerUserID],
                          let ownerAggregateSequence = aggregateSequencesByID[aggregateSequenceID]
                    else {
                        throw Abort(.internalServerError, reason: "Owner delivery batch sequence allocation returned incomplete results.")
                    }
                    let deliveryPayload = payloadWithDeliveryMetadata(
                        request.payload,
                        ownerCursor: cursor,
                        ownerAggregateSequence: ownerAggregateSequence
                    )
                    let bytes = try IMTCPProtobufCodec.encodeDomainEvent(deliveryPayload)
                    return OwnerDomainEventDelivery(
                        ownerUserID: request.ownerUserID,
                        ownerCursor: cursor,
                        ownerAggregateSequence: ownerAggregateSequence,
                        aggregateType: request.payload.aggregateType,
                        aggregateID: request.payload.aggregateID,
                        eventID: request.payload.eventID,
                        sourceType: request.sourceType,
                        sourceEventID: request.sourceEventID,
                        eventPBBase64: bytes.base64EncodedString(),
                        createdAt: request.createdAt
                    )
                }
                try await insertDeliveryRows(rows, on: txSQL)
            }

            guard returningRows else {
                return []
            }

            let allRows = try await OwnerDomainEventDelivery.query(on: tx)
                .filter(\.$id ~~ recordIDs)
                .all()
            let rowsByID = Dictionary(uniqueKeysWithValues: allRows.compactMap { row in
                row.id.map { ($0, row) }
            })
            return recordIDs.compactMap { rowsByID[$0] }
        }
    }

    func find(ownerUserID: UUID, eventID: UUID) async throws -> OwnerDomainEventDelivery? {
        try await OwnerDomainEventDelivery.find(
            OwnerDomainEventDelivery.recordID(ownerUserID: ownerUserID, eventID: eventID),
            on: db
        )
    }

    func decodePayload(from delivery: OwnerDomainEventDelivery) throws -> IMTCPChatDomainEventPayload {
        guard let data = Data(base64Encoded: delivery.eventPBBase64) else {
            throw Abort(.internalServerError, reason: "Owner domain event delivery payload is not valid base64.")
        }
        return try IMTCPProtobufCodec.decodeDomainEvent(data)
    }

    func canonicalDelivery(from delivery: OwnerDomainEventDelivery) throws -> IMCanonicalDomainEventDelivery {
        try IMCanonicalDomainEventDelivery(
            ownerUserID: delivery.ownerUserID,
            eventID: delivery.eventID,
            payload: decodePayload(from: delivery)
        )
    }

    func list(
        ownerUserID: UUID,
        afterCursor: UInt64,
        limit requestedLimit: Int?
    ) async throws -> DomainEventChangesResponse {
        let limit = max(1, min(requestedLimit ?? 100, 200))
        let rows = try await OwnerDomainEventDelivery.query(on: db)
            .filter(\.$ownerUserID == ownerUserID)
            .filter(\.$ownerCursor > afterCursor)
            .sort(\.$ownerCursor, .ascending)
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        let pageRows = Array(rows.prefix(limit))
        return DomainEventChangesResponse(
            items: try pageRows.map {
                DomainEventDeliveryResponse(
                    cursor: try imPositiveUInt64Sequence($0.ownerCursor, field: "owner_cursor"),
                    eventID: $0.eventID,
                    ownerAggregateSequence: try imPositiveUInt64Sequence($0.ownerAggregateSequence, field: "owner_aggregate_sequence"),
                    eventPBBase64: $0.eventPBBase64
                )
            },
            nextCursor: try pageRows.last.map { try imPositiveUInt64Sequence($0.ownerCursor, field: "owner_cursor") } ?? afterCursor,
            hasMore: hasMore
        )
    }

}

private extension OwnerDomainEventDeliveryService {
    struct OwnerCursorAllocationRow: Decodable {
        let ownerUserID: UUID
        let value: Int

        enum CodingKeys: String, CodingKey {
            case ownerUserID = "owner_user_id"
            case value
        }
    }

    struct OwnerAggregateSequenceAllocationRow: Decodable {
        let id: String
        let value: Int
    }

    func hasUniqueOwnerAndAggregateKeys(_ requests: [RecordRequest]) -> Bool {
        let ownerIDs = requests.map(\.ownerUserID)
        guard Set(ownerIDs).count == ownerIDs.count else {
            return false
        }
        let aggregateSequenceIDs = requests.map {
            OwnerDomainEventAggregateSequence.sequenceID(
                ownerUserID: $0.ownerUserID,
                aggregateType: $0.payload.aggregateType,
                aggregateID: $0.payload.aggregateID
            )
        }
        return Set(aggregateSequenceIDs).count == aggregateSequenceIDs.count
    }

    func allocateOwnerCursors(
        for ownerUserIDs: [UUID],
        on sql: any SQLDatabase
    ) async throws -> [UUID: UInt64] {
        let values = ownerUserIDs.map {
            "(\(bind: $0))" as SQLQueryString
        }.joined(separator: ", ")

        let rows = try await sql.raw("""
            WITH \(ident: "input")(\(ident: "owner_user_id")) AS (
                VALUES \(values)
            ),
            \(ident: "inserted") AS (
                INSERT INTO \(ident: OwnerDomainEventDeliveryCursor.schema) (
                    \(ident: "owner_user_id"),
                    \(ident: "last_cursor")
                )
                SELECT \(ident: "owner_user_id"), 0 FROM \(ident: "input")
                ON CONFLICT (\(ident: "owner_user_id")) DO NOTHING
            ),
            \(ident: "updated") AS (
                UPDATE \(ident: OwnerDomainEventDeliveryCursor.schema) AS \(ident: "cursors")
                SET \(ident: "last_cursor") = \(ident: "cursors").\(ident: "last_cursor") + 1
                FROM \(ident: "input")
                WHERE \(ident: "cursors").\(ident: "owner_user_id") = \(ident: "input").\(ident: "owner_user_id")
                RETURNING \(ident: "cursors").\(ident: "owner_user_id") AS \(ident: "owner_user_id"),
                    \(ident: "cursors").\(ident: "last_cursor") AS \(ident: "value")
            )
            SELECT \(ident: "owner_user_id"), \(ident: "value") FROM \(ident: "updated")
            """).all(decoding: OwnerCursorAllocationRow.self)

        var result: [UUID: UInt64] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            result[row.ownerUserID] = try imPositiveUInt64Sequence(row.value, field: "owner_cursor")
        }
        return result
    }

    func allocateOwnerAggregateSequences(
        for requests: [RecordRequest],
        on sql: any SQLDatabase
    ) async throws -> [String: UInt64] {
        let values = requests.map { request -> SQLQueryString in
            let id = OwnerDomainEventAggregateSequence.sequenceID(
                ownerUserID: request.ownerUserID,
                aggregateType: request.payload.aggregateType,
                aggregateID: request.payload.aggregateID
            )
            return """
            (
                \(bind: id),
                \(bind: request.ownerUserID),
                \(bind: request.payload.aggregateType),
                \(bind: request.payload.aggregateID)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        let rows = try await sql.raw("""
            WITH \(ident: "input")(
                \(ident: "id"),
                \(ident: "owner_user_id"),
                \(ident: "aggregate_type"),
                \(ident: "aggregate_id")
            ) AS (
                VALUES \(values)
            ),
            \(ident: "inserted") AS (
                INSERT INTO \(ident: OwnerDomainEventAggregateSequence.schema) (
                    \(ident: "id"),
                    \(ident: "owner_user_id"),
                    \(ident: "aggregate_type"),
                    \(ident: "aggregate_id"),
                    \(ident: "last_sequence")
                )
                SELECT
                    \(ident: "id"),
                    \(ident: "owner_user_id"),
                    \(ident: "aggregate_type"),
                    \(ident: "aggregate_id"),
                    0
                FROM \(ident: "input")
                ON CONFLICT (\(ident: "id")) DO NOTHING
            ),
            \(ident: "updated") AS (
                UPDATE \(ident: OwnerDomainEventAggregateSequence.schema) AS \(ident: "sequences")
                SET \(ident: "last_sequence") = \(ident: "sequences").\(ident: "last_sequence") + 1
                FROM \(ident: "input")
                WHERE \(ident: "sequences").\(ident: "id") = \(ident: "input").\(ident: "id")
                RETURNING \(ident: "sequences").\(ident: "id") AS \(ident: "id"),
                    \(ident: "sequences").\(ident: "last_sequence") AS \(ident: "value")
            )
            SELECT \(ident: "id"), \(ident: "value") FROM \(ident: "updated")
            """).all(decoding: OwnerAggregateSequenceAllocationRow.self)

        var result: [String: UInt64] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            result[row.id] = try imPositiveUInt64Sequence(row.value, field: "owner_aggregate_sequence")
        }
        return result
    }

    func insertDeliveryRows(
        _ rows: [OwnerDomainEventDelivery],
        on sql: any SQLDatabase
    ) async throws {
        guard !rows.isEmpty else {
            return
        }
        let values = rows.map { row -> SQLQueryString in
            """
            (
                \(bind: row.id),
                \(bind: row.ownerUserID),
                \(bind: row.ownerCursor),
                \(bind: row.ownerAggregateSequence),
                \(bind: row.aggregateType),
                \(bind: row.aggregateID),
                \(bind: row.eventID),
                \(bind: row.sourceType),
                \(bind: row.sourceEventID),
                \(bind: row.eventPBBase64),
                \(bind: row.createdAt)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        try await sql.raw("""
            INSERT INTO \(ident: OwnerDomainEventDelivery.schema) (
                \(ident: "id"),
                \(ident: "owner_user_id"),
                \(ident: "owner_cursor"),
                \(ident: "owner_aggregate_sequence"),
                \(ident: "aggregate_type"),
                \(ident: "aggregate_id"),
                \(ident: "event_id"),
                \(ident: "source_type"),
                \(ident: "source_event_id"),
                \(ident: "event_pb_base64"),
                \(ident: "created_at")
            )
            VALUES \(values)
            ON CONFLICT (\(ident: "id")) DO NOTHING
            """).run()
    }

    func payloadWithDeliveryMetadata(
        _ payload: IMTCPChatDomainEventPayload,
        ownerCursor: UInt64,
        ownerAggregateSequence: UInt64
    ) -> IMTCPChatDomainEventPayload {
        IMTCPChatDomainEventPayload(
            eventID: payload.eventID,
            eventType: payload.eventType,
            aggregateType: payload.aggregateType,
            aggregateID: payload.aggregateID,
            aggregateSequence: payload.aggregateSequence,
            occurredAt: payload.occurredAt,
            actorUserID: payload.actorUserID,
            conversation: payload.conversation,
            timelineNotice: payload.timelineNotice,
            requiresTimelineNotice: payload.requiresTimelineNotice,
            ownerCursor: ownerCursor,
            ownerAggregateSequence: ownerAggregateSequence,
            body: payload.body
        )
    }
}

struct DomainEventDeliveryResponse: Content, Equatable {
    let cursor: UInt64
    let eventID: UUID
    let ownerAggregateSequence: UInt64
    let eventPBBase64: String
}

struct DomainEventChangesResponse: Content, Equatable {
    let items: [DomainEventDeliveryResponse]
    let nextCursor: UInt64
    let hasMore: Bool
}
