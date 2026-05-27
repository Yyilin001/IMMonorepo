import Fluent
import Foundation
import Vapor

struct ContactOutboxService {
    let db: any Database

    func enqueue(
        type: ContactDomainEventType,
        ownerUserIDs: [UUID],
        aggregateID: UUID,
        actorUserID: UUID?,
        payloadForOwner: @Sendable (UUID) -> ContactDomainEventPayload,
        on database: (any Database)? = nil
    ) async throws {
        let database = database ?? db
        let uniqueOwnerIDs = Array(Set(ownerUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueOwnerIDs.isEmpty else {
            return
        }

        for ownerUserID in uniqueOwnerIDs {
            let ownerSequence = try await OwnerContactEventSequenceAllocator(db: database).allocate(
                ownerUserID: ownerUserID,
                on: database
            )
            let ownerSequenceValue = try imIntSequence(ownerSequence.rawValue, field: "owner_sequence")
            let event = try ContactDomainEvent(
                ownerUserID: ownerUserID,
                eventType: type,
                aggregateID: aggregateID,
                ownerSequence: ownerSequenceValue,
                actorUserID: actorUserID,
                payload: payloadForOwner(ownerUserID)
            )
            try await event.create(on: database)
        }
    }

    @discardableResult
    func processPendingBatch(
        app: Application,
        configuration: ConversationOutboxConfiguration? = nil
    ) async throws -> Int {
        try await ContactOutboxProcessor(db: db).processPendingBatch(app: app, configuration: configuration)
    }

}

struct ContactOutboxProcessor {
    let db: any Database

    @discardableResult
    func processPendingBatch(
        app: Application,
        configuration: ConversationOutboxConfiguration? = nil
    ) async throws -> Int {
        let configuration = configuration ?? app.conversationOutboxConfiguration
        let events = try await ContactDomainEvent.query(on: db)
            .group(.or) { group in
                group.filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                group.filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
            }
            .filter(\.$retryCount < configuration.maxRetries)
            .sort(\.$createdAt, .ascending)
            .limit(configuration.batchSize)
            .all()

        var processed = 0
        for event in events {
            processed += try await process(event, app: app, configuration: configuration)
        }
        return processed
    }

    private func process(
        _ event: ContactDomainEvent,
        app: Application,
        configuration: ConversationOutboxConfiguration
    ) async throws -> Int {
        let startedAt = Date()
        event.statusEnum = .processing
        event.processingStartedAt = startedAt
        event.errorMessage = nil
        try await event.update(on: db)

        do {
            let payload = try event.decodedPayload()
            try await ContactProjectionConsumer(db: db, app: app).consume(event: event, payload: payload)
            try await ContactDeliveryConsumer(db: db).consume(event: event, payload: payload)

            event.statusEnum = .processed
            event.processedAt = Date()
            try await event.update(on: db)
            await app.outboxMetrics.recordProcessedEvent(
                eventType: event.eventType,
                durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            )
            await ContactRealtimeRelay(app: app, db: db).relay(event: event)
            return 1
        } catch {
            let processingError = error
            event.statusEnum = .failed
            event.retryCount += 1
            event.errorMessage = String(describing: processingError)
            do {
                try await event.update(on: db)
            } catch {
                app.logger.critical(
                    "Failed to persist contact outbox failure state",
                    metadata: [
                        "event_id": .string(event.id?.uuidString ?? "unknown"),
                        "owner_user_id": .string(event.ownerUserID.uuidString),
                        "event_type": .string(event.eventType),
                        "processing_error": .string(String(describing: processingError)),
                        "persistence_error": .string(String(describing: error))
                    ]
                )
                throw error
            }
            await app.outboxMetrics.recordFailedEvent(
                eventType: event.eventType,
                durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            )
            if configuration.logsProcessingFailures {
                app.logger.warning(
                    "Contact outbox event processing failed",
                    metadata: [
                        "event_id": .string(event.id?.uuidString ?? "unknown"),
                        "owner_user_id": .string(event.ownerUserID.uuidString),
                        "event_type": .string(event.eventType),
                        "error": .string(String(describing: processingError))
                    ]
                )
            }
            return 0
        }
    }

}

struct ContactProjectionConsumer {
    let db: any Database
    let app: Application

    func consume(
        event: ContactDomainEvent,
        payload: ContactDomainEventPayload
    ) async throws {
        try await applyContactProjection(event: event, payload: payload)
        try await enqueueAffectedConversationEvents(event: event, payload: payload)
    }

    private func applyContactProjection(
        event: ContactDomainEvent,
        payload: ContactDomainEventPayload
    ) async throws {
        let changes = ContactChangesService()
        if let request = payload.request {
            try await changes.recordRequestUpsert(
                ownerUserID: event.ownerUserID,
                requestID: request.id,
                on: db
            )
        }
        if let contact = payload.contact {
            try await changes.recordContactUpsert(
                ownerUserID: event.ownerUserID,
                contactUserID: contact.id,
                on: db
            )
        } else if let contactUserID = payload.contactUserID,
                  payload.request == nil {
            try await changes.recordContactRemoval(
                ownerUserID: event.ownerUserID,
                contactUserID: contactUserID,
                on: db
            )
        }
    }

    private func enqueueAffectedConversationEvents(
        event: ContactDomainEvent,
        payload: ContactDomainEventPayload
    ) async throws {
        for conversationID in payload.affectedConversationIDs {
            let conversationDB = try await app.conversationShardRouter.commandDatabase(forConversationID: conversationID)
            let eventID = try event.requireID()
            let sideEffectKey = [
                "contact",
                eventID.uuidString.lowercased(),
                "direct-peer",
                conversationID.uuidString.lowercased(),
                event.ownerUserID.uuidString.lowercased()
            ].joined(separator: ":")
            try await ConversationOutboxService(db: conversationDB).enqueueOnce(
                sideEffectKey: sideEffectKey,
                type: .directPeerUpdated,
                conversationID: conversationID,
                actorUserID: event.actorUserID,
                payload: .directPeerUpdated(recipientUserIDs: [event.ownerUserID]),
                on: conversationDB
            )
        }
    }
}

struct ContactDeliveryConsumer {
    let db: any Database

    @discardableResult
    func consume(
        event: ContactDomainEvent,
        payload: ContactDomainEventPayload
    ) async throws -> OwnerDomainEventDelivery {
        let eventID = try event.requireID()
        let eventType = try event.eventTypeEnum
        let domainPayload = IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: eventType.chatDomainEventType,
            aggregateType: "contact",
            aggregateID: event.aggregateID,
            aggregateSequence: try imPositiveUInt64Sequence(event.ownerSequence, field: "owner_sequence"),
            occurredAt: event.createdAt,
            actorUserID: event.actorUserID,
            conversation: nil,
            body: .contactChanged(
                request: payload.request,
                contact: payload.contact,
                contactUserID: payload.contactUserID
            )
        )
        return try await OwnerDomainEventDeliveryService(db: db).record(
            payload: domainPayload,
            ownerUserID: event.ownerUserID,
            sourceType: .contact,
            sourceEventID: eventID,
            createdAt: event.createdAt
        )
    }
}

struct ContactRealtimeRelay {
    let app: Application
    let db: any Database

    func relay(event: ContactDomainEvent) async {
        do {
            let eventID = try event.requireID()
            await app.gatewaySessionService.sendDomainEventDelivery(
                ownerUserID: event.ownerUserID,
                eventID: eventID,
                requestID: eventID
            )
        } catch {
            app.logger.warning("Contact realtime relay failed.", metadata: [
                "event_id": .string(event.id?.uuidString ?? "unknown"),
                "owner_user_id": .string(event.ownerUserID.uuidString),
                "error": .string(String(describing: error))
            ])
        }
    }
}

private extension ContactDomainEventType {
    var chatDomainEventType: IMTCPChatDomainEventType {
        switch self {
        case .contactRequestCreated:
            return .contactRequestCreated
        case .contactRequestAccepted:
            return .contactRequestAccepted
        case .contactRequestUpdated, .contactRemoved:
            return .contactRequestUpdated
        }
    }
}
