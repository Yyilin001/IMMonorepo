import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

public struct V2TLSListenerConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let certificateChainPath: String
    public let privateKeyPath: String

    public init(host: String, port: Int, certificateChainPath: String, privateKeyPath: String) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(port),
              !certificateChainPath.isEmpty,
              !privateKeyPath.isEmpty
        else { throw V2TLSGatewayServerError.invalidConfiguration }
        self.host = host
        self.port = port
        self.certificateChainPath = certificateChainPath
        self.privateKeyPath = privateKeyPath
    }

    func makeTLSConfiguration() throws -> TLSConfiguration {
        let certificates = try NIOSSLCertificate.fromPEMFile(certificateChainPath).map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: certificates, privateKey: .privateKey(key))
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        return configuration
    }
}

public enum V2TLSGatewayServerError: Error, Equatable, Sendable { case invalidConfiguration, alreadyBound, notBound }

/// Injects a fresh session/handler graph for every connection. It deliberately
/// has no environment-variable auth fallback: production composition must
/// provide a real authenticator and a configured V2 domain handler.
public struct V2GatewayConnectionFactory: Sendable {
    private let makeConnection: @Sendable () -> V2GatewayByteStream

    public init(makeConnection: @escaping @Sendable () -> V2GatewayByteStream) {
        self.makeConnection = makeConnection
    }

    func make() -> V2GatewayByteStream { makeConnection() }
}

public final class V2TLSGatewayServer {
    private let configuration: V2TLSListenerConfiguration
    private let sslContext: NIOSSLContext
    private let connectionFactory: V2GatewayConnectionFactory
    private let maximumQueuedInboundBytes: Int
    private let idleTimeoutMilliseconds: Int
    private let transportMetrics: (any V2GatewayTransportMetricsRecorder)?
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(
        configuration: V2TLSListenerConfiguration,
        connectionFactory: V2GatewayConnectionFactory,
        maximumQueuedInboundBytes: Int,
        idleTimeoutMilliseconds: Int,
        transportMetrics: (any V2GatewayTransportMetricsRecorder)? = nil,
        eventLoopThreads: Int = System.coreCount
    ) throws {
        precondition(maximumQueuedInboundBytes > 0 && idleTimeoutMilliseconds > 0 && eventLoopThreads > 0)
        self.configuration = configuration
        self.sslContext = try .init(configuration: configuration.makeTLSConfiguration())
        self.connectionFactory = connectionFactory
        self.maximumQueuedInboundBytes = maximumQueuedInboundBytes
        self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
        self.transportMetrics = transportMetrics
        self.group = .init(numberOfThreads: eventLoopThreads)
    }

    deinit { try? group.syncShutdownGracefully() }

    public func bind() async throws {
        guard channel == nil else { throw V2TLSGatewayServerError.alreadyBound }
        let sslContext = sslContext
        let factory = connectionFactory
        let inboundLimit = maximumQueuedInboundBytes
        let idleTimeoutMilliseconds = idleTimeoutMilliseconds
        let transportMetrics = transportMetrics
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                // This closure is already invoked on the child EventLoop.
                // Both handlers are deliberately loop-confined and therefore
                // must use NIO's synchronous pipeline view rather than the
                // cross-concurrency `ChannelHandler & Sendable` overload.
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    try channel.pipeline.syncOperations.addHandler(
                        V2NIOGatewayChannelHandler(
                            stream: factory.make(),
                            maximumQueuedInboundBytes: inboundLimit,
                            idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                            transportMetrics: transportMetrics
                        )
                    )
                }
            }
            .bind(host: configuration.host, port: configuration.port)
            .get()
        self.channel = channel
    }

    public func shutdown() async throws {
        if let channel {
            self.channel = nil
            try await channel.close().get()
        }
        try await group.shutdownGracefully()
    }

    public func waitUntilClosed() async throws {
        guard let channel else { throw V2TLSGatewayServerError.notBound }
        try await channel.closeFuture.get()
    }
}
