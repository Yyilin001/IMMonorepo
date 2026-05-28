import Fluent
import Foundation
import Vapor

struct IMCanonicalDomainEventDelivery: Sendable {
    let ownerUserID: UUID
    let eventID: UUID
    let payload: IMTCPChatDomainEventPayload

    fileprivate init(
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
