import Foundation
import Kafka
import NIOCore
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
