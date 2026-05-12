import Fluent
import Foundation
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
        case .messageCreated:
            guard let messageID = envelope.payload.messageID else {
                for target in projectionTargets(for: envelope.payload.recipientUserIDs) {
                    try await IMConversationSummaryProjectionService(
                        sourceDB: sourceDB,
                        readModelDB: target.readModelDB
                    ).refreshConversationSummaries(
                        conversationID: envelope.conversationID,
                        recipientUserIDs: target.recipientUserIDs,
                        on: sourceDB,
                        writeChangeLog: true
                    )
                }
                return
            }

            for target in projectionTargets(for: envelope.payload.recipientUserIDs) {
                try await IMConversationSummaryProjectionService(
                    sourceDB: sourceDB,
                    readModelDB: target.readModelDB
                ).applyMessageCreated(
                    conversationID: envelope.conversationID,
                    messageID: messageID,
                    recipientUserIDs: target.recipientUserIDs,
                    on: sourceDB,
                    writeChangeLog: true
                )
            }
        case .readAdvanced:
            for target in projectionTargets(for: envelope.payload.recipientUserIDs) {
                for recipientUserID in target.recipientUserIDs {
                    try await IMConversationSummaryProjectionService(
                        sourceDB: sourceDB,
                        readModelDB: target.readModelDB
                    ).applyReadAdvanced(
                        conversationID: envelope.conversationID,
                        recipientUserID: recipientUserID,
                        on: sourceDB,
                        writeChangeLog: true
                    )
                }
            }
        case .messageUpdated,
             .messageRecalled,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated,
             .messageFavoriteChanged,
             .messageVisibilityChanged,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
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
        summaryProjectionTargets(app: app, recipientUserIDs: recipientUserIDs)
    }
}

struct ConversationMediaAssetReferenceConsumer: ConversationEventConsumer {
    let db: any Database
    let app: Application?

    init(db: any Database, app: Application? = nil) {
        self.db = db
        self.app = app
    }

    var supportedEventTypes: Set<ConversationDomainEventType> {
        [.messageCreated, .messageUpdated, .messageRecalled]
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard let messageID = envelope.payload.messageID else {
            return
        }

        let reference = try await ConversationMediaAssetReferenceService(db: db).syncMessageReference(
            conversationID: envelope.conversationID,
            messageID: messageID,
            on: db
        )
        guard let app else {
            return
        }
        let shardID = try await app.conversationShardRouter.shardID(forConversationID: envelope.conversationID)
        try await ConversationMediaAssetReferenceDirectoryService(db: app.imSummaryDB).sync(
            reference: reference,
            shardID: shardID,
            messageID: messageID,
            on: app.imSummaryDB
        )
        await app.conversationMediaAccessCache.invalidate(conversationID: envelope.conversationID)
        if let reference {
            await app.conversationMediaAccessCache.invalidate(assetID: reference.assetID)
        }
    }
}

struct ConversationMediaAssetReferenceBatchWriter {
    let db: any Database
    let app: Application

    func syncMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        guard let firstEnvelope = envelopes.first else {
            return
        }
        let conversationID = firstEnvelope.conversationID
        let messageIDs = envelopes.compactMap(\.payload.messageID)
        guard !messageIDs.isEmpty else {
            return
        }

        let referencesByMessageID = try await ConversationMediaAssetReferenceService(db: db).syncMessageReferences(
            conversationID: conversationID,
            messageIDs: messageIDs,
            on: db
        )
        let shardID = try await app.conversationShardRouter.shardID(forConversationID: conversationID)
        try await ConversationMediaAssetReferenceDirectoryService(db: app.imSummaryDB).sync(
            referencesByMessageID: referencesByMessageID,
            shardID: shardID,
            on: app.imSummaryDB
        )
        await app.conversationMediaAccessCache.invalidate(conversationID: conversationID)
        for reference in referencesByMessageID.values.compactMap({ $0 }) {
            await app.conversationMediaAccessCache.invalidate(assetID: reference.assetID)
        }
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
             .readAdvanced:
            return
        case .messageUpdated,
             .messageRecalled,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated,
             .messageFavoriteChanged,
             .messageVisibilityChanged,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
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
        summaryProjectionTargets(app: app, recipientUserIDs: recipientUserIDs)
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

        let recipientUserIDsByShard = Dictionary(grouping: recipientUserIDs) {
            app.summaryShardRouter.shardID(forOwnerUserID: $0)
        }

        for shardRecipientUserIDs in recipientUserIDsByShard.values {
            guard let firstRecipient = shardRecipientUserIDs.first else {
                continue
            }
            let db = app.summaryShardRouter.database(forOwnerUserID: firstRecipient)
            let rows = shardRecipientUserIDs.map { ownerUserID in
                ConversationNotificationBatchWriter.Row(
                    ownerUserID: ownerUserID,
                    eventID: eventID,
                    conversationID: envelope.conversationID,
                    eventType: envelope.event.eventType,
                    payload: envelope.payload,
                    createdAt: envelope.event.createdAt,
                    updatedAt: now
                )
            }
            try await ConversationNotificationBatchWriter(database: db).upsert(rows)
        }

        await IMAPNSPushService(app: app).sendOfflinePushIfNeeded(for: envelope)
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
             .directPeerUpdated,
             .messageFavoriteChanged,
             .messageVisibilityChanged,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
            return Array(Set(envelope.payload.recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
    }
}

struct ConversationNotificationRunWriter {
    let app: Application

    func consume(_ envelopes: [ConversationEventEnvelope]) async throws {
        let now = Date()
        var rowsByShard: [String: [ConversationNotificationBatchWriter.Row]] = [:]

        for envelope in envelopes {
            guard let eventID = envelope.eventID else {
                continue
            }
            let recipientUserIDs = notificationRecipientUserIDs(for: envelope)
            for ownerUserID in recipientUserIDs {
                let shardID = app.summaryShardRouter.shardID(forOwnerUserID: ownerUserID)
                rowsByShard[shardID, default: []].append(
                    ConversationNotificationBatchWriter.Row(
                        ownerUserID: ownerUserID,
                        eventID: eventID,
                        conversationID: envelope.conversationID,
                        eventType: envelope.event.eventType,
                        payload: envelope.payload,
                        createdAt: envelope.event.createdAt,
                        updatedAt: now
                    )
                )
            }
        }

        for rows in rowsByShard.values where !rows.isEmpty {
            guard let firstOwnerUserID = rows.first?.ownerUserID else {
                continue
            }
            let db = app.summaryShardRouter.database(forOwnerUserID: firstOwnerUserID)
            try await ConversationNotificationBatchWriter(database: db).upsert(rows)
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
             .directPeerUpdated,
             .messageFavoriteChanged,
             .messageVisibilityChanged,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
            return Array(Set(envelope.payload.recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
    }
}

struct ConversationSearchIndexConsumer: ConversationEventConsumer {
    let app: Application
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
            try await app.conversationSearchIndexWriter.reindexMessage(messageID: messageID, on: db)
        case .readAdvanced,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated,
             .messageVisibilityChanged,
             .messageFavoriteChanged,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged,
             .conversationRemovedForUser:
            return
        }
    }
}

struct ConversationEventConsumerRegistry: Sendable {
    private let consumers: [any ConversationEventConsumer]

    init(consumers: [any ConversationEventConsumer]) {
        self.consumers = consumers
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        for consumer in consumers where consumer.supportedEventTypes.contains(envelope.eventType) {
            try await consumer.consume(envelope)
        }
    }

    func consumeBestEffort(
        _ envelope: ConversationEventEnvelope,
        onError: @Sendable (String, any Error) async -> Void
    ) async {
        let supportedConsumers = consumers.filter { $0.supportedEventTypes.contains(envelope.eventType) }
        await withTaskGroup(of: (String, (any Error)?).self) { group in
            for consumer in supportedConsumers {
                group.addTask {
                    let consumerName = String(describing: type(of: consumer))
                    do {
                        try await consumeWithTimeout(consumer, envelope: envelope)
                        return (consumerName, nil)
                    } catch {
                        return (consumerName, error)
                    }
                }
            }

            for await (consumerName, error) in group {
                if let error {
                    await onError(consumerName, error)
                }
            }
        }
    }

    private func consumeWithTimeout(
        _ consumer: any ConversationEventConsumer,
        envelope: ConversationEventEnvelope,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await consumer.consume(envelope)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ConversationEventConsumerTimeoutError()
            }

            try await group.next()
            group.cancelAll()
        }
    }
}

private struct ConversationEventConsumerTimeoutError: Error {}

struct SummaryProjectionTarget {
    let readModelDB: any Database
    let recipientUserIDs: [UUID]
}

func summaryProjectionTargets(
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
