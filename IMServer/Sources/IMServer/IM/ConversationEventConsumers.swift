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

struct ConversationRealtimeConsumer: ConversationEventConsumer {
    let app: Application
    let sourceDB: any Database

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard envelope.eventID != nil else {
            return
        }
        let payloads = try await domainEventPayloads(for: envelope)
        for (recipientUserID, payload) in payloads {
            await app.gatewaySessionService.sendDomainEventDelivery(
                ownerUserID: recipientUserID,
                eventID: payload.eventID,
                requestID: payload.eventID
            )
        }
    }

    func domainEventPayloads(for envelope: ConversationEventEnvelope) async throws -> [(UUID, IMTCPChatDomainEventPayload)] {
        let recipientUserIDs = realtimeRecipientUserIDs(for: envelope)
        guard !recipientUserIDs.isEmpty else {
            return []
        }

        let message = try await messageResponse(for: envelope)
        guard let eventID = envelope.eventID else {
            throw Abort(.internalServerError, reason: "领域事件缺少 eventID。")
        }
        guard envelope.event.aggregateSequence > 0 else {
            throw Abort(.internalServerError, reason: "领域事件缺少 aggregate_sequence。")
        }
        let aggregateSequence = UInt64(envelope.event.aggregateSequence)
        var payloads: [(UUID, IMTCPChatDomainEventPayload)] = []

        for recipientUserID in recipientUserIDs {
            let conversation = try? await ConversationStrongReadService(app: app).conversationSummary(
                conversationID: envelope.conversationID,
                for: recipientUserID
            )
            let payload = IMTCPChatDomainEventPayload(
                eventID: eventID,
                eventType: envelope.eventType.chatDomainEventType,
                aggregateType: "conversation",
                aggregateID: envelope.conversationID,
                aggregateSequence: aggregateSequence,
                occurredAt: envelope.event.createdAt,
                actorUserID: envelope.event.actorUserID,
                conversation: conversation,
                requiresTimelineNotice: envelope.eventType.requiresTimelineNotice,
                body: try domainEventBody(for: envelope, message: message)
            )
            payloads.append((recipientUserID, payload))
        }
        return payloads
    }

    private func realtimeRecipientUserIDs(for envelope: ConversationEventEnvelope) -> [UUID] {
        switch envelope.eventType {
        case .conversationRemovedForUser:
            return envelope.payload.affectedUserID.map { [$0] } ?? []
        case .messageCreated,
             .messageUpdated,
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
             .conversationVisibilityChanged,
             .conversationSettingsChanged,
             .inviteChanged:
            return Array(Set(envelope.payload.recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
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

struct OwnerDomainEventDeliveryConsumer: ConversationEventConsumer {
    let app: Application
    let sourceDB: any Database

    var supportedEventTypes: Set<ConversationDomainEventType> {
        Set(ConversationDomainEventType.allCases)
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        guard let sourceEventID = envelope.eventID else {
            return
        }
        let payloads = try await ConversationRealtimeConsumer(app: app, sourceDB: sourceDB)
            .domainEventPayloads(for: envelope)
        let timelineNotice = try await timelineNotice(forEventID: sourceEventID)
        if envelope.eventType.requiresTimelineNotice, timelineNotice == nil {
            throw Abort(.internalServerError, reason: "领域事件需要 timeline notice，但 projection 未生成。")
        }
        for (ownerUserID, payload) in payloads {
            let db = app.summaryShardRouter.database(forOwnerUserID: ownerUserID)
            try await OwnerDomainEventDeliveryService(db: db).record(
                payload: payload.withTimelineNotice(timelineNotice),
                ownerUserID: ownerUserID,
                sourceType: .conversation,
                sourceEventID: sourceEventID,
                createdAt: envelope.event.createdAt
            )
        }
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

private extension ConversationDomainEventType {
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

    return shardedSummaryProjectionTargets(app: app, recipientUserIDs: uniqueRecipientUserIDs)
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
