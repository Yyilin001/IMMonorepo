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
    static let minimumPostgresRecordBatchMaxRequests = 100
    static let defaultPostgresRecordBatchMaxRequests = 1_000
    static let maximumPostgresRecordBatchMaxRequests = 5_000

    let db: any Database
    let domainEventMetrics: ConversationDomainEventMetrics?
    let postgresRecordBatchMaxRequests: Int

    init(
        db: any Database,
        domainEventMetrics: ConversationDomainEventMetrics? = nil,
        postgresRecordBatchMaxRequests: Int = OwnerDomainEventDeliveryService.defaultPostgresRecordBatchMaxRequests
    ) {
        self.db = db
        self.domainEventMetrics = domainEventMetrics
        self.postgresRecordBatchMaxRequests = max(1, postgresRecordBatchMaxRequests)
    }

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

    struct BatchRecordResult: Sendable {
        let rows: [OwnerDomainEventDelivery]
        let canonicalDeliveries: [IMCanonicalDomainEventDelivery]
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
        try await recordBatchResult(
            requests,
            returningRows: returningRows,
            returningCanonicalDeliveries: false
        ).rows
    }

    func recordBatchCanonicalDeliveries(
        _ requests: [RecordRequest]
    ) async throws -> [IMCanonicalDomainEventDelivery] {
        try await recordBatchResult(
            requests,
            returningRows: false,
            returningCanonicalDeliveries: true
        ).canonicalDeliveries
    }

    func recordBatchResult(
        _ requests: [RecordRequest],
        returningRows: Bool,
        returningCanonicalDeliveries: Bool
    ) async throws -> BatchRecordResult {
        guard !requests.isEmpty else {
            return BatchRecordResult(rows: [], canonicalDeliveries: [])
        }
        let startedAt = Date()
        guard (db as? any SQLDatabase)?.dialect.name == "postgresql"
        else {
            var deliveries: [OwnerDomainEventDelivery] = []
            var canonicalDeliveries: [IMCanonicalDomainEventDelivery] = []
            deliveries.reserveCapacity(requests.count)
            canonicalDeliveries.reserveCapacity(returningCanonicalDeliveries ? requests.count : 0)
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
                if returningCanonicalDeliveries {
                    canonicalDeliveries.append(try canonicalDelivery(from: delivery))
                }
            }
            await domainEventMetrics?.recordOwnerDeliveryBatchWrite(
                requestCount: requests.count,
                insertedRowCount: 0,
                returnedRowCount: deliveries.count,
                elapsedMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt),
                usedFallback: true
            )
            return BatchRecordResult(rows: deliveries, canonicalDeliveries: canonicalDeliveries)
        }

        if requests.count > postgresRecordBatchMaxRequests {
            var rows: [OwnerDomainEventDelivery] = []
            var canonicalDeliveries: [IMCanonicalDomainEventDelivery] = []
            rows.reserveCapacity(returningRows ? requests.count : 0)
            canonicalDeliveries.reserveCapacity(returningCanonicalDeliveries ? requests.count : 0)
            let chunks = chunkedRecordRequests(requests, maxChunkSize: postgresRecordBatchMaxRequests)
            await domainEventMetrics?.recordOwnerDeliveryBatchWriteChunking(
                requestCount: requests.count,
                chunkCount: chunks.count
            )
            for chunk in chunks {
                let result = try await recordBatchResult(
                    chunk,
                    returningRows: returningRows,
                    returningCanonicalDeliveries: returningCanonicalDeliveries
                )
                rows.append(contentsOf: result.rows)
                canonicalDeliveries.append(contentsOf: result.canonicalDeliveries)
            }
            return BatchRecordResult(rows: rows, canonicalDeliveries: canonicalDeliveries)
        }

        let uniqueRequests = uniqueRequestsByRecordID(requests)
        let recordIDs = requests.map {
            OwnerDomainEventDelivery.recordID(ownerUserID: $0.ownerUserID, eventID: $0.payload.eventID)
        }
        let uniqueRecordIDs = uniqueRequests.map {
            OwnerDomainEventDelivery.recordID(ownerUserID: $0.ownerUserID, eventID: $0.payload.eventID)
        }

        let result = try await db.transaction { tx -> (BatchRecordResult, Int, Bool, Bool) in
            let existing = try await OwnerDomainEventDelivery.query(on: tx)
                .filter(\.$id ~~ uniqueRecordIDs)
                .all()
            let existingByID = Dictionary(uniqueKeysWithValues: existing.compactMap { row in
                row.id.map { ($0, row) }
            })
            let missingRequests = uniqueRequests.filter { request in
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
                    for: missingRequests,
                    on: txSQL
                )
                let aggregateSequencesByID = try await allocateOwnerAggregateSequences(
                    for: missingRequests,
                    on: txSQL
                )
                var canonicalPayloadsByID: [String: IMTCPChatDomainEventPayload] = [:]
                canonicalPayloadsByID.reserveCapacity(returningCanonicalDeliveries ? missingRequests.count : 0)
                let rows = try missingRequests.map { request -> OwnerDomainEventDelivery in
                    let recordID = OwnerDomainEventDelivery.recordID(
                        ownerUserID: request.ownerUserID,
                        eventID: request.payload.eventID
                    )
                    guard let cursor = cursorsByOwner[recordID],
                          let ownerAggregateSequence = aggregateSequencesByID[recordID]
                    else {
                        throw Abort(.internalServerError, reason: "Owner delivery batch sequence allocation returned incomplete results.")
                    }
                    let deliveryPayload = payloadWithDeliveryMetadata(
                        request.payload,
                        ownerCursor: cursor,
                        ownerAggregateSequence: ownerAggregateSequence
                    )
                    if returningCanonicalDeliveries {
                        canonicalPayloadsByID[recordID] = deliveryPayload
                    }
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
                let insertedRowCount = try await insertDeliveryRows(rows, on: txSQL)
                if insertedRowCount == missingRequests.count {
                    // With no insert conflicts, the materialized rows are identical to persisted rows.
                    guard returningRows || returningCanonicalDeliveries else {
                        return (BatchRecordResult(rows: [], canonicalDeliveries: []), insertedRowCount, false, true)
                    }
                    let insertedRowsByID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                        row.id.map { ($0, row) }
                    })
                    let rowsByID = existingByID.merging(insertedRowsByID) { existing, _ in existing }
                    let orderedRows = recordIDs.compactMap { rowsByID[$0] }
                    let canonicalDeliveries = try returningCanonicalDeliveries
                        ? canonicalDeliveries(
                            for: recordIDs,
                            rowsByID: rowsByID,
                            canonicalPayloadsByID: canonicalPayloadsByID
                        )
                        : []
                    return (
                        BatchRecordResult(
                            rows: returningRows ? orderedRows : [],
                            canonicalDeliveries: canonicalDeliveries
                        ),
                        insertedRowCount,
                        !returningRows && returningCanonicalDeliveries,
                        true
                    )
                }
                guard returningRows || returningCanonicalDeliveries else {
                    return (BatchRecordResult(rows: [], canonicalDeliveries: []), insertedRowCount, false, false)
                }
                let allRows = try await OwnerDomainEventDelivery.query(on: tx)
                    .filter(\.$id ~~ uniqueRecordIDs)
                    .all()
                let rowsByID = Dictionary(uniqueKeysWithValues: allRows.compactMap { row in
                    row.id.map { ($0, row) }
                })
                let orderedRows = recordIDs.compactMap { rowsByID[$0] }
                let canonicalDeliveries = try returningCanonicalDeliveries
                    ? canonicalDeliveries(
                        for: recordIDs,
                        rowsByID: rowsByID,
                        canonicalPayloadsByID: canonicalPayloadsByID
                    )
                    : []
                return (
                    BatchRecordResult(
                        rows: returningRows ? orderedRows : [],
                        canonicalDeliveries: canonicalDeliveries
                    ),
                    insertedRowCount,
                    false,
                    false
                )
            }

            guard returningRows || returningCanonicalDeliveries else {
                return (BatchRecordResult(rows: [], canonicalDeliveries: []), 0, false, false)
            }

            let orderedRows = recordIDs.compactMap { existingByID[$0] }
            let canonicalDeliveries = try returningCanonicalDeliveries
                ? canonicalDeliveries(
                    for: recordIDs,
                    rowsByID: existingByID,
                    canonicalPayloadsByID: [:]
                )
                : []
            return (
                BatchRecordResult(
                    rows: returningRows ? orderedRows : [],
                    canonicalDeliveries: canonicalDeliveries
                ),
                0,
                false,
                false
            )
        }
        await domainEventMetrics?.recordOwnerDeliveryBatchWrite(
            requestCount: requests.count,
            insertedRowCount: result.1,
            returnedRowCount: result.0.rows.count,
            elapsedMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt),
            usedFallback: false,
            usedCanonicalFastPath: result.2,
            usedMaterializedFastPath: result.3
        )
        return result.0
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

    struct OwnerCursorAllocationInput {
        let ownerUserID: UUID
        let count: Int
        let recordIDs: [String]
    }

    struct OwnerAggregateSequenceAllocationRow: Decodable {
        let id: String
        let value: Int
    }

    struct OwnerAggregateSequenceAllocationInput {
        let id: String
        let ownerUserID: UUID
        let aggregateType: String
        let aggregateID: UUID
        let count: Int
        let recordIDs: [String]
    }

    struct OwnerDeliveryInsertedRow: Decodable {
        let id: String
    }

    func uniqueRequestsByRecordID(_ requests: [RecordRequest]) -> [RecordRequest] {
        var seenRecordIDs = Set<String>()
        var uniqueRequests: [RecordRequest] = []
        uniqueRequests.reserveCapacity(requests.count)
        for request in requests {
            let recordID = OwnerDomainEventDelivery.recordID(
                ownerUserID: request.ownerUserID,
                eventID: request.payload.eventID
            )
            guard seenRecordIDs.insert(recordID).inserted else {
                continue
            }
            uniqueRequests.append(request)
        }
        return uniqueRequests
    }

    func chunkedRecordRequests(
        _ requests: [RecordRequest],
        maxChunkSize: Int
    ) -> [[RecordRequest]] {
        let safeChunkSize = max(1, maxChunkSize)
        guard requests.count > safeChunkSize else {
            return [requests]
        }
        var chunks: [[RecordRequest]] = []
        chunks.reserveCapacity((requests.count + safeChunkSize - 1) / safeChunkSize)
        var startIndex = requests.startIndex
        while startIndex < requests.endIndex {
            let endIndex = requests.index(startIndex, offsetBy: safeChunkSize, limitedBy: requests.endIndex) ?? requests.endIndex
            chunks.append(Array(requests[startIndex..<endIndex]))
            startIndex = endIndex
        }
        return chunks
    }

    func requestsByRecordID(_ requests: [RecordRequest]) -> [String: RecordRequest] {
        Dictionary(uniqueKeysWithValues: requests.map { request in
            (
                OwnerDomainEventDelivery.recordID(
                    ownerUserID: request.ownerUserID,
                    eventID: request.payload.eventID
                ),
                request
            )
        })
    }

    func allocateOwnerCursors(
        for requests: [RecordRequest],
        on sql: any SQLDatabase
    ) async throws -> [String: UInt64] {
        let inputs = ownerCursorAllocationInputs(for: requests)
        guard !inputs.isEmpty else {
            return [:]
        }
        let values = inputs.map {
            "(\(bind: $0.ownerUserID), \(bind: $0.count))" as SQLQueryString
        }.joined(separator: ", ")

        let rows = try await sql.raw("""
            WITH \(ident: "input")(\(ident: "owner_user_id"), \(ident: "increment_by")) AS (
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
                SET \(ident: "last_cursor") = \(ident: "cursors").\(ident: "last_cursor") + \(ident: "input").\(ident: "increment_by")
                FROM \(ident: "input")
                WHERE \(ident: "cursors").\(ident: "owner_user_id") = \(ident: "input").\(ident: "owner_user_id")
                RETURNING \(ident: "cursors").\(ident: "owner_user_id") AS \(ident: "owner_user_id"),
                    \(ident: "cursors").\(ident: "last_cursor") AS \(ident: "value")
            )
            SELECT \(ident: "owner_user_id"), \(ident: "value") FROM \(ident: "updated")
            """).all(decoding: OwnerCursorAllocationRow.self)

        let valuesByOwnerID = Dictionary(uniqueKeysWithValues: rows.map { ($0.ownerUserID, $0.value) })
        var result: [String: UInt64] = [:]
        result.reserveCapacity(requests.count)
        for input in inputs {
            guard let value = valuesByOwnerID[input.ownerUserID] else {
                throw Abort(.internalServerError, reason: "Owner cursor batch allocation returned incomplete results.")
            }
            let endCursor = try imPositiveUInt64Sequence(value, field: "owner_cursor")
            let increment = UInt64(input.count)
            guard endCursor >= increment else {
                throw Abort(.internalServerError, reason: "Owner cursor batch allocation returned invalid range.")
            }
            let startCursor = endCursor - increment + 1
            for (index, recordID) in input.recordIDs.enumerated() {
                result[recordID] = startCursor + UInt64(index)
            }
        }
        return result
    }

    func ownerCursorAllocationInputs(for requests: [RecordRequest]) -> [OwnerCursorAllocationInput] {
        var order: [UUID] = []
        var groupedRecordIDs: [UUID: [String]] = [:]
        for request in requests {
            if groupedRecordIDs[request.ownerUserID] == nil {
                order.append(request.ownerUserID)
                groupedRecordIDs[request.ownerUserID] = []
            }
            groupedRecordIDs[request.ownerUserID]?.append(
                OwnerDomainEventDelivery.recordID(ownerUserID: request.ownerUserID, eventID: request.payload.eventID)
            )
        }
        return order.compactMap { ownerUserID in
            guard let recordIDs = groupedRecordIDs[ownerUserID], !recordIDs.isEmpty else {
                return nil
            }
            return OwnerCursorAllocationInput(
                ownerUserID: ownerUserID,
                count: recordIDs.count,
                recordIDs: recordIDs
            )
        }
    }

    func allocateOwnerAggregateSequences(
        for requests: [RecordRequest],
        on sql: any SQLDatabase
    ) async throws -> [String: UInt64] {
        let inputs = ownerAggregateSequenceAllocationInputs(for: requests)
        guard !inputs.isEmpty else {
            return [:]
        }
        let values = inputs.map { input -> SQLQueryString in
            """
            (
                \(bind: input.id),
                \(bind: input.ownerUserID),
                \(bind: input.aggregateType),
                \(bind: input.aggregateID),
                \(bind: input.count)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        let rows = try await sql.raw("""
            WITH \(ident: "input")(
                \(ident: "id"),
                \(ident: "owner_user_id"),
                \(ident: "aggregate_type"),
                \(ident: "aggregate_id"),
                \(ident: "increment_by")
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
                SET \(ident: "last_sequence") = \(ident: "sequences").\(ident: "last_sequence") + \(ident: "input").\(ident: "increment_by")
                FROM \(ident: "input")
                WHERE \(ident: "sequences").\(ident: "id") = \(ident: "input").\(ident: "id")
                RETURNING \(ident: "sequences").\(ident: "id") AS \(ident: "id"),
                    \(ident: "sequences").\(ident: "last_sequence") AS \(ident: "value")
            )
            SELECT \(ident: "id"), \(ident: "value") FROM \(ident: "updated")
            """).all(decoding: OwnerAggregateSequenceAllocationRow.self)

        let valuesByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
        var result: [String: UInt64] = [:]
        result.reserveCapacity(requests.count)
        for input in inputs {
            guard let value = valuesByID[input.id] else {
                throw Abort(.internalServerError, reason: "Owner aggregate sequence batch allocation returned incomplete results.")
            }
            let endSequence = try imPositiveUInt64Sequence(value, field: "owner_aggregate_sequence")
            let increment = UInt64(input.count)
            guard endSequence >= increment else {
                throw Abort(.internalServerError, reason: "Owner aggregate sequence batch allocation returned invalid range.")
            }
            let startSequence = endSequence - increment + 1
            for (index, recordID) in input.recordIDs.enumerated() {
                result[recordID] = startSequence + UInt64(index)
            }
        }
        return result
    }

    func ownerAggregateSequenceAllocationInputs(
        for requests: [RecordRequest]
    ) -> [OwnerAggregateSequenceAllocationInput] {
        var order: [String] = []
        var inputsByID: [String: OwnerAggregateSequenceAllocationInput] = [:]
        for request in requests {
            let id = OwnerDomainEventAggregateSequence.sequenceID(
                ownerUserID: request.ownerUserID,
                aggregateType: request.payload.aggregateType,
                aggregateID: request.payload.aggregateID
            )
            let recordID = OwnerDomainEventDelivery.recordID(
                ownerUserID: request.ownerUserID,
                eventID: request.payload.eventID
            )
            if let existing = inputsByID[id] {
                inputsByID[id] = OwnerAggregateSequenceAllocationInput(
                    id: existing.id,
                    ownerUserID: existing.ownerUserID,
                    aggregateType: existing.aggregateType,
                    aggregateID: existing.aggregateID,
                    count: existing.count + 1,
                    recordIDs: existing.recordIDs + [recordID]
                )
            } else {
                order.append(id)
                inputsByID[id] = OwnerAggregateSequenceAllocationInput(
                    id: id,
                    ownerUserID: request.ownerUserID,
                    aggregateType: request.payload.aggregateType,
                    aggregateID: request.payload.aggregateID,
                    count: 1,
                    recordIDs: [recordID]
                )
            }
        }
        return order.compactMap { inputsByID[$0] }
    }

    func insertDeliveryRows(
        _ rows: [OwnerDomainEventDelivery],
        on sql: any SQLDatabase
    ) async throws -> Int {
        guard !rows.isEmpty else {
            return 0
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

        let insertedRows = try await sql.raw("""
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
            RETURNING \(ident: "id")
            """).all(decoding: OwnerDeliveryInsertedRow.self)
        return insertedRows.count
    }

    func canonicalDeliveries(
        for recordIDs: [String],
        rowsByID: [String: OwnerDomainEventDelivery],
        canonicalPayloadsByID: [String: IMTCPChatDomainEventPayload]
    ) throws -> [IMCanonicalDomainEventDelivery] {
        try recordIDs.compactMap { recordID in
            guard let row = rowsByID[recordID] else {
                return nil
            }
            let rowOwnerCursor = UInt64(exactly: row.ownerCursor)
            let rowOwnerAggregateSequence = UInt64(exactly: row.ownerAggregateSequence)
            if let payload = canonicalPayloadsByID[recordID],
               payload.ownerCursor == rowOwnerCursor,
               payload.ownerAggregateSequence == rowOwnerAggregateSequence {
                return IMCanonicalDomainEventDelivery(
                    ownerUserID: row.ownerUserID,
                    eventID: row.eventID,
                    payload: payload
                )
            }
            return try canonicalDelivery(from: row)
        }
    }

    func canonicalDeliveries(
        for recordIDs: [String],
        existingRowsByID: [String: OwnerDomainEventDelivery],
        requestsByID: [String: RecordRequest],
        canonicalPayloadsByID: [String: IMTCPChatDomainEventPayload]
    ) throws -> [IMCanonicalDomainEventDelivery] {
        try recordIDs.compactMap { recordID in
            if let row = existingRowsByID[recordID] {
                return try canonicalDelivery(from: row)
            }
            guard let request = requestsByID[recordID],
                  let payload = canonicalPayloadsByID[recordID]
            else {
                return nil
            }
            return IMCanonicalDomainEventDelivery(
                ownerUserID: request.ownerUserID,
                eventID: payload.eventID,
                payload: payload
            )
        }
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
