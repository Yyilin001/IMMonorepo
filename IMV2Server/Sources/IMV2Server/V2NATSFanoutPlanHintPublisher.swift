import Foundation
import Synchronization
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

/// 非权威的唤醒提示。
///
/// 消费方会从 PostgreSQL 重新读取全部持久化事实；提示丢失或重复都不会决定工作是否完成。
public struct V2NATSFanoutPlanHint: Codable, Equatable, Sendable {
    /// 来源事件标识。
    public let sourceEventID: String
    /// 扇出计划标识。
    public let planID: String

    /// 由扇出触发构造提示。
    ///
    /// - Parameter trigger: 扇出触发。
    public init(trigger: V2FanoutPlanTrigger) {
        sourceEventID = trigger.sourceEventID.rawValue
        planID = trigger.planID.rawValue
    }
}

/// NATS 扇出提示的发布配置。
public struct V2NATSFanoutHintConfiguration: Equatable, Sendable {
    /// 消息代理地址。
    public let url: URL
    /// 发布主题。
    public let subject: String
    /// 可选的认证令牌。
    public let token: String?
    /// 可选的 CA 证书路径。
    public let tlsCAPath: String?
    /// 可选的 TLS 服务端名称。
    public let tlsServerName: String?
    /// 确认超时秒数。
    ///
    /// 用于约束一次可选的唤醒提示：持久化的 PostgreSQL 推进绝不能因为代理连接无响应
    /// 而无限期等待。
    public let acknowledgementTimeout: TimeInterval
    let acknowledgementTimeoutNanoseconds: Int64

    public init(
        url: URL,
        subject: String,
        token: String? = nil,
        tlsCAPath: String? = nil,
        tlsServerName: String? = nil,
        acknowledgementTimeout: TimeInterval = 2
    ) throws {
        guard let scheme = url.scheme?.lowercased(),
              ["nats", "tls"].contains(scheme),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              subject.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil,
              let timeoutNanoseconds = v2TimeoutNanoseconds(acknowledgementTimeout),
              acknowledgementTimeout <= 30
        else { throw V2NATSFanoutHintConfigurationError.invalidConfiguration }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        let normalizedCAPath = tlsCAPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServerName = tlsServerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken?.isEmpty != true,
              (isLoopback || normalizedToken != nil),
              (scheme == "tls" || isLoopback),
              (scheme == "tls" || (normalizedCAPath == nil && normalizedServerName == nil)),
              normalizedCAPath?.hasPrefix("/") != false,
              normalizedServerName?.isEmpty != true
        else { throw V2NATSFanoutHintConfigurationError.invalidConfiguration }
        self.url = url
        self.subject = subject
        self.token = normalizedToken
        self.tlsCAPath = normalizedCAPath
        self.tlsServerName = normalizedServerName
        self.acknowledgementTimeout = acknowledgementTimeout
        self.acknowledgementTimeoutNanoseconds = timeoutNanoseconds
    }

    var usesTLS: Bool { url.scheme?.lowercased() == "tls" }
}

/// 扇出提示配置错误。
public enum V2NATSFanoutHintConfigurationError: Error, Equatable, Sendable { case invalidConfiguration }

/// 扇出计划提示的发布能力。
public protocol V2FanoutPlanHintPublishing: Sendable {
    /// 发布一条扇出提示。
    ///
    /// - Parameter trigger: 扇出触发。
    /// - Throws: 连接或发布失败时抛出。
    func publishHint(_ trigger: V2FanoutPlanTrigger) async throws
}

/// 仅基于运行时 NIO 依赖实现的最小 Core NATS CONNECT/PUB 发布器。
///
/// 在 `PUB` 之后发送 `PING`，要求代理在提示被视为已发布之前解析完全部前置命令。
/// 该 actor 为每个发布器保留一条串行连接，并在任何失败时丢弃它：既避免每条提示都做一次
/// TCP 握手，又不让失败的通道污染后续发布。外层持久化包装器在 PostgreSQL 规划器完成之后
/// 会刻意忽略这里的错误。
public actor V2NATSFanoutPlanHintPublisher: V2FanoutPlanHintPublishing {
    private struct Connect: Encodable {
        let verbose = false
        let pedantic = false
        let token: String?

        enum CodingKeys: String, CodingKey {
            case verbose
            case pedantic
            case token = "auth_token"
        }
    }

    private struct Connection {
        let channel: any Channel
        let handler: V2NATSConnectionHandler
    }

    private let configuration: V2NATSFanoutHintConfiguration
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var retainedConnection: Connection?

    /// 以配置构造发布器。
    ///
    /// - Parameter configuration: 连接与主题配置。
    public init(configuration: V2NATSFanoutHintConfiguration) { self.configuration = configuration }
    deinit {
        retainedConnection?.channel.close(promise: nil)
        try? eventLoopGroup.syncShutdownGracefully()
    }

    /// 发布一条扇出提示并等待代理确认。
    ///
    /// - Parameter trigger: 扇出触发。
    /// - Throws: 连接建立、发布或确认超时失败时抛出。
    public func publishHint(_ trigger: V2FanoutPlanTrigger) async throws {
        let timeout = TimeAmount.nanoseconds(configuration.acknowledgementTimeoutNanoseconds)
        let connection = try await connectedChannel(timeout: timeout)
        let channel = connection.value.channel
        let acknowledgement = try connection.value.handler.beginAcknowledgement(
            eventLoop: channel.eventLoop
        )
        let watchdog = channel.eventLoop.scheduleTask(in: timeout) {
            if connection.value.handler.timeout(acknowledgement) {
                channel.close(promise: nil)
            }
        }
        defer { watchdog.cancel() }
        do {
            let payload = try JSONEncoder().encode(V2NATSFanoutPlanHint(trigger: trigger))
            let connect = String(decoding: try JSONEncoder().encode(Connect(token: configuration.token)), as: UTF8.self)
            var buffer = channel.allocator.buffer(capacity: payload.count + connect.utf8.count + configuration.subject.utf8.count + 40)
            if connection.isNew {
                buffer.writeString("CONNECT \(connect)\r\n")
            }
            buffer.writeString("PUB \(configuration.subject) \(payload.count)\r\n")
            buffer.writeBytes(payload)
            buffer.writeString("\r\nPING\r\n")
            try await channel.writeAndFlush(buffer).get()
            try await acknowledgement.awaitBrokerConfirmation()
        } catch {
            await discardRetainedConnection(connection.value)
            throw error
        }
    }

    private func connectedChannel(timeout: TimeAmount) async throws -> (value: Connection, isNew: Bool) {
        if let retainedConnection, retainedConnection.channel.isActive {
            return (retainedConnection, false)
        }
        retainedConnection = nil
        let handler = V2NATSConnectionHandler()
        let sslContext: NIOSSLContext?
        if configuration.usesTLS {
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.minimumTLSVersion = .tlsv13
            if let path = configuration.tlsCAPath {
                tls.trustRoots = .certificates(
                    try NIOSSLCertificate.fromPEMFile(path)
                )
            }
            sslContext = try NIOSSLContext(configuration: tls)
        } else {
            sslContext = nil
        }
        let serverName = configuration.tlsServerName ?? configuration.url.host!
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.connectTimeout, value: timeout)
            .channelInitializer { channel in
                do {
                    if let sslContext {
                        let tlsHandler = try NIOSSLClientHandler(
                            context: sslContext,
                            serverHostname: serverName
                        )
                        try channel.pipeline.syncOperations.addHandler(tlsHandler)
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: configuration.url.host!, port: configuration.url.port ?? 4222)
            .get()
        let connection = Connection(channel: channel, handler: handler)
        retainedConnection = connection
        return (connection, true)
    }

    private func discardRetainedConnection(_ connection: Connection) async {
        if retainedConnection?.channel === connection.channel {
            retainedConnection = nil
        }
        try? await connection.channel.close().get()
    }
}

/// 单个处理器持有一条保活 Core NATS 连接的生命周期。
///
/// 除了关联发布器串行的 PING/PONG 确认之外，它还会在连接空闲时应答代理主动发起的 PING 帧。
private final class V2NATSConnectionHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private struct State: Sendable {
        var pendingBytes = Data()
        var acknowledgement: V2NATSPublishAcknowledgement?
    }

    private enum InboundAction {
        case answerPing
        case confirm(V2NATSPublishAcknowledgement)
        case fail(V2NATSPublishAcknowledgement?, V2NATSPublishError)
    }

    private let state = Mutex(State())

    func beginAcknowledgement(eventLoop: any EventLoop) throws -> V2NATSPublishAcknowledgement {
        let acknowledgement = V2NATSPublishAcknowledgement(eventLoop: eventLoop)
        let installed = state.withLock { state in
            guard state.acknowledgement == nil else { return false }
            state.acknowledgement = acknowledgement
            return true
        }
        guard installed else { throw V2NATSPublishError.overlappingPublish }
        return acknowledgement
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let received = buffer.readData(length: buffer.readableBytes) else { return }
        for action in consumeLines(received) {
            switch action {
            case .answerPing:
                var response = context.channel.allocator.buffer(capacity: 6)
                response.writeString("PONG\r\n")
                context.writeAndFlush(NIOAny(response), promise: nil)
            case .confirm(let acknowledgement):
                acknowledgement.succeed()
            case .fail(let acknowledgement, let error):
                acknowledgement?.fail(error)
                context.close(promise: nil)
            }
        }
    }

    func channelInactive(context _: ChannelHandlerContext) {
        failPending(V2NATSPublishError.connectionClosedBeforeConfirmation)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failPending(error)
        context.close(promise: nil)
    }

    /// 仅由该 channel 自身的事件循环看门狗调用。
    ///
    /// - Parameter acknowledgement: 可能仍未完成的发布确认。
    /// - Returns: 若本次调用真正完成了确认则返回 `true`；已完成过则返回 `false`。
    @discardableResult
    func timeout(_ acknowledgement: V2NATSPublishAcknowledgement) -> Bool {
        let shouldFail = state.withLock { state in
            guard state.acknowledgement === acknowledgement else { return false }
            state.acknowledgement = nil
            return true
        }
        if shouldFail {
            acknowledgement.fail(V2NATSPublishError.acknowledgementTimedOut)
        }
        return shouldFail
    }

    private func consumeLines(_ received: Data) -> [InboundAction] {
        state.withLock { state in
            var actions: [InboundAction] = []
            state.pendingBytes.append(received)
            guard state.pendingBytes.count <= 64 * 1_024 else {
                let acknowledgement = state.acknowledgement
                state.acknowledgement = nil
                state.pendingBytes.removeAll(keepingCapacity: false)
                return [.fail(acknowledgement, .invalidBrokerFrame)]
            }
            parsing: while let delimiter = state.pendingBytes.range(of: Data([13, 10])) {
                let line = String(data: state.pendingBytes[..<delimiter.lowerBound], encoding: .utf8)
                state.pendingBytes.removeSubrange(..<delimiter.upperBound)
                guard let line else {
                    let acknowledgement = state.acknowledgement
                    state.acknowledgement = nil
                    actions.append(.fail(acknowledgement, .invalidBrokerFrame))
                    break parsing
                }
                switch line {
                case "PING":
                    actions.append(.answerPing)
                case "PONG":
                    if let acknowledgement = state.acknowledgement {
                        state.acknowledgement = nil
                        actions.append(.confirm(acknowledgement))
                    }
                case let error where error.hasPrefix("-ERR"):
                    let acknowledgement = state.acknowledgement
                    state.acknowledgement = nil
                    actions.append(.fail(acknowledgement, .brokerRejected))
                    break parsing
                default:
                    // Initial INFO and optional +OK lines precede the PONG.
                    continue
                }
            }
            return actions
        }
    }

    private func failPending(_ error: any Error) {
        let acknowledgement = state.withLock { state in
            defer { state.acknowledgement = nil }
            return state.acknowledgement
        }
        acknowledgement?.fail(error)
    }
}

/// 发布确认。
///
/// 确认可由事件循环回调、看门狗或 channel 关闭三者中任意一方完成；
/// 通过互斥锁保证完成只发生一次。
private final class V2NATSPublishAcknowledgement: Sendable {
    private let confirmation: EventLoopPromise<Void>
    private let didResolve = Mutex(false)

    init(eventLoop: any EventLoop) {
        confirmation = eventLoop.makePromise(of: Void.self)
    }

    func awaitBrokerConfirmation() async throws {
        try await confirmation.futureResult.get()
    }

    func succeed() {
        guard markResolved() else { return }
        confirmation.succeed(())
    }

    func fail(_ error: any Error) {
        guard markResolved() else { return }
        confirmation.fail(error)
    }

    private func markResolved() -> Bool {
        didResolve.withLock { didResolve in
            guard !didResolve else { return false }
            didResolve = true
            return true
        }
    }
}

private enum V2NATSPublishError: Error, Equatable, Sendable {
    case acknowledgementTimedOut
    case connectionClosedBeforeConfirmation
    case invalidBrokerFrame
    case brokerRejected
    case overlappingPublish
}

/// 尽力而为的扇出计划提示发布器。
///
/// 先完成持久化发布，再把提示异步提交给代理：提示失败不影响持久化结果，
/// 消费方仍可通过轮询发现待处理计划。
public struct V2BestEffortFanoutPlanHintPublisher: V2BatchFanoutPlanPublisher {
    private let durablePublisher: any V2FanoutPlanPublisher
    private let hints: V2AsynchronousFanoutHintDispatcher

    /// 组合持久化发布器与提示发布器。
    ///
    /// - Parameters:
    ///   - durablePublisher: 完成持久化发布的发布器。
    ///   - hintPublisher: 发送非权威提示的发布器。
    public init(durablePublisher: any V2FanoutPlanPublisher, hintPublisher: any V2FanoutPlanHintPublishing) {
        self.durablePublisher = durablePublisher
        hints = .init(publisher: hintPublisher)
    }

    /// 先持久化发布，再异步提交提示。
    ///
    /// - Parameter trigger: 扇出触发。
    /// - Throws: 持久化发布失败时抛出；提示失败不会向上传播。
    public func publish(_ trigger: V2FanoutPlanTrigger) async throws {
        try await durablePublisher.publish(trigger)
        hints.submit(trigger)
    }

    /// 先批量持久化发布，再逐条异步提交提示。
    ///
    /// - Parameter triggers: 本批触发。
    /// - Throws: 持久化发布失败时抛出；提示失败不会向上传播。
    public func publishBatch(_ triggers: [V2FanoutPlanTrigger]) async throws {
        if let durableBatch = durablePublisher as? any V2BatchFanoutPlanPublisher {
            try await durableBatch.publishBatch(triggers)
        } else {
            for trigger in triggers { try await durablePublisher.publish(trigger) }
        }
        for trigger in triggers { hints.submit(trigger) }
    }
}

/// 异步扇出提示派发器。
///
/// PostgreSQL 发布才是正确性边界。可选的 broker PING/PONG 延迟属于一条有界的后台通道，
/// 它绝不延长发件箱中继事务，也不会推迟下一个持久触发。
private final class V2AsynchronousFanoutHintDispatcher: Sendable {
    private let continuation: AsyncStream<V2FanoutPlanTrigger>.Continuation
    private let worker: Task<Void, Never>

    init(publisher: any V2FanoutPlanHintPublishing, capacity: Int = 256) {
        precondition(capacity > 0)
        let (stream, continuation) = AsyncStream<V2FanoutPlanTrigger>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        self.continuation = continuation
        worker = Task {
            for await trigger in stream {
                guard !Task.isCancelled else { break }
                try? await publisher.publishHint(trigger)
            }
        }
    }

    func submit(_ trigger: V2FanoutPlanTrigger) {
        continuation.yield(trigger)
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }
}
