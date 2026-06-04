import Fluent
import Foundation
import Kafka
import NIOCore
import Vapor

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
        await application.shutdownConversationEventStreamProducerIfConfigured()
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

    func shutdownConversationEventStreamProducerIfConfigured() async {
        if let producer = storage[ConversationEventStreamProducerStorageKey.self] {
            await producer.shutdown()
        }
    }
}

struct ExplicitDatabaseConversationShardRouter: ConversationShardRouter {
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
    let packetBase64: String
    let recipientUserIDs: [UUID]
    let requestID: UUID?
}

struct GatewayRelayDomainEventDeliveryRequest: Content {
    let ownerUserID: UUID
    let eventID: UUID
    let requestID: UUID?
}

struct GatewayRelayDomainEventPayloadRequest: Content {
    let payloadBase64: String
    let recipientUserIDs: [UUID]
    let requestID: UUID?
}

struct GatewayRelayDomainEventPayloadBatchRequest: Content {
    let deliveries: [GatewayRelayDomainEventPayloadBatchEntry]
    let requestID: UUID?
}

struct GatewayRelayDomainEventPayloadBatchEntry: Content {
    let ownerUserID: UUID
    let payloadBase64: String
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

struct GatewayRelaySessionCountsRequest: Content {
    let sessionIDs: [UUID]
}

struct GatewayRelaySessionCountsResponse: Content {
    let counts: [UUID: Int]
}
