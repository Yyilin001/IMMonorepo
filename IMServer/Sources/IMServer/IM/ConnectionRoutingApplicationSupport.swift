import Foundation
import Vapor

final class ConnectionRoutingLifecycle: LifecycleHandler, @unchecked Sendable {
    func shutdownAsync(_ application: Application) async {
        await application.connectionRoutingService.backend.shutdown()
    }
}

private struct IMNodeIDStorageKey: StorageKey {
    typealias Value = String
}

private struct IMRealtimeCellConfigurationStorageKey: StorageKey {
    typealias Value = IMRealtimeCellConfiguration
}

private struct ConnectionRoutingServiceStorageKey: StorageKey {
    typealias Value = ConnectionRoutingService
}

private struct RoutingMetricsStorageKey: StorageKey {
    typealias Value = RoutingMetrics
}

private struct IMTCPConnectionCloseBatcherStorageKey: StorageKey {
    typealias Value = IMTCPConnectionCloseBatcher
}

private struct IMRedisRoutingConfigurationStorageKey: StorageKey {
    typealias Value = IMRedisRoutingConfiguration
}

extension Application {
    var hasConnectionRoutingServiceConfigured: Bool {
        storage[ConnectionRoutingServiceStorageKey.self] != nil
    }

    var imNodeID: String {
        get {
            if let nodeID = storage[IMNodeIDStorageKey.self] {
                return nodeID
            }

            let nodeID = Environment.get("IM_NODE_ID") ?? UUID().uuidString.lowercased()
            storage[IMNodeIDStorageKey.self] = nodeID
            return nodeID
        }
        set {
            storage[IMNodeIDStorageKey.self] = newValue
        }
    }

    var imRealtimeCellConfiguration: IMRealtimeCellConfiguration {
        get {
            if let configuration = storage[IMRealtimeCellConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = (try? IMRealtimeCellConfiguration.load(from: environment)) ?? .default
            storage[IMRealtimeCellConfigurationStorageKey.self] = configuration
            return configuration
        }
        set {
            storage[IMRealtimeCellConfigurationStorageKey.self] = newValue
        }
    }

    var imRealtimeCellID: String {
        imRealtimeCellConfiguration.cellID
    }

    var routingMetrics: RoutingMetrics {
        get {
            if let metrics = storage[RoutingMetricsStorageKey.self] {
                return metrics
            }

            let metrics = RoutingMetrics()
            storage[RoutingMetricsStorageKey.self] = metrics
            return metrics
        }
        set {
            storage[RoutingMetricsStorageKey.self] = newValue
        }
    }

    var imTCPConnectionCloseBatcher: IMTCPConnectionCloseBatcher {
        get {
            if let batcher = storage[IMTCPConnectionCloseBatcherStorageKey.self] {
                return batcher
            }
            let batcher = IMTCPConnectionCloseBatcher(application: self)
            storage[IMTCPConnectionCloseBatcherStorageKey.self] = batcher
            return batcher
        }
        set {
            storage[IMTCPConnectionCloseBatcherStorageKey.self] = newValue
        }
    }

    var connectionRoutingService: ConnectionRoutingService {
        get {
            if let service = storage[ConnectionRoutingServiceStorageKey.self] {
                return service
            }
            logger.critical("ConnectionRoutingService accessed before configuration; using local fallback")
            let service = ConnectionRoutingService(
                app: self,
                backend: LocalConnectionRoutingBackend(nodeID: imNodeID)
            )
            storage[ConnectionRoutingServiceStorageKey.self] = service
            return service
        }
        set {
            storage[ConnectionRoutingServiceStorageKey.self] = newValue
        }
    }

    var imRedisRoutingConfigurationOverride: IMRedisRoutingConfiguration? {
        get { storage[IMRedisRoutingConfigurationStorageKey.self] }
        set { storage[IMRedisRoutingConfigurationStorageKey.self] = newValue }
    }

    func configureConnectionRoutingServiceIfNeeded() async throws {
        if hasConnectionRoutingServiceConfigured {
            return
        }

        let configuration = imRedisRoutingConfigurationOverride ?? IMRedisRoutingConfiguration.load(from: environment)
        let logger = self.logger

        if environment == .production, configuration.mode != .redis {
            throw RedisRoutingError.redisRequiredInProduction
        }
        try configuration.validateTopologySupport()

        let backend: any ConnectionRoutingBackend
        switch configuration.mode {
        case .local:
            backend = LocalConnectionRoutingBackend(nodeID: imNodeID)
        case .redis:
            if configuration.deploymentTopology == .cluster {
                let clusterBackend = try ValkeyClusterConnectionRoutingBackend(
                    configuration: configuration,
                    nodeDispatchConfiguration: nodeDispatchConfiguration,
                    nodeID: imNodeID,
                    cellID: imRealtimeCellID,
                    logger: logger
                )
                connectionRoutingService = ConnectionRoutingService(app: self, backend: clusterBackend)
                try await clusterBackend.start(app: self)
                return
            }
            if environment == .production {
                let redisBackend = try RedisConnectionRoutingBackend(
                    configuration: configuration,
                    nodeDispatchConfiguration: nodeDispatchConfiguration,
                    nodeID: imNodeID,
                    cellID: imRealtimeCellID,
                    logger: logger,
                    eventLoop: eventLoopGroup.next()
                )
                connectionRoutingService = ConnectionRoutingService(app: self, backend: redisBackend)
                try await redisBackend.start(app: self)
                return
            }

            do {
                let redisBackend = try RedisConnectionRoutingBackend(
                    configuration: configuration,
                    nodeDispatchConfiguration: nodeDispatchConfiguration,
                    nodeID: imNodeID,
                    cellID: imRealtimeCellID,
                    logger: logger,
                    eventLoop: eventLoopGroup.next()
                )
                connectionRoutingService = ConnectionRoutingService(app: self, backend: redisBackend)
                try await redisBackend.start(app: self)
                return
            } catch {
                let metadata: Logger.Metadata = [
                    "node_id": .string(imNodeID),
                    "error": .string(String(describing: error))
                ]
                if environment == .testing {
                    logger.debug("Redis routing backend unavailable; falling back to local routing", metadata: metadata)
                } else {
                    logger.warning("Redis routing backend unavailable; falling back to local routing", metadata: metadata)
                }
                backend = LocalConnectionRoutingBackend(nodeID: imNodeID)
            }
        }

        connectionRoutingService = ConnectionRoutingService(app: self, backend: backend)
        try await backend.start(app: self)
    }
}
