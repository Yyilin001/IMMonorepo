import Vapor

/// Components that still use RediStack's single-node pool. They must never be
/// pointed at a Redis/Valkey Cluster until their storage model and transport
/// have been migrated independently.
enum IMRedisStandaloneConsumer: String, CaseIterable, Sendable, Hashable {
    case connectionRouting = "connection-routing"
    case nodeRealtimeDispatch = "node-realtime-dispatch"
    case hotConversationLimiter = "hot-conversation-limiter"
    case authSessionCache = "auth-session-cache"
    case authRateLimiter = "auth-rate-limiter"
    case timelineSinceInvalidation = "timeline-since-cache-invalidation"
}

enum IMRedisTopologyCompatibility {
    static func validate(
        topology: IMRedisDeploymentTopology,
        standaloneConsumers: Set<IMRedisStandaloneConsumer>
    ) throws {
        switch topology {
        case .standalone:
            return
        case .unsupported(let value):
            throw RedisRoutingError.invalidRedisDeploymentTopology(value)
        case .cluster:
            guard !standaloneConsumers.isEmpty else {
                return
            }
            throw RedisRoutingError.redisClusterTopologyUnsupportedByComponents(
                standaloneConsumers
                    .map(\.rawValue)
                    .sorted()
            )
        }
    }

    static func configuredStandaloneConsumers(
        app: Application,
        routingConfiguration: IMRedisRoutingConfiguration,
        authSessionCacheConfiguration: AuthSessionCacheConfiguration,
        authSecurityConfiguration: AuthSecurityConfiguration
    ) -> Set<IMRedisStandaloneConsumer> {
        var consumers: Set<IMRedisStandaloneConsumer> = []
        let routingUsesRedis = routingConfiguration.mode == .redis
            && (app.environment == .production || routingConfiguration.url?.isEmpty == false)
        let configuresConnectionRouting = app.imRuntimeRole.servesGateway
            || (
                app.imRuntimeRole == .streamConsumer
                    && app.streamConsumerConfiguration.isEnabled("realtime-delivery-consumer")
            )

        if routingUsesRedis && configuresConnectionRouting {
            if routingConfiguration.deploymentTopology != .cluster {
                consumers.insert(.connectionRouting)
            }
            if app.nodeDispatchConfiguration.mode == .redis {
                consumers.insert(.nodeRealtimeDispatch)
            }
        }

        if app.imRuntimeRole.servesCommandAPI,
           app.hotConversationConfiguration.limiterMode == .redis,
           routingConfiguration.deploymentTopology != .cluster {
            consumers.insert(.hotConversationLimiter)
        }
        if authSessionCacheConfiguration.mode == .redis,
           routingConfiguration.deploymentTopology != .cluster {
            consumers.insert(.authSessionCache)
        }
        if authSecurityConfiguration.rateLimitBackend == .redis,
           routingConfiguration.deploymentTopology != .cluster {
            consumers.insert(.authRateLimiter)
        }
        if app.timelineReadConfiguration.requiresSinceCacheInvalidation,
           app.timelineSinceCacheInvalidationConfiguration.mode == .redis,
           routingConfiguration.deploymentTopology != .cluster {
            consumers.insert(.timelineSinceInvalidation)
        }
        return consumers
    }
}
