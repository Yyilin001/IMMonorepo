import Fluent
import Foundation
import Kafka
import NIOCore
import Vapor

protocol GatewaySessionTransport: Sendable {
    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async
    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async
    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async
    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async
    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async
}

protocol SessionDirectory: Sendable {
    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>]
    func activeNodeIDs() async throws -> Set<String>
}

protocol GatewayDispatchBus: Sendable {
    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws
}

struct ConnectionRoutingSessionDirectory: SessionDirectory {
    let presenceStore: any PresenceStore

    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await presenceStore.routeNodeIDs(forUserIDs: userIDs)
    }

    func activeNodeIDs() async throws -> Set<String> {
        try await presenceStore.activeNodeIDs()
    }
}

struct ConnectionRoutingGatewayDispatchBus: GatewayDispatchBus {
    let dispatchService: any NodeMessageDispatchService

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {
        try await dispatchService.dispatch(envelope, toNodeID: nodeID)
    }
}

struct LocalGatewaySessionTransport: GatewaySessionTransport {
    let routingService: ConnectionRoutingService

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        await routingService.sendMessage(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        await routingService.sendConversationEvent(payload, toUserID: userID, requestID: requestID)
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        await routingService.sendContactEvent(payload, toUserID: userID, requestID: requestID)
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await routingService.kickConnections(forSessionID: sessionID, reason: reason, message: message)
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await routingService.kickConnections(forUserID: userID, reason: reason, message: message)
    }
}

struct HTTPGatewaySessionTransport: GatewaySessionTransport {
    let app: Application
    let configuration: IMGatewayRelayConfiguration

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        try? await post(
            path: "/internal/gateway/realtime/message",
            payload: GatewayRelayMessageRequest(
                payload: payload,
                recipientUserIDs: userIDs,
                requestID: requestID
            )
        )
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        try? await post(
            path: "/internal/gateway/realtime/conversation-event",
            payload: GatewayRelayConversationEventRequest(
                payload: payload,
                recipientUserID: userID,
                requestID: requestID
            )
        )
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        try? await post(
            path: "/internal/gateway/realtime/contact-event",
            payload: GatewayRelayContactEventRequest(
                payload: payload,
                recipientUserID: userID,
                requestID: requestID
            )
        )
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        try? await post(
            path: "/internal/gateway/realtime/kick-session",
            payload: GatewayRelayKickSessionRequest(
                sessionID: sessionID,
                reason: reason,
                message: message
            )
        )
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        try? await post(
            path: "/internal/gateway/realtime/kick-user",
            payload: GatewayRelayKickUserRequest(
                userID: userID,
                reason: reason,
                message: message
            )
        )
    }

    private func post<Payload: Content>(path: String, payload: Payload) async throws {
        guard let baseURL = configuration.baseURL else {
            return
        }

        let response = try await app.client.post(URI(string: "\(baseURL)\(path)")) { request in
            if let sharedSecret = configuration.sharedSecret, !sharedSecret.isEmpty {
                request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
            }
            try request.content.encode(payload)
        }

        guard response.status == .ok else {
            app.logger.warning(
                "Gateway relay request failed",
                metadata: [
                    "path": .string(path),
                    "status": .string(response.status.code.description)
                ]
            )
            return
        }
    }
}

struct LoggingUnavailableGatewaySessionTransport: GatewaySessionTransport {
    let logger: Logger
    let role: IMRuntimeRole

    func sendMessage(_ payload: IMTCPMessagePayload, toUserIDs userIDs: [UUID], requestID: UUID?) async {
        logUnavailable()
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        logUnavailable()
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        logUnavailable()
    }

    private func logUnavailable() {
        logger.warning(
            "Gateway session transport unavailable; realtime relay skipped",
            metadata: ["role": .string(role.rawValue)]
        )
    }
}

struct GatewaySessionService {
    let transport: any GatewaySessionTransport

    func bind(_ connection: IMAuthenticatedConnection, control: IMConnectionControl) async throws {
        if let transport = transport as? LocalGatewaySessionTransport {
            try await transport.routingService.bind(connection, control: control)
        }
    }

    func remove(connectionID: UUID) async {
        if let transport = transport as? LocalGatewaySessionTransport {
            await transport.routingService.remove(connectionID: connectionID)
        }
    }

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await transport.sendMessage(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await transport.sendConversationEvent(payload, toUserID: userID, requestID: requestID)
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await transport.sendContactEvent(payload, toUserID: userID, requestID: requestID)
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await transport.kickConnections(forSessionID: sessionID, reason: reason, message: message)
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await transport.kickConnections(forUserID: userID, reason: reason, message: message)
    }
}

protocol ConversationEventBus: Sendable {
    func publish(
        type: ConversationDomainEventType,
        conversationID: UUID,
        payload: ConversationDomainEventPayload,
        on database: (any Database)?
    ) async throws
}

protocol ConversationEventStreamProducer: Sendable {
    var driverName: String { get }
    func publish(_ envelope: ConversationEventStreamEnvelope) async throws
    func shutdown() async
}

extension ConversationEventStreamProducer {
    func shutdown() async {}
}

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
        _ = try producer.send(message)
    }

    func shutdown() async {
        producer?.triggerGracefulShutdown()
        eventsTask?.cancel()
        runTask?.cancel()
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
            }
        }
        eventsTask = Task {
            for await event in events {
                switch event {
                case .deliveryReports(let deliveryReports):
                    self.logger.debug(
                        "Kafka producer delivered conversation event batch",
                        metadata: ["count": .stringConvertible(deliveryReports.count)]
                    )
                case .DO_NOT_SWITCH_OVER_THIS_EXHAUSITVELY:
                    break
                }
            }
        }

        self.producer = producer
        return producer
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

    init(app: Application, db: (any Database)? = nil) {
        if let db {
            self.shardRouter = ExplicitDatabaseConversationShardRouter(database: db)
        } else {
            self.shardRouter = app.conversationShardRouter
        }
        self.producer = app.conversationEventStreamProducer
        self.conversationDirectory = app.conversationDirectory
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

            let events = try await ConversationDomainEvent.query(on: routedDatabase.database)
                .filter(\.$status == ConversationDomainEventStatus.pending.rawValue)
                .filter(\.$streamPublishedAt == nil)
                .sort(\.$createdAt, .ascending)
                .limit(remaining)
                .all()

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
                    try await event.update(on: routedDatabase.database)
                    relayedCount += 1
                    remaining -= 1
                } catch {
                    event.streamPublishError = String(describing: error)
                    try await event.update(on: routedDatabase.database)
                    throw error
                }
            }
        }

        return relayedCount
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
                    try await consumer.commit(message)
                } catch {
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
                        try? await deadLetterProducer.publish(
                            envelope,
                            topicOverride: app.eventStreamConfiguration.deadLetterTopic,
                            additionalHeaders: [deadLetterHeader]
                        )
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
}

struct QueryReadModelFacade {
    private let strongReadService: ConversationStrongReadService
    private let timelineReadService: ConversationEventualReadService
    private let summaryStore: any SummaryReadModelStore
    private let searchAdapter: any ConversationSearchAdapter

    init(app: Application) {
        self.strongReadService = ConversationStrongReadService(app: app)
        self.timelineReadService = ConversationEventualReadService(app: app)
        self.summaryStore = app.summaryReadModelStore
        self.searchAdapter = app.conversationSearchAdapter
    }

    func latestMessage(in conversationID: UUID) async throws -> IMMessageResponse? {
        try await strongReadService.latestMessage(in: conversationID)
    }

    func conversationSummary(
        conversationID: UUID,
        for userID: UUID
    ) async throws -> IMConversationResponse {
        try await summaryStore.conversationSummary(conversationID: conversationID, for: userID)
    }

    func listConversations(
        for userID: UUID,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationPageResponse {
        try await summaryStore.listConversations(for: userID, cursor: cursor, limit: limit)
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationChangesResponse {
        try await summaryStore.listConversationChanges(
            for: userID,
            afterToken: afterToken,
            cursor: cursor,
            limit: limit
        )
    }

    func listMembers(in conversationID: UUID, for userID: UUID) async throws -> [IMConversationMemberResponse] {
        try await timelineReadService.listMembers(in: conversationID, for: userID)
    }

    func listMessages(
        in conversationID: UUID,
        for userID: UUID,
        beforeSequence: Int?,
        limit: Int?
    ) async throws -> [IMMessageResponse] {
        try await timelineReadService.listMessages(
            in: conversationID,
            for: userID,
            beforeSequence: beforeSequence,
            limit: limit
        )
    }

    func listMessagesSince(
        in conversationID: UUID,
        for userID: UUID,
        afterSequence: Int,
        limit: Int?
    ) async throws -> IMMessageSinceResponse {
        try await timelineReadService.listMessagesSince(
            in: conversationID,
            for: userID,
            afterSequence: afterSequence,
            limit: limit
        )
    }

    func searchMessages(
        in conversationID: UUID,
        for userID: UUID,
        query: String,
        cursor: String?,
        limit: Int?
    ) async throws -> IMConversationMessageSearchPageResponse {
        try await searchAdapter.searchMessages(
            in: conversationID,
            for: userID,
            query: query,
            cursor: cursor,
            limit: limit
        )
    }
}

private struct SessionDirectoryStorageKey: StorageKey {
    typealias Value = any SessionDirectory
}

private struct GatewayDispatchBusStorageKey: StorageKey {
    typealias Value = any GatewayDispatchBus
}

private struct ConversationEventStreamProducerStorageKey: StorageKey {
    typealias Value = any ConversationEventStreamProducer
}

final class ConversationEventStreamProducerLifecycle: LifecycleHandler, @unchecked Sendable {
    func shutdown(_ application: Application) async {
        if let producer = application.storage[ConversationEventStreamProducerStorageKey.self] {
            await producer.shutdown()
        }
    }
}

extension Application {
    var sessionDirectory: any SessionDirectory {
        get {
            if let directory = storage[SessionDirectoryStorageKey.self] {
                return directory
            }
            let directory = ConnectionRoutingSessionDirectory(
                presenceStore: connectionRoutingService.backend.presenceStore
            )
            storage[SessionDirectoryStorageKey.self] = directory
            return directory
        }
        set { storage[SessionDirectoryStorageKey.self] = newValue }
    }

    var gatewayDispatchBus: any GatewayDispatchBus {
        get {
            if let bus = storage[GatewayDispatchBusStorageKey.self] {
                return bus
            }
            let bus = ConnectionRoutingGatewayDispatchBus(
                dispatchService: connectionRoutingService.backend.dispatchService
            )
            storage[GatewayDispatchBusStorageKey.self] = bus
            return bus
        }
        set { storage[GatewayDispatchBusStorageKey.self] = newValue }
    }

    var gatewaySessionService: GatewaySessionService {
        if hasConnectionRoutingServiceConfigured {
            return GatewaySessionService(
                transport: LocalGatewaySessionTransport(routingService: connectionRoutingService)
            )
        }

        if gatewayRelayConfiguration.mode == .http {
            return GatewaySessionService(
                transport: HTTPGatewaySessionTransport(app: self, configuration: gatewayRelayConfiguration)
            )
        }

        return GatewaySessionService(
            transport: LoggingUnavailableGatewaySessionTransport(
                logger: logger,
                role: imRuntimeRole
            )
        )
    }

    var conversationEventStreamProducer: any ConversationEventStreamProducer {
        get {
            if let producer = storage[ConversationEventStreamProducerStorageKey.self] {
                return producer
            }

            let producer: any ConversationEventStreamProducer
            switch eventStreamConfiguration.driver {
            case .databaseOutbox:
                producer = LocalConversationEventStreamProducer(logger: logger)
            case .kafka:
                producer = KafkaConversationEventStreamProducer(
                    logger: logger,
                    configuration: eventStreamConfiguration,
                    nodeID: imNodeID
                )
            }
            storage[ConversationEventStreamProducerStorageKey.self] = producer
            return producer
        }
        set { storage[ConversationEventStreamProducerStorageKey.self] = newValue }
    }
}

private struct ExplicitDatabaseConversationShardRouter: ConversationShardRouter {
    let database: any Database

    var routerName: String { "explicit-database" }
    var shardIDs: [String] { [SingleShardConversationShardRouter.defaultShardID] }

    func commandDatabase() -> any Database {
        database
    }

    func commandDatabase(forShardID shardID: String) -> any Database {
        database
    }

    func strongReadDatabase() -> any Database {
        database
    }

    func eventualReadDatabase() -> any Database {
        database
    }

    func strongReadDatabase(forShardID shardID: String) -> any Database {
        database
    }

    func eventualReadDatabase(forShardID shardID: String) -> any Database {
        database
    }

    func shardID(forNewConversationID conversationID: UUID) -> String {
        SingleShardConversationShardRouter.defaultShardID
    }

    func shardID(forConversationID conversationID: UUID) async throws -> String {
        SingleShardConversationShardRouter.defaultShardID
    }

    func commandDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        database
    }

    func strongReadDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        database
    }

    func eventualReadDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        database
    }

    func allCommandDatabases() -> [RoutedShardDatabase] {
        [RoutedShardDatabase(shardID: SingleShardConversationShardRouter.defaultShardID, database: database)]
    }
}

struct GatewayRelayMessageRequest: Content {
    let payload: IMTCPMessagePayload
    let recipientUserIDs: [UUID]
    let requestID: UUID?
}

struct GatewayRelayConversationEventRequest: Content {
    let payload: IMTCPConversationEventPayload
    let recipientUserID: UUID
    let requestID: UUID?
}

struct GatewayRelayContactEventRequest: Content {
    let payload: IMTCPContactEventPayload
    let recipientUserID: UUID
    let requestID: UUID?
}

struct GatewayRelayKickSessionRequest: Content {
    let sessionID: UUID
    let reason: IMTCPKickReason
    let message: String
}

struct GatewayRelayKickUserRequest: Content {
    let userID: UUID
    let reason: IMTCPKickReason
    let message: String
}
