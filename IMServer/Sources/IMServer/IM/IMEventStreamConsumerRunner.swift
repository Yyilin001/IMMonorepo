import Fluent
import Foundation
import Kafka
import NIOCore
import Vapor

struct KafkaConversationEventStreamConsumerRunner {
    let app: Application
    let groupID: String
    let clientSuffix: String
    let topics: [String]
    let replayRecordsEnabled: Bool
    let autoOffsetReset: KafkaConsumerConfiguration.AutoOffsetReset
    let consumerFactory: @Sendable (String) -> [any ConversationEventConsumer]

    init(
        app: Application,
        groupID: String,
        clientSuffix: String,
        topics: [String],
        replayRecordsEnabled: Bool = true,
        autoOffsetReset: KafkaConsumerConfiguration.AutoOffsetReset = .earliest,
        consumerFactory: @escaping @Sendable (String) -> [any ConversationEventConsumer]
    ) {
        self.app = app
        self.groupID = groupID
        self.clientSuffix = clientSuffix
        self.topics = topics
        self.replayRecordsEnabled = replayRecordsEnabled
        self.autoOffsetReset = autoOffsetReset
        self.consumerFactory = consumerFactory
    }

    func run() async throws {
        guard app.eventStreamConfiguration.driver == .kafka else {
            throw Abort(.internalServerError, reason: "stream-consumer requires IM_EVENT_STREAM_DRIVER=kafka.")
        }

        let configuration = try app.eventStreamConfiguration.makeConsumerConfiguration(
            consumerGroupID: groupID,
            clientSuffix: clientSuffix,
            topics: topics,
            autoOffsetReset: autoOffsetReset
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
                var transientAttempt = 0
                while !Task.isCancelled {
                    do {
                        let envelope = try decodeEnvelope(from: message)
                        if replayRecordsEnabled, try await hasAlreadyProcessed(envelope.eventID) {
                            await app.streamMetrics.recordDuplicate(groupID: groupID)
                            try await consumer.commit(message)
                            break
                        }
                        guard let eventType = ConversationDomainEventType(rawValue: envelope.eventType) else {
                            throw Abort(.unprocessableEntity, reason: "未知 conversation stream event 类型：\(envelope.eventType)。")
                        }
                        let syntheticEvent = try ConversationDomainEvent(
                            id: envelope.eventID,
                            conversationID: envelope.conversationID,
                            eventType: eventType,
                            aggregateSequence: envelope.aggregateSequence,
                            actorUserID: envelope.actorUserID,
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
                        if replayRecordsEnabled {
                            try await recordProcessed(envelope)
                        }
                        await app.streamMetrics.recordConsumed(groupID: groupID)
                        try await consumer.commit(message)
                        break
                    } catch let transientError as ConversationEventTransientProcessingError {
                        transientAttempt += 1
                        let maxTransientAttempts = app.streamConsumerConfiguration.domainDeliveryTransientMaxAttempts
                        if transientAttempt >= maxTransientAttempts {
                            await app.streamMetrics.recordFailed(groupID: groupID)
                            app.logger.warning(
                                "Kafka stream consumer transient processing exhausted; publishing to dead letter",
                                metadata: [
                                    "group_id": .string(groupID),
                                    "attempt": .stringConvertible(transientAttempt),
                                    "max_attempts": .stringConvertible(maxTransientAttempts),
                                    "error": .string(String(describing: transientError))
                                ]
                            )
                            if await publishDeadLetter(for: message, error: transientError, producer: deadLetterProducer) {
                                try? await consumer.commit(message)
                                break
                            }
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            continue
                        }
                        app.logger.warning(
                            "Kafka stream consumer transient processing failed; retrying without commit",
                            metadata: [
                                "group_id": .string(groupID),
                                "attempt": .stringConvertible(transientAttempt),
                                "max_attempts": .stringConvertible(maxTransientAttempts),
                                "error": .string(String(describing: transientError))
                            ]
                        )
                        let retryDelay = UInt64(app.streamConsumerConfiguration.domainDeliveryTimelineNoticeRetryDelayMilliseconds) * 1_000_000
                        try? await Task.sleep(nanoseconds: retryDelay)
                    } catch {
                        await app.streamMetrics.recordFailed(groupID: groupID)
                        app.logger.warning(
                            "Kafka stream consumer message processing failed",
                            metadata: [
                                "group_id": .string(groupID),
                                "error": .string(String(describing: error))
                            ]
                        )

                        if !(await publishDeadLetter(for: message, error: error, producer: deadLetterProducer)) {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            continue
                        }
                        try? await consumer.commit(message)
                        break
                    }
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

    private func publishDeadLetter(
        for message: KafkaConsumerMessage,
        error: any Error,
        producer: KafkaConversationEventStreamProducer
    ) async -> Bool {
        guard let envelope = try? decodeEnvelope(from: message) else {
            return true
        }
        let deadLetterHeader = kafkaHeader(
            key: "dead-letter-error",
            value: String(describing: error)
        )
        do {
            try await producer.publish(
                envelope,
                topicOverride: app.eventStreamConfiguration.deadLetterTopic,
                additionalHeaders: [deadLetterHeader]
            )
            await app.streamMetrics.recordDeadLetterPublished(groupID: groupID)
            return true
        } catch {
            app.logger.error(
                "Kafka stream consumer dead-letter publish failed; original message will not be committed",
                metadata: [
                    "group_id": .string(groupID),
                    "event_id": .string(envelope.eventID.uuidString),
                    "error": .string(String(describing: error))
                ]
            )
            return false
        }
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
            aggregateSequence: envelope.aggregateSequence,
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
