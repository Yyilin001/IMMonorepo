import Fluent
import Foundation
import Kafka
import NIOCore
import SQLKit
import Vapor

struct LocalConversationEventStreamProducer: ConversationEventStreamProducer {
    let logger: Logger

    var driverName: String { "local-inline" }

    func publish(_ envelope: ConversationEventStreamEnvelope) async throws {
        logger.debug(
            "Relayed conversation event to local inline stream producer",
            metadata: [
                "event_id": .string(envelope.eventID.uuidString),
                "conversation_id": .string(envelope.conversationID.uuidString),
                "event_type": .string(envelope.eventType),
                "producer_shard": .string(envelope.producerShard)
            ]
        )
    }
}

actor KafkaConversationEventStreamProducer: ConversationEventStreamProducer {
    nonisolated let driverName = "kafka"

    private let logger: Logger
    private let configuration: IMEventStreamConfiguration
    private let nodeID: String
    private var producer: KafkaProducer?
    private var runTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var pendingDeliveries: [KafkaProducerMessageID: CheckedContinuation<Void, any Error>] = [:]

    init(logger: Logger, configuration: IMEventStreamConfiguration, nodeID: String) {
        self.logger = logger
        self.configuration = configuration
        self.nodeID = nodeID
    }

    func publish(_ envelope: ConversationEventStreamEnvelope) async throws {
        try await publish(envelope, topicOverride: nil, additionalHeaders: [])
    }

    func publish(
        _ envelope: ConversationEventStreamEnvelope,
        topicOverride: String?,
        additionalHeaders: [KafkaHeader]
    ) async throws {
        let producer = try ensureProducer()
        let payload = try JSONEncoder().encode(envelope)
        let message = KafkaProducerMessage(
            topic: topicOverride ?? configuration.topic,
            headers: makeHeaders(for: envelope) + additionalHeaders,
            key: envelope.conversationID.uuidString,
            value: [UInt8](payload)
        )
        let messageID = try producer.send(message)
        try await waitForDelivery(messageID)
    }

    func shutdown() async {
        producer?.triggerGracefulShutdown()
        eventsTask?.cancel()
        runTask?.cancel()
        failPendingDeliveries(
            Abort(.serviceUnavailable, reason: "Kafka producer is shutting down before delivery acknowledgement.")
        )
        producer = nil
        eventsTask = nil
        runTask = nil
    }

    private func ensureProducer() throws -> KafkaProducer {
        if let producer {
            return producer
        }

        let producerConfiguration = try configuration.makeProducerConfiguration(nodeID: nodeID)

        let (producer, events) = try KafkaProducer.makeProducerWithEvents(
            configuration: producerConfiguration,
            logger: logger
        )

        runTask = Task {
            do {
                try await producer.run()
            } catch {
                self.logger.error(
                    "Kafka producer run loop exited with error",
                    metadata: ["error": .string(String(describing: error))]
                )
                await self.failPendingDeliveries(error)
            }
        }
        eventsTask = Task {
            for await event in events {
                await self.handleProducerEvent(event)
            }
        }

        self.producer = producer
        return producer
    }

    private func handleProducerEvent(_ event: KafkaProducerEvent) {
        switch event {
        case .deliveryReports(let deliveryReports):
            logger.debug(
                "Kafka producer delivered conversation event batch",
                metadata: ["count": .stringConvertible(deliveryReports.count)]
            )
            for report in deliveryReports {
                guard let continuation = pendingDeliveries.removeValue(forKey: report.id) else {
                    continue
                }
                switch report.status {
                case .acknowledged:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        case .DO_NOT_SWITCH_OVER_THIS_EXHAUSITVELY:
            break
        }
    }

    private func waitForDelivery(_ messageID: KafkaProducerMessageID) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForDeliveryReport(messageID)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.deliveryTimeoutNanoseconds)
                throw Abort(.serviceUnavailable, reason: "Timed out waiting for Kafka delivery acknowledgement.")
            }

            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                await self.cancelPendingDelivery(messageID)
                throw error
            }
        }
    }

    private func waitForDeliveryReport(_ messageID: KafkaProducerMessageID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingDeliveries[messageID] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelPendingDelivery(messageID)
            }
        }
    }

    private func cancelPendingDelivery(_ messageID: KafkaProducerMessageID) {
        pendingDeliveries.removeValue(forKey: messageID)
    }

    private func failPendingDeliveries(_ error: any Error) {
        let continuations = pendingDeliveries.values
        pendingDeliveries.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private var deliveryTimeoutNanoseconds: UInt64 {
        UInt64(max(1, configuration.messageTimeoutMilliseconds)) * 1_000_000
    }

    private func makeHeaders(for envelope: ConversationEventStreamEnvelope) -> [KafkaHeader] {
        [
            kafkaHeader(key: "event-id", value: envelope.eventID.uuidString),
            kafkaHeader(key: "event-version", value: String(envelope.eventVersion)),
            kafkaHeader(key: "aggregate-type", value: envelope.aggregateType),
            kafkaHeader(key: "event-type", value: envelope.eventType),
            kafkaHeader(key: "producer-shard", value: envelope.producerShard),
            kafkaHeader(key: "occurred-at", value: ISO8601DateFormatter().string(from: envelope.occurredAt))
        ]
    }

    private func kafkaHeader(key: String, value: String) -> KafkaHeader {
        var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
        buffer.writeString(value)
        return KafkaHeader(key: key, value: buffer)
    }
}

struct DatabaseOutboxConversationEventBus: ConversationEventBus {
    let db: any Database

    func publish(
        type: ConversationDomainEventType,
        conversationID: UUID,
        payload: ConversationDomainEventPayload,
        on database: (any Database)? = nil
    ) async throws {
        try await ConversationOutboxService(db: db).enqueue(
            type: type,
            conversationID: conversationID,
            payload: payload,
            on: database
        )
    }
}

struct ConversationOutboxRelay {
    let shardRouter: any ConversationShardRouter
    let producer: any ConversationEventStreamProducer
    let conversationDirectory: any ConversationDirectory
    let nodeID: String
    let claimTimeoutSeconds: Int

    init(app: Application, db: (any Database)? = nil) {
        if let db {
            self.shardRouter = ExplicitDatabaseConversationShardRouter(database: db)
        } else {
            self.shardRouter = app.conversationShardRouter
        }
        self.producer = app.conversationEventStreamProducer
        self.conversationDirectory = app.conversationDirectory
        self.nodeID = app.imNodeID
        self.claimTimeoutSeconds = app.conversationOutboxConfiguration.claimTimeoutSeconds
    }

    func drainPendingEvents(app: Application) async throws -> Int {
        var processed = 0
        for routedDatabase in shardRouter.allCommandDatabases() {
            processed += try await ConversationOutboxService(db: routedDatabase.database).processPendingBatch(app: app)
        }
        return processed
    }

    @discardableResult
    func relayPendingEvents(limit: Int = 200) async throws -> Int {
        var relayedCount = 0
        var remaining = max(0, limit)

        for routedDatabase in shardRouter.allCommandDatabases() {
            guard remaining > 0 else {
                break
            }

            let events = try await claimPendingEvents(
                on: routedDatabase.database,
                limit: remaining,
                nodeID: nodeID
            )

            for event in events {
                guard let eventID = event.id else {
                    continue
                }
                let payload = try event.decodedPayload()
                let shardID = try await conversationDirectory.shardID(for: event.conversationID)
                let envelope = ConversationEventStreamEnvelope(
                    eventID: eventID,
                    conversationID: event.conversationID,
                    eventType: event.eventType,
                    payload: payload,
                    occurredAt: event.createdAt,
                    producerShard: shardID
                )
                do {
                    try await producer.publish(envelope)
                    event.streamPublishedAt = Date()
                    event.streamPublishError = nil
                    event.streamPublishStartedAt = nil
                    event.streamPublishClaimedBy = nil
                    try await event.update(on: routedDatabase.database)
                    relayedCount += 1
                    remaining -= 1
                } catch {
                    event.streamPublishError = String(describing: error)
                    event.streamPublishStartedAt = nil
                    event.streamPublishClaimedBy = nil
                    try await event.update(on: routedDatabase.database)
                    throw error
                }
            }
        }

        return relayedCount
    }

    private func claimPendingEvents(
        on database: any Database,
        limit: Int,
        nodeID: String
    ) async throws -> [ConversationDomainEvent] {
        guard limit > 0 else {
            return []
        }

        let now = Date()
        let cutoff = Date(timeIntervalSinceNow: -Double(claimTimeoutSeconds))
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            struct ClaimedRow: Decodable {
                let id: UUID
            }

            let rows = try await sql.raw(
                """
                UPDATE \(ident: ConversationDomainEvent.schema)
                SET \(ident: "stream_publish_started_at") = \(bind: now),
                    \(ident: "stream_publish_claimed_by") = \(bind: nodeID),
                    \(ident: "stream_publish_error") = NULL
                WHERE \(ident: "id") IN (
                    SELECT \(ident: "id")
                    FROM \(ident: ConversationDomainEvent.schema)
                    WHERE \(ident: "status") = \(bind: ConversationDomainEventStatus.pending.rawValue)
                      AND \(ident: "stream_published_at") IS NULL
                      AND (
                          \(ident: "stream_publish_started_at") IS NULL
                          OR \(ident: "stream_publish_started_at") <= \(bind: cutoff)
                      )
                    ORDER BY \(ident: "created_at") ASC, \(ident: "id") ASC
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                RETURNING \(ident: "id")
                """
            ).all(decoding: ClaimedRow.self)
            guard !rows.isEmpty else {
                return []
            }
            return try await ConversationDomainEvent.query(on: database)
                .filter(\.$id ~~ rows.map(\.id))
                .sort(\.$createdAt, .ascending)
                .all()
        }

        return try await database.transaction { transaction in
            let events = try await ConversationDomainEvent.query(on: transaction)
                .filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                .filter(\.$streamPublishedAt == nil)
                .sort(\.$createdAt, .ascending)
                .all()
                .filter { event in
                    guard let startedAt = event.streamPublishStartedAt else {
                        return true
                    }
                    return startedAt <= cutoff
                }
                .prefix(limit)

            for event in events {
                event.streamPublishStartedAt = now
                event.streamPublishClaimedBy = nodeID
                event.streamPublishError = nil
                try await event.update(on: transaction)
            }

            return Array(events)
        }
    }
}

struct KafkaConversationEventStreamConsumerRunner {
    let app: Application
    let groupID: String
    let clientSuffix: String
    let topics: [String]
    let consumerFactory: @Sendable (String) -> [any ConversationEventConsumer]

    func run() async throws {
        guard app.eventStreamConfiguration.driver == .kafka else {
            throw Abort(.internalServerError, reason: "stream-consumer requires IM_EVENT_STREAM_DRIVER=kafka.")
        }

        let configuration = try app.eventStreamConfiguration.makeConsumerConfiguration(
            consumerGroupID: groupID,
            clientSuffix: clientSuffix,
            topics: topics
        )
        let (consumer, events) = try KafkaConsumer.makeConsumerWithEvents(
            configuration: configuration,
            logger: app.logger
        )
        let deadLetterProducer = KafkaConversationEventStreamProducer(
            logger: app.logger,
            configuration: app.eventStreamConfiguration,
            nodeID: "\(app.imNodeID)-\(clientSuffix)-dead-letter"
        )

        let runTask = Task {
            try await consumer.run()
        }
        let eventsTask = Task {
            for await event in events {
                app.logger.debug(
                    "Kafka stream consumer event received",
                    metadata: [
                        "group_id": .string(groupID),
                        "event": .string(String(describing: event))
                    ]
                )
            }
        }

        defer {
            consumer.triggerGracefulShutdown()
            runTask.cancel()
            eventsTask.cancel()
            Task {
                await deadLetterProducer.shutdown()
            }
        }

        do {
            for try await message in consumer.messages {
                do {
                    let envelope = try decodeEnvelope(from: message)
                    if try await hasAlreadyProcessed(envelope.eventID) {
                        await app.streamMetrics.recordDuplicate(groupID: groupID)
                        try await consumer.commit(message)
                        continue
                    }
                    let eventType = ConversationDomainEventType(rawValue: envelope.eventType)
                        ?? .metadataUpdated
                    let syntheticEvent = try ConversationDomainEvent(
                        id: envelope.eventID,
                        conversationID: envelope.conversationID,
                        eventType: eventType,
                        payload: envelope.payload,
                        status: .pending,
                        createdAt: envelope.occurredAt
                    )
                    let registry = ConversationEventConsumerRegistry(
                        consumers: consumerFactory(envelope.producerShard)
                    )
                    try await registry.consume(
                        ConversationEventEnvelope(
                            event: syntheticEvent,
                            payload: envelope.payload,
                            deliveryContext: .init(
                                sourceTopic: topics.first ?? app.eventStreamConfiguration.topic,
                                consumerGroupID: groupID,
                                producerShard: envelope.producerShard,
                                deadLetterError: headerValue(
                                    named: "dead-letter-error",
                                    in: message.headers
                                )
                            )
                        )
                    )
                    try await recordProcessed(envelope)
                    await app.streamMetrics.recordConsumed(groupID: groupID)
                    try await consumer.commit(message)
                } catch {
                    await app.streamMetrics.recordFailed(groupID: groupID)
                    app.logger.warning(
                        "Kafka stream consumer message processing failed",
                        metadata: [
                            "group_id": .string(groupID),
                            "error": .string(String(describing: error))
                        ]
                    )

                    if let envelope = try? decodeEnvelope(from: message) {
                        let deadLetterHeader = kafkaHeader(
                            key: "dead-letter-error",
                            value: String(describing: error)
                        )
                        do {
                            try await deadLetterProducer.publish(
                                envelope,
                                topicOverride: app.eventStreamConfiguration.deadLetterTopic,
                                additionalHeaders: [deadLetterHeader]
                            )
                            await app.streamMetrics.recordDeadLetterPublished(groupID: groupID)
                        } catch {
                            app.logger.error(
                                "Kafka stream consumer dead-letter publish failed; original message will not be committed",
                                metadata: [
                                    "group_id": .string(groupID),
                                    "event_id": .string(envelope.eventID.uuidString),
                                    "error": .string(String(describing: error))
                                ]
                            )
                            continue
                        }
                    }
                    try? await consumer.commit(message)
                }
            }
        } catch {
            await deadLetterProducer.shutdown()
            throw error
        }

        await deadLetterProducer.shutdown()
    }

    private func decodeEnvelope(from message: KafkaConsumerMessage) throws -> ConversationEventStreamEnvelope {
        let data = Data(Array(message.value.readableBytesView))
        return try JSONDecoder().decode(ConversationEventStreamEnvelope.self, from: data)
    }

    private func headerValue(
        named key: String,
        in headers: [KafkaHeader]
    ) -> String? {
        guard let header = headers.first(where: { $0.key == key }),
              var value = header.value else {
            return nil
        }
        return value.readString(length: value.readableBytes)
    }

    private func kafkaHeader(key: String, value: String) -> KafkaHeader {
        var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
        buffer.writeString(value)
        return KafkaHeader(key: key, value: buffer)
    }

    private func hasAlreadyProcessed(_ eventID: UUID) async throws -> Bool {
        let recordID = ConversationReplayRecord.recordID(consumerGroupID: groupID, eventID: eventID)
        guard let record = try await ConversationReplayRecord.find(recordID, on: app.imWriteDB) else {
            return false
        }
        return record.statusEnum == .replayed
    }

    private func recordProcessed(_ envelope: ConversationEventStreamEnvelope) async throws {
        let recordID = ConversationReplayRecord.recordID(consumerGroupID: groupID, eventID: envelope.eventID)
        let now = Date()
        if let existing = try await ConversationReplayRecord.find(recordID, on: app.imWriteDB) {
            existing.statusEnum = .replayed
            existing.receiveCount += 1
            existing.lastError = nil
            existing.replayedAt = now
            existing.updatedAt = now
            try await existing.update(on: app.imWriteDB)
            return
        }

        let record = try ConversationReplayRecord(
            eventID: envelope.eventID,
            consumerGroupID: groupID,
            sourceTopic: topics.first ?? app.eventStreamConfiguration.topic,
            conversationID: envelope.conversationID,
            eventType: envelope.eventType,
            producerShard: envelope.producerShard,
            payload: envelope.payload,
            status: .replayed,
            lastError: nil,
            receiveCount: 1,
            replayedAt: now,
            createdAt: envelope.occurredAt,
            updatedAt: now
        )
        try await record.create(on: app.imWriteDB)
    }
}
