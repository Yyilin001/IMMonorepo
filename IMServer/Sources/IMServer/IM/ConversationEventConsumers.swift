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
    let eventType: ConversationDomainEventType

    var eventID: UUID? { event.id }
    var conversationID: UUID { event.conversationID }

    init(
        event: ConversationDomainEvent,
        payload: ConversationDomainEventPayload,
        deliveryContext: DeliveryContext?
    ) throws {
        self.event = event
        self.payload = payload
        self.deliveryContext = deliveryContext
        self.eventType = try event.eventTypeEnum
    }
}

protocol ConversationEventConsumer: Sendable {
    var supportedEventTypes: Set<ConversationDomainEventType> { get }
    func consume(_ envelope: ConversationEventEnvelope) async throws
    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws
}

extension ConversationEventConsumer {
    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        for envelope in envelopes {
            try await consume(envelope)
        }
    }
}

private func sharedResolvedMessageCreatedRunRecipients(
    for envelopes: [ConversationEventEnvelope],
    sourceDB: any Database,
    app: Application
) async throws -> ConversationDomainEventResolvedRecipients? {
    guard envelopes.count > 1,
          let first = envelopes.first,
          first.eventType == .messageCreated,
          first.payload.messageID != nil
    else {
        return nil
    }
    guard envelopes.allSatisfy({
        $0.eventType == .messageCreated
            && $0.payload.messageID != nil
            && $0.conversationID == first.conversationID
    }) else {
        return nil
    }

    let resolver = ConversationDomainEventRecipientResolver(db: sourceDB, app: app)
    let inlineRecipientSets = envelopes.map { Set($0.payload.recipientUserIDs) }
    if inlineRecipientSets.allSatisfy({ !$0.isEmpty }) {
        guard let firstRecipientSet = inlineRecipientSets.first,
              inlineRecipientSets.allSatisfy({ $0 == firstRecipientSet })
        else {
            return nil
        }
        return try await resolver.resolveRecipients(for: first)
    }

    let eventIDs = envelopes.compactMap(\.eventID)
    if eventIDs.count == envelopes.count {
        let snapshots = try await ConversationDomainEventRecipientSnapshot.query(on: sourceDB)
            .filter(\.$id ~~ eventIDs)
            .all()
        let snapshotsByEventID = Dictionary(
            uniqueKeysWithValues: snapshots.compactMap { snapshot in
                snapshot.id.map { ($0, snapshot) }
            }
        )
        let orderedSnapshots = eventIDs.compactMap { snapshotsByEventID[$0] }
        if orderedSnapshots.count == envelopes.count {
            let snapshotHashes = orderedSnapshots.map(\.recipientHash)
            if snapshotHashes.allSatisfy({ $0 != nil }) {
                guard let firstHash = snapshotHashes.first.flatMap({ $0 }),
                      snapshotHashes.allSatisfy({ $0 == firstHash })
                else {
                    return nil
                }
                return try await resolver.resolveRecipients(for: first)
            }

            var snapshotRecipientSets: [Set<UUID>] = []
            snapshotRecipientSets.reserveCapacity(orderedSnapshots.count)
            for snapshot in orderedSnapshots {
                snapshotRecipientSets.append(Set(try await snapshot.recipientUserIDs(on: sourceDB)))
            }
            guard let firstRecipientSet = snapshotRecipientSets.first,
                  snapshotRecipientSets.allSatisfy({ $0 == firstRecipientSet })
            else {
                return nil
            }
            return try await resolver.resolveRecipients(for: first)
        }
    }

    return try await resolver.resolveRecipients(for: first)
}

private struct ActiveConversationRouteLookupResult: Sendable {
    let routes: [UUID: Set<String>]
    let cacheHit: Bool
    let cachePartialHit: Bool
    let cachedUserCount: Int
    let missedUserCount: Int
    let joinedInFlight: Bool
}

private func activeConversationRoutes(
    app: Application,
    conversationID: UUID,
    recipientUserIDs: [UUID]?
) async throws -> ActiveConversationRouteLookupResult {
    let configuration = app.streamConsumerConfiguration
    let ttlMilliseconds = configuration.realtimeActiveConversationRouteCacheTTLMilliseconds
    let maxEntries = configuration.realtimeActiveConversationRouteCacheMaxEntries
    let lookup: ActiveConversationRouteLookupCache.ResolveResult
    if ttlMilliseconds > 0, maxEntries > 0 {
        lookup = try await app.activeConversationRouteLookupCache.resolveActiveConversation(
            conversationID: conversationID,
            ttlMilliseconds: ttlMilliseconds,
            maxEntries: maxEntries
        ) {
            try await app.connectionRoutingService.backend.presenceStore.routeNodeIDs(
                forActiveConversationID: conversationID
            )
        }
    } else {
        let fetchedRoutes = try await app.connectionRoutingService.backend.presenceStore.routeNodeIDs(
            forActiveConversationID: conversationID
        )
        lookup = ActiveConversationRouteLookupCache.ResolveResult(
            routes: fetchedRoutes,
            cachedUserCount: 0,
            missedUserCount: fetchedRoutes.count,
            joinedInFlight: false,
            cacheHit: false
        )
    }
    let filteredRoutes: [UUID: Set<String>]
    if let recipientUserIDs {
        let recipientUserIDSet = Set(recipientUserIDs)
        filteredRoutes = lookup.routes.filter { recipientUserIDSet.contains($0.key) }
    } else {
        filteredRoutes = lookup.routes
    }
    if lookup.cacheHit {
        await app.routingMetrics.recordRealtimeActiveConversationRouteCache(
            hit: true,
            cachedUserCount: filteredRoutes.count,
            joinedInFlight: lookup.joinedInFlight
        )
        return ActiveConversationRouteLookupResult(
            routes: filteredRoutes,
            cacheHit: true,
            cachePartialHit: false,
            cachedUserCount: filteredRoutes.count,
            missedUserCount: 0,
            joinedInFlight: lookup.joinedInFlight
        )
    }

    await app.routingMetrics.recordRealtimeActiveConversationRouteCache(
        hit: false,
        partialHit: lookup.cachedUserCount > 0,
        cachedUserCount: lookup.cachedUserCount,
        missedUserCount: lookup.missedUserCount,
        joinedInFlight: lookup.joinedInFlight
    )
    return ActiveConversationRouteLookupResult(
        routes: filteredRoutes,
        cacheHit: false,
        cachePartialHit: lookup.cachedUserCount > 0,
        cachedUserCount: lookup.cachedUserCount,
        missedUserCount: lookup.missedUserCount,
        joinedInFlight: lookup.joinedInFlight
    )
}

struct ConversationProjectionConsumer: ConversationEventConsumer {
    let app: Application
    let sourceDB: any Database

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        guard let collapsedRun = try await collapsibleActivityOnlyMessageCreatedRun(envelopes) else {
            for envelope in envelopes {
                try await consume(envelope)
            }
            return
        }

        for (index, target) in activityProjectionTargets().enumerated() {
            try await IMConversationSummaryProjectionService(
                sourceDB: sourceDB,
                readModelDB: target.readModelDB,
                streamConsumerConfiguration: app.streamConsumerConfiguration,
                domainEventMetrics: app.conversationDomainEventMetrics,
                activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
            ).applyMessageCreatedActivityOnly(
                conversationID: collapsedRun.envelope.conversationID,
                messageID: collapsedRun.messageID,
                recipientCount: collapsedRun.recipientCount,
                on: sourceDB,
                readModelKey: target.shardID,
                recordMetrics: index == 0
            )
        }
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        switch envelope.eventType {
        case .conversationRemovedForUser:
            if let affectedUserID = envelope.payload.affectedUserID {
                for target in projectionTargets(for: [affectedUserID]) {
                    try await IMConversationSummaryProjectionService(
                        sourceDB: sourceDB,
                        readModelDB: target.readModelDB,
                        streamConsumerConfiguration: app.streamConsumerConfiguration,
                        domainEventMetrics: app.conversationDomainEventMetrics,
                        activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
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
                let recipientUserIDs = try await recipientUserIDs(for: envelope)
                for target in projectionTargets(for: recipientUserIDs) {
                    try await IMConversationSummaryProjectionService(
                        sourceDB: sourceDB,
                        readModelDB: target.readModelDB,
                        streamConsumerConfiguration: app.streamConsumerConfiguration,
                        domainEventMetrics: app.conversationDomainEventMetrics,
                        activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
                    ).refreshConversationSummaries(
                        conversationID: envelope.conversationID,
                        recipientUserIDs: target.recipientUserIDs,
                        on: sourceDB,
                        writeChangeLog: true
                    )
                }
                return
            }

            if let recipientCount = try await activityOnlyRecipientCountIfNeeded(for: envelope) {
                for (index, target) in activityProjectionTargets().enumerated() {
                    try await IMConversationSummaryProjectionService(
                        sourceDB: sourceDB,
                        readModelDB: target.readModelDB,
                        streamConsumerConfiguration: app.streamConsumerConfiguration,
                        domainEventMetrics: app.conversationDomainEventMetrics,
                        activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
                    ).applyMessageCreatedActivityOnly(
                        conversationID: envelope.conversationID,
                        messageID: messageID,
                        recipientCount: recipientCount,
                        on: sourceDB,
                        readModelKey: target.shardID,
                        recordMetrics: index == 0
                    )
                }
                return
            }

            let recipientUserIDs = try await recipientUserIDs(for: envelope)
            for target in projectionTargets(for: recipientUserIDs) {
                try await IMConversationSummaryProjectionService(
                    sourceDB: sourceDB,
                    readModelDB: target.readModelDB,
                    streamConsumerConfiguration: app.streamConsumerConfiguration,
                    domainEventMetrics: app.conversationDomainEventMetrics,
                    activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
                ).applyMessageCreated(
                    conversationID: envelope.conversationID,
                    messageID: messageID,
                    recipientUserIDs: target.recipientUserIDs,
                    on: sourceDB,
                    writeChangeLog: true
                )
            }
        case .readAdvanced:
            let recipientUserIDs = try await recipientUserIDs(for: envelope)
            for target in projectionTargets(for: recipientUserIDs) {
                for recipientUserID in target.recipientUserIDs {
                    try await IMConversationSummaryProjectionService(
                        sourceDB: sourceDB,
                        readModelDB: target.readModelDB,
                        streamConsumerConfiguration: app.streamConsumerConfiguration,
                        domainEventMetrics: app.conversationDomainEventMetrics,
                        activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
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
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
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
            let recipientUserIDs = try await recipientUserIDs(for: envelope)
            for target in projectionTargets(for: recipientUserIDs) {
                try await IMConversationSummaryProjectionService(
                    sourceDB: sourceDB,
                    readModelDB: target.readModelDB,
                    streamConsumerConfiguration: app.streamConsumerConfiguration,
                    domainEventMetrics: app.conversationDomainEventMetrics,
                    activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
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

    private func activityProjectionTargets() -> [SummaryActivityProjectionTarget] {
        summaryProjectionActivityTargets(app: app)
    }

    private func recipientUserIDs(for envelope: ConversationEventEnvelope) async throws -> [UUID] {
        try await ConversationDomainEventRecipientResolver(db: sourceDB, app: app).recipientUserIDs(for: envelope)
    }

    private func collapsibleActivityOnlyMessageCreatedRun(
        _ envelopes: [ConversationEventEnvelope]
    ) async throws -> (envelope: ConversationEventEnvelope, messageID: UUID, recipientCount: Int)? {
        guard envelopes.count > 1,
              let first = envelopes.first,
              first.eventType == .messageCreated,
              first.payload.messageID != nil
        else {
            return nil
        }
        guard envelopes.allSatisfy({
            $0.eventType == .messageCreated
                && $0.payload.messageID != nil
                && $0.conversationID == first.conversationID
        }) else {
            return nil
        }

        let threshold = app.streamConsumerConfiguration.summaryProjectionMessageCreatedActivityOnlyRecipientThreshold
        guard threshold > 0 else {
            return nil
        }
        guard let recipientCount = try await consistentMessageCreatedRunRecipientCount(envelopes),
              recipientCount >= threshold
        else {
            return nil
        }

        let latestEnvelope = envelopes.max { lhs, rhs in
            lhs.event.aggregateSequence < rhs.event.aggregateSequence
        } ?? first
        guard let latestMessageID = latestEnvelope.payload.messageID else {
            return nil
        }
        return (latestEnvelope, latestMessageID, recipientCount)
    }

    private func consistentMessageCreatedRunRecipientCount(
        _ envelopes: [ConversationEventEnvelope]
    ) async throws -> Int? {
        let inlineRecipientSets = envelopes.map { Set($0.payload.recipientUserIDs) }
        if inlineRecipientSets.allSatisfy({ !$0.isEmpty }) {
            guard let firstRecipientSet = inlineRecipientSets.first,
                  inlineRecipientSets.allSatisfy({ $0 == firstRecipientSet })
            else {
                return nil
            }
            return firstRecipientSet.count
        }

        let eventIDs = envelopes.compactMap(\.eventID)
        if eventIDs.count == envelopes.count {
            let snapshots = try await ConversationDomainEventRecipientSnapshot.query(on: sourceDB)
                .filter(\.$id ~~ eventIDs)
                .all()
            let snapshotsByEventID = Dictionary(
                uniqueKeysWithValues: snapshots.compactMap { snapshot in
                    snapshot.id.map { ($0, snapshot) }
                }
            )
            let orderedSnapshots = eventIDs.compactMap { snapshotsByEventID[$0] }
            if orderedSnapshots.count == envelopes.count {
                let snapshotHashes = orderedSnapshots.map(\.recipientHash)
                if snapshotHashes.allSatisfy({ $0 != nil }) {
                    guard let firstHash = snapshotHashes.first.flatMap({ $0 }),
                          snapshotHashes.allSatisfy({ $0 == firstHash })
                    else {
                        return nil
                    }
                    return orderedSnapshots[0].recipientCount
                }

                var snapshotRecipientSets: [Set<UUID>] = []
                snapshotRecipientSets.reserveCapacity(orderedSnapshots.count)
                for snapshot in orderedSnapshots {
                    snapshotRecipientSets.append(Set(try await snapshot.recipientUserIDs(on: sourceDB)))
                }
                guard let firstRecipientSet = snapshotRecipientSets.first,
                      snapshotRecipientSets.allSatisfy({ $0 == firstRecipientSet })
                else {
                    return nil
                }
                return firstRecipientSet.count
            }
        }

        return try await messageCreatedRecipientCountHint(for: envelopes[0])
    }

    private func activityOnlyRecipientCountIfNeeded(
        for envelope: ConversationEventEnvelope
    ) async throws -> Int? {
        let threshold = app.streamConsumerConfiguration.summaryProjectionMessageCreatedActivityOnlyRecipientThreshold
        guard threshold > 0,
              envelope.eventType == .messageCreated,
              envelope.payload.messageID != nil
        else {
            return nil
        }
        let recipientCount = try await messageCreatedRecipientCountHint(for: envelope)
        return recipientCount >= threshold ? recipientCount : nil
    }

    private func messageCreatedRecipientCountHint(for envelope: ConversationEventEnvelope) async throws -> Int {
        let inlineCount = Set(envelope.payload.recipientUserIDs).count
        if inlineCount > 0 {
            return inlineCount
        }
        guard let eventID = envelope.eventID,
              let snapshot = try await ConversationDomainEventRecipientSnapshot.find(eventID, on: sourceDB)
        else {
            if app.streamConsumerConfiguration.streamConsumerRequiresMessageCreatedRecipientSnapshot {
                await app.conversationDomainEventMetrics.recordRecipientResolutionMissingSnapshot()
                throw ConversationEventTransientProcessingError.messageCreatedRecipientSnapshotMissing(
                    eventID: envelope.eventID,
                    conversationID: envelope.conversationID
                )
            }
            return try await ConversationMember.query(on: sourceDB)
                .filter(\.$conversation.$id == envelope.conversationID)
                .count()
        }
        return snapshot.recipientCount
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
                        readModelDB: target.readModelDB,
                        streamConsumerConfiguration: app.streamConsumerConfiguration,
                        domainEventMetrics: app.conversationDomainEventMetrics,
                        activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
                    ).recordConversationRemovedChange(
                        conversationID: envelope.conversationID,
                        recipientUserID: affectedUserID
                    )
                }
            }
        case .messageCreated,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
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
                    readModelDB: target.readModelDB,
                    streamConsumerConfiguration: app.streamConsumerConfiguration,
                    domainEventMetrics: app.conversationDomainEventMetrics,
                    activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
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

struct ConversationRealtimeConsumer: ConversationEventConsumer {
    enum PayloadDetail: Sendable {
        case full
        case lightweightMessageCreatedIfLarge
        case activeCompactMessageCreatedIfLarge
        case fullMessageCreatedWithoutSummaryIfLarge
    }

    struct DomainEventPayloadBatch: Sendable {
        let payload: IMTCPChatDomainEventPayload
        let recipientUserIDs: [UUID]
        let fanoutIntent: IMGatewayDomainEventFanoutIntent

        init(
            payload: IMTCPChatDomainEventPayload,
            recipientUserIDs: [UUID],
            fanoutIntent: IMGatewayDomainEventFanoutIntent = .unspecified
        ) {
            self.payload = payload
            self.recipientUserIDs = recipientUserIDs
            self.fanoutIntent = fanoutIntent
        }
    }

    private struct LightweightMessagePreview: Sendable {
        let id: UUID
        let senderUserID: UUID
        let serverSequence: UInt64
        let timelineSequence: UInt64
        let previewText: String
        let createdAt: Date?
    }

    let app: Application
    let sourceDB: any Database

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard envelope.eventID != nil else {
            return
        }
        let payloads = try await domainEventPayloads(for: envelope, detail: .lightweightMessageCreatedIfLarge)
        await app.gatewaySessionService.sendDomainEventPayloads(
            payloads.map { recipientUserID, payload in
                IMCanonicalDomainEventDelivery(
                    ownerUserID: recipientUserID,
                    eventID: payload.eventID,
                    payload: payload
                )
            },
            requestID: envelope.eventID
        )
    }

    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        guard !envelopes.isEmpty else {
            return
        }
        let sharedResolvedRecipients = try await sharedMessageCreatedRunRecipients(for: envelopes)
        let payloadSourceEnvelopes = shouldCollapseLightweightMessageCreatedRun(
            envelopes,
            resolvedRecipients: sharedResolvedRecipients
        )
            ? Array(envelopes.suffix(1))
            : envelopes
        var deliveries: [IMCanonicalDomainEventDelivery] = []
        var requestID: UUID?
        for envelope in payloadSourceEnvelopes {
            guard envelope.eventType == .messageCreated,
                  envelope.payload.messageID != nil
            else {
                throw Abort(.internalServerError, reason: "messageCreated run realtime delivery only accepts message_created events with messageID.")
            }
            guard envelope.eventID != nil else {
                continue
            }
            requestID = requestID ?? envelope.eventID
            let payloads = try await domainEventPayloads(
                for: envelope,
                detail: .lightweightMessageCreatedIfLarge,
                resolvedRecipients: sharedResolvedRecipients
            )
            deliveries.append(
                contentsOf: payloads.map { recipientUserID, payload in
                    IMCanonicalDomainEventDelivery(
                        ownerUserID: recipientUserID,
                        eventID: payload.eventID,
                        payload: payload
                    )
                }
            )
        }
        await app.gatewaySessionService.sendDomainEventPayloads(deliveries, requestID: requestID)
    }

    func domainEventPayloads(
        for envelope: ConversationEventEnvelope,
        detail: PayloadDetail = .full,
        resolvedRecipients: ConversationDomainEventResolvedRecipients? = nil
    ) async throws -> [(UUID, IMTCPChatDomainEventPayload)] {
        let batches = try await domainEventPayloadBatches(
            for: envelope,
            detail: detail,
            resolvedRecipients: resolvedRecipients
        )
        return batches.flatMap { batch in
            batch.recipientUserIDs.map { recipientUserID in
                (recipientUserID, batch.payload)
            }
        }
    }

    func domainEventPayloadBatches(
        for envelope: ConversationEventEnvelope,
        detail: PayloadDetail = .full,
        resolvedRecipients: ConversationDomainEventResolvedRecipients? = nil
    ) async throws -> [DomainEventPayloadBatch] {
        let recipientUserIDs = try await resolvedRecipientUserIDs(
            for: envelope,
            resolvedRecipients: resolvedRecipients
        )
        guard !recipientUserIDs.isEmpty else {
            return []
        }

        guard let eventID = envelope.eventID else {
            throw Abort(.internalServerError, reason: "领域事件缺少 eventID。")
        }
        guard envelope.event.aggregateSequence > 0 else {
            throw Abort(.internalServerError, reason: "领域事件缺少 aggregate_sequence。")
        }
        let aggregateSequence = UInt64(envelope.event.aggregateSequence)
        let shouldUseLightweightMessageCreated = shouldUseLightweightMessageCreatedPayload(
            for: envelope,
            recipientCount: recipientUserIDs.count,
            detail: detail
        )
        let shouldOmitConversationSummary = shouldOmitMessageCreatedConversationSummary(
            for: envelope,
            recipientCount: recipientUserIDs.count,
            detail: detail
        )
        let payloadBatches: [DomainEventPayloadBatch]
        if shouldUseLightweightMessageCreated,
           let lightweightPreview = try await lightweightMessagePreview(for: envelope) {
            if detail == .activeCompactMessageCreatedIfLarge {
                payloadBatches = [
                    DomainEventPayloadBatch(
                        payload: activeCompactMessageCreatedPayload(
                            from: lightweightPreview,
                            eventID: lightweightMessageCreatedHintEventID(for: eventID),
                            conversationID: envelope.conversationID,
                            aggregateSequence: aggregateSequence,
                            occurredAt: envelope.event.createdAt,
                            actorUserID: envelope.event.actorUserID
                        ),
                        recipientUserIDs: recipientUserIDs
                    )
                ]
            } else {
                let activityHint = lightweightConversationActivityHint(
                    from: lightweightPreview,
                    updatedAt: envelope.event.createdAt,
                    maxPreviewCharacters: previewMaxCharacters(for: detail)
                )
                let payload = IMTCPChatDomainEventPayload(
                    eventID: lightweightMessageCreatedHintEventID(for: eventID),
                    eventType: .conversationActivityHint,
                    aggregateType: "conversation",
                    aggregateID: envelope.conversationID,
                    aggregateSequence: aggregateSequence,
                    occurredAt: envelope.event.createdAt,
                    actorUserID: envelope.event.actorUserID,
                    conversation: nil,
                    requiresTimelineNotice: false,
                    body: .conversationActivityHint(activityHint)
                )
                payloadBatches = [DomainEventPayloadBatch(payload: payload, recipientUserIDs: recipientUserIDs)]
            }
        } else {
            let message = try await messageResponse(for: envelope)
            let body = try domainEventBody(for: envelope, message: message)
            let conversationsByRecipient: [UUID: IMConversationResponse]
            if shouldOmitConversationSummary {
                conversationsByRecipient = [:]
            } else if envelope.eventType.shouldIncludeRealtimeConversationSummary {
                conversationsByRecipient = await conversationSummaries(
                    for: envelope.conversationID,
                    recipientUserIDs: recipientUserIDs,
                    includeMemberUserIDs: envelope.eventType.shouldIncludeRealtimeSummaryMemberUserIDs
                )
            } else {
                conversationsByRecipient = [:]
            }

            if conversationsByRecipient.isEmpty {
                let payload = IMTCPChatDomainEventPayload(
                    eventID: eventID,
                    eventType: envelope.eventType.chatDomainEventType,
                    aggregateType: "conversation",
                    aggregateID: envelope.conversationID,
                    aggregateSequence: aggregateSequence,
                    occurredAt: envelope.event.createdAt,
                    actorUserID: envelope.event.actorUserID,
                    conversation: nil,
                    requiresTimelineNotice: envelope.eventType.requiresTimelineNotice,
                    body: body
                )
                payloadBatches = [DomainEventPayloadBatch(payload: payload, recipientUserIDs: recipientUserIDs)]
            } else {
                payloadBatches = recipientUserIDs.map { recipientUserID in
                    let payload = IMTCPChatDomainEventPayload(
                        eventID: eventID,
                        eventType: envelope.eventType.chatDomainEventType,
                        aggregateType: "conversation",
                        aggregateID: envelope.conversationID,
                        aggregateSequence: aggregateSequence,
                        occurredAt: envelope.event.createdAt,
                        actorUserID: envelope.event.actorUserID,
                        conversation: conversationsByRecipient[recipientUserID],
                        requiresTimelineNotice: envelope.eventType.requiresTimelineNotice,
                        body: body
                    )
                    return DomainEventPayloadBatch(payload: payload, recipientUserIDs: [recipientUserID])
                }
            }
        }
        return payloadBatches
    }

    private func shouldUseLightweightMessageCreatedPayload(
        for envelope: ConversationEventEnvelope,
        recipientCount: Int,
        detail: PayloadDetail
    ) -> Bool {
        guard detail == .lightweightMessageCreatedIfLarge || detail == .activeCompactMessageCreatedIfLarge,
              envelope.eventType == .messageCreated
        else {
            return false
        }
        let threshold = app.streamConsumerConfiguration.realtimeMessageCreatedLightweightRecipientThreshold
        return threshold > 0 && recipientCount >= threshold
    }

    private func shouldOmitMessageCreatedConversationSummary(
        for envelope: ConversationEventEnvelope,
        recipientCount: Int,
        detail: PayloadDetail
    ) -> Bool {
        guard detail == .fullMessageCreatedWithoutSummaryIfLarge,
              envelope.eventType == .messageCreated
        else {
            return false
        }
        let threshold = app.streamConsumerConfiguration.realtimeMessageCreatedLightweightRecipientThreshold
        return threshold > 0 && recipientCount >= threshold
    }

    private func shouldCollapseLightweightMessageCreatedRun(
        _ envelopes: [ConversationEventEnvelope],
        resolvedRecipients: ConversationDomainEventResolvedRecipients?
    ) -> Bool {
        guard envelopes.count > 1,
              let resolvedRecipients,
              let first = envelopes.first,
              first.eventType == .messageCreated,
              first.payload.messageID != nil
        else {
            return false
        }
        guard envelopes.allSatisfy({
            $0.eventType == .messageCreated
                && $0.payload.messageID != nil
                && $0.conversationID == first.conversationID
        }) else {
            return false
        }
        let threshold = app.streamConsumerConfiguration.realtimeMessageCreatedLightweightRecipientThreshold
        return threshold > 0 && resolvedRecipients.userIDs.count >= threshold
    }

    private func sharedMessageCreatedRunRecipients(
        for envelopes: [ConversationEventEnvelope]
    ) async throws -> ConversationDomainEventResolvedRecipients? {
        try await sharedResolvedMessageCreatedRunRecipients(
            for: envelopes,
            sourceDB: sourceDB,
            app: app
        )
    }

    private func lightweightMessageCreatedHintEventID(for eventID: UUID) -> UUID {
        imLightweightMessageCreatedHintEventID(for: eventID)
    }

    private func resolvedRecipientUserIDs(
        for envelope: ConversationEventEnvelope,
        resolvedRecipients: ConversationDomainEventResolvedRecipients?
    ) async throws -> [UUID] {
        if let resolvedRecipients {
            return resolvedRecipients.userIDs
        }
        return try await ConversationDomainEventRecipientResolver(db: sourceDB, app: app)
            .resolveRecipients(for: envelope)
            .userIDs
    }

    private func lightweightConversationActivityHint(
        from message: LightweightMessagePreview,
        updatedAt: Date,
        maxPreviewCharacters: Int? = nil
    ) -> IMConversationActivityHint {
        let maxCharacters = maxPreviewCharacters
            ?? app.streamConsumerConfiguration.realtimeMessageCreatedLightweightPreviewMaxCharacters
        let preview = truncatedPreview(message.previewText, maxCharacters: maxCharacters)
        return IMConversationActivityHint(
            messageID: message.id,
            senderUserID: message.senderUserID,
            serverSequence: message.serverSequence,
            timelineSequence: message.timelineSequence,
            previewText: preview,
            messageCreatedAt: preview.isEmpty ? nil : message.createdAt,
            updatedAt: updatedAt
        )
    }

    private func activeCompactMessageCreatedPayload(
        from message: LightweightMessagePreview,
        eventID: UUID,
        conversationID: UUID,
        aggregateSequence: UInt64,
        occurredAt: Date,
        actorUserID: UUID?
    ) -> IMTCPChatDomainEventPayload {
        return IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: .conversationActivityHint,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: nil,
            requiresTimelineNotice: false,
            body: .conversationActivityHint(
                lightweightConversationActivityHint(
                    from: message,
                    updatedAt: occurredAt,
                    maxPreviewCharacters: previewMaxCharacters(for: .activeCompactMessageCreatedIfLarge)
                )
            )
        )
    }

    private func previewMaxCharacters(for detail: PayloadDetail) -> Int {
        switch detail {
        case .activeCompactMessageCreatedIfLarge:
            return app.streamConsumerConfiguration.realtimeActiveCompactHintPreviewMaxCharacters
        case .full, .lightweightMessageCreatedIfLarge, .fullMessageCreatedWithoutSummaryIfLarge:
            return app.streamConsumerConfiguration.realtimeMessageCreatedLightweightPreviewMaxCharacters
        }
    }

    private func lightweightMessagePreview(for envelope: ConversationEventEnvelope) async throws -> LightweightMessagePreview? {
        guard envelope.eventType == .messageCreated,
              let messageID = envelope.payload.messageID
        else {
            return nil
        }
        if let preview = envelope.payload.messageCreatedPreview {
            await app.conversationDomainEventMetrics.recordMessageCreatedEmbeddedPreviewUsed()
            return LightweightMessagePreview(
                id: messageID,
                senderUserID: preview.senderUserID,
                serverSequence: preview.serverSequence,
                timelineSequence: preview.timelineSequence,
                previewText: preview.previewText,
                createdAt: preview.createdAt
            )
        }
        guard app.streamConsumerConfiguration.realtimeMessageCreatedPreviewLookupEnabled else {
            await app.conversationDomainEventMetrics.recordMessageCreatedPreviewMissing()
            guard let actorUserID = envelope.event.actorUserID,
                  envelope.event.aggregateSequence > 0
            else {
                return nil
            }
            let sequence = UInt64(envelope.event.aggregateSequence)
            return LightweightMessagePreview(
                id: messageID,
                senderUserID: actorUserID,
                serverSequence: sequence,
                timelineSequence: sequence,
                previewText: "",
                createdAt: envelope.event.createdAt
            )
        }
        guard let message = try await ConversationMessage.find(messageID, on: sourceDB) else {
            await app.conversationDomainEventMetrics.recordMessageCreatedPreviewMissing()
            return nil
        }
        await app.conversationDomainEventMetrics.recordMessageCreatedPreviewMessageLookup()
        let content = try message.decodedContent()
        return try LightweightMessagePreview(
            id: message.requireID(),
            senderUserID: message.$sender.id,
            serverSequence: imPositiveUInt64Sequence(message.serverSequence, field: "server_sequence"),
            timelineSequence: imPositiveUInt64Sequence(message.timelineSequence, field: "timeline_sequence"),
            previewText: content.previewText,
            createdAt: message.createdAt
        )
    }

    private func truncatedPreview(_ preview: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else {
            return ""
        }
        guard maxCharacters > 0, preview.count > maxCharacters else {
            return preview
        }
        return String(preview.prefix(maxCharacters))
    }

    private func conversationSummaries(
        for conversationID: UUID,
        recipientUserIDs: [UUID],
        includeMemberUserIDs: Bool
    ) async -> [UUID: IMConversationResponse] {
        let targets = summaryProjectionTargets(app: app, recipientUserIDs: recipientUserIDs)
        guard !targets.isEmpty else {
            return [:]
        }

        var results: [UUID: IMConversationResponse] = [:]
        await withTaskGroup(of: [(UUID, IMConversationResponse)].self) { group in
            for target in targets {
                group.addTask {
                    let recordIDs = target.recipientUserIDs.map {
                        ConversationUserSummary.recordID(ownerUserID: $0, conversationID: conversationID)
                    }
                    do {
                        let summaries = try await ConversationUserSummary.query(on: target.readModelDB)
                            .filter(\.$id ~~ recordIDs)
                            .all()
                        return summaries.compactMap { summary in
                            guard !summary.isRemoved else {
                                return nil
                            }
                            return (
                                summary.ownerUserID,
                                Self.makeConversationResponse(
                                    from: summary,
                                    includeMemberUserIDs: includeMemberUserIDs,
                                    memberUserIDsLimit: app.summaryReadModelConfiguration.responseMemberUserIDsLimit
                                )
                            )
                        }
                    } catch {
                        app.logger.warning(
                            "Realtime conversation summary batch read failed conversationID=\(conversationID.uuidString) recipients=\(target.recipientUserIDs.count) error=\(error)"
                        )
                        return []
                    }
                }
            }

            for await batch in group {
                for (recipientUserID, response) in batch {
                    results[recipientUserID] = response
                }
            }
        }
        return results
    }

    private static func makeConversationResponse(
        from row: ConversationUserSummary,
        includeMemberUserIDs: Bool = true,
        memberUserIDsLimit: Int = 0
    ) -> IMConversationResponse {
        let memberUserIDs: [UUID]
        if includeMemberUserIDs,
           (memberUserIDsLimit <= 0 || row.memberCount <= memberUserIDsLimit) {
            memberUserIDs = row.memberUserIDs.sorted { $0.uuidString < $1.uuidString }
        } else {
            memberUserIDs = []
        }

        return IMConversationResponse(
            id: row.conversationID,
            title: row.title,
            kind: row.kind,
            directMessagingState: row.directMessagingState,
            directPeer: row.directPeerUserID.map { directPeerUserID in
                IMDirectPeerResponse(
                    id: directPeerUserID,
                    email: row.directPeerEmail ?? "",
                    displayName: row.directPeerDisplayName,
                    avatarPreset: row.directPeerAvatarPresetEnum
                )
            },
            notice: row.notice,
            avatarPreset: row.avatarPresetEnum,
            muteAll: row.muteAll,
            memberCount: row.memberCount,
            memberUserIDs: memberUserIDs,
            lastMessage: row.lastMessage,
            lastReadSequence: UInt64(row.lastReadSequence),
            unreadCount: row.unreadCount,
            isPinned: row.isPinned,
            pinnedAt: row.pinnedAt,
            isMuted: row.isMuted,
            createdAt: nil,
            updatedAt: row.lastActivityAt
        )
    }

    private func messageResponse(for envelope: ConversationEventEnvelope) async throws -> IMMessageResponse? {
        guard let messageID = envelope.payload.messageID ?? envelope.payload.favoriteChangedMessageID else {
            return nil
        }
        guard let message = try await ConversationMessage.find(messageID, on: sourceDB) else {
            return nil
        }
        return try ConversationMessageService(db: sourceDB).messageResponse(
            from: message,
            conversationID: envelope.conversationID
        )
    }

    private func domainEventBody(
        for envelope: ConversationEventEnvelope,
        message: IMMessageResponse?
    ) throws -> IMTCPChatDomainEventBody {
        switch envelope.eventType {
        case .messageCreated:
            guard let message else {
                throw Abort(.internalServerError, reason: "message_created 缺少消息正文。")
            }
            return .messageCreated(message: message, clientMessageID: message.clientMessageID)
        case .messageUpdated:
            guard let messageID = envelope.payload.messageID else {
                throw Abort(.internalServerError, reason: "message_edited 缺少 messageID。")
            }
            let body = message.flatMap { richTextBody(from: $0.content) } ?? .plain(message?.content.previewText ?? "")
            return .messageEdited(
                messageID: messageID,
                body: body,
                editedAt: message?.derivedState.edits.last?.editedAt ?? envelope.event.createdAt,
                message: message
            )
        case .messageRecalled:
            guard let messageID = envelope.payload.messageID else {
                throw Abort(.internalServerError, reason: "message_revoked 缺少 messageID。")
            }
            return .messageRevoked(
                messageID: messageID,
                revokedAt: envelope.event.createdAt,
                revokedByUserID: envelope.event.actorUserID,
                message: message
            )
        case .messageVisibilityChanged:
            return .messageVisibilityChanged(
                messageIDs: envelope.payload.messageIDs,
                message: message,
                visibilityAction: envelope.payload.visibilityAction
            )
        case .messageFavoriteChanged:
            guard let messageID = envelope.payload.favoriteChangedMessageID else {
                throw Abort(.internalServerError, reason: "message_favorite_changed 缺少 messageID。")
            }
            return .messageFavoriteChanged(
                messageID: messageID,
                isFavorited: envelope.payload.isFavorited ?? false
            )
        case .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled:
            return .messageStream(
                try streamPayload(for: envelope),
                message: message
            )
        case .conversationRemovedForUser:
            return .conversationRemovedForSelf
        case .conversationVisibilityChanged:
            return .conversationVisibilityChanged(
                visibilityAction: envelope.payload.visibilityAction ?? .conversationCleared,
                messageIDs: envelope.payload.messageIDs
            )
        case .membershipAdded:
            return .memberChanged(memberUserIDs: envelope.payload.recipientUserIDs)
        case .membershipRemoved:
            return .memberChanged(memberUserIDs: envelope.payload.affectedUserID.map { [$0] } ?? [])
        case .membershipRoleUpdated:
            return .memberChanged(memberUserIDs: envelope.payload.affectedUserID.map { [$0] } ?? [])
        case .metadataUpdated,
             .directPeerUpdated,
             .conversationSettingsChanged,
             .inviteChanged,
             .readAdvanced:
            return .conversationChanged
        }
    }

    private func streamPayload(for envelope: ConversationEventEnvelope) throws -> IMTCPMessageStreamPayload {
        guard let messageID = envelope.payload.messageID,
              let streamID = envelope.payload.streamID
        else {
            throw Abort(.internalServerError, reason: "message_stream 事件缺少 messageID 或 streamID。")
        }
        let state: MessageStreamLifecycleState
        switch envelope.eventType {
        case .messageStreamStarted:
            state = .streaming
        case .messageStreamCompleted:
            state = .completed
        case .messageStreamFailed:
            state = .failed
        case .messageStreamCancelled:
            state = .cancelled
        default:
            throw Abort(.internalServerError, reason: "非 stream 事件不能构造 stream payload。")
        }
        return IMTCPMessageStreamPayload(
            streamID: streamID,
            messageID: messageID.uuidString,
            conversationID: envelope.conversationID.uuidString,
            chunkIndex: 0,
            deltaText: nil,
            partialTextLength: 0,
            state: state,
            serverTimestamp: envelope.event.createdAt
        )
    }

    private func richTextBody(from content: IMMessageContent) -> IMRichTextContent? {
        switch content {
        case .richText(let body):
            return body
        case .reply(_, let body):
            return body
        case .image, .audio, .file:
            return nil
        }
    }
}

struct ConversationRealtimeDeliveryConsumer: ConversationEventConsumer {
    private struct ActiveConversationFanoutSplit: Sendable {
        var activeFullBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch] = []
        var activeCompactBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch] = []
        var activeFullRecipientCount = 0
        var activeCompactRecipientCount = 0
        var downgradedActiveRecipientCount = 0
        var routeMilliseconds = 0
        var didSplit = false
    }

    private struct ActiveConversationFanoutPlan: Sendable {
        let fullActiveUserIDs: [UUID]
        let compactActiveUserIDs: [UUID]
        let downgradedActiveUserIDs: [UUID]
    }

    private struct ActiveConversationRouteCacheKey: Hashable, Sendable {
        let conversationID: UUID
        let recipientUserIDs: Set<UUID>
    }

    let app: Application
    let sourceDB: any Database

    var supportedEventTypes: Set<ConversationDomainEventType> {
        [.messageCreated]
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        try await consumeMessageCreatedEnvelopes([envelope])
    }

    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        guard !envelopes.isEmpty else {
            return
        }
        let conversationID = envelopes[0].conversationID
        guard envelopes.allSatisfy({
            $0.eventType == .messageCreated
                && $0.payload.messageID != nil
                && $0.conversationID == conversationID
        }) else {
            for envelope in envelopes {
                try await consume(envelope)
            }
            return
        }
        try await consumeMessageCreatedEnvelopes(envelopes)
    }

    private func consumeMessageCreatedEnvelopes(_ envelopes: [ConversationEventEnvelope]) async throws {
        guard !envelopes.isEmpty else {
            return
        }
        let startedAt = Date()
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        let eventLagMilliseconds = envelopes.map {
            IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(from: $0.event.createdAt, to: startedAt)
        }.max() ?? 0
        let realtimeConsumer = ConversationRealtimeConsumer(app: app, sourceDB: sourceDB)
        let payloadDetail: ConversationRealtimeConsumer.PayloadDetail = .fullMessageCreatedWithoutSummaryIfLarge
        let sharedResolvedRecipients = shouldDeferMessageCreatedRunRecipientResolutionForActiveOnlyFanout(envelopes)
            ? nil
            : try await sharedMessageCreatedRunRecipients(for: envelopes)
        let payloadSourceEnvelopes = envelopes
        let requestID = payloadSourceEnvelopes.first?.eventID
        guard app.streamConsumerConfiguration.realtimeDeliveryAsyncRelayEnabled else {
            let split = try await preparedMessageCreatedFanoutSplit(
                envelopes: payloadSourceEnvelopes,
                realtimeConsumer: realtimeConsumer,
                payloadDetail: payloadDetail,
                sharedResolvedRecipients: sharedResolvedRecipients
            )
            let relayBatches = split.activeFullBatches
                + split.activeCompactBatches
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                relayBatches.map {
                    IMGatewayDomainEventPayloadBatch(
                        payload: $0.payload,
                        recipientUserIDs: $0.recipientUserIDs,
                        fanoutIntent: $0.fanoutIntent
                    )
                },
                requestID: requestID
            )
            let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
            if IMRealtimeDeliveryDiagnostics.shouldLogAny(
                [eventLagMilliseconds, totalMilliseconds],
                thresholdMilliseconds: slowLogMilliseconds
            ) {
                app.logger.info("Realtime delivery consumer slow synchronous relay.", metadata: [
                    "event_id": .string(requestID?.uuidString ?? ""),
                    "conversation_id": .string(envelopes.first?.conversationID.uuidString ?? ""),
                    "event_type": .string(ConversationDomainEventType.messageCreated.rawValue),
                    "event_count": .stringConvertible(envelopes.count),
                    "recipient_count": .stringConvertible(relayBatches.reduce(0) { $0 + $1.recipientUserIDs.count }),
                    "payload_batch_count": .stringConvertible(relayBatches.count),
                    "active_full_recipient_count": .stringConvertible(split.activeFullRecipientCount),
                    "active_compact_recipient_count": .stringConvertible(split.activeCompactRecipientCount),
                    "downgraded_active_recipient_count": .stringConvertible(split.downgradedActiveRecipientCount),
                    "active_route_ms": .stringConvertible(split.routeMilliseconds),
                    "lightweight_threshold": .stringConvertible(app.streamConsumerConfiguration.realtimeMessageCreatedLightweightRecipientThreshold),
                    "event_lag_ms": .stringConvertible(eventLagMilliseconds),
                    "total_ms": .stringConvertible(totalMilliseconds)
                ])
            }
            return
        }

        let payloadStartedAt = Date()
        let split = try await preparedMessageCreatedFanoutSplit(
            envelopes: payloadSourceEnvelopes,
            realtimeConsumer: realtimeConsumer,
            payloadDetail: payloadDetail,
            sharedResolvedRecipients: sharedResolvedRecipients
        )
        let payloadBuildMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: payloadStartedAt)
        let splitMilliseconds = split.routeMilliseconds
        let activeFullRecipientCount = split.activeFullRecipientCount
        let activeCompactRecipientCount = split.activeCompactRecipientCount
        let downgradedActiveRecipientCount = split.downgradedActiveRecipientCount
        let activeFullBatches = split.activeFullBatches
        let activeCompactBatches = split.activeCompactBatches
        let recipientCount = activeFullBatches.reduce(0) { $0 + $1.recipientUserIDs.count }
            + activeCompactBatches.reduce(0) { $0 + $1.recipientUserIDs.count }
        let dispatchStartedAt = Date()
        if !activeFullBatches.isEmpty {
            await app.realtimeDeliveryAsyncDispatcher.dispatchPayloadBatches(
                activeFullBatches,
                requestID: requestID,
                coalescingKey: nil,
                coalescingWindowMilliseconds: 0
            )
        }
        if !activeCompactBatches.isEmpty {
            let coalescingWindowMilliseconds = activeCompactHintCoalescingWindowMilliseconds(
                for: envelopes,
                recipientCount: activeCompactRecipientCount
            )
            await app.realtimeDeliveryAsyncDispatcher.dispatchPayloadBatches(
                activeCompactBatches,
                requestID: requestID,
                coalescingKey: coalescingWindowMilliseconds > 0 ? envelopes.first?.conversationID : nil,
                coalescingScope: .activeCompactHint,
                coalescingWindowMilliseconds: coalescingWindowMilliseconds
            )
        }
        let dispatchEnqueueMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: dispatchStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [eventLagMilliseconds, payloadBuildMilliseconds, splitMilliseconds, dispatchEnqueueMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Realtime delivery consumer slow async enqueue.", metadata: [
                "event_id": .string(requestID?.uuidString ?? ""),
                "conversation_id": .string(envelopes.first?.conversationID.uuidString ?? ""),
                "event_type": .string(ConversationDomainEventType.messageCreated.rawValue),
                "event_count": .stringConvertible(envelopes.count),
                "recipient_count": .stringConvertible(recipientCount),
                "payload_batch_count": .stringConvertible(activeFullBatches.count + activeCompactBatches.count),
                "active_full_recipient_count": .stringConvertible(activeFullRecipientCount),
                "active_compact_recipient_count": .stringConvertible(activeCompactRecipientCount),
                "downgraded_active_recipient_count": .stringConvertible(downgradedActiveRecipientCount),
                "lightweight_threshold": .stringConvertible(app.streamConsumerConfiguration.realtimeMessageCreatedLightweightRecipientThreshold),
                "active_compact_coalescing_window_ms": .stringConvertible(activeCompactHintCoalescingWindowMilliseconds(
                    for: envelopes,
                    recipientCount: activeCompactRecipientCount
                )),
                "event_lag_ms": .stringConvertible(eventLagMilliseconds),
                "payload_build_ms": .stringConvertible(payloadBuildMilliseconds),
                "split_ms": .stringConvertible(splitMilliseconds),
                "active_route_ms": .stringConvertible(split.routeMilliseconds),
                "dispatch_enqueue_ms": .stringConvertible(dispatchEnqueueMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds)
            ])
        }
    }

    private func preparedMessageCreatedFanoutSplit(
        envelopes: [ConversationEventEnvelope],
        realtimeConsumer: ConversationRealtimeConsumer,
        payloadDetail: ConversationRealtimeConsumer.PayloadDetail,
        sharedResolvedRecipients: ConversationDomainEventResolvedRecipients?
    ) async throws -> ActiveConversationFanoutSplit {
        if let preSplit = try await preSplitLargeGroupMessageCreatedFanoutBeforePayloadBuild(
            envelopes: envelopes,
            realtimeConsumer: realtimeConsumer,
            sharedResolvedRecipients: sharedResolvedRecipients
        ) {
            return preSplit
        }

        var payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch] = []
        for envelope in envelopes {
            payloadBatches.append(
                contentsOf: try await realtimeConsumer.domainEventPayloadBatches(
                    for: envelope,
                    detail: payloadDetail,
                    resolvedRecipients: sharedResolvedRecipients
                )
            )
        }
        return await splitActiveConversationFanoutIfNeeded(payloadBatches)
    }

    private func shouldDeferMessageCreatedRunRecipientResolutionForActiveOnlyFanout(
        _ envelopes: [ConversationEventEnvelope]
    ) -> Bool {
        guard app.gatewayLocalFanoutConfiguration.activeConversationFanoutEnabled,
              app.hasConnectionRoutingServiceConfigured,
              let first = envelopes.first,
              first.eventType == .messageCreated,
              first.payload.messageID != nil
        else {
            return false
        }
        return envelopes.allSatisfy {
            $0.eventType == .messageCreated
                && $0.payload.messageID != nil
                && $0.conversationID == first.conversationID
        }
    }

    private func messageCreatedRecipientCountHint(
        for envelope: ConversationEventEnvelope
    ) async throws -> Int {
        let inlineCount = Set(envelope.payload.recipientUserIDs).count
        if inlineCount > 0 {
            return inlineCount
        }
        guard let eventID = envelope.eventID,
              let snapshot = try await ConversationDomainEventRecipientSnapshot.find(eventID, on: sourceDB)
        else {
            if app.streamConsumerConfiguration.streamConsumerRequiresMessageCreatedRecipientSnapshot {
                await app.conversationDomainEventMetrics.recordRecipientResolutionMissingSnapshot()
                throw ConversationEventTransientProcessingError.messageCreatedRecipientSnapshotMissing(
                    eventID: envelope.eventID,
                    conversationID: envelope.conversationID
                )
            }
            return try await ConversationMember.query(on: sourceDB)
                .filter(\.$conversation.$id == envelope.conversationID)
                .count()
        }
        return snapshot.recipientCount
    }

    private func preSplitLargeGroupMessageCreatedFanoutBeforePayloadBuild(
        envelopes: [ConversationEventEnvelope],
        realtimeConsumer: ConversationRealtimeConsumer,
        sharedResolvedRecipients: ConversationDomainEventResolvedRecipients?
    ) async throws -> ActiveConversationFanoutSplit? {
        guard app.gatewayLocalFanoutConfiguration.activeConversationFanoutEnabled,
              app.hasConnectionRoutingServiceConfigured,
              let first = envelopes.first,
              first.eventType == .messageCreated,
              first.payload.messageID != nil
        else {
            return nil
        }
        guard envelopes.allSatisfy({
            $0.eventType == .messageCreated
                && $0.payload.messageID != nil
                && $0.conversationID == first.conversationID
        }) else {
            return nil
        }

        if let split = try await preSplitPullOnlyMessageCreatedFanoutBeforeRecipientExpansion(
               envelopes: envelopes,
               realtimeConsumer: realtimeConsumer,
               first: first
           )
        {
            return split
        }

        let resolvedRecipients: ConversationDomainEventResolvedRecipients
        if let sharedResolvedRecipients {
            resolvedRecipients = sharedResolvedRecipients
        } else {
            resolvedRecipients = try await ConversationDomainEventRecipientResolver(db: sourceDB, app: app)
                .resolveRecipients(for: first)
        }
        let recipientUserIDs = resolvedRecipients.userIDs
        let recipientCount = recipientUserIDs.count
        let lightweightThreshold = app.streamConsumerConfiguration.realtimeMessageCreatedLightweightRecipientThreshold
        let fanoutThreshold = app.gatewayLocalFanoutConfiguration.activeConversationFanoutRecipientThreshold
        guard lightweightThreshold > 0,
              fanoutThreshold > 0,
              recipientCount >= lightweightThreshold,
              recipientCount >= fanoutThreshold
        else {
            return nil
        }

        let routeStartedAt = Date()
        do {
            let routeLookup = try await activeConversationRoutes(
                app: app,
                conversationID: first.conversationID,
                recipientUserIDs: recipientUserIDs
            )
            let activeRoutes = routeLookup.routes
            var split = ActiveConversationFanoutSplit()
            split.didSplit = true
            split.routeMilliseconds = routeLookup.cacheHit
                ? 0
                : IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: routeStartedAt)

            for envelope in envelopes {
                let aggregateSequence = try imPositiveUInt64Sequence(
                    envelope.event.aggregateSequence,
                    field: "aggregate_sequence"
                )
                var plan = activeConversationFanoutPlan(
                    recipientUserIDs: recipientUserIDs,
                    activeRoutes: activeRoutes,
                    aggregateSequence: aggregateSequence
                )

                let fullBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch]
                if !plan.fullActiveUserIDs.isEmpty {
                    fullBatches = try await realtimeConsumer.domainEventPayloadBatches(
                        for: envelope,
                        detail: .fullMessageCreatedWithoutSummaryIfLarge,
                        resolvedRecipients: resolvedRecipients
                    )
                    if let payload = fullBatches.first?.payload {
                        plan = activeConversationFanoutPlan(
                            recipientUserIDs: recipientUserIDs,
                            activeRoutes: activeRoutes,
                            aggregateSequence: aggregateSequence,
                            payload: payload
                        )
                    }
                    split.activeFullRecipientCount += plan.fullActiveUserIDs.count
                    split.activeCompactRecipientCount += plan.compactActiveUserIDs.count
                    split.downgradedActiveRecipientCount += plan.downgradedActiveUserIDs.count
                    await app.routingMetrics.recordActiveConversationFanoutSplit(
                        activeRecipientCount: plan.fullActiveUserIDs.count,
                        compactActiveRecipientCount: plan.compactActiveUserIDs.count,
                        inactiveHintRecipientCount: 0,
                        downgradedActiveRecipientCount: plan.downgradedActiveUserIDs.count
                    )
                    split.activeFullBatches.append(
                        contentsOf: fullBatches.map {
                            ConversationRealtimeConsumer.DomainEventPayloadBatch(
                                payload: $0.payload,
                                recipientUserIDs: plan.fullActiveUserIDs,
                                fanoutIntent: .preSplitActiveFull
                            )
                        }
                    )
                    if !plan.compactActiveUserIDs.isEmpty {
                        split.activeCompactBatches.append(
                            contentsOf: compactActiveHintBatches(
                                from: fullBatches,
                                recipientUserIDs: plan.compactActiveUserIDs,
                                eventID: envelope.eventID
                            )
                        )
                    }
                } else {
                    fullBatches = []
                    split.activeFullRecipientCount += plan.fullActiveUserIDs.count
                    split.activeCompactRecipientCount += plan.compactActiveUserIDs.count
                    split.downgradedActiveRecipientCount += plan.downgradedActiveUserIDs.count
                    await app.routingMetrics.recordActiveConversationFanoutSplit(
                        activeRecipientCount: plan.fullActiveUserIDs.count,
                        compactActiveRecipientCount: plan.compactActiveUserIDs.count,
                        inactiveHintRecipientCount: 0,
                        downgradedActiveRecipientCount: plan.downgradedActiveUserIDs.count
                    )
                    if !plan.compactActiveUserIDs.isEmpty {
                        let compactBatches = try await realtimeConsumer.domainEventPayloadBatches(
                            for: envelope,
                            detail: .activeCompactMessageCreatedIfLarge,
                            resolvedRecipients: resolvedRecipients
                        )
                        split.activeCompactBatches.append(
                            contentsOf: compactBatches.map {
                                ConversationRealtimeConsumer.DomainEventPayloadBatch(
                                    payload: $0.payload,
                                    recipientUserIDs: plan.compactActiveUserIDs,
                                    fanoutIntent: .preSplitActiveCompact
                                )
                            }
                        )
                    }
                }
            }
            return split
        } catch {
            await app.routingMetrics.recordActiveConversationFanoutRouteSplitDrop(
                recipientCount: recipientCount
            )
            app.logger.warning("Realtime delivery consumer pre-split failed; dropping realtime fanout.", metadata: [
                "conversation_id": .string(first.conversationID.uuidString),
                "recipient_count": .stringConvertible(recipientCount),
                "error": .string(String(describing: error))
            ])
            return ActiveConversationFanoutSplit(didSplit: true)
        }
    }

    private func preSplitPullOnlyMessageCreatedFanoutBeforeRecipientExpansion(
        envelopes: [ConversationEventEnvelope],
        realtimeConsumer: ConversationRealtimeConsumer,
        first: ConversationEventEnvelope
    ) async throws -> ActiveConversationFanoutSplit? {
        guard shouldDeferMessageCreatedRunRecipientResolutionForActiveOnlyFanout(envelopes) else {
            return nil
        }
        let recipientCount = try await messageCreatedRecipientCountHint(for: first)
        let lightweightThreshold = app.streamConsumerConfiguration.realtimeMessageCreatedLightweightRecipientThreshold
        let fanoutThreshold = app.gatewayLocalFanoutConfiguration.activeConversationFanoutRecipientThreshold
        guard lightweightThreshold > 0,
              fanoutThreshold > 0,
              recipientCount >= lightweightThreshold,
              recipientCount >= fanoutThreshold
        else {
            return nil
        }

        let routeStartedAt = Date()
        do {
            let routeLookup = try await activeConversationRoutes(
                app: app,
                conversationID: first.conversationID,
                recipientUserIDs: nil
            )
            let activeCandidateUserIDs = Array(routeLookup.routes.keys)
            let resolvedActiveRecipients = try await ConversationDomainEventRecipientResolver(db: sourceDB, app: app)
                .filterRecipients(for: first, candidateUserIDs: activeCandidateUserIDs)
            let activeRecipientUserIDs = resolvedActiveRecipients.userIDs
            let activeRecipientSet = Set(activeRecipientUserIDs)
            let activeRoutes = routeLookup.routes.filter { activeRecipientSet.contains($0.key) }
            if routeLookup.routes.isEmpty || activeRecipientUserIDs.isEmpty {
                app.logger.info("Realtime delivery consumer active-only pre-split has no active recipients.", metadata: [
                    "conversation_id": .string(first.conversationID.uuidString),
                    "route_count": .stringConvertible(routeLookup.routes.count),
                    "active_candidate_count": .stringConvertible(activeCandidateUserIDs.count),
                    "filtered_active_recipient_count": .stringConvertible(activeRecipientUserIDs.count),
                    "route_cache_hit": .stringConvertible(routeLookup.cacheHit),
                    "route_cache_partial_hit": .stringConvertible(routeLookup.cachePartialHit),
                    "route_cached_user_count": .stringConvertible(routeLookup.cachedUserCount),
                    "route_missed_user_count": .stringConvertible(routeLookup.missedUserCount),
                    "route_joined_in_flight": .stringConvertible(routeLookup.joinedInFlight),
                    "resolved_source": .string(resolvedActiveRecipients.source.rawValue),
                    "recipient_count_hint": .stringConvertible(recipientCount)
                ])
            }
            var split = ActiveConversationFanoutSplit()
            split.didSplit = true
            split.routeMilliseconds = routeLookup.cacheHit
                ? 0
                : IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: routeStartedAt)

            for envelope in envelopes {
                let aggregateSequence = try imPositiveUInt64Sequence(
                    envelope.event.aggregateSequence,
                    field: "aggregate_sequence"
                )
                var plan = activeConversationFanoutPlan(
                    recipientUserIDs: activeRecipientUserIDs,
                    activeRoutes: activeRoutes,
                    aggregateSequence: aggregateSequence
                )

                let fullBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch]
                if !plan.fullActiveUserIDs.isEmpty {
                    let resolvedRecipients = ConversationDomainEventResolvedRecipients(
                        userIDs: activeRecipientUserIDs,
                        source: resolvedActiveRecipients.source
                    )
                    fullBatches = try await realtimeConsumer.domainEventPayloadBatches(
                        for: envelope,
                        detail: .fullMessageCreatedWithoutSummaryIfLarge,
                        resolvedRecipients: resolvedRecipients
                    )
                    if let payload = fullBatches.first?.payload {
                        plan = activeConversationFanoutPlan(
                            recipientUserIDs: activeRecipientUserIDs,
                            activeRoutes: activeRoutes,
                            aggregateSequence: aggregateSequence,
                            payload: payload
                        )
                    }
                    split.activeFullRecipientCount += plan.fullActiveUserIDs.count
                    split.activeCompactRecipientCount += plan.compactActiveUserIDs.count
                    split.downgradedActiveRecipientCount += plan.downgradedActiveUserIDs.count
                    await app.routingMetrics.recordActiveConversationFanoutSplit(
                        activeRecipientCount: plan.fullActiveUserIDs.count,
                        compactActiveRecipientCount: plan.compactActiveUserIDs.count,
                        inactiveHintRecipientCount: 0,
                        downgradedActiveRecipientCount: plan.downgradedActiveUserIDs.count
                    )
                    split.activeFullBatches.append(
                        contentsOf: fullBatches.map {
                            ConversationRealtimeConsumer.DomainEventPayloadBatch(
                                payload: $0.payload,
                                recipientUserIDs: plan.fullActiveUserIDs,
                                fanoutIntent: .preSplitActiveFull
                            )
                        }
                    )
                    if !plan.compactActiveUserIDs.isEmpty {
                        split.activeCompactBatches.append(
                            contentsOf: compactActiveHintBatches(
                                from: fullBatches,
                                recipientUserIDs: plan.compactActiveUserIDs,
                                eventID: envelope.eventID
                            )
                        )
                    }
                } else {
                    fullBatches = []
                    split.activeFullRecipientCount += plan.fullActiveUserIDs.count
                    split.activeCompactRecipientCount += plan.compactActiveUserIDs.count
                    split.downgradedActiveRecipientCount += plan.downgradedActiveUserIDs.count
                    await app.routingMetrics.recordActiveConversationFanoutSplit(
                        activeRecipientCount: plan.fullActiveUserIDs.count,
                        compactActiveRecipientCount: plan.compactActiveUserIDs.count,
                        inactiveHintRecipientCount: 0,
                        downgradedActiveRecipientCount: plan.downgradedActiveUserIDs.count
                    )
                    if !plan.compactActiveUserIDs.isEmpty {
                        let resolvedRecipients = ConversationDomainEventResolvedRecipients(
                            userIDs: activeRecipientUserIDs,
                            source: resolvedActiveRecipients.source
                        )
                        let compactBatches = try await realtimeConsumer.domainEventPayloadBatches(
                            for: envelope,
                            detail: .activeCompactMessageCreatedIfLarge,
                            resolvedRecipients: resolvedRecipients
                        )
                        split.activeCompactBatches.append(
                            contentsOf: compactBatches.map {
                                ConversationRealtimeConsumer.DomainEventPayloadBatch(
                                    payload: $0.payload,
                                    recipientUserIDs: plan.compactActiveUserIDs,
                                    fanoutIntent: .preSplitActiveCompact
                                )
                            }
                        )
                    }
                }
            }
            return split
        } catch {
            await app.routingMetrics.recordActiveConversationFanoutRouteSplitDrop(
                recipientCount: recipientCount
            )
            app.logger.warning("Realtime delivery consumer pull-only pre-split failed; dropping realtime fanout.", metadata: [
                "conversation_id": .string(first.conversationID.uuidString),
                "recipient_count": .stringConvertible(recipientCount),
                "error": .string(String(describing: error))
            ])
            return ActiveConversationFanoutSplit(didSplit: true)
        }
    }

    private func realtimeMessageCreatedCoalescingWindowMilliseconds(
        for envelope: ConversationEventEnvelope,
        recipientCount: Int
    ) -> Int {
        guard envelope.eventType == .messageCreated else {
            return 0
        }
        let configuration = app.streamConsumerConfiguration
        let threshold = configuration.realtimeMessageCreatedLightweightRecipientThreshold
        guard threshold > 0, recipientCount >= threshold else {
            return 0
        }
        return configuration.realtimeMessageCreatedCoalesceWindowMilliseconds
    }

    private func activeCompactHintCoalescingWindowMilliseconds(
        for envelopes: [ConversationEventEnvelope],
        recipientCount: Int
    ) -> Int {
        guard let first = envelopes.first,
              first.eventType == .messageCreated,
              first.payload.messageID != nil
        else {
            return 0
        }
        guard envelopes.allSatisfy({
            $0.eventType == .messageCreated
                && $0.payload.messageID != nil
                && $0.conversationID == first.conversationID
        }) else {
            return 0
        }
        let configuration = app.streamConsumerConfiguration
        let threshold = configuration.realtimeMessageCreatedLightweightRecipientThreshold
        guard threshold > 0, recipientCount >= threshold else {
            return 0
        }
        return configuration.realtimeActiveCompactHintCoalesceWindowMilliseconds
    }

    private func compactActiveHintBatches(
        from fullBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        recipientUserIDs: [UUID],
        eventID: UUID?
    ) -> [ConversationRealtimeConsumer.DomainEventPayloadBatch] {
        guard !recipientUserIDs.isEmpty else {
            return []
        }
        let hintEventID = eventID.map(imLightweightMessageCreatedHintEventID)
        return fullBatches.compactMap { batch in
            batch.payload.activeCompactHintForRealtimeActiveRecipient(
                maxPreviewCharacters: app.streamConsumerConfiguration.realtimeActiveCompactHintPreviewMaxCharacters,
                eventID: hintEventID
            ).map {
                ConversationRealtimeConsumer.DomainEventPayloadBatch(
                    payload: $0,
                    recipientUserIDs: recipientUserIDs,
                    fanoutIntent: .preSplitActiveCompact
                )
            }
        }
    }

    private func splitActiveConversationFanoutIfNeeded(
        _ payloadBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch]
    ) async -> ActiveConversationFanoutSplit {
        var split = ActiveConversationFanoutSplit()
        guard app.gatewayLocalFanoutConfiguration.activeConversationFanoutEnabled,
              app.hasConnectionRoutingServiceConfigured
        else {
            split.activeFullBatches = payloadBatches
            return split
        }

        var activeRouteCache: [ActiveConversationRouteCacheKey: [UUID: Set<String>]] = [:]
        for batch in payloadBatches {
            guard shouldSplitActiveConversationFanout(batch) else {
                split.activeFullBatches.append(batch)
                continue
            }

            do {
                let cacheKey = activeConversationRouteCacheKey(for: batch)
                let activeRoutes: [UUID: Set<String>]
                if let cachedRoutes = activeRouteCache[cacheKey] {
                    activeRoutes = cachedRoutes
                } else {
                    let routeStartedAt = Date()
                    let routeLookup = try await activeConversationRoutes(
                        app: app,
                        conversationID: batch.payload.aggregateID,
                        recipientUserIDs: batch.recipientUserIDs
                    )
                    let fetchedRoutes = routeLookup.routes
                    if !routeLookup.cacheHit {
                        split.routeMilliseconds += IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: routeStartedAt)
                    }
                    activeRouteCache[cacheKey] = fetchedRoutes
                    activeRoutes = fetchedRoutes
                }
                let plan = activeConversationFanoutPlan(for: batch, activeRoutes: activeRoutes)
                split.didSplit = true
                split.activeFullRecipientCount += plan.fullActiveUserIDs.count
                split.activeCompactRecipientCount += plan.compactActiveUserIDs.count
                split.downgradedActiveRecipientCount += plan.downgradedActiveUserIDs.count
                await app.routingMetrics.recordActiveConversationFanoutSplit(
                    activeRecipientCount: plan.fullActiveUserIDs.count,
                    compactActiveRecipientCount: plan.compactActiveUserIDs.count,
                    inactiveHintRecipientCount: 0,
                    downgradedActiveRecipientCount: plan.downgradedActiveUserIDs.count
                )

                if !plan.fullActiveUserIDs.isEmpty {
                    split.activeFullBatches.append(
                        ConversationRealtimeConsumer.DomainEventPayloadBatch(
                            payload: batch.payload,
                            recipientUserIDs: plan.fullActiveUserIDs,
                            fanoutIntent: .preSplitActiveFull
                        )
                    )
                }
                if !plan.compactActiveUserIDs.isEmpty {
                    split.activeCompactBatches.append(
                        contentsOf: compactActiveHintBatches(
                            from: [batch],
                            recipientUserIDs: plan.compactActiveUserIDs,
                            eventID: batch.payload.eventID
                        )
                    )
                }
            } catch {
                await app.routingMetrics.recordActiveConversationFanoutRouteSplitDrop(
                    recipientCount: batch.recipientUserIDs.count
                )
                app.logger.warning("Realtime delivery consumer active conversation split failed; dropping realtime fanout.", metadata: [
                    "event_id": .string(batch.payload.eventID.uuidString),
                    "conversation_id": .string(batch.payload.aggregateID.uuidString),
                    "recipient_count": .stringConvertible(batch.recipientUserIDs.count),
                    "error": .string(String(describing: error))
                ])
            }
        }
        return split
    }

    private func activeConversationRouteCacheKey(
        for batch: ConversationRealtimeConsumer.DomainEventPayloadBatch
    ) -> ActiveConversationRouteCacheKey {
        return ActiveConversationRouteCacheKey(
            conversationID: batch.payload.aggregateID,
            recipientUserIDs: Set(batch.recipientUserIDs)
        )
    }

    private func shouldSplitActiveConversationFanout(
        _ batch: ConversationRealtimeConsumer.DomainEventPayloadBatch
    ) -> Bool {
        guard batch.payload.eventType == .messageCreated else {
            return false
        }
        let threshold = app.gatewayLocalFanoutConfiguration.activeConversationFanoutRecipientThreshold
        guard threshold > 0 else {
            return false
        }
        if let conversation = batch.payload.conversation,
           conversation.kind == IMConversationKind.group.rawValue {
            return conversation.memberCount >= threshold
        }
        return Set(batch.recipientUserIDs).count >= threshold
    }

    private func activeConversationFanoutPlan(
        for batch: ConversationRealtimeConsumer.DomainEventPayloadBatch,
        activeRoutes: [UUID: Set<String>]
    ) -> ActiveConversationFanoutPlan {
        activeConversationFanoutPlan(
            recipientUserIDs: batch.recipientUserIDs,
            activeRoutes: activeRoutes,
            aggregateSequence: batch.payload.aggregateSequence,
            payload: batch.payload
        )
    }

    private func activeConversationFanoutPlan(
        recipientUserIDs: [UUID],
        activeRoutes: [UUID: Set<String>],
        aggregateSequence: UInt64,
        payload: IMTCPChatDomainEventPayload? = nil
    ) -> ActiveConversationFanoutPlan {
        var seenUserIDs = Set<UUID>()
        let orderedUserIDs = recipientUserIDs.filter { seenUserIDs.insert($0).inserted }
        let activeUserIDs = orderedUserIDs.filter { !(activeRoutes[$0] ?? []).isEmpty }
        return ActiveConversationFanoutPlan(
            fullActiveUserIDs: [],
            compactActiveUserIDs: activeUserIDs,
            downgradedActiveUserIDs: activeUserIDs
        )
    }

    private func sharedMessageCreatedRunRecipients(
        for envelopes: [ConversationEventEnvelope]
    ) async throws -> ConversationDomainEventResolvedRecipients? {
        try await sharedResolvedMessageCreatedRunRecipients(
            for: envelopes,
            sourceDB: sourceDB,
            app: app
        )
    }
}

struct OwnerDomainEventDeliveryConsumer: ConversationEventConsumer {
    private struct RelayAfterRecordActiveRouteCacheKey: Hashable, Sendable {
        let conversationID: UUID
        let recipientUserIDs: [UUID]
    }

    private struct OwnerDeliveryRecordEntry: Sendable {
        let ownerUserID: UUID
        let payload: IMTCPChatDomainEventPayload
        let timelineNotice: IMTimelineNoticeResponse?
        let sourceEventID: UUID
        let createdAt: Date
    }

    let app: Application
    let sourceDB: any Database
    let relayRealtimeAfterRecord: Bool

    init(
        app: Application,
        sourceDB: any Database,
        relayRealtimeAfterRecord: Bool = false
    ) {
        self.app = app
        self.sourceDB = sourceDB
        self.relayRealtimeAfterRecord = relayRealtimeAfterRecord
    }

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        _ = try await consume([envelope])
    }

    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        guard !envelopes.isEmpty else {
            return
        }
        for envelope in envelopes {
            guard envelope.eventType == .messageCreated,
                  envelope.payload.messageID != nil
            else {
                throw Abort(.internalServerError, reason: "messageCreated run owner delivery only accepts message_created events with messageID.")
            }
        }
        if try await consumeMessageCreatedRunOwnerDeliverySkipIfPossible(envelopes) {
            return
        }
        _ = try await consume(envelopes)
    }

    private func consumeMessageCreatedRunOwnerDeliverySkipIfPossible(
        _ envelopes: [ConversationEventEnvelope]
    ) async throws -> Bool {
        guard !relayRealtimeAfterRecord,
              let first = envelopes.first,
              let firstEventID = first.eventID,
              envelopes.allSatisfy({
                  $0.eventType == .messageCreated
                      && $0.payload.messageID != nil
                      && $0.conversationID == first.conversationID
                      && $0.eventID != nil
              })
        else {
            return false
        }

        let recipientCount = try await messageCreatedRecipientCountHint(for: first)
        guard let skipReason = messageCreatedOwnerDeliverySkipReason(
            for: first,
            recipientCount: recipientCount
        ) else {
            return false
        }

        try validateMessageCreatedOwnerDeliverySkipRealtimePath(
            eventID: firstEventID,
            conversationID: first.conversationID,
            skipReason: skipReason
        )
        for _ in envelopes {
            await app.conversationDomainEventMetrics.recordMessageCreatedOwnerDeliverySkipped(
                recipientCount: recipientCount
            )
            await app.conversationDomainEventMetrics.recordMessageCreatedTimelinePullDelivery(
                recipientCount: recipientCount
            )
        }
        app.logger.info("Domain delivery skipped messageCreated owner delivery run.", metadata: [
            "conversation_id": .string(first.conversationID.uuidString),
            "recipient_count": .stringConvertible(recipientCount),
            "run_count": .stringConvertible(envelopes.count),
            "skip_reason": .string(skipReason)
        ])
        return true
    }

    @discardableResult
    private func consume(_ envelopes: [ConversationEventEnvelope]) async throws -> [IMCanonicalDomainEventDelivery] {
        let realtimeConsumer = ConversationRealtimeConsumer(app: app, sourceDB: sourceDB)
        var entries: [OwnerDeliveryRecordEntry] = []
        var expectedPayloadCount = 0
        var relayRequestID: UUID?
        var relayAfterRecordBatches: [IMGatewayDomainEventPayloadBatch] = []
        var relayAfterRecordActiveRouteCache: [RelayAfterRecordActiveRouteCacheKey: [UUID: Set<String>]] = [:]
        let sharedResolvedRecipients = try await sharedMessageCreatedRunRecipients(for: envelopes)

        for envelope in envelopes {
            guard let sourceEventID = envelope.eventID else {
                continue
            }
            relayRequestID = relayRequestID ?? sourceEventID
            let resolvedRecipients = if let sharedResolvedRecipients {
                sharedResolvedRecipients
            } else {
                try await ConversationDomainEventRecipientResolver(db: sourceDB, app: app)
                    .resolveRecipients(for: envelope)
            }
            let recipientUserIDs = resolvedRecipients.userIDs
            if let skipReason = messageCreatedOwnerDeliverySkipReason(
                for: envelope,
                recipientCount: recipientUserIDs.count
            ) {
                try validateMessageCreatedOwnerDeliverySkipRealtimePath(
                    eventID: sourceEventID,
                    conversationID: envelope.conversationID,
                    skipReason: skipReason
                )
                await app.conversationDomainEventMetrics.recordMessageCreatedOwnerDeliverySkipped(
                    recipientCount: recipientUserIDs.count
                )
                await app.conversationDomainEventMetrics.recordMessageCreatedTimelinePullDelivery(
                    recipientCount: recipientUserIDs.count
                )
                app.logger.info("Domain delivery skipped messageCreated owner delivery.", metadata: [
                    "event_id": .string(sourceEventID.uuidString),
                    "conversation_id": .string(envelope.conversationID.uuidString),
                    "recipient_count": .stringConvertible(recipientUserIDs.count),
                    "skip_reason": .string(skipReason)
                ])
                if relayRealtimeAfterRecord {
                    relayAfterRecordBatches.append(
                        contentsOf: try await realtimeRelayBatchesWithoutOwnerDelivery(
                            for: envelope,
                            resolvedRecipients: resolvedRecipients,
                            activeRouteCache: &relayAfterRecordActiveRouteCache
                        )
                    )
                }
                continue
            }
            let payloads = try await realtimeConsumer.domainEventPayloads(
                for: envelope,
                resolvedRecipients: resolvedRecipients
            )
            let timelineNotice = envelope.eventType.requiresTimelineNotice
                ? try await waitForTimelineNotice(forEventID: sourceEventID)
                : try await timelineNotice(forEventID: sourceEventID)
            if envelope.eventType.requiresTimelineNotice, timelineNotice == nil {
                throw ConversationEventTransientProcessingError.timelineNoticeMissing(
                    eventID: sourceEventID,
                    waitedMilliseconds: app.streamConsumerConfiguration.domainDeliveryTimelineNoticeMaxWaitMilliseconds
                )
            }
            expectedPayloadCount += payloads.count
            entries.append(
                contentsOf: payloads.map { ownerUserID, payload in
                    OwnerDeliveryRecordEntry(
                        ownerUserID: ownerUserID,
                        payload: payload,
                        timelineNotice: timelineNotice,
                        sourceEventID: sourceEventID,
                        createdAt: envelope.event.createdAt
                    )
                }
            )
        }

        if !relayAfterRecordBatches.isEmpty {
            await dispatchRelayAfterRecordBatches(
                relayAfterRecordBatches,
                requestID: relayRequestID
            )
        }

        return try await recordOwnerDeliveries(
            entries: entries,
            expectedPayloadCount: expectedPayloadCount,
            relayRequestID: relayRequestID,
            relayRealtimeAfterRecord: relayRealtimeAfterRecord
        )
    }

    private func validateMessageCreatedOwnerDeliverySkipRealtimePath(
        eventID: UUID,
        conversationID: UUID,
        skipReason: String
    ) throws {
        guard relayRealtimeAfterRecord
            || app.streamConsumerConfiguration.isEnabled("realtime-delivery-consumer")
            || app.streamConsumerConfiguration.domainDeliveryExternalRealtimeDeliveryEnabled
        else {
            throw Abort(
                .internalServerError,
                reason: "Refusing to skip messageCreated owner delivery without realtime delivery path. Enable realtime-delivery-consumer, set IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true, or set IM_DOMAIN_DELIVERY_EXTERNAL_REALTIME_DELIVERY_ENABLED=true when a dedicated realtime-delivery-consumer runs in the same deployment. eventID=\(eventID.uuidString) conversationID=\(conversationID.uuidString) skipReason=\(skipReason)"
            )
        }
    }

    private func recordOwnerDeliveries(
        entries: [OwnerDeliveryRecordEntry],
        expectedPayloadCount: Int,
        relayRequestID: UUID?,
        relayRealtimeAfterRecord: Bool
    ) async throws -> [IMCanonicalDomainEventDelivery] {
        let targets = summaryProjectionTargets(app: app, recipientUserIDs: entries.map(\.ownerUserID))
        var deliveries: [IMCanonicalDomainEventDelivery] = []
        deliveries.reserveCapacity(expectedPayloadCount)

        try await withThrowingTaskGroup(of: [IMCanonicalDomainEventDelivery].self) { group in
            for target in targets {
                group.addTask {
                    let deliveryService = OwnerDomainEventDeliveryService(
                        db: target.readModelDB,
                        domainEventMetrics: app.conversationDomainEventMetrics,
                        postgresRecordBatchMaxRequests: app.streamConsumerConfiguration.domainDeliveryOwnerRecordBatchMaxRequests
                    )
                    let targetOwnerIDs = Set(target.recipientUserIDs)
                    let requests = entries.compactMap { entry -> OwnerDomainEventDeliveryService.RecordRequest? in
                        guard targetOwnerIDs.contains(entry.ownerUserID) else {
                            return nil
                        }
                        return OwnerDomainEventDeliveryService.RecordRequest(
                            ownerUserID: entry.ownerUserID,
                            payload: entry.payload.withTimelineNotice(entry.timelineNotice),
                            sourceType: .conversation,
                            sourceEventID: entry.sourceEventID,
                            createdAt: entry.createdAt
                        )
                    }
                    guard relayRealtimeAfterRecord else {
                        _ = try await deliveryService.recordBatch(
                            requests,
                            returningRows: false
                        )
                        return []
                    }
                    let canonicalDeliveries = try await deliveryService.recordBatchCanonicalDeliveries(requests)
                    await app.gatewaySessionService.sendDomainEventPayloads(
                        canonicalDeliveries.map {
                            IMCanonicalDomainEventDelivery(
                                ownerUserID: $0.ownerUserID,
                                eventID: $0.eventID,
                                payload: $0.payload
                            )
                        },
                        requestID: relayRequestID
                    )
                    return canonicalDeliveries
                }
            }

            while let batch = try await group.next() {
                deliveries.append(contentsOf: batch)
            }
        }

        return deliveries
    }

    private func relayRealtimeWithoutOwnerDelivery(
        for envelope: ConversationEventEnvelope,
        resolvedRecipients: ConversationDomainEventResolvedRecipients
    ) async throws {
        var activeRouteCache: [RelayAfterRecordActiveRouteCacheKey: [UUID: Set<String>]] = [:]
        let batches = try await realtimeRelayBatchesWithoutOwnerDelivery(
            for: envelope,
            resolvedRecipients: resolvedRecipients,
            activeRouteCache: &activeRouteCache
        )
        await app.gatewaySessionService.sendDomainEventPayloadBatches(batches, requestID: envelope.eventID)
    }

    private func realtimeRelayBatchesWithoutOwnerDelivery(
        for envelope: ConversationEventEnvelope,
        resolvedRecipients: ConversationDomainEventResolvedRecipients,
        activeRouteCache: inout [RelayAfterRecordActiveRouteCacheKey: [UUID: Set<String>]]
    ) async throws -> [IMGatewayDomainEventPayloadBatch] {
        if let preSplitBatches = try await preSplitRelayRealtimeWithoutOwnerDelivery(
            for: envelope,
            resolvedRecipients: resolvedRecipients,
            activeRouteCache: &activeRouteCache
        ) {
            return preSplitBatches
        }

        let batches = try await ConversationRealtimeConsumer(app: app, sourceDB: sourceDB)
            .domainEventPayloadBatches(
                for: envelope,
                detail: .fullMessageCreatedWithoutSummaryIfLarge,
                resolvedRecipients: resolvedRecipients
            )
        return batches.map {
            IMGatewayDomainEventPayloadBatch(
                payload: $0.payload,
                recipientUserIDs: $0.recipientUserIDs
            )
        }
    }

    private func dispatchRelayAfterRecordBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        guard app.streamConsumerConfiguration.realtimeDeliveryAsyncRelayEnabled else {
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                batches,
                requestID: requestID
            )
            return
        }

        let activeCompactBatches = batches.filter {
            $0.fanoutIntent == .preSplitActiveCompact
                && $0.payload.eventType == .conversationActivityHint
        }
        let immediatePassthroughBatches = batches.filter { batch in
            !(batch.fanoutIntent == .preSplitActiveCompact
                && batch.payload.eventType == .conversationActivityHint)
        }

        if !immediatePassthroughBatches.isEmpty {
            await app.realtimeDeliveryAsyncDispatcher.dispatchPayloadBatches(
                immediatePassthroughBatches.map {
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: $0.payload,
                        recipientUserIDs: $0.recipientUserIDs,
                        fanoutIntent: $0.fanoutIntent
                    )
                },
                requestID: requestID,
                coalescingKey: nil,
                coalescingWindowMilliseconds: 0
            )
        }

        let activeCompactBatchesByConversation = Dictionary(grouping: activeCompactBatches) {
            $0.payload.aggregateID
        }
        for (conversationID, activeCompactBatches) in activeCompactBatchesByConversation {
            let coalescingWindowMilliseconds = relayAfterRecordActiveCompactHintCoalescingWindowMilliseconds(
                for: activeCompactBatches
            )
            await app.realtimeDeliveryAsyncDispatcher.dispatchPayloadBatches(
                activeCompactBatches.map {
                    ConversationRealtimeConsumer.DomainEventPayloadBatch(
                        payload: $0.payload,
                        recipientUserIDs: $0.recipientUserIDs,
                        fanoutIntent: $0.fanoutIntent
                    )
                },
                requestID: requestID,
                coalescingKey: coalescingWindowMilliseconds > 0 ? conversationID : nil,
                coalescingScope: .activeCompactHint,
                coalescingWindowMilliseconds: coalescingWindowMilliseconds
            )
        }
    }

    private func relayAfterRecordActiveCompactHintCoalescingWindowMilliseconds(
        for activeCompactBatches: [IMGatewayDomainEventPayloadBatch]
    ) -> Int {
        guard !activeCompactBatches.isEmpty,
              activeCompactBatches.allSatisfy({
                  $0.fanoutIntent == .preSplitActiveCompact
                      && $0.payload.eventType == .conversationActivityHint
              })
        else {
            return 0
        }
        let configuration = app.streamConsumerConfiguration
        let threshold = configuration.realtimeMessageCreatedLightweightRecipientThreshold
        let recipientCount = activeCompactBatches.reduce(0) { $0 + $1.recipientUserIDs.count }
        guard threshold > 0, recipientCount >= threshold else {
            return 0
        }
        return configuration.realtimeActiveCompactHintCoalesceWindowMilliseconds
    }

    private func compactActiveRelayHintBatches(
        from fullBatches: [ConversationRealtimeConsumer.DomainEventPayloadBatch],
        recipientUserIDs: [UUID],
        eventID: UUID?
    ) -> [IMGatewayDomainEventPayloadBatch] {
        guard !recipientUserIDs.isEmpty else {
            return []
        }
        let hintEventID = eventID.map(imLightweightMessageCreatedHintEventID)
        return fullBatches.compactMap { batch in
            batch.payload.activeCompactHintForRealtimeActiveRecipient(
                maxPreviewCharacters: app.streamConsumerConfiguration.realtimeActiveCompactHintPreviewMaxCharacters,
                eventID: hintEventID
            ).map {
                IMGatewayDomainEventPayloadBatch(
                    payload: $0,
                    recipientUserIDs: recipientUserIDs,
                    fanoutIntent: .preSplitActiveCompact
                )
            }
        }
    }

    private func preSplitRelayRealtimeWithoutOwnerDelivery(
        for envelope: ConversationEventEnvelope,
        resolvedRecipients: ConversationDomainEventResolvedRecipients,
        activeRouteCache: inout [RelayAfterRecordActiveRouteCacheKey: [UUID: Set<String>]]
    ) async throws -> [IMGatewayDomainEventPayloadBatch]? {
        guard app.gatewayLocalFanoutConfiguration.activeConversationFanoutEnabled,
              app.hasConnectionRoutingServiceConfigured,
              envelope.eventType == .messageCreated,
              envelope.payload.messageID != nil
        else {
            return nil
        }
        let recipientUserIDs = resolvedRecipients.userIDs
        let recipientCount = recipientUserIDs.count
        let lightweightThreshold = app.streamConsumerConfiguration.realtimeMessageCreatedLightweightRecipientThreshold
        let fanoutThreshold = app.gatewayLocalFanoutConfiguration.activeConversationFanoutRecipientThreshold
        guard lightweightThreshold > 0,
              fanoutThreshold > 0,
              recipientCount >= lightweightThreshold,
              recipientCount >= fanoutThreshold
        else {
            return nil
        }

        let startedAt = Date()
        do {
            var seenUserIDs = Set<UUID>()
            let orderedUserIDs = recipientUserIDs.filter { seenUserIDs.insert($0).inserted }
            let cacheKey = RelayAfterRecordActiveRouteCacheKey(
                conversationID: envelope.conversationID,
                recipientUserIDs: orderedUserIDs.sorted { $0.uuidString < $1.uuidString }
            )
            let routeStartedAt = Date()
            let activeRoutes: [UUID: Set<String>]
            let routeCacheHit: Bool
            let routeCachePartialHit: Bool
            let routeCachedUserCount: Int
            let routeMissedUserCount: Int
            let routeJoinedInFlight: Bool
            if let cachedRoutes = activeRouteCache[cacheKey] {
                activeRoutes = cachedRoutes
                routeCacheHit = true
                routeCachePartialHit = false
                routeCachedUserCount = orderedUserIDs.count
                routeMissedUserCount = 0
                routeJoinedInFlight = false
            } else {
                let routeLookup = try await activeConversationRoutes(
                    app: app,
                    conversationID: envelope.conversationID,
                    recipientUserIDs: recipientUserIDs
                )
                activeRoutes = routeLookup.routes
                activeRouteCache[cacheKey] = activeRoutes
                routeCacheHit = routeLookup.cacheHit
                routeCachePartialHit = routeLookup.cachePartialHit
                routeCachedUserCount = routeLookup.cachedUserCount
                routeMissedUserCount = routeLookup.missedUserCount
                routeJoinedInFlight = routeLookup.joinedInFlight
            }
            let routeMilliseconds = routeCacheHit
                ? 0
                : IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: routeStartedAt)
            await app.routingMetrics.recordDomainRelayAfterRecordActiveRouteCache(
                hit: routeCacheHit,
                partialHit: routeCachePartialHit,
                cachedUserCount: routeCachedUserCount,
                missedUserCount: routeMissedUserCount,
                joinedInFlight: routeJoinedInFlight
            )
            let activeUserIDs = orderedUserIDs.filter { !(activeRoutes[$0] ?? []).isEmpty }
            let realtimeConsumer = ConversationRealtimeConsumer(app: app, sourceDB: sourceDB)
            var relayBatches: [IMGatewayDomainEventPayloadBatch] = []
            if !activeUserIDs.isEmpty || orderedUserIDs.count > activeUserIDs.count {
                let compactActiveUserIDs = activeUserIDs
                await app.routingMetrics.recordActiveConversationFanoutSplit(
                    activeRecipientCount: 0,
                    compactActiveRecipientCount: compactActiveUserIDs.count,
                    inactiveHintRecipientCount: 0,
                    downgradedActiveRecipientCount: compactActiveUserIDs.count
                )
                await app.routingMetrics.recordDomainRelayAfterRecordPreSplit(
                    activeRecipientCount: 0,
                    compactActiveRecipientCount: compactActiveUserIDs.count,
                    inactiveHintRecipientCount: 0,
                    downgradedActiveRecipientCount: compactActiveUserIDs.count
                )
                if !compactActiveUserIDs.isEmpty {
                    let compactBatches = try await realtimeConsumer.domainEventPayloadBatches(
                        for: envelope,
                        detail: .activeCompactMessageCreatedIfLarge,
                        resolvedRecipients: resolvedRecipients
                    )
                    relayBatches.append(
                        contentsOf: compactBatches.map {
                            IMGatewayDomainEventPayloadBatch(
                                payload: $0.payload,
                                recipientUserIDs: compactActiveUserIDs,
                                fanoutIntent: .preSplitActiveCompact
                            )
                        }
                    )
                }
            }
            let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
            if IMRealtimeDeliveryDiagnostics.shouldLogAny(
                [routeMilliseconds, totalMilliseconds],
                thresholdMilliseconds: app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
            ) {
                app.logger.info("Domain delivery relay-after-record pre-split realtime relay.", metadata: [
                    "event_id": .string(envelope.eventID?.uuidString ?? ""),
                    "conversation_id": .string(envelope.conversationID.uuidString),
                    "recipient_count": .stringConvertible(recipientCount),
                    "active_full_recipient_count": .stringConvertible(0),
                    "active_compact_recipient_count": .stringConvertible(activeUserIDs.count),
                    "downgraded_active_recipient_count": .stringConvertible(activeUserIDs.count),
                    "payload_batch_count": .stringConvertible(relayBatches.count),
                    "active_route_cache_hit": .stringConvertible(routeCacheHit),
                    "active_route_ms": .stringConvertible(routeMilliseconds),
                    "total_ms": .stringConvertible(totalMilliseconds)
                ])
            }
            return relayBatches
        } catch {
            await app.routingMetrics.recordDomainRelayAfterRecordPreSplitRouteDrop()
            await app.routingMetrics.recordActiveConversationFanoutRouteSplitDrop(
                recipientCount: recipientCount
            )
            app.logger.warning("Domain delivery relay-after-record pre-split failed; dropping unsplit realtime relay.", metadata: [
                "event_id": .string(envelope.eventID?.uuidString ?? ""),
                "conversation_id": .string(envelope.conversationID.uuidString),
                "recipient_count": .stringConvertible(recipientCount),
                "error": .string(String(describing: error))
            ])
            return []
        }
    }

    private func messageCreatedOwnerDeliverySkipReason(
        for envelope: ConversationEventEnvelope,
        recipientCount: Int
    ) -> String? {
        guard envelope.eventType == .messageCreated else {
            return nil
        }
        let configuration = app.streamConsumerConfiguration
        if configuration.domainDeliverySkipsMessageCreatedOwnerDelivery {
            return "timeline_pull_all_message_created"
        }
        guard configuration.domainDeliveryMessageCreatedLargeGroupMode == .timelinePull else {
            return nil
        }
        let threshold = configuration.domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold
        guard threshold > 0 else {
            return nil
        }
        guard recipientCount >= threshold else {
            return nil
        }
        return "timeline_pull_recipient_threshold_\(threshold)"
    }

    private func messageCreatedRecipientCountHint(for envelope: ConversationEventEnvelope) async throws -> Int {
        let inlineCount = Set(envelope.payload.recipientUserIDs).count
        if inlineCount > 0 {
            return inlineCount
        }
        guard let eventID = envelope.eventID,
              let snapshot = try await ConversationDomainEventRecipientSnapshot.find(eventID, on: sourceDB)
        else {
            if app.streamConsumerConfiguration.streamConsumerRequiresMessageCreatedRecipientSnapshot {
                await app.conversationDomainEventMetrics.recordRecipientResolutionMissingSnapshot()
                throw ConversationEventTransientProcessingError.messageCreatedRecipientSnapshotMissing(
                    eventID: envelope.eventID,
                    conversationID: envelope.conversationID
                )
            }
            return try await ConversationMember.query(on: sourceDB)
                .filter(\.$conversation.$id == envelope.conversationID)
                .count()
        }
        return snapshot.recipientCount
    }

    private func sharedMessageCreatedRunRecipients(
        for envelopes: [ConversationEventEnvelope]
    ) async throws -> ConversationDomainEventResolvedRecipients? {
        try await sharedResolvedMessageCreatedRunRecipients(
            for: envelopes,
            sourceDB: sourceDB,
            app: app
        )
    }

    private func timelineNotice(forEventID eventID: UUID) async throws -> IMTimelineNoticeResponse? {
        guard let notice = try await ConversationTimelineNotice.find(eventID, on: sourceDB),
              let id = notice.eventID
        else {
            return nil
        }
        return IMTimelineNoticeResponse(
            id: id,
            conversationID: notice.conversationID,
            timelineSequence: try imPositiveUInt64Sequence(notice.timelineSequence, field: "timeline_sequence"),
            eventType: notice.eventType,
            actorUserID: notice.actorUserID,
            targetUserIDs: try notice.targetUserIDs,
            noticeKind: notice.noticeKind,
            params: try notice.params,
            fallbackText: notice.fallbackText,
            createdAt: notice.createdAt
        )
    }

    private func waitForTimelineNotice(forEventID eventID: UUID) async throws -> IMTimelineNoticeResponse? {
        let maxWaitMilliseconds = app.streamConsumerConfiguration.domainDeliveryTimelineNoticeMaxWaitMilliseconds
        let retryDelayMilliseconds = app.streamConsumerConfiguration.domainDeliveryTimelineNoticeRetryDelayMilliseconds
        let maxAttempts = max(1, Int(ceil(Double(maxWaitMilliseconds) / Double(retryDelayMilliseconds))))
        let retryDelayNanoseconds = UInt64(retryDelayMilliseconds) * 1_000_000
        for attempt in 0..<maxAttempts {
            if let notice = try await timelineNotice(forEventID: eventID) {
                return notice
            }
            if attempt < maxAttempts - 1 {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
        return nil
    }
}

private extension IMTCPChatDomainEventPayload {
    func withTimelineNotice(_ timelineNotice: IMTimelineNoticeResponse?) -> IMTCPChatDomainEventPayload {
        IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: eventType,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: conversation,
            timelineNotice: timelineNotice,
            requiresTimelineNotice: requiresTimelineNotice,
            ownerCursor: ownerCursor,
            ownerAggregateSequence: ownerAggregateSequence,
            body: body
        )
    }
}

struct ConversationNotificationConsumer: ConversationEventConsumer {
    let app: Application

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        try await ConversationNotificationRunWriter(app: app).consume(envelopes)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard let eventID = envelope.eventID else {
            return
        }

        let resolvedRecipients = try await notificationRecipientResolution(for: envelope)
        let recipientUserIDs = resolvedRecipients.userIDs
        if let skipReason = messageCreatedOwnerNotificationSkipReason(
            for: envelope,
            recipientCount: recipientUserIDs.count,
            configuration: app.streamConsumerConfiguration
        ) {
            await app.conversationDomainEventMetrics.recordMessageCreatedOwnerNotificationSkipped(
                recipientCount: recipientUserIDs.count
            )
            app.logger.info("Notification consumer skipped messageCreated owner notifications.", metadata: [
                "event_id": .string(eventID.uuidString),
                "conversation_id": .string(envelope.conversationID.uuidString),
                "recipient_count": .stringConvertible(recipientUserIDs.count),
                "skip_reason": .string(skipReason)
            ])
            return
        }
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

        await IMAPNSPushService(app: app).sendOfflinePushIfNeeded(
            for: envelope,
            candidateUserIDs: recipientUserIDs
        )
    }

    private func notificationRecipientResolution(
        for envelope: ConversationEventEnvelope
    ) async throws -> ConversationDomainEventResolvedRecipients {
        let db = try await app.conversationShardRouter.strongReadDatabase(forConversationID: envelope.conversationID)
        return try await ConversationDomainEventRecipientResolver(db: db, app: app)
            .resolveRecipients(for: envelope)
    }
}

struct ConversationNotificationRunWriter {
    let app: Application

    func consume(_ envelopes: [ConversationEventEnvelope]) async throws {
        let now = Date()
        var rowsByShard: [String: [ConversationNotificationBatchWriter.Row]] = [:]

        if let skippedRun = try await messageCreatedRunSkipReason(envelopes) {
            for _ in envelopes {
                await app.conversationDomainEventMetrics.recordMessageCreatedOwnerNotificationSkipped(
                    recipientCount: skippedRun.recipientCount
                )
            }
            app.logger.info("Notification run writer skipped messageCreated owner notifications.", metadata: [
                "conversation_id": .string(skippedRun.conversationID.uuidString),
                "recipient_count": .stringConvertible(skippedRun.recipientCount),
                "run_count": .stringConvertible(envelopes.count),
                "skip_reason": .string(skippedRun.reason)
            ])
            return
        }

        for envelope in envelopes {
            guard let eventID = envelope.eventID else {
                continue
            }
            let recipientUserIDs = try await notificationRecipientUserIDs(for: envelope)
            if let skipReason = messageCreatedOwnerNotificationSkipReason(
                for: envelope,
                recipientCount: recipientUserIDs.count,
                configuration: app.streamConsumerConfiguration
            ) {
                await app.conversationDomainEventMetrics.recordMessageCreatedOwnerNotificationSkipped(
                    recipientCount: recipientUserIDs.count
                )
                app.logger.info("Notification run writer skipped messageCreated owner notifications.", metadata: [
                    "event_id": .string(eventID.uuidString),
                    "conversation_id": .string(envelope.conversationID.uuidString),
                    "recipient_count": .stringConvertible(recipientUserIDs.count),
                    "skip_reason": .string(skipReason)
                ])
                continue
            }
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

    private func notificationRecipientUserIDs(for envelope: ConversationEventEnvelope) async throws -> [UUID] {
        let db = try await app.conversationShardRouter.strongReadDatabase(forConversationID: envelope.conversationID)
        return try await ConversationDomainEventRecipientResolver(db: db, app: app)
            .recipientUserIDs(for: envelope)
    }

    private func messageCreatedRunSkipReason(
        _ envelopes: [ConversationEventEnvelope]
    ) async throws -> (conversationID: UUID, recipientCount: Int, reason: String)? {
        guard let first = envelopes.first,
              first.eventType == .messageCreated,
              first.payload.messageID != nil,
              envelopes.allSatisfy({
                  $0.eventType == .messageCreated
                      && $0.payload.messageID != nil
                      && $0.conversationID == first.conversationID
              })
        else {
            return nil
        }

        let configuration = app.streamConsumerConfiguration
        if configuration.notificationSkipsMessageCreatedOwnerNotifications {
            let recipientCount = try await notificationRecipientCountHint(for: first)
            return (
                first.conversationID,
                recipientCount,
                "message_created_owner_notifications_disabled"
            )
        }

        let threshold = configuration.notificationMessageCreatedOwnerNotificationSkipRecipientThreshold
        guard threshold > 0 else {
            return nil
        }
        let recipientCount = try await notificationRecipientCountHint(for: first)
        guard recipientCount >= threshold else {
            return nil
        }
        return (
            first.conversationID,
            recipientCount,
            "recipient_threshold_\(threshold)"
        )
    }

    private func notificationRecipientCountHint(for envelope: ConversationEventEnvelope) async throws -> Int {
        let inlineCount = Set(envelope.payload.recipientUserIDs).count
        if inlineCount > 0 {
            return inlineCount
        }
        let db = try await app.conversationShardRouter.strongReadDatabase(forConversationID: envelope.conversationID)
        guard let eventID = envelope.eventID,
              let snapshot = try await ConversationDomainEventRecipientSnapshot.find(eventID, on: db)
        else {
            if app.streamConsumerConfiguration.streamConsumerRequiresMessageCreatedRecipientSnapshot {
                await app.conversationDomainEventMetrics.recordRecipientResolutionMissingSnapshot()
                throw ConversationEventTransientProcessingError.messageCreatedRecipientSnapshotMissing(
                    eventID: envelope.eventID,
                    conversationID: envelope.conversationID
                )
            }
            return try await ConversationMember.query(on: db)
                .filter(\.$conversation.$id == envelope.conversationID)
                .count()
        }
        return snapshot.recipientCount
    }
}

private func messageCreatedOwnerNotificationSkipReason(
    for envelope: ConversationEventEnvelope,
    recipientCount: Int,
    configuration: IMStreamConsumerConfiguration
) -> String? {
    guard envelope.eventType == .messageCreated else {
        return nil
    }
    if configuration.notificationSkipsMessageCreatedOwnerNotifications {
        return "message_created_owner_notifications_disabled"
    }
    let threshold = configuration.notificationMessageCreatedOwnerNotificationSkipRecipientThreshold
    guard threshold > 0, recipientCount >= threshold else {
        return nil
    }
    return "recipient_threshold_\(threshold)"
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
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
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

    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        guard !envelopes.isEmpty else {
            return
        }
        let isMessageCreatedRun = envelopes.allSatisfy { envelope in
            envelope.eventType == .messageCreated && envelope.payload.messageID != nil
        }
        guard isMessageCreatedRun else {
            for envelope in envelopes {
                try await consume(envelope)
            }
            return
        }
        for consumer in consumers where consumer.supportedEventTypes.contains(.messageCreated) {
            try await consumer.consumeMessageCreatedRun(envelopes)
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

enum ConversationEventTransientProcessingError: Error, CustomStringConvertible {
    case timelineNoticeMissing(eventID: UUID, waitedMilliseconds: Int)
    case messageCreatedRecipientSnapshotMissing(eventID: UUID?, conversationID: UUID)

    var description: String {
        switch self {
        case .timelineNoticeMissing(let eventID, let waitedMilliseconds):
            return "Transient timeline notice missing after \(waitedMilliseconds)ms for event \(eventID.uuidString)."
        case .messageCreatedRecipientSnapshotMissing(let eventID, let conversationID):
            return "Transient message_created recipient snapshot missing for event \(eventID?.uuidString ?? "unknown") conversation \(conversationID.uuidString)."
        }
    }
}

private extension ConversationDomainEventType {
    var shouldIncludeRealtimeConversationSummary: Bool {
        switch self {
        case .messageCreated:
            return false
        case .messageUpdated,
             .messageRecalled,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .readAdvanced,
             .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated,
             .messageFavoriteChanged,
             .messageVisibilityChanged,
             .conversationRemovedForUser,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
            return true
        }
    }

    var shouldIncludeRealtimeSummaryMemberUserIDs: Bool {
        switch self {
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .readAdvanced,
             .messageFavoriteChanged,
             .messageVisibilityChanged:
            return false
        case .metadataUpdated,
             .directPeerUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .conversationRemovedForUser,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
            return true
        }
    }

    var requiresTimelineNotice: Bool {
        switch self {
        case .metadataUpdated,
             .membershipAdded,
             .membershipRemoved,
             .membershipRoleUpdated,
             .directPeerUpdated,
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
            return true
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .readAdvanced,
             .messageVisibilityChanged,
             .messageFavoriteChanged,
             .conversationRemovedForUser:
            return false
        }
    }

    var chatDomainEventType: IMTCPChatDomainEventType {
        switch self {
        case .messageCreated:
            return .messageCreated
        case .messageUpdated:
            return .messageEdited
        case .messageRecalled:
            return .messageRevoked
        case .messageStreamStarted:
            return .messageStreamStarted
        case .messageStreamCompleted:
            return .messageStreamCompleted
        case .messageStreamFailed:
            return .messageStreamFailed
        case .messageStreamCancelled:
            return .messageStreamCancelled
        case .messageVisibilityChanged:
            return .messageVisibilityChanged
        case .messageFavoriteChanged:
            return .messageFavoriteChanged
        case .metadataUpdated, .directPeerUpdated, .readAdvanced:
            return .conversationUpdated
        case .membershipAdded:
            return .memberAdded
        case .membershipRemoved:
            return .memberRemoved
        case .membershipRoleUpdated:
            return .memberRoleUpdated
        case .conversationRemovedForUser:
            return .conversationRemovedForSelf
        case .conversationVisibilityChanged:
            return .conversationVisibilityChanged
        case .conversationSettingsChanged, .inviteChanged:
            return .conversationSettingsChanged
        }
    }
}

private extension IMTCPChatDomainEventPayload {
    func activeCompactHintForRealtimeActiveRecipient(
        maxPreviewCharacters: Int,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        return conversationActivityHintForRealtimeActiveRecipient(
            maxPreviewCharacters: maxPreviewCharacters,
            eventID: hintEventID
        )
    }

    func conversationActivityHintForRealtimeActiveRecipient(
        maxPreviewCharacters: Int,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        guard eventType == .messageCreated else {
            return nil
        }
        guard let activityHint = realtimeConversationActivityHint(maxPreviewCharacters: maxPreviewCharacters) else {
            return nil
        }
        return IMTCPChatDomainEventPayload(
            eventID: hintEventID ?? eventID,
            eventType: .conversationActivityHint,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: nil,
            timelineNotice: nil,
            requiresTimelineNotice: false,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .conversationActivityHint(activityHint)
        )
    }

    func conversationActivityHintForRealtimeInactiveRecipient(
        maxPreviewCharacters: Int,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        guard eventType == .messageCreated else {
            return nil
        }
        guard let activityHint = realtimeConversationActivityHint(maxPreviewCharacters: maxPreviewCharacters) else {
            return nil
        }
        return IMTCPChatDomainEventPayload(
            eventID: hintEventID ?? eventID,
            eventType: .conversationActivityHint,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: nil,
            timelineNotice: nil,
            requiresTimelineNotice: false,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .conversationActivityHint(activityHint)
        )
    }

    private func realtimeConversationActivityHint(maxPreviewCharacters: Int) -> IMConversationActivityHint? {
        guard case .messageCreated(let message, _) = body else {
            return nil
        }
        let preview = Self.truncatedPreview(
            message.content.previewText,
            maxCharacters: maxPreviewCharacters
        )
        return IMConversationActivityHint(
            messageID: message.id,
            senderUserID: message.senderUserID,
            serverSequence: message.serverSequence,
            timelineSequence: message.timelineSequence,
            previewText: preview,
            messageCreatedAt: preview.isEmpty ? nil : message.createdAt,
            updatedAt: message.createdAt ?? occurredAt
        )
    }

    private static func truncatedPreview(_ preview: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else {
            return ""
        }
        guard maxCharacters > 0, preview.count > maxCharacters else {
            return preview
        }
        return String(preview.prefix(maxCharacters))
    }
}

struct SummaryProjectionTarget {
    let readModelDB: any Database
    let recipientUserIDs: [UUID]
}

struct SummaryActivityProjectionTarget {
    let shardID: String
    let readModelDB: any Database
}

func summaryProjectionTargets(
    app: Application,
    recipientUserIDs: [UUID]
) -> [SummaryProjectionTarget] {
    let uniqueRecipientUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
    guard !uniqueRecipientUserIDs.isEmpty else {
        return []
    }

    return shardedSummaryProjectionTargets(app: app, recipientUserIDs: uniqueRecipientUserIDs)
}

func summaryProjectionActivityTargets(app: Application) -> [SummaryActivityProjectionTarget] {
    let shardIDs = app.summaryShardRouter.shardIDs
    guard !shardIDs.isEmpty else {
        return [SummaryActivityProjectionTarget(shardID: "default", readModelDB: app.imSummaryDB)]
    }
    return shardIDs.map {
        SummaryActivityProjectionTarget(
            shardID: $0,
            readModelDB: app.summaryShardRouter.database(forShardID: $0)
        )
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
