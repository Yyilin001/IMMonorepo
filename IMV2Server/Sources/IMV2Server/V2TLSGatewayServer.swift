import Foundation
import Synchronization
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

/// Process-local admission is intentionally independent of the authenticated
/// device registry: TLS handshakes and slow pre-auth sockets consume resources
/// before a device identity exists.
final class V2GatewayConnectionAdmission: Sendable {
    private struct State: Sendable { var active = 0 }
    private let maximumConnections: Int
    private let state = Mutex(State())

    init(maximumConnections: Int) {
        precondition(maximumConnections > 0)
        self.maximumConnections = maximumConnections
    }

    func acquire() -> Bool {
        state.withLock { state in
            guard state.active < maximumConnections else { return false }
            state.active += 1
            return true
        }
    }

    func release() {
        state.withLock { $0.active = max(0, $0.active - 1) }
    }
}

/// Owns exactly one admission token and makes release idempotent across the
/// several NIO lifecycle callbacks a failed handshake may trigger.
private final class V2GatewayConnectionLease: Sendable {
    private let admission: V2GatewayConnectionAdmission
    private let released = Mutex(false)

    init(admission: V2GatewayConnectionAdmission) { self.admission = admission }

    func release() {
        let shouldRelease = released.withLock { released in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { admission.release() }
    }
}

private final class V2GatewayConnectionLeaseHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let lease: V2GatewayConnectionLease
    private let registry: V2GatewayChildChannelRegistry
    private let channel: V2GatewayTrackedChannel

    init(
        lease: V2GatewayConnectionLease,
        registry: V2GatewayChildChannelRegistry,
        channel: any Channel
    ) {
        self.lease = lease
        self.registry = registry
        self.channel = .init(channel)
    }
    func channelInactive(context: ChannelHandlerContext) {
        lease.release()
        registry.remove(channel)
        context.fireChannelInactive()
    }
    func handlerRemoved(context _: ChannelHandlerContext) {
        lease.release()
        registry.remove(channel)
    }
}

/// Channel is event-loop confined but its `close()` operation is explicitly
/// thread-safe. This narrow wrapper lets shutdown retain only the operation it
/// needs without making handlers or application state unchecked-Sendable.
private struct V2GatewayTrackedChannel: @unchecked Sendable {
    let channel: any Channel
    let identity: ObjectIdentifier

    init(_ channel: any Channel) {
        self.channel = channel
        identity = ObjectIdentifier(channel)
    }
}

private final class V2GatewayChildChannelRegistry: Sendable {
    private let channels = Mutex([ObjectIdentifier: V2GatewayTrackedChannel]())

    func insert(_ channel: any Channel) {
        let tracked = V2GatewayTrackedChannel(channel)
        channels.withLock { $0[tracked.identity] = tracked }
    }

    func remove(_ channel: V2GatewayTrackedChannel) {
        _ = channels.withLock { $0.removeValue(forKey: channel.identity) }
    }

    func closeAll() async {
        let snapshot = channels.withLock { Array($0.values) }
        await withTaskGroup(of: Void.self) { group in
            for tracked in snapshot {
                group.addTask {
                    try? await tracked.channel.close().get()
                }
            }
        }
    }
}

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
    private let maximumConnections: Int
    private let listenBacklog: Int32
    private let acceptBatchSize: UInt
    private let maximumQueuedInboundBytes: Int
    private let maximumQueuedInboundChunks: Int
    private let authenticationTimeoutMilliseconds: Int
    private let idleTimeoutMilliseconds: Int
    private let transportMetrics: any V2GatewayTransportMetricsRecorder
    private let eventLoopLagMetrics: V2EventLoopLagMetrics?
    private let childChannels = V2GatewayChildChannelRegistry()
    private let foregroundWriteScheduler = V2NIOForegroundWriteScheduler()
    /// Keep accept work off the child channel group so a coordinated reconnect
    /// cannot consume one of the event loops serving established TLS streams.
    private let acceptorGroup: MultiThreadedEventLoopGroup
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(
        configuration: V2TLSListenerConfiguration,
        connectionFactory: V2GatewayConnectionFactory,
        maximumConnections: Int,
        listenBacklog: Int,
        acceptBatchSize: Int,
        maximumQueuedInboundBytes: Int,
        maximumQueuedInboundChunks: Int,
        authenticationTimeoutMilliseconds: Int,
        idleTimeoutMilliseconds: Int,
        transportMetrics: any V2GatewayTransportMetricsRecorder,
        eventLoopLagMetrics: V2EventLoopLagMetrics? = nil,
        eventLoopThreads: Int = System.coreCount
    ) throws {
        _ = try V2GatewayConnectionTimeouts(authenticationMilliseconds: authenticationTimeoutMilliseconds,
                                             idleMilliseconds: idleTimeoutMilliseconds)
        precondition(
            maximumConnections > 0 &&
            listenBacklog > 0 && listenBacklog <= Int(Int32.max) &&
            acceptBatchSize > 0 &&
            maximumQueuedInboundBytes > 0 &&
            maximumQueuedInboundChunks > 0 &&
            eventLoopThreads > 0
        )
        self.configuration = configuration
        self.sslContext = try .init(configuration: configuration.makeTLSConfiguration())
        self.connectionFactory = connectionFactory
        self.maximumConnections = maximumConnections
        self.listenBacklog = Int32(listenBacklog)
        self.acceptBatchSize = UInt(acceptBatchSize)
        self.maximumQueuedInboundBytes = maximumQueuedInboundBytes
        self.maximumQueuedInboundChunks = maximumQueuedInboundChunks
        self.authenticationTimeoutMilliseconds = authenticationTimeoutMilliseconds
        self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
        self.transportMetrics = transportMetrics
        self.eventLoopLagMetrics = eventLoopLagMetrics
        self.acceptorGroup = .init(numberOfThreads: 1)
        self.group = .init(numberOfThreads: eventLoopThreads)
        eventLoopLagMetrics?.start(on: self.group)
    }

    deinit {
        eventLoopLagMetrics?.stop()
        try? group.syncShutdownGracefully()
        try? acceptorGroup.syncShutdownGracefully()
    }

    public func bind() async throws {
        guard channel == nil else { throw V2TLSGatewayServerError.alreadyBound }
        let sslContext = sslContext
        let factory = connectionFactory
        let admission = V2GatewayConnectionAdmission(maximumConnections: maximumConnections)
        let listenBacklog = listenBacklog
        let acceptBatchSize = acceptBatchSize
        let inboundLimit = maximumQueuedInboundBytes
        let inboundChunkLimit = maximumQueuedInboundChunks
        let authenticationTimeoutMilliseconds = authenticationTimeoutMilliseconds
        let idleTimeoutMilliseconds = idleTimeoutMilliseconds
        let transportMetrics = transportMetrics
        let childChannels = childChannels
        let foregroundWriteScheduler = foregroundWriteScheduler
        let channel = try await ServerBootstrap(group: acceptorGroup, childGroup: group)
            .serverChannelOption(ChannelOptions.backlog, value: listenBacklog)
            .serverChannelOption(ChannelOptions.maxMessagesPerRead, value: acceptBatchSize)
            // After an abrupt process exit, accepted TCP sockets can remain
            // in TIME_WAIT.  Allow the replacement process to reclaim the
            // listener immediately without permitting two live listeners to
            // bind the same address.
            .serverChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelInitializer { channel in
                guard admission.acquire() else {
                    transportMetrics.connectionRejected(reason: .connectionLimit)
                    return channel.close()
                }
                let lease = V2GatewayConnectionLease(admission: admission)
                childChannels.insert(channel)
                // This closure is already invoked on the child EventLoop.
                // Both handlers are deliberately loop-confined and therefore
                // must use NIO's synchronous pipeline view rather than the
                // cross-concurrency `ChannelHandler & Sendable` overload.
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(V2GatewayConnectionLeaseHandler(
                        lease: lease,
                        registry: childChannels,
                        channel: channel
                    ))
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    try channel.pipeline.syncOperations.addHandler(
                        V2NIOGatewayChannelHandler(
                            stream: factory.make(),
                            maximumQueuedInboundBytes: inboundLimit,
                            maximumQueuedInboundChunks: inboundChunkLimit,
                            authenticationTimeoutMilliseconds: authenticationTimeoutMilliseconds,
                            idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                            transportMetrics: transportMetrics,
                            foregroundWriteScheduler: foregroundWriteScheduler
                        )
                    )
                }.flatMapError { error in
                    lease.release()
                    childChannels.remove(.init(channel))
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: configuration.host, port: configuration.port)
            .get()
        self.channel = channel
    }

    public func shutdown() async throws {
        eventLoopLagMetrics?.stop()
        try await stopAccepting()
        await childChannels.closeAll()
        try await group.shutdownGracefully()
        try await acceptorGroup.shutdownGracefully()
    }

    /// Closes only the public listener. Existing child channels remain alive
    /// until `shutdown()` so in-flight commands can finish during the bounded
    /// application drain, while no new work enters the process.
    public func stopAccepting() async throws {
        guard let channel else { return }
        self.channel = nil
        try await channel.close().get()
    }

    public func waitUntilClosed() async throws {
        guard let channel else { throw V2TLSGatewayServerError.notBound }
        try await channel.closeFuture.get()
    }
}
