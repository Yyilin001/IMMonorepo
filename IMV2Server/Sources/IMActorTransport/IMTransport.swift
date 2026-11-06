import Foundation
import Synchronization
import NIOCore
import NIOPosix
import NIOSSL
@_exported import IMActorWire

public struct IMTransportConfiguration: Sendable {
    public var node: IMNode
    public var tls: TLSConfiguration?
    public var protocolDigest: [UInt8]
    public var threadCount = 2
    public var maximumFrameBytes = 2 * 1_048_576
    public var maximumConnections = 256
    public var maximumCallsPerConnection = 256
    public var maximumBytesPerConnection = 8 * 1_048_576
    public var maximumExecutingCalls = 4096
    public var maximumExecutingBytes = 64 * 1_048_576
    public var handshakeTimeout: TimeAmount = .seconds(5)
    public var shutdownTimeout: Duration = .seconds(10)
    public init(node: IMNode, tls: TLSConfiguration?, protocolDigest: [UInt8]) {
        self.node = node; self.tls = tls; self.protocolDigest = protocolDigest
    }
}

package final class IMReplyReservation: Sendable {
    private let release: @Sendable () -> Void
    package init(release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}

public struct IMTransportReply: Sendable {
    public let isFailure: Bool
    public let body: ByteBuffer
    private let reservation: IMReplyReservation?
    public init(body: ByteBuffer, isFailure: Bool = false) {
        self.body = body; self.isFailure = isFailure; self.reservation = nil
    }
    package init(body: ByteBuffer, isFailure: Bool = false, reservation: IMReplyReservation) {
        self.body = body; self.isFailure = isFailure; self.reservation = reservation
    }
    public static func failure(_ error: IMActorError) -> Self {
        var bytes = ByteBuffer(); bytes.writeInteger(UInt32(0)); bytes.writeInteger(error.rawValue)
        return .init(body: bytes, isFailure: true)
    }
}

/// Connections own protocol state on their EventLoop. This lock only coordinates
/// establishment, global admission, and shutdown; no user code runs under it.
public final class IMTransport: Sendable {
    public typealias Receiver = @Sendable (IMNode, IMTrafficClass, IMFrame) async throws -> IMTransportReply
    public let configuration: IMTransportConfiguration
    public var eventLoop: any EventLoop { group.next() }
    let group: MultiThreadedEventLoopGroup
    let receive: Receiver
    let peerChanged: @Sendable (IMNode, Bool) -> Void
    let referenceRetired: @Sendable (IMActorID) -> Void
    let connectionFailed: @Sendable (any Error) -> Void
    private let clientTLS: NIOSSLContext?
    private let serverTLS: NIOSSLContext?
    struct Key: Hashable, Sendable { let endpoint: IMEndpoint; let lane: IMTrafficClass }
    private struct Connecting {
        let token: UUID
        let task: Task<Void, Never>
        let promise: EventLoopPromise<IMConnection>
    }
    private struct State {
        var server: (any Channel)?
        var stopping = false
        var stopped = false
        var connections: [UUID: IMConnection] = [:]
        var established: [Key: IMConnection] = [:]
        var connecting: [Key: Connecting] = [:]
        var connectionWaiters = 0
        var retryAfter: [Key: ContinuousClock.Instant] = [:]
        var pendingCalls = 0
        var pendingBytes = 0
        var pendingByLane: [IMTrafficClass: Int] = [:]
        var executingCount = 0
        var executingBytes = 0
        var replyBytes = 0
        var replyByLane: [IMTrafficClass: Int] = [:]
        var writingBytes = 0
        var executingByLane: [IMTrafficClass: Int] = [:]
        var writingByLane: [IMTrafficClass: Int] = [:]
        var admitted: UInt64 = 0
        var rejected: UInt64 = 0
        var completed: UInt64 = 0
    }
    private let state = Mutex(State())

    public init(configuration: IMTransportConfiguration, receive: @escaping Receiver,
                peerChanged: @escaping @Sendable (IMNode, Bool) -> Void,
                referenceRetired: @escaping @Sendable (IMActorID) -> Void,
                connectionFailed: @escaping @Sendable (any Error) -> Void = { _ in }) throws {
        guard configuration.threadCount > 0, configuration.protocolDigest.count == 32,
              (1...65535).contains(configuration.node.endpoint.port),
              configuration.maximumFrameBytes >= 1024,
              configuration.maximumFrameBytes <= 32 * 1_048_576,
              configuration.maximumCallsPerConnection > 0, configuration.maximumCallsPerConnection <= 65_536,
              configuration.maximumBytesPerConnection >= configuration.maximumFrameBytes,
              configuration.maximumBytesPerConnection <= 1_073_741_824,
              configuration.maximumConnections > 0,
              configuration.maximumExecutingCalls > 0,
              configuration.maximumExecutingBytes >= configuration.maximumFrameBytes else { throw IMActorError.invalidConfiguration }
        if configuration.tls == nil {
            guard Self.isLoopback(configuration.node.endpoint.host) else { throw IMActorError.invalidConfiguration }
        }
        self.configuration = configuration; self.receive = receive; self.peerChanged = peerChanged
        self.referenceRetired = referenceRetired; self.connectionFailed = connectionFailed
        self.clientTLS = try configuration.tls.map { supplied in
            var tls = supplied
            tls.minimumTLSVersion = .tlsv13; tls.maximumTLSVersion = .tlsv13
            tls.certificateVerification = .fullVerification
            return try NIOSSLContext(configuration: tls)
        }
        self.serverTLS = try configuration.tls.map { supplied in
            var tls = supplied
            tls.minimumTLSVersion = .tlsv13; tls.maximumTLSVersion = .tlsv13
            // An inbound client has no expected DNS hostname. Its certificate is
            // mandatory and chain-verified; signed application identity authorizes RPCs.
            tls.certificateVerification = .noHostnameVerification
            return try NIOSSLContext(configuration: tls)
        }
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: configuration.threadCount)
    }
    static func isLoopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "::1" || host == "localhost" }

    public func start() async throws {
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 65_536, high: 262_144))
                .childChannelInitializer { [self] channel in
                    do {
                        if let serverTLS { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: serverTLS)) }
                        let connection = try makeConnection(channel: channel, expected: nil, lane: nil)
                        do { try install(connection, on: channel) }
                        catch { connection.close(); throw error }
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.bind(host: configuration.node.endpoint.host, port: configuration.node.endpoint.port).get()
            state.withLock { $0.server = channel }
        } catch {
            try? await group.shutdownGracefully(); throw error
        }
    }
    private func install(_ connection: IMConnection, on channel: any Channel) throws {
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(
            IMFrameDecoder(maximumBytes: configuration.maximumFrameBytes),
            maximumBufferSize: configuration.maximumFrameBytes + 4))
        try channel.pipeline.syncOperations.addHandler(connection)
    }
    private func makeConnection(channel: any Channel, expected: IMEndpoint?, lane: IMTrafficClass?) throws -> IMConnection {
        let connection = IMConnection(transport: self, channel: channel, expected: expected, lane: lane)
        try state.withLock { state in
            guard !state.stopping else { throw IMActorError.shuttingDown }
            guard state.connections.count < configuration.maximumConnections else { throw IMActorError.overloaded }
            state.connections[connection.id] = connection
        }
        return connection
    }
    private func connection(to endpoint: IMEndpoint, lane: IMTrafficClass,
                            deadline: ContinuousClock.Instant) async throws -> IMConnection {
        try Task.checkCancellation()
        guard deadline > .now else { throw IMActorError.deadlineExceeded }
        let key = Key(endpoint: endpoint, lane: lane)
        let choice = try state.withLock { state -> (IMConnection?, EventLoopFuture<IMConnection>?) in
            guard !state.stopping else { throw IMActorError.shuttingDown }
            if let connection = state.established[key] { return (connection, nil) }
            guard state.connectionWaiters < configuration.maximumExecutingCalls else { throw IMActorError.overloaded }
            if let connecting = state.connecting[key] {
                state.connectionWaiters += 1; return (nil, connecting.promise.futureResult)
            }
            guard state.connecting.count < configuration.maximumConnections else { throw IMActorError.overloaded }
            if let retry = state.retryAfter[key], retry > .now { throw IMActorError.connectionLost }
            let token = UUID(), promise = group.next().makePromise(of: IMConnection.self)
            let task = Task { [self] in
                let result: Result<IMConnection, any Error>
                do { result = .success(try await connect(endpoint: endpoint, lane: lane)) }
                catch { result = .failure(error) }
                self.state.withLock { state in
                    if state.connecting[key]?.token == token { state.connecting[key] = nil }
                    if case .failure = result {
                        if state.retryAfter.count >= configuration.maximumConnections { state.retryAfter.removeAll() }
                        state.retryAfter[key] = .now + .milliseconds(Int.random(in: 100...300))
                    } else { state.retryAfter[key] = nil }
                }
                promise.completeWith(result)
            }
            state.connecting[key] = Connecting(token: token, task: task, promise: promise)
            state.connectionWaiters += 1
            return (nil, promise.futureResult)
        }
        if let connection = choice.0 { return connection }
        guard let future = choice.1 else { throw IMActorError.connectionLost }
        // One shared dial task. Cancelled waiters settle immediately, but retain
        // their admission slot until the shared dial finishes, bounding callbacks.
        let waiter = IMConnectionWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                let duration = ContinuousClock.now.duration(to: deadline).components
                let nanoseconds = max(0, min(duration.seconds, 3600) * 1_000_000_000 + duration.attoseconds / 1_000_000_000)
                let timer = future.eventLoop.scheduleTask(in: .nanoseconds(nanoseconds)) {
                    waiter.finish(.failure(IMActorError.deadlineExceeded))
                }
                future.whenComplete { [self] result in
                    timer.cancel()
                    state.withLock { $0.connectionWaiters -= 1 }
                    waiter.finish(result)
                }
            }
        } onCancel: { waiter.finish(.failure(IMActorError.cancelled)) }
    }
    private func connect(endpoint: IMEndpoint, lane: IMTrafficClass) async throws -> IMConnection {
        guard configuration.tls != nil || Self.isLoopback(endpoint.host) else { throw IMActorError.forbidden }
        let holder = Mutex<IMConnection?>(nil)
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(configuration.handshakeTimeout)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 65_536, high: 262_144))
            .channelInitializer { [self] channel in
                do {
                    if let clientTLS {
                        let handler = try NIOSSLClientHandler(context: clientTLS, serverHostname: endpoint.host)
                        try channel.pipeline.syncOperations.addHandler(handler)
                    }
                    let connection = try makeConnection(channel: channel, expected: endpoint, lane: lane)
                    holder.withLock { $0 = connection }
                    do { try install(connection, on: channel) }
                    catch { connection.close(); throw error }
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.connect(host: endpoint.host, port: endpoint.port).get()
        guard let connection = holder.withLock({ $0 }) else { try? await channel.close(); throw IMActorError.connectionLost }
        do { try await connection.ready.futureResult.get(); return connection }
        catch { try? await channel.close(); throw error }
    }

    public func request(to node: IMNode, lane: IMTrafficClass, frame: IMFrame,
                        deadline: ContinuousClock.Instant) async throws -> IMTransportReply {
        let bytes = frame.body.readableBytes + IMFrame.headerBytes
        try acquirePending(bytes: bytes, lane: lane)
        defer { releasePending(bytes: bytes, lane: lane) }
        let connection = try await connection(to: node.endpoint, lane: lane, deadline: deadline)
        try Task.checkCancellation()
        return try await connection.request(frame, expectedNode: node, deadline: deadline)
    }
    public func lookup(at endpoint: IMEndpoint, body: ByteBuffer,
                       deadline: ContinuousClock.Instant) async throws -> IMTransportReply {
        let bytes = body.readableBytes + IMFrame.headerBytes
        try acquirePending(bytes: bytes, lane: .control)
        defer { releasePending(bytes: bytes, lane: .control) }
        let connection = try await connection(to: endpoint, lane: .control, deadline: deadline)
        try Task.checkCancellation()
        return try await connection.request(.init(kind: .lookup, body: body), expectedNode: nil, deadline: deadline)
    }
    public func connect(to endpoint: IMEndpoint) async throws {
        _ = try await connection(to: endpoint, lane: .control, deadline: .now + .seconds(5))
    }
    func becameReady(_ connection: IMConnection, node: IMNode, lane: IMTrafficClass) {
        // Keep outgoing and incoming channels independently. Outgoing arbitration is
        // per endpoint/lane; incoming channels never steal a caller's request stream.
        if connection.expected != nil {
            state.withLock { $0.established[Key(endpoint: connection.expected!, lane: lane)] = connection }
        }
        peerChanged(node, true)
    }
    func disconnected(_ connection: IMConnection, node: IMNode?) {
        let stillConnected = state.withLock { state in
            state.connections[connection.id] = nil
            state.established = state.established.filter { $0.value.id != connection.id }
            return node.map { node in state.connections.values.contains { $0.remoteSnapshot == node } } ?? false
        }
        if let node, !stillConnected { peerChanged(node, false) }
    }
    // Reserve half for ordinary RPC and a quarter each for control/bulk.
    // No traffic class can consume another class's receive or write budget.
    private func byteLimit(_ lane: IMTrafficClass) -> Int {
        max(configuration.maximumFrameBytes, configuration.maximumExecutingBytes / (lane == .rpc ? 2 : 4))
    }
    private func acquirePending(bytes: Int, lane: IMTrafficClass) throws {
        try state.withLock { state in
            guard !state.stopping else { throw IMActorError.shuttingDown }
            guard state.pendingCalls < configuration.maximumExecutingCalls,
                  bytes <= byteLimit(lane) - state.pendingByLane[lane, default: 0],
                  bytes <= configuration.maximumExecutingBytes - state.pendingBytes else { throw IMActorError.overloaded }
            state.pendingCalls += 1; state.pendingBytes += bytes; state.pendingByLane[lane, default: 0] += bytes
        }
    }
    private func releasePending(bytes: Int, lane: IMTrafficClass) {
        state.withLock {
            $0.pendingCalls -= 1; $0.pendingBytes -= bytes; $0.pendingByLane[lane, default: 0] -= bytes
        }
    }
    /// Admit encoded replies only when their actual size is known, before
    /// allocating the wire buffer. Input execution does not reserve a worst-case
    /// reply for every small control request, which can starve nested Raft RPCs.
    package func reserveReply(bytes: Int, lane: IMTrafficClass) throws -> IMReplyReservation {
        guard bytes >= 0, bytes <= configuration.maximumFrameBytes - IMFrame.headerBytes else { throw IMActorError.overloaded }
        let reservation = bytes + IMFrame.headerBytes
        try state.withLock { state in
            guard reservation <= byteLimit(lane) - state.replyByLane[lane, default: 0],
                  reservation <= configuration.maximumExecutingBytes - state.replyBytes else { throw IMActorError.overloaded }
            state.replyBytes += reservation; state.replyByLane[lane, default: 0] += reservation
        }
        return IMReplyReservation { [self] in
            state.withLock { $0.replyBytes -= reservation; $0.replyByLane[lane, default: 0] -= reservation }
        }
    }
    func acquireExecution(bytes: Int, lane: IMTrafficClass) -> Bool {
        state.withLock { state in
            guard !state.stopping, state.executingCount < configuration.maximumExecutingCalls,
                  bytes <= byteLimit(lane) - state.executingByLane[lane, default: 0],
                  bytes <= configuration.maximumExecutingBytes - state.executingBytes else {
                state.rejected &+= 1; return false
            }
            state.executingCount += 1; state.executingBytes += bytes
            state.executingByLane[lane, default: 0] += bytes; state.admitted &+= 1
            return true
        }
    }
    func releaseExecution(bytes: Int, lane: IMTrafficClass) {
        state.withLock {
            $0.executingCount -= 1; $0.executingBytes -= bytes
            $0.executingByLane[lane, default: 0] -= bytes; $0.completed &+= 1
        }
    }
    func acquireWrite(bytes: Int, lane: IMTrafficClass) -> Bool {
        state.withLock { state in
            guard bytes <= byteLimit(lane) + 65_536 - state.writingByLane[lane, default: 0],
                  bytes <= configuration.maximumExecutingBytes - state.writingBytes else { return false }
            state.writingBytes += bytes; state.writingByLane[lane, default: 0] += bytes; return true
        }
    }
    func releaseWrite(bytes: Int, lane: IMTrafficClass) {
        state.withLock { $0.writingBytes -= bytes; $0.writingByLane[lane, default: 0] -= bytes }
    }
    public var metrics: IMTransportMetrics {
        state.withLock {
            .init(connections: $0.connections.count, connecting: $0.connecting.count,
                  connectionWaiters: $0.connectionWaiters, pendingCalls: $0.pendingCalls, pendingBytes: $0.pendingBytes, executingCalls: $0.executingCount,
                  executingBytes: $0.executingBytes, replyBytes: $0.replyBytes, writingBytes: $0.writingBytes,
                  admitted: $0.admitted, rejected: $0.rejected, completed: $0.completed)
        }
    }
    public func retire(_ node: IMNode) {
        let connections = state.withLock { Array($0.connections.values) }
        for connection in connections where connection.remoteSnapshot == node { connection.close() }
        peerChanged(node, false)
    }
    public func publishRetirement(_ id: IMActorID) {
        let connections = state.withLock { Array($0.connections.values) }
        for connection in connections { connection.sendRetirement(id.localID) }
    }
    public func shutdown() async throws {
        let snapshot = state.withLock { state -> ((any Channel)?, [IMConnection], [Task<Void, Never>], Bool) in
            state.stopping = true
            return (state.server, Array(state.connections.values), state.connecting.values.map(\.task), state.stopped)
        }
        if snapshot.3 { return }
        try? await snapshot.0?.close()
        for task in snapshot.2 { task.cancel() }
        for connection in snapshot.1 { connection.drain() }
        let deadline = ContinuousClock.now + configuration.shutdownTimeout
        while state.withLock({ $0.executingCount > 0 || $0.writingBytes > 0 || $0.connectionWaiters > 0 }) {
            guard ContinuousClock.now < deadline else { throw IMActorError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(10))
        }
        for connection in snapshot.1 { connection.close() }
        for task in snapshot.2 { await task.value }
        // Include inbound connections which raced the initial shutdown snapshot.
        let remaining = state.withLock { Array($0.connections.values) }
        for connection in remaining { try? await connection.channel.close() }
        try await group.shutdownGracefully()
        state.withLock { $0.stopped = true; $0.connections.removeAll(); $0.established.removeAll(); $0.connecting.removeAll() }
    }
}

/// Bridges a shared dial future to an independently cancellable caller without a
/// per-caller task. Completion can race installation, cancellation, and timeout.
private final class IMConnectionWaiter: Sendable {
    private struct State {
        var continuation: CheckedContinuation<IMConnection, any Error>?
        var result: Result<IMConnection, any Error>?
    }
    private let state = Mutex(State())
    func install(_ continuation: CheckedContinuation<IMConnection, any Error>) {
        let completed = state.withLock { state -> Result<IMConnection, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation; return nil
        }
        if let completed { continuation.resume(with: completed) }
    }
    func finish(_ result: Result<IMConnection, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<IMConnection, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation; state.continuation = nil; return continuation
        }
        continuation?.resume(with: result)
    }
}

public struct IMTransportMetrics: Sendable {
    public let connections: Int
    public let connecting: Int
    public let connectionWaiters: Int
    public let pendingCalls: Int
    public let pendingBytes: Int
    public let executingCalls: Int
    public let executingBytes: Int
    public let replyBytes: Int
    public let writingBytes: Int
    public let admitted: UInt64
    public let rejected: UInt64
    public let completed: UInt64
}
