import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import Synchronization

/// A one-shot plaintext PostgreSQL wire proxy. It proves that PostgreSQL has
/// emitted CommandComplete for COMMIT, then withholds that packet and closes
/// the client connection. It is deliberately available only to tests.
// Immutable NIO handles are thread-safe; mutable observations are protected by a mutex.
final class V2PostgresCommitAckLossProxy: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let listener: any Channel
    let port: Int
    private let observation: V2CommitAckLossObservation

    private init(group: MultiThreadedEventLoopGroup, listener: any Channel, port: Int,
                 observation: V2CommitAckLossObservation) {
        self.group = group
        self.listener = listener
        self.port = port
        self.observation = observation
    }

    static func start(backendHost: String, backendPort: Int, initiallyArmed: Bool = true) async throws -> Self {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let observation = V2CommitAckLossObservation(initiallyArmed: initiallyArmed)
        do {
            let listener = try await ServerBootstrap(group: group)
                .childChannelInitializer { frontend in
                    ClientBootstrap(group: group)
                        .channelOption(ChannelOptions.connectTimeout, value: .seconds(2))
                        .connect(host: backendHost, port: backendPort)
                        .flatMap { backend in
                            frontend.pipeline.addHandler(V2PostgresFrontendRelay(backend: backend))
                                .flatMap {
                                    backend.pipeline.addHandler(V2PostgresBackendRelay(
                                        frontend: frontend, observation: observation))
                                }
                        }
                }
                .bind(host: "127.0.0.1", port: 0).get()
            guard let port = listener.localAddress?.port else {
                try await listener.close().get()
                throw V2PostgresCommitAckLossProxyError.missingListenerPort
            }
            return .init(group: group, listener: listener, port: port, observation: observation)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    var observedSuccessfulCommit: Bool { observation.observedSuccessfulCommit }

    func arm() { observation.arm() }

    func shutdown() async throws {
        try await listener.close().get()
        try await group.shutdownGracefully()
    }
}

private enum V2PostgresCommitAckLossProxyError: Error { case missingListenerPort }

private final class V2CommitAckLossObservation: Sendable {
    private struct State: Sendable { var armed: Bool; var dropped = false }
    private let value: Mutex<State>

    init(initiallyArmed: Bool) { value = Mutex(State(armed: initiallyArmed)) }
    func arm() { value.withLock { $0.armed = true } }
    var observedSuccessfulCommit: Bool { value.withLock { $0.dropped } }

    /// Only the first armed COMMIT is dropped; earlier setup/read transactions pass through.
    func claimSuccessfulCommit() -> Bool {
        value.withLock { state in
            guard state.armed, !state.dropped else { return false }
            state.dropped = true
            return true
        }
    }
}

// NIO confines handler methods to one EventLoop; peers are NIO Channel handles.
private final class V2PostgresFrontendRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let backend: any Channel

    init(backend: any Channel) { self.backend = backend }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        backend.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        backend.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        backend.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class V2PostgresBackendRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let frontend: any Channel
    private let observation: V2CommitAckLossObservation
    private var pending = ByteBuffer()

    init(frontend: any Channel, observation: V2CommitAckLossObservation) {
        self.frontend = frontend
        self.observation = observation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)
        guard pending.readableBytes <= 16_777_221 else {
            context.close(promise: nil)
            frontend.close(promise: nil)
            return
        }
        while pending.readableBytes >= 5 {
            let offset = pending.readerIndex
            guard let type: UInt8 = pending.getInteger(at: offset),
                  let length: UInt32 = pending.getInteger(at: offset + 1) else { break }
            guard (4...16_777_216).contains(length) else {
                context.close(promise: nil)
                frontend.close(promise: nil)
                return
            }
            let packetLength = Int(length) + 1
            guard pending.readableBytes >= packetLength,
                  let packet = pending.readSlice(length: packetLength) else { break }
            if type == UInt8(ascii: "C"),
               packet.getString(at: packet.readerIndex + 5, length: Int(length) - 4) == "COMMIT\0",
               observation.claimSuccessfulCommit() {
                // PostgreSQL emits this only after a successful COMMIT. Neither
                // CommandComplete nor ReadyForQuery reaches the client.
                frontend.close(promise: nil)
                context.close(promise: nil)
                return
            }
            frontend.writeAndFlush(packet, promise: nil)
        }
        pending.discardReadBytes()
    }

    func channelInactive(context: ChannelHandlerContext) {
        frontend.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        frontend.close(promise: nil)
        context.close(promise: nil)
    }
}
