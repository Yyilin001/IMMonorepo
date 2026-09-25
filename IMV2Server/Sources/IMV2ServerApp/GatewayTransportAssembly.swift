import Foundation
import IMV2Server

/// 集中构造客户端会话、连接工厂与 TLS 监听器；调用方负责启动监听。
enum GatewayTransportAssembly {
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        authenticator: V2PostgresGatewayAuthenticator,
        commandRateLimiter: V2AuthenticatedGatewayCommandRateLimiter,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCache?,
        handler: V2GatewayDomainCommandHandler,
        connectionRegistry: V2DeviceConnectionRegistry,
        transportMetrics: V2GatewayTransportMetrics,
        gatewayEventLoopLagMetrics: V2EventLoopLagMetrics
    ) throws -> V2TLSGatewayServer {
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
                commandAdmission: commandRateLimiter
            )
            return .init(frameLimits: configuration.frameLimits, session: session, handler: handler, registry: connectionRegistry)
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
