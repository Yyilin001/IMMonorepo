import Fluent
import Foundation
import SQLKit
import Vapor

struct ConversationOutboxProcessor {
    let db: any Database

    @discardableResult
    func processPendingBatch(
        app: Application,
        configuration: ConversationOutboxConfiguration? = nil
    ) async throws -> Int {
        let configuration = configuration ?? app.conversationOutboxConfiguration
        let events = try await claimPendingBatch(configuration: configuration)

        guard !events.isEmpty else {
            await recordSnapshot(app: app)
            return 0
        }

        let processedCount = try await processGroupedEvents(
            events,
            app: app,
            configuration: configuration
        )

        await recordSnapshot(app: app)
        return processedCount
    }

    private func claimPendingBatch(configuration: ConversationOutboxConfiguration) async throws -> [ConversationDomainEvent] {
        if let sql = db as? any SQLDatabase,
           sql.dialect.name == "postgresql"
        {
            struct ClaimedEventRow: Decodable {
                let id: UUID
            }

            let claimedRows = try await sql.raw("""
                WITH \(ident: "claimed") AS (
                    SELECT \(ident: "id")
                    FROM \(ident: ConversationDomainEvent.schema)
                    WHERE (
                        \(ident: "status") = \(bind: ConversationDomainEventStatus.pending.rawValue)
                        OR \(ident: "status") = \(bind: ConversationDomainEventStatus.failed.rawValue)
                    )
                    AND \(ident: "retry_count") < \(bind: configuration.maxRetries)
                    ORDER BY \(ident: "created_at") ASC
                    LIMIT \(bind: configuration.batchSize)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE \(ident: ConversationDomainEvent.schema)
                SET
                    \(ident: "status") = \(bind: ConversationDomainEventStatus.processing.rawValue),
                    \(ident: "processing_started_at") = \(bind: Date()),
                    \(ident: "error_message") = NULL
                WHERE \(ident: "id") IN (SELECT \(ident: "id") FROM \(ident: "claimed"))
                RETURNING \(ident: "id")
                """).all(decoding: ClaimedEventRow.self)
            let claimedIDs = claimedRows.map(\.id)
            guard !claimedIDs.isEmpty else {
                return []
            }
            let events = try await ConversationDomainEvent.query(on: db)
                .filter(\.$id ~~ claimedIDs)
                .all()
            return events.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
                }
                return lhs.createdAt < rhs.createdAt
            }
        }

        return try await ConversationDomainEvent.query(on: db)
            .group(.or) { group in
                group.filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                group.filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
            }
            .filter(\.$retryCount < configuration.maxRetries)
            .sort(\.$createdAt, .ascending)
            .limit(configuration.batchSize)
            .all()
    }

    private func processGroupedEvents(
        _ events: [ConversationDomainEvent],
        app: Application,
        configuration: ConversationOutboxConfiguration
    ) async throws -> Int {
        let groupedEvents = Dictionary(grouping: events, by: \.conversationID)
            .values
            .map { group in
                group.sorted { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
                    }
                    return lhs.createdAt < rhs.createdAt
                }
            }
        let maxConcurrency = min(configuration.maxConcurrentConversations, groupedEvents.count)
        guard maxConcurrency > 1 else {
            var processedCount = 0
            let registries = makeRegistries(app: app)
            for group in groupedEvents {
                processedCount += try await processEventGroup(
                    group,
                    app: app,
                    configuration: configuration,
                    registries: registries
                )
            }
            return processedCount
        }

        var nextGroupIndex = 0
        var processedCount = 0
        return try await withThrowingTaskGroup(of: Int.self) { group in
            func submitNextGroupIfNeeded() {
                guard nextGroupIndex < groupedEvents.count else {
                    return
                }
                let events = groupedEvents[nextGroupIndex]
                nextGroupIndex += 1
                group.addTask {
                    try await processEventGroup(
                        events,
                        app: app,
                        configuration: configuration,
                        registries: makeRegistries(app: app)
                    )
                }
            }

            for _ in 0..<maxConcurrency {
                submitNextGroupIfNeeded()
            }

            while let groupProcessedCount = try await group.next() {
                processedCount += groupProcessedCount
                submitNextGroupIfNeeded()
            }

            return processedCount
        }
    }

    private func processEventGroup(
        _ events: [ConversationDomainEvent],
        app: Application,
        configuration: ConversationOutboxConfiguration,
        registries: ConversationOutboxConsumerRegistries
    ) async throws -> Int {
        var processedCount = 0
        var index = events.startIndex
        while index < events.endIndex {
            if let run = messageCreatedRun(in: events, startingAt: index), run.count > 1 {
                processedCount += try await processMessageCreatedRun(
                    run,
                    app: app,
                    configuration: configuration,
                    registries: registries
                )
                index += run.count
                continue
            }

            processedCount += try await processEvent(
                events[index],
                app: app,
                configuration: configuration,
                registries: registries
            )
            index += 1
        }
        return processedCount
    }

    private func messageCreatedRun(
        in events: [ConversationDomainEvent],
        startingAt index: Int
    ) -> [ConversationDomainEvent]? {
        guard index < events.endIndex,
              isCoalescableMessageCreated(events[index])
        else {
            return nil
        }

        var run = [events[index]]
        var nextIndex = index + 1
        while nextIndex < events.endIndex,
              events[nextIndex].conversationID == events[index].conversationID,
              isCoalescableMessageCreated(events[nextIndex])
        {
            run.append(events[nextIndex])
            nextIndex += 1
        }
        return run
    }

    private func isCoalescableMessageCreated(_ event: ConversationDomainEvent) -> Bool {
        guard event.eventTypeEnum == .messageCreated,
              let payload = try? event.decodedPayload()
        else {
            return false
        }
        return payload.messageID != nil
    }

    private func processMessageCreatedRun(
        _ events: [ConversationDomainEvent],
        app: Application,
        configuration: ConversationOutboxConfiguration,
        registries: ConversationOutboxConsumerRegistries
    ) async throws -> Int {
        let startedAt = Date()
        let statusUpdater = ConversationOutboxStatusBatchUpdater(db: db)
        do {
            try await statusUpdater.markProcessing(events, startedAt: startedAt)

            let envelopes = try events.map { event in
                ConversationEventEnvelope(
                    event: event,
                    payload: try event.decodedPayload(),
                    deliveryContext: nil
                )
            }

            try await ConversationMediaAssetReferenceBatchWriter(db: db, app: app)
                .syncMessageCreatedRun(envelopes)

            guard let lastEnvelope = envelopes.last,
                  let lastMessageID = lastEnvelope.payload.messageID
            else {
                return 0
            }

            let coalescedPayload = ConversationDomainEventPayload(
                recipientUserIDs: Array(Set(envelopes.flatMap(\.payload.recipientUserIDs)))
                    .sorted { $0.uuidString < $1.uuidString },
                messageID: lastMessageID
            )
            let coalescedEnvelope = ConversationEventEnvelope(
                event: lastEnvelope.event,
                payload: coalescedPayload,
                deliveryContext: nil
            )
            try await ConversationProjectionConsumer(app: app, sourceDB: db).consume(coalescedEnvelope)

            await processMessageCreatedRunSideEffects(
                envelopes,
                app: app,
                startedAt: startedAt
            )

            let processedAt = Date()
            try await statusUpdater.markProcessed(events, processedAt: processedAt)
            for event in events {
                await app.outboxMetrics.recordProcessedEvent(
                    eventType: event.eventTypeEnum.rawValue,
                    durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                )
            }
            return events.count
        } catch {
            try? await statusUpdater.markFailed(events, errorMessage: String(describing: error))
            for event in events {
                await app.outboxMetrics.recordFailedEvent(
                    eventType: event.eventTypeEnum.rawValue,
                    durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                )
                if configuration.logsProcessingFailures {
                    app.logger.warning(
                        "Conversation outbox messageCreated run processing failed",
                        metadata: [
                            "node_id": .string(app.imNodeID),
                            "event_id": .string(event.id?.uuidString ?? "unknown"),
                            "conversation_id": .string(event.conversationID.uuidString),
                            "event_type": .string(event.eventType),
                            "duration_ms": .stringConvertible(max(0, Int(Date().timeIntervalSince(startedAt) * 1000))),
                            "retry_count": .stringConvertible(event.retryCount),
                            "error": .string(String(describing: error))
                        ]
                    )
                }
            }
            return 0
        }
    }

    private func processEvent(
        _ event: ConversationDomainEvent,
        app: Application,
        configuration: ConversationOutboxConfiguration,
        registries: ConversationOutboxConsumerRegistries
    ) async throws -> Int {
        let startedAt = Date()
        event.statusEnum = .processing
        event.processingStartedAt = startedAt
        event.errorMessage = nil
        try await event.update(on: db)

        do {
            let payload = try event.decodedPayload()
            let envelope = ConversationEventEnvelope(
                event: event,
                payload: payload,
                deliveryContext: nil
            )
            try await registries.critical.consume(envelope)
            await registries.sideEffects.consumeBestEffort(envelope) { consumerName, error in
                await app.outboxMetrics.recordFailedEvent(
                    eventType: "\(event.eventTypeEnum.rawValue).\(consumerName)",
                    durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                )
                app.logger.warning(
                    "Conversation outbox side-effect consumer failed",
                    metadata: [
                        "node_id": .string(app.imNodeID),
                        "event_id": .string(event.id?.uuidString ?? "unknown"),
                        "conversation_id": .string(event.conversationID.uuidString),
                        "event_type": .string(event.eventType),
                        "consumer": .string(consumerName),
                        "error": .string(String(describing: error))
                    ]
                )
            }

            event.statusEnum = .processed
            event.processedAt = Date()
            try await event.update(on: db)

            await app.outboxMetrics.recordProcessedEvent(
                eventType: event.eventTypeEnum.rawValue,
                durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            )
            app.logger.debug(
                "Conversation outbox event processed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "event_id": .string(event.id?.uuidString ?? "unknown"),
                    "conversation_id": .string(event.conversationID.uuidString),
                    "event_type": .string(event.eventType),
                    "duration_ms": .stringConvertible(max(0, Int(Date().timeIntervalSince(startedAt) * 1000))),
                    "retry_count": .stringConvertible(event.retryCount)
                ]
            )
            return 1
        } catch {
            event.statusEnum = .failed
            event.retryCount += 1
            event.errorMessage = String(describing: error)
            try? await event.update(on: db)

            await app.outboxMetrics.recordFailedEvent(
                eventType: event.eventTypeEnum.rawValue,
                durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            )
            if configuration.logsProcessingFailures {
                app.logger.warning(
                    "Conversation outbox event processing failed",
                    metadata: [
                        "node_id": .string(app.imNodeID),
                        "event_id": .string(event.id?.uuidString ?? "unknown"),
                        "conversation_id": .string(event.conversationID.uuidString),
                        "event_type": .string(event.eventType),
                        "duration_ms": .stringConvertible(max(0, Int(Date().timeIntervalSince(startedAt) * 1000))),
                        "retry_count": .stringConvertible(event.retryCount),
                        "error": .string(String(describing: error))
                    ]
                )
            }
            return 0
        }
    }

    private func processMessageCreatedRunSideEffects(
        _ envelopes: [ConversationEventEnvelope],
        app: Application,
        startedAt: Date
    ) async {
        let messageIDs = envelopes.compactMap(\.payload.messageID)
        await withTaskGroup(of: (String, ConversationEventEnvelope?, (any Error)?).self) { group in
            group.addTask {
                do {
                    try await app.conversationSearchIndexWriter.reindexMessages(messageIDs: messageIDs, on: db)
                    return ("ConversationSearchIndexConsumer", envelopes.last, nil)
                } catch {
                    return ("ConversationSearchIndexConsumer", envelopes.last, error)
                }
            }

            group.addTask {
                do {
                    try await ConversationNotificationRunWriter(app: app).consume(envelopes)
                    return ("ConversationNotificationConsumer", envelopes.last, nil)
                } catch {
                    return ("ConversationNotificationConsumer", envelopes.last, error)
                }
            }

            for await (consumerName, envelope, error) in group {
                guard let error else {
                    continue
                }
                await app.outboxMetrics.recordFailedEvent(
                    eventType: "\(envelope?.eventType.rawValue ?? "message_created").\(consumerName)",
                    durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                )
                app.logger.warning(
                    "Conversation outbox side-effect consumer failed",
                    metadata: [
                        "node_id": .string(app.imNodeID),
                        "event_id": .string(envelope?.event.id?.uuidString ?? "unknown"),
                        "conversation_id": .string(envelope?.conversationID.uuidString ?? "unknown"),
                        "event_type": .string(envelope?.event.eventType ?? ConversationDomainEventType.messageCreated.rawValue),
                        "consumer": .string(consumerName),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }
    }

    private func makeRegistries(app: Application) -> ConversationOutboxConsumerRegistries {
        ConversationOutboxConsumerRegistries(
            critical: ConversationEventConsumerRegistry(consumers: [
                ConversationMediaAssetReferenceConsumer(db: db, app: app),
                ConversationProjectionConsumer(app: app, sourceDB: db),
                ChangesLogConsumer(app: app, sourceDB: db)
            ]),
            sideEffects: ConversationEventConsumerRegistry(consumers: [
                ConversationSearchIndexConsumer(app: app, db: db),
                ConversationNotificationConsumer(app: app)
            ])
        )
    }

    private func recordSnapshot(app: Application) async {
        do {
            let pendingCount = try await ConversationDomainEvent.query(on: db)
                .group(.or) { group in
                    group.filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                    group.filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
                }
                .count()

            let oldestPending = try await ConversationDomainEvent.query(on: db)
                .group(.or) { group in
                    group.filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                    group.filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
                }
                .sort(\.$createdAt, .ascending)
                .first()
                .map(\.createdAt)

            let projectionLagMillis = oldestPending.map { max(0, Int(Date().timeIntervalSince($0) * 1000)) } ?? 0
            await app.outboxMetrics.recordBacklog(
                pendingCount: pendingCount,
                oldestPendingAgeMillis: projectionLagMillis
            )
        } catch {
            app.logger.debug(
                "Conversation outbox snapshot collection failed",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }
}

private struct ConversationOutboxConsumerRegistries: Sendable {
    let critical: ConversationEventConsumerRegistry
    let sideEffects: ConversationEventConsumerRegistry
}

struct ConversationOutboxStatusBatchUpdater {
    let db: any Database

    func markProcessing(_ events: [ConversationDomainEvent], startedAt: Date) async throws {
        guard !events.isEmpty else { return }
        for event in events {
            event.statusEnum = .processing
            event.processingStartedAt = startedAt
            event.errorMessage = nil
        }
        guard let sql = db as? any SQLDatabase else {
            for event in events {
                try await event.update(on: db)
            }
            return
        }

        let idList = try idList(for: events)
        try await sql.raw("""
            UPDATE \(ident: ConversationDomainEvent.schema)
            SET
                \(ident: "status") = \(bind: ConversationDomainEventStatus.processing.rawValue),
                \(ident: "processing_started_at") = \(bind: startedAt),
                \(ident: "error_message") = NULL
            WHERE \(ident: "id") IN (\(idList))
            """).run()
    }

    func markProcessed(_ events: [ConversationDomainEvent], processedAt: Date) async throws {
        guard !events.isEmpty else { return }
        for event in events {
            event.statusEnum = .processed
            event.processedAt = processedAt
            event.errorMessage = nil
        }
        guard let sql = db as? any SQLDatabase else {
            for event in events {
                try await event.update(on: db)
            }
            return
        }

        let idList = try idList(for: events)
        try await sql.raw("""
            UPDATE \(ident: ConversationDomainEvent.schema)
            SET
                \(ident: "status") = \(bind: ConversationDomainEventStatus.processed.rawValue),
                \(ident: "processed_at") = \(bind: processedAt),
                \(ident: "error_message") = NULL
            WHERE \(ident: "id") IN (\(idList))
            """).run()
    }

    func markFailed(_ events: [ConversationDomainEvent], errorMessage: String) async throws {
        guard !events.isEmpty else { return }
        for event in events {
            event.statusEnum = .failed
            event.retryCount += 1
            event.errorMessage = errorMessage
        }
        guard let sql = db as? any SQLDatabase else {
            for event in events {
                try await event.update(on: db)
            }
            return
        }

        let idList = try idList(for: events)
        try await sql.raw("""
            UPDATE \(ident: ConversationDomainEvent.schema)
            SET
                \(ident: "status") = \(bind: ConversationDomainEventStatus.failed.rawValue),
                \(ident: "retry_count") = \(ident: "retry_count") + 1,
                \(ident: "error_message") = \(bind: errorMessage)
            WHERE \(ident: "id") IN (\(idList))
            """).run()
    }

    private func idList(for events: [ConversationDomainEvent]) throws -> SQLQueryString {
        try events.map { event -> SQLQueryString in
            "\(bind: try event.requireID())"
        }.joined(separator: ", ")
    }
}
