import Foundation
import IMV2Core
import IMV2Server

/// 集中构造客户端会话、连接工厂与 TLS 服务对象。
/// 构造不会绑定端口；`GatewayRuntime.runServices` 在后台依赖就绪后绑定监听。
enum GatewayTransportAssembly {
    /// 每条连接独立创建会话，共享认证器、命令处理器、限流器与连接注册表。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        prepared: GatewayPreparedAssembly,
        handler: V2GatewayDomainCommandHandler,
        authors: V2AuthorPresentationRuntime? = nil
    ) throws -> V2TLSGatewayServer {
        let authenticator = prepared.frontdoor.authenticator
        let commandRateLimiter = prepared.frontdoor.commandRateLimiter
        let preparedGroupEventPageCache = prepared.projection.preparedGroupEventPageCache
        let connectionRegistry = prepared.frontdoor.connectionRegistry
        let transportMetrics = prepared.frontdoor.transportMetrics
        let gatewayEventLoopLagMetrics = prepared.frontdoor.gatewayEventLoopLagMetrics
        let messageSendBudget = V2GatewayMessageSendBudget(
            maximumBytes: configuration.messageSendMaximumInFlightBytesProcess)
        let factory = V2GatewayConnectionFactory {
            let session = V2GatewaySession(
                limits: configuration.connectionLimits,
                authenticator: authenticator,
                capabilityProfile: configuration.capabilityProfile,
                maximumProtobufMessageDepth: configuration.maximumProtobufMessageDepth,
                supportedFrameCompression: configuration.frameCompression,
                maximumUncompressedPayloadBytes: configuration.frameLimits.maximumPayloadBytes,
                compressionThresholdBytes: configuration.frameCompressionThresholdBytes,
                maximumCompressionExpansionRatio: configuration.frameCompressionMaximumExpansionRatio,
                preparedGroupEventPageCache: preparedGroupEventPageCache,
                supportsAuthorPresentationDelta: authors != nil,
                messageSendOperationsEnabled: configuration.messageSendOperationsEnabled,
                maximumMessageSendPayloadBytes: configuration.frameLimits.maximumMessageSendPayloadBytes,
                commandAdmission: commandRateLimiter
            )
            return .init(frameLimits: configuration.frameLimits, session: session, handler: handler, registry: connectionRegistry,
                         authorPresentationDispatcher: authors?.dispatcher, authorPresentationIngress: authors?.ingress,
                         messageSendBudget: messageSendBudget,
                         maximumConcurrentMessageSends: configuration.messageSendMaximumInFlightPerConnection,
                         maximumConcurrentMessageSendBytes: configuration.messageSendMaximumInFlightBytesPerConnection)
        }
        return try V2TLSGatewayServer(
            configuration: configuration.tls,
            connectionFactory: factory,
            maximumConnections: configuration.maximumConnections,
            listenBacklog: configuration.listenBacklog,
            acceptBatchSize: configuration.acceptBatchSize,
            maximumQueuedInboundBytes: configuration.maximumQueuedInboundBytes,
            maximumQueuedInboundChunks: configuration.maximumQueuedInboundChunks,
            authenticationTimeoutMilliseconds: configuration.authenticationTimeoutMilliseconds,
            idleTimeoutMilliseconds: configuration.idleTimeoutMilliseconds,
            transportMetrics: transportMetrics,
            eventLoopLagMetrics: gatewayEventLoopLagMetrics
        )
    }
}
