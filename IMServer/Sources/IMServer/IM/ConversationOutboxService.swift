import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

struct ConversationEventEnvelope: Sendable {
    struct DeliveryContext: Sendable {
        let sourceTopic: String
        let consumerGroupID: String
        let producerShard: String
        let deadLetterError: String?
    }

    let event: ConversationDomainEvent
    let payload: ConversationDomainEventPayload
    let deliveryContext: DeliveryContext?

    var eventID: UUID? { event.id }
    var conversationID: UUID { event.conversationID }
    var eventType: ConversationDomainEventType { event.eventTypeEnum }
}

protocol ConversationEventConsumer: Sendable {
    var supportedEventTypes: Set<ConversationDomainEventType> { get }
    func consume(_ envelope: ConversationEventEnvelope) async throws
}

struct ConversationProjectionConsumer: ConversationEventConsumer {
    let app: Application
    let sourceDB: any Database

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        switch envelope.eventType {
        case .conversationRemovedForUser:
            if let affectedUserID = envelope.payload.affectedUserID {
                for target in projectionTargets(for: [affectedUserID]) {
                    try await IMConversationSummaryProjectionService(
                        sourceDB: sourceDB,
                        readModelDB: target.readModelDB
                    ).markConversationRemoved(
                        conversationID: envelope.conversationID,
                        recipientUserID: affectedUserID,
                        on: sourceDB,
                        writeChangeLog: false
                    )
                }
            }
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .readAdvanced,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated:
            for target in projectionTargets(for: envelope.payload.recipientUserIDs) {
                try await IMConversationSummaryProjectionService(
                    sourceDB: sourceDB,
                    readModelDB: target.readModelDB
                ).refreshConversationSummaries(
                    conversationID: envelope.conversationID,
                    recipientUserIDs: target.recipientUserIDs,
                    on: sourceDB,
                    writeChangeLog: false
                )
            }
        }
    }

    private func projectionTargets(for recipientUserIDs: [UUID]) -> [SummaryProjectionTarget] {
        summaryProjectionTargets(
            app: app,
            recipientUserIDs: recipientUserIDs
        )
    }
}

struct ChangesLogConsumer: ConversationEventConsumer {
    let app: Application
    let sourceDB: any Database

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        switch envelope.eventType {
        case .conversationRemovedForUser:
            if let affectedUserID = envelope.payload.affectedUserID {
                for target in projectionTargets(for: [affectedUserID]) {
                    try await IMConversationSummaryProjectionService(
                        sourceDB: sourceDB,
                        readModelDB: target.readModelDB
                    ).recordConversationRemovedChange(
                        conversationID: envelope.conversationID,
                        recipientUserID: affectedUserID
                    )
                }
            }
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .readAdvanced,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated:
            for target in projectionTargets(for: envelope.payload.recipientUserIDs) {
                try await IMConversationSummaryProjectionService(
                    sourceDB: sourceDB,
                    readModelDB: target.readModelDB
                ).recordConversationSummaryChanges(
                    conversationID: envelope.conversationID,
                    recipientUserIDs: target.recipientUserIDs
                )
            }
        }
    }

    private func projectionTargets(for recipientUserIDs: [UUID]) -> [SummaryProjectionTarget] {
        summaryProjectionTargets(
            app: app,
            recipientUserIDs: recipientUserIDs
        )
    }
}

struct ConversationNotificationConsumer: ConversationEventConsumer {
    let app: Application

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard let eventID = envelope.eventID else {
            return
        }

        let recipientUserIDs = notificationRecipientUserIDs(for: envelope)
        let now = Date()

        for ownerUserID in recipientUserIDs {
            let db = app.summaryShardRouter.database(forOwnerUserID: ownerUserID)
            let recordID = ConversationNotificationEntry.recordID(ownerUserID: ownerUserID, eventID: eventID)
            let entry: ConversationNotificationEntry
            let isExisting: Bool
            if let existing = try await ConversationNotificationEntry.find(recordID, on: db) {
                entry = existing
                isExisting = true
            } else {
                entry = try ConversationNotificationEntry(
                    ownerUserID: ownerUserID,
                    eventID: eventID,
                    conversationID: envelope.conversationID,
                    eventType: envelope.event.eventType,
                    payload: envelope.payload,
                    createdAt: envelope.event.createdAt,
                    updatedAt: now
                )
                isExisting = false
            }
            entry.ownerUserID = ownerUserID
            entry.eventID = eventID
            entry.conversationID = envelope.conversationID
            entry.eventType = envelope.event.eventType
            entry.payload = envelope.payload
            entry.updatedAt = now

            if isExisting {
                try await entry.update(on: db)
            } else {
                try await entry.create(on: db)
            }
        }
    }

    private func notificationRecipientUserIDs(for envelope: ConversationEventEnvelope) -> [UUID] {
        switch envelope.eventType {
        case .conversationRemovedForUser:
            return envelope.payload.affectedUserID.map { [$0] } ?? []
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .readAdvanced,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated:
            return Array(Set(envelope.payload.recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
    }
}

struct RepairReplayConsumer: ConversationEventConsumer {
    let db: any Database
    let consumerGroupID: String

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard let eventID = envelope.eventID,
              let deliveryContext = envelope.deliveryContext
        else {
            return
        }

        let recordID = ConversationReplayRecord.recordID(
            consumerGroupID: consumerGroupID,
            eventID: eventID
        )
        let now = Date()
        let record: ConversationReplayRecord
        let isExisting: Bool
        if let existing = try await ConversationReplayRecord.find(recordID, on: db) {
            record = existing
            isExisting = true
        } else {
            record = try ConversationReplayRecord(
                eventID: eventID,
                consumerGroupID: consumerGroupID,
                sourceTopic: deliveryContext.sourceTopic,
                conversationID: envelope.conversationID,
                eventType: envelope.event.eventType,
                producerShard: deliveryContext.producerShard,
                payload: envelope.payload,
                lastError: deliveryContext.deadLetterError,
                createdAt: envelope.event.createdAt,
                updatedAt: now
            )
            isExisting = false
        }

        record.eventID = eventID
        record.consumerGroupID = consumerGroupID
        record.sourceTopic = deliveryContext.sourceTopic
        record.conversationID = envelope.conversationID
        record.eventType = envelope.event.eventType
        record.producerShard = deliveryContext.producerShard
        record.payload = envelope.payload
        record.statusEnum = .pending
        record.lastError = deliveryContext.deadLetterError
        record.receiveCount = isExisting ? record.receiveCount + 1 : 1
        record.updatedAt = now

        if isExisting {
            try await record.update(on: db)
        } else {
            try await record.create(on: db)
        }
    }
}

struct ConversationSearchIndexConsumer: ConversationEventConsumer {
    let db: any Database

    var supportedEventTypes: Set<ConversationDomainEventType> {
        [.messageCreated, .messageUpdated, .messageRecalled]
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard let messageID = envelope.payload.messageID else {
            return
        }

        switch envelope.eventType {
        case .messageCreated, .messageUpdated, .messageRecalled:
            try await ConversationSearchIndexWorker(db: db).reindexMessage(messageID: messageID, on: db)
        case .readAdvanced,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated,
             .conversationRemovedForUser:
            return
        }
    }
}

struct ConversationEventConsumerRegistry {
    private let consumers: [any ConversationEventConsumer]

    init(consumers: [any ConversationEventConsumer]) {
        self.consumers = consumers
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        for consumer in consumers where consumer.supportedEventTypes.contains(envelope.eventType) {
            try await consumer.consume(envelope)
        }
    }
}

struct ConversationOutboxService {
    let db: any Database

    func enqueue(
        type: ConversationDomainEventType,
        conversationID: UUID,
        payload: ConversationDomainEventPayload,
        on database: (any Database)? = nil
    ) async throws {
        let database = database ?? db
        let event = try ConversationDomainEvent(
            conversationID: conversationID,
            eventType: type,
            payload: payload
        )
        try await event.create(on: database)
    }

    @discardableResult
    func processPendingBatch(
        app: Application,
        configuration: ConversationOutboxConfiguration? = nil
    ) async throws -> Int {
        let configuration = configuration ?? app.conversationOutboxConfiguration
        let events = try await ConversationDomainEvent.query(on: db)
            .group(.or) { group in
                group.filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                group.filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
            }
            .sort(\.$createdAt, .ascending)
            .limit(configuration.batchSize)
            .all()
            .filter { $0.retryCount < configuration.maxRetries }

        guard !events.isEmpty else {
            await recordSnapshot(app: app)
            return 0
        }

        let registry = ConversationEventConsumerRegistry(consumers: [
            ConversationProjectionConsumer(app: app, sourceDB: db),
            ChangesLogConsumer(app: app, sourceDB: db),
            ConversationSearchIndexConsumer(db: db),
            ConversationNotificationConsumer(app: app)
        ])
        var processedCount = 0

        for event in events {
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
                try await registry.consume(envelope)

                event.statusEnum = .processed
                event.processedAt = Date()
                try await event.update(on: db)
                processedCount += 1

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
            } catch {
                event.statusEnum = .failed
                event.retryCount += 1
                event.errorMessage = String(describing: error)
                try? await event.update(on: db)

                await app.outboxMetrics.recordFailedEvent(
                    eventType: event.eventTypeEnum.rawValue,
                    durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                )
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
        }

        await recordSnapshot(app: app)
        return processedCount
    }

    @discardableResult
    func requeueFailedEvents(
        maxRetryCount: Int? = nil,
        eventTypes: Set<ConversationDomainEventType> = []
    ) async throws -> Int {
        let failedEvents = try await ConversationDomainEvent.query(on: db)
            .filter(\.$status == ConversationDomainEventStatus.failed.rawValue)
            .sort(\.$createdAt, .ascending)
            .all()

        var requeuedCount = 0
        for event in failedEvents {
            if let maxRetryCount, event.retryCount > maxRetryCount {
                continue
            }
            if !eventTypes.isEmpty, !eventTypes.contains(event.eventTypeEnum) {
                continue
            }

            event.statusEnum = .pending
            event.retryCount = 0
            event.processingStartedAt = nil
            event.processedAt = nil
            event.errorMessage = nil
            try await event.update(on: db)
            requeuedCount += 1
        }

        return requeuedCount
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

private struct SummaryProjectionTarget {
    let readModelDB: any Database
    let recipientUserIDs: [UUID]
}

private func summaryProjectionTargets(
    app: Application,
    recipientUserIDs: [UUID]
) -> [SummaryProjectionTarget] {
    let uniqueRecipientUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
    guard !uniqueRecipientUserIDs.isEmpty else {
        return []
    }

    switch app.summaryReadModelConfiguration.projectionWriteMode {
    case .legacy:
        return [
            SummaryProjectionTarget(
                readModelDB: app.imSummaryDB,
                recipientUserIDs: uniqueRecipientUserIDs
            )
        ]
    case .sharded:
        return shardedSummaryProjectionTargets(app: app, recipientUserIDs: uniqueRecipientUserIDs)
    case .dualWrite:
        return [
            SummaryProjectionTarget(
                readModelDB: app.imSummaryDB,
                recipientUserIDs: uniqueRecipientUserIDs
            )
        ] + shardedSummaryProjectionTargets(app: app, recipientUserIDs: uniqueRecipientUserIDs)
    }
}

private func shardedSummaryProjectionTargets(
    app: Application,
    recipientUserIDs: [UUID]
) -> [SummaryProjectionTarget] {
    Dictionary(grouping: recipientUserIDs) {
        app.summaryShardRouter.shardID(forOwnerUserID: $0)
    }
    .values
    .compactMap { shardRecipientUserIDs in
        guard let firstRecipient = shardRecipientUserIDs.first else {
            return nil
        }
        return SummaryProjectionTarget(
            readModelDB: app.summaryShardRouter.database(forOwnerUserID: firstRecipient),
            recipientUserIDs: shardRecipientUserIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }
}

struct ConversationSearchIndexWorker {
    let db: any Database

    func reindexMessage(messageID: UUID, on database: (any Database)? = nil) async throws {
        let database = database ?? db
        let recordID = ConversationMessageSearchIndex.recordID(messageID: messageID)

        guard let message = try await ConversationMessage.find(messageID, on: database) else {
            if let existing = try await ConversationMessageSearchIndex.find(recordID, on: database) {
                try await existing.delete(on: database)
            }
            return
        }

        let aggregate = try message.decodedAggregate()
        let searchableText = MessagePresentation(aggregate: aggregate)
            .searchableTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let updatedAt = Date()
        let createdAt = message.createdAt ?? updatedAt

        if let existing = try await ConversationMessageSearchIndex.find(recordID, on: database) {
            existing.conversationID = message.$conversation.id
            existing.messageID = messageID
            existing.serverSequence = message.serverSequence
            existing.messageType = message.kind
            existing.searchableText = searchableText
            existing.updatedAt = updatedAt
            try await existing.update(on: database)
        } else {
            let index = ConversationMessageSearchIndex(
                messageID: messageID,
                conversationID: message.$conversation.id,
                serverSequence: message.serverSequence,
                messageType: message.kind,
                searchableText: searchableText,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            try await index.create(on: database)
        }
    }
}

final class ConversationProjectionWorkerLifecycle: LifecycleHandler, @unchecked Sendable {
    private let taskLock = NIOLock()
    private var task: Task<Void, Never>?

    func didBootAsync(_ application: Application) async throws {
        guard application.conversationProjectionMode == .asynchronous else {
            return
        }

        let configuration = application.conversationOutboxConfiguration
        taskLock.withLock {
            task = Task {
                while !Task.isCancelled {
                    do {
                        var processedCount = 0
                        for shard in application.conversationShardRouter.allCommandDatabases() {
                            processedCount += try await ConversationOutboxService(db: shard.database).processPendingBatch(
                                app: application,
                                configuration: configuration
                            )
                        }
                        if processedCount == 0 {
                            try await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                        }
                    } catch {
                        application.logger.warning(
                            "Conversation projection worker iteration failed",
                            metadata: [
                                "node_id": .string(application.imNodeID),
                                "error": .string(String(describing: error))
                            ]
                        )
                        try? await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                    }
                }
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        let task = taskLock.withLock { () -> Task<Void, Never>? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }
}

struct ConversationOutboxConfiguration: Sendable {
    let batchSize: Int
    let pollIntervalNanoseconds: UInt64
    let maxRetries: Int

    static func load(from environment: Environment) -> ConversationOutboxConfiguration {
        let batchSize = max(1, Environment.get("IM_OUTBOX_BATCH_SIZE").flatMap(Int.init(_:)) ?? 200)
        let pollIntervalMillis = max(50, Environment.get("IM_OUTBOX_POLL_INTERVAL_MS").flatMap(Int.init(_:)) ?? 500)
        let maxRetries = max(1, Environment.get("IM_OUTBOX_MAX_RETRIES").flatMap(Int.init(_:)) ?? 5)
        return ConversationOutboxConfiguration(
            batchSize: batchSize,
            pollIntervalNanoseconds: UInt64(pollIntervalMillis) * 1_000_000,
            maxRetries: maxRetries
        )
    }
}

actor OutboxMetrics {
    struct Snapshot: Sendable {
        var processedEvents: Int = 0
        var failedEvents: Int = 0
        var backlogCount: Int = 0
        var oldestPendingAgeMillis: Int = 0
        var lastProcessedEventType: String?
        var lastFailedEventType: String?
    }

    private var snapshot = Snapshot()

    func recordProcessedEvent(eventType: String, durationMillis: Int) {
        snapshot.processedEvents += 1
        snapshot.lastProcessedEventType = eventType
        _ = durationMillis
    }

    func recordFailedEvent(eventType: String, durationMillis: Int) {
        snapshot.failedEvents += 1
        snapshot.lastFailedEventType = eventType
        _ = durationMillis
    }

    func recordBacklog(pendingCount: Int, oldestPendingAgeMillis: Int) {
        snapshot.backlogCount = pendingCount
        snapshot.oldestPendingAgeMillis = oldestPendingAgeMillis
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

enum ConversationProjectionMode: String, Sendable {
    case synchronous
    case asynchronous
}

private struct ConversationProjectionModeStorageKey: StorageKey {
    typealias Value = ConversationProjectionMode
}

private struct ConversationOutboxConfigurationStorageKey: StorageKey {
    typealias Value = ConversationOutboxConfiguration
}

private struct OutboxMetricsStorageKey: StorageKey {
    typealias Value = OutboxMetrics
}

extension Application {
    var conversationProjectionMode: ConversationProjectionMode {
        get {
            if let mode = storage[ConversationProjectionModeStorageKey.self] {
                return mode
            }
            let mode: ConversationProjectionMode = environment == .testing ? .synchronous : .asynchronous
            storage[ConversationProjectionModeStorageKey.self] = mode
            return mode
        }
        set {
            storage[ConversationProjectionModeStorageKey.self] = newValue
        }
    }

    var conversationOutboxConfiguration: ConversationOutboxConfiguration {
        get {
            if let configuration = storage[ConversationOutboxConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = ConversationOutboxConfiguration.load(from: environment)
            storage[ConversationOutboxConfigurationStorageKey.self] = configuration
            return configuration
        }
        set {
            storage[ConversationOutboxConfigurationStorageKey.self] = newValue
        }
    }

    var outboxMetrics: OutboxMetrics {
        get {
            if let metrics = storage[OutboxMetricsStorageKey.self] {
                return metrics
            }
            let metrics = OutboxMetrics()
            storage[OutboxMetricsStorageKey.self] = metrics
            return metrics
        }
        set {
            storage[OutboxMetricsStorageKey.self] = newValue
        }
    }

    func processConversationOutboxIfNeeded() async throws {
        guard conversationProjectionMode == .synchronous else {
            return
        }

        for shard in conversationShardRouter.allCommandDatabases() {
            _ = try await ConversationOutboxService(db: shard.database).processPendingBatch(
                app: self,
                configuration: conversationOutboxConfiguration
            )
        }
    }

    func processConversationOutboxForTesting() async throws {
        guard environment == .testing else {
            return
        }

        try await processConversationOutboxIfNeeded()
    }
}
