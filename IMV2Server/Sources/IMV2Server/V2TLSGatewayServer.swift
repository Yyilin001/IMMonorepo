import Foundation
import Synchronization
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

/// TLS 网关监听配置。
public struct V2TLSListenerConfiguration: Sendable {
    /// 监听主机。
    public let host: String
    /// 监听端口。
    public let port: Int
    /// PEM 证书链文件路径。
    public let certificateChainPath: String
    /// PEM 私钥文件路径。
    public let privateKeyPath: String

    /// 校验并保存监听配置。
    ///
    /// - Parameters:
    ///   - host: 监听主机，去除首尾空白后需非空。
    ///   - port: 监听端口，需落在 `1...65535`。
    ///   - certificateChainPath: 证书链路径，需非空。
    ///   - privateKeyPath: 私钥路径，需非空。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2TLSGatewayServerError/invalidConfiguration``。
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

    /// 构造仅允许 TLS 1.3 的服务端配置。
    ///
    /// - Returns: 加载证书链与私钥后的 TLS 配置。
    /// - Throws: 证书或私钥无法读取时抛出对应错误。
    func makeTLSConfiguration() throws -> TLSConfiguration {
        let certificates = try NIOSSLCertificate.fromPEMFile(certificateChainPath).map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: certificates, privateKey: .privateKey(key))
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        return configuration
    }
}

/// TLS 网关服务错误。
public enum V2TLSGatewayServerError: Error, Equatable, Sendable {
    /// 监听配置或证书材料非法。
    case invalidConfiguration
    /// 监听地址已被占用。
    case alreadyBound
    /// 服务尚未绑定监听地址。
    case notBound
}

/// 进程内连接准入。
///
/// 它刻意独立于已认证设备注册表：TLS 握手与认证前的慢速套接字在设备身份存在之前
/// 就已经在消耗资源，因此必须单独限流。
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

/// 网关连接租约。
///
/// 它恰好持有一个准入令牌，并使释放操作在失败握手可能触发的多个
/// NIO 生命周期回调之间保持幂等。
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

/// 受跟踪的子通道包装。
///
/// 通道本身限定在事件循环内，但其 `close()` 明确是线程安全的。
/// 该窄包装让关闭流程只保留它需要的操作，而不必把处理器或应用状态标记为
/// `@unchecked Sendable`。
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

/// 为每条连接注入全新的会话与处理器图。
///
/// 它刻意不提供基于环境变量的兜底认证：生产组合必须提供真实的认证器与已配置的
/// V2 领域处理器。
public struct V2GatewayConnectionFactory: Sendable {
    private let makeConnection: @Sendable () -> V2GatewayByteStream

    /// 以连接构造闭包创建工厂。
    ///
    /// - Parameter makeConnection: 每次连接时调用的构造闭包。
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
    /// 把接入工作放在子通道组之外执行。
    ///
    /// 这样一次大规模重连不会占用正在服务既有 TLS 流的事件循环。
    private let acceptorGroup: MultiThreadedEventLoopGroup
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    /// 构造 TLS 网关服务。
    ///
    /// 会先行校验认证与空闲超时毫米数可精确表示，再校验连接数、监听积压、接入批量、
    /// 入站排队字节与分片上限以及事件循环线程数均为正值，并加载 TLS 材料与指标记录器。
    ///
    /// - Parameters:
    ///   - configuration: 监听与证书配置。
    ///   - connectionFactory: 连接构造工厂。
    ///   - maximumConnections: 进程内最大连接数，需大于零。
    ///   - listenBacklog: 监听积压长度，需落在 `1...Int32.max`。
    ///   - acceptBatchSize: 单次接入批量，需大于零。
    ///   - maximumQueuedInboundBytes: 单连接入站排队字节上限，需大于零。
    ///   - maximumQueuedInboundChunks: 单连接入站排队分片上限，需大于零。
    ///   - authenticationTimeoutMilliseconds: 认证阶段超时毫秒数。
    ///   - idleTimeoutMilliseconds: 空闲超时毫秒数。
    ///   - transportMetrics: 传输指标记录器。
    ///   - eventLoopLagMetrics: 事件循环滞后指标，可选。
    ///   - eventLoopThreads: 事件循环线程数，需大于零，默认取系统核心数。
    /// - Throws: 超时配置不可表示、任一参数越界或 TLS 材料加载失败时抛出
    ///   ``V2TLSGatewayServerError/invalidConfiguration`` 或底层 TLS 错误。
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

    /// 绑定监听地址并开始接受连接。
    ///
    /// 绑定成功后记录监听通道；子通道在建立时会登记进注册表，
    /// 使关闭流程可以统一处理尚未结束的连接。
    ///
    /// - Throws: 监听地址无法绑定，或构造子通道失败时抛出
    ///   ``V2TLSGatewayServerError/alreadyBound`` 或底层 NIO 错误。
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
            // 进程突然退出后，已接受的 TCP 套接字可能仍处于 TIME_WAIT。
            // 允许替代进程立即重新取得监听地址，
            // 同时不允许两个仍活动的监听器绑定同一地址。
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
                // 此闭包已在子 EventLoop 上调用。两个处理器都有意限制在该循环内，
                // 因而须使用 NIO 的同步流水线视图，
                // 而非跨并发域的 `ChannelHandler & Sendable` 重载。
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

    /// 关闭监听、子通道与事件循环组。
    ///
    /// 顺序为停止接受新连接、关闭全部子通道、再依次优雅关闭连接与接入事件循环组，
    /// 使在途命令有界完成后再释放线程资源。
    ///
    /// - Throws: 关闭监听或事件循环组失败时抛出。
    public func shutdown() async throws {
        eventLoopLagMetrics?.stop()
        try await stopAccepting()
        await childChannels.closeAll()
        try await group.shutdownGracefully()
        try await acceptorGroup.shutdownGracefully()
    }

    /// 只关闭对外监听。
    ///
    /// 既有子通道会保持存活直到 ``shutdown()``，使在途命令能在有界的应用排水期内完成，
    /// 同时不再有新工作进入进程。
    public func stopAccepting() async throws {
        guard let channel else { return }
        self.channel = nil
        try await channel.close().get()
    }

    /// 等待监听通道关闭。
    ///
    /// 用于让进程在监听到达关闭事件后自然退出。
    ///
    /// - Throws: 服务尚未绑定监听地址时抛出 ``V2TLSGatewayServerError/notBound``。
    public func waitUntilClosed() async throws {
        guard let channel else { throw V2TLSGatewayServerError.notBound }
        try await channel.closeFuture.get()
    }
}
