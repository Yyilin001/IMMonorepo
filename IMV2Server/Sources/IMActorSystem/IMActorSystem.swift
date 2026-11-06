import Crypto
import Logging
import Distributed
import Foundation
import NIOCore
import NIOSSL
import Synchronization

public struct IMActorSystemSettings: Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public var tls: TLSConfiguration?
    public var threadPoolSize = 2
    public var maximumInboundFrameBytes = 2 * 1_048_576
    public var maximumCallsPerConnection = 256
    public var maximumBytesPerConnection = 8 * 1_048_576
    public var maximumExecutingCalls = 4096
    public var maximumExecutingBytes = 64 * 1_048_576
    public var methods: [IMMethod] = []
    public var errorTypes: [any IMWireValue.Type] = []
    public var callTimeout: Duration = .seconds(5)
    public var shutdownTimeout: Duration = .seconds(10)
    public init(name: String, host: String, port: Int, tls: TLSConfiguration? = nil) {
        self.name = name; self.host = host; self.port = port; self.tls = tls
    }
}

/// Physical actor runtime. Placement, business idempotency, and room scheduling
/// remain in the application. Every exported method is explicitly registered.
public final class IMActorSystem: DistributedActorSystem, Sendable {
    public typealias ActorID = IMActorID
    public typealias SerializationRequirement = IMWireValue
    public typealias InvocationEncoder = IMInvocationEncoder
    public typealias InvocationDecoder = IMInvocationDecoder
    public typealias ResultHandler = IMInvocationResultHandler
    public var transportMetrics: IMTransportMetrics? { transport.withLock { $0 }?.metrics }
    public let log: Logger
    public var eventLoop: any EventLoop { transport.withLock { $0! }.eventLoop }
    public let node: IMNode
    public let settings: IMActorSystemSettings
    private let methods: [UInt32: IMMethod]
    private let targets: [String: IMMethod]
    private let errors: [UInt32: any IMWireValue.Type]
    private let recording: Bool
    private let transport = Mutex<IMTransport?>(nil)
    private final class WeakActor: Sendable {
        private struct Reference { weak var value: (any DistributedActor)? }
        private let reference: Mutex<Reference>
        var value: (any DistributedActor)? { reference.withLock { $0.value } }
        init(_ actor: any DistributedActor) { reference = Mutex(Reference(value: actor)) }
    }
    private struct Entry: Sendable {
        let actor: WeakActor
        let type: ObjectIdentifier
        let invoke: @Sendable (IMMethod, ByteBuffer) async throws -> IMTransportReply
    }
    private struct State {
        var nextID: UInt64 = 1
        var actors: [UInt64: Entry] = [:]
        var services: [String: Set<IMActorID>] = [:]
        var stopping = false
        var captured: IMMethod?
        var peers: [IMNode: Bool] = [:]
        var revision: UInt64 = 0
        var lossRevisions: [IMNode: UInt64] = [:]
        var observers: [UUID: AsyncStream<IMPeerSnapshot>.Continuation] = [:]
        var watches: [IMActorID: [UUID: @Sendable (IMActorID) -> Void]] = [:]
        var connections: [IMEndpoint: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())

    private init(settings: IMActorSystemSettings, recording: Bool) throws {
        guard Set(settings.methods.map(\.id)).count == settings.methods.count,
              Set(settings.methods.map(\.target)).count == settings.methods.count,
              settings.methods.allSatisfy({ $0.id > 0 }),
              settings.errorTypes.allSatisfy({ $0.wireTypeID > 0 && $0 is any Error.Type }),
              settings.callTimeout > .zero, settings.callTimeout <= .seconds(3600),
              Set(settings.errorTypes.map { $0.wireTypeID }).count == settings.errorTypes.count else {
            throw IMActorError.invalidConfiguration
        }
        self.settings = settings; self.recording = recording
        var log = Logger(label: "IMActorSystem.\(settings.name)")
        if ProcessInfo.processInfo.environment["IM_ACTOR_RUNTIME_DEBUG"] == "1" { log.logLevel = .debug }
        self.log = log
        node = .init(id: settings.name, endpoint: .init(host: settings.host, port: settings.port))
        methods = Dictionary(uniqueKeysWithValues: settings.methods.map { ($0.id, $0) })
        targets = Dictionary(uniqueKeysWithValues: settings.methods.map { ($0.target, $0) })
        var errorCodecs: [UInt32: any IMWireValue.Type] = [:]
        for codec in settings.errorTypes { errorCodecs[codec.wireTypeID] = codec }
        errors = errorCodecs
        state.withLock { $0.peers[node] = true }
    }
    public convenience init(_ name: String, settings: IMActorSystemSettings) async throws {
        guard name == settings.name else { throw IMActorError.invalidConfiguration }
        try self.init(settings: settings, recording: false)
        // The digest includes exact Swift targets as well as explicit IDs/signatures.
        // A mismatched executable fails closed instead of dispatching another method.
        var manifest = ByteBuffer()
        for method in settings.methods.sorted(by: { $0.id < $1.id }) {
            manifest.writeInteger(method.id); manifest.writeInteger(method.traffic.rawValue)
            try manifest.imWriteString(method.target, maximum: 65_536)
            manifest.writeInteger(UInt32(method.arguments.count))
            for type in method.arguments { manifest.writeInteger(type) }
            manifest.writeInteger(method.result?.wireTypeID ?? 0)
        }
        for type in errors.keys.sorted() { manifest.writeInteger(type) }
        var configuration = IMTransportConfiguration(node: node, tls: settings.tls,
            protocolDigest: Array(SHA256.hash(data: Data(manifest.readableBytesView))))
        configuration.threadCount = settings.threadPoolSize
        configuration.maximumFrameBytes = settings.maximumInboundFrameBytes
        configuration.maximumCallsPerConnection = settings.maximumCallsPerConnection
        configuration.maximumBytesPerConnection = max(settings.maximumBytesPerConnection, settings.maximumInboundFrameBytes)
        configuration.maximumExecutingCalls = settings.maximumExecutingCalls
        configuration.maximumExecutingBytes = max(settings.maximumExecutingBytes, settings.maximumInboundFrameBytes)
        configuration.shutdownTimeout = settings.shutdownTimeout
        let transport = try IMTransport(configuration: configuration,
            receive: { [weak self] node, lane, frame in
                guard let self else { throw IMActorError.shuttingDown }
                return try await self.receive(from: node, lane: lane, frame: frame)
            }, peerChanged: { [weak self] node, available in self?.peerChanged(node, available: available) },
            referenceRetired: { [weak self] id in self?.retired(id) },
            connectionFailed: { [weak self] error in
                self?.log.debug("Actor connection closed", metadata: ["reason": .string(String(describing: error))])
            })
        self.transport.withLock { $0 = transport }
        try await transport.start()
    }

    /// Capture the compiler's opaque target through a no-I/O proxy. It never executes
    /// the actor body or serializes sample arguments, and throws before dispatch.
    public static func register<Act: DistributedActor>(id: UInt32, traffic: IMTrafficClass = .rpc,
        actor: Act.Type, invocation: @Sendable (Act) async throws -> Void) async throws -> IMMethod
        where Act.ActorSystem == IMActorSystem {
        let system = try IMActorSystem(settings: .init(name: "registration", host: "127.0.0.1", port: 1), recording: true)
        let remoteNode = IMNode(id: "registration-proxy", endpoint: .init(host: "127.0.0.1", port: 2))
        let proxy = try Act.resolve(id: .init(node: remoteNode, localID: 1), using: system)
        do { try await invocation(proxy); throw IMActorError.invalidConfiguration }
        catch IMActorError.registrationComplete {}
        guard let method = system.state.withLock({ $0.captured }) else { throw IMActorError.invalidConfiguration }
        return .init(id: id, traffic: traffic, target: method.target, actorType: method.actorType,
                     arguments: method.arguments, result: method.result)
    }
    public func assignID<Act: DistributedActor>(_ actorType: Act.Type) -> IMActorID where Act.ID == IMActorID {
        state.withLock { state in
            precondition(state.nextID < UInt64.max, "Actor ID space exhausted")
            let id = state.nextID; state.nextID += 1; return .init(node: node, localID: id)
        }
    }
    public func actorReady<Act: DistributedActor>(_ actor: Act) where Act.ID == IMActorID {
        let entry = Entry(actor: WeakActor(actor), type: ObjectIdentifier(Act.self), invoke: { [weak self, weak actor] method, bytes in
            guard let self, let actor else { throw IMActorError.unknownActor }
            var decoder = IMInvocationDecoder(bytes: bytes, resultType: method.result)
            let box = IMResultBox()
            try await self.executeDistributedTarget(on: actor, target: .init(method.target), invocationDecoder: &decoder,
                handler: .init(box: box, allowedErrors: Set(self.errors.keys), reserveReply: { [self] bytes in
                    guard let transport = transport.withLock({ $0 }) else { throw IMActorError.shuttingDown }
                    return try transport.reserveReply(bytes: bytes, lane: method.traffic)
                }))
            try decoder.bytes.imRequireEnd()
            guard let reply = box.result.withLock({ $0 }) else { throw IMActorError.remoteFailure }
            return reply
        })
        state.withLock { state in
            guard !state.stopping else { return }
            state.actors[actor.id.localID] = entry
        }
    }
    public func resolve<Act: DistributedActor>(id: IMActorID, as actorType: Act.Type) throws -> Act? where Act.ID == IMActorID {
        guard id.localID > 0 else { throw IMActorError.unknownActor }
        if id.node == node {
            return try state.withLock { state in
                guard !state.stopping else { throw IMActorError.shuttingDown }
                guard let actor = state.actors[id.localID]?.actor.value as? Act else { throw IMActorError.unknownActor }
                return actor
            }
        }
        guard id.node.endpoint != node.endpoint || id.node.incarnationID == node.incarnationID else { throw IMActorError.staleIncarnation }
        return nil
    }
    public func resignID(_ id: IMActorID) {
        state.withLock { state in
            state.actors[id.localID] = nil
            for key in Array(state.services.keys) { state.services[key]?.remove(id) }
        }
        retired(id); transport.withLock { $0 }?.publishRetirement(id)
    }
    public func makeInvocationEncoder() -> IMInvocationEncoder { .init(recording: recording) }
    private func method<Act: DistributedActor>(actor: Act, target: RemoteCallTarget,
        invocation: IMInvocationEncoder) throws -> IMMethod where Act.ID == IMActorID {
        if recording {
            state.withLock { $0.captured = .init(id: 0, traffic: .rpc, target: target.identifier,
                actorType: ObjectIdentifier(Act.self), arguments: invocation.argumentTypes, result: invocation.resultType) }
            throw IMActorError.registrationComplete
        }
        guard let method = targets[target.identifier], method.actorType == ObjectIdentifier(Act.self),
              method.arguments == invocation.argumentTypes,
              method.result?.wireTypeID == invocation.resultType?.wireTypeID else { throw IMActorError.unknownMethod }
        return method
    }
    public func remoteCall<Act, Err, Res>(on actor: Act, target: RemoteCallTarget,
        invocation: inout IMInvocationEncoder, throwing: Err.Type, returning: Res.Type) async throws -> Res
        where Act: DistributedActor, Act.ID == IMActorID, Err: Error, Res: IMWireValue {
        let method = try method(actor: actor, target: target, invocation: invocation)
        var bytes = try await send(actor: actor.id, method: method, bytes: invocation.bytes)
        let result = try Res.decodeWire(from: &bytes); try bytes.imRequireEnd(); return result
    }
    public func remoteCallVoid<Act, Err>(on actor: Act, target: RemoteCallTarget,
        invocation: inout IMInvocationEncoder, throwing: Err.Type) async throws
        where Act: DistributedActor, Act.ID == IMActorID, Err: Error {
        let method = try method(actor: actor, target: target, invocation: invocation)
        let bytes = try await send(actor: actor.id, method: method, bytes: invocation.bytes); try bytes.imRequireEnd()
    }
    private func send(actor: IMActorID, method: IMMethod, bytes: ByteBuffer) async throws -> ByteBuffer {
        guard !state.withLock({ $0.stopping }), let transport = transport.withLock({ $0 }) else { throw IMActorError.shuttingDown }
        let deadline = IMRemoteCall.deadline ?? .now + settings.callTimeout
        let reply = try await transport.request(to: actor.node, lane: method.traffic,
            frame: .init(kind: .request, actorID: actor.localID, methodID: method.id, body: bytes), deadline: deadline)
        return try unwrap(reply)
    }
    private func unwrap(_ reply: IMTransportReply) throws -> ByteBuffer {
        guard reply.isFailure else { return reply.body }
        var bytes = reply.body
        let type = try bytes.imRead(UInt32.self)
        if type == 0 {
            guard let error = IMActorError(rawValue: try bytes.imRead(UInt16.self)) else { throw IMActorError.malformed }
            try bytes.imRequireEnd(); throw error
        }
        guard let codec = errors[type], let error = try codec.decodeWire(from: &bytes) as? any Error else { throw IMActorError.remoteFailure }
        try bytes.imRequireEnd(); throw error
    }
    private func receive(from node: IMNode, lane: IMTrafficClass, frame: IMFrame) async throws -> IMTransportReply {
        try Task.checkCancellation()
        if frame.kind == .lookup {
            var bytes = frame.body; let key = try bytes.imReadString(); try bytes.imRequireEnd()
            let ids = state.withLock { state in
                (state.services[key] ?? []).filter { state.actors[$0.localID]?.actor.value != nil }.sorted()
            }
            var body = ByteBuffer(); body.writeInteger(UInt32(ids.count))
            for id in ids { try id.encodeWire(into: &body) }
            return .init(body: body)
        }
        guard let method = methods[frame.methodID], method.traffic == lane else { throw IMActorError.unknownMethod }
        let entry = try state.withLock { state in
            guard !state.stopping else { throw IMActorError.shuttingDown }
            guard let entry = state.actors[frame.actorID], entry.type == method.actorType else { throw IMActorError.unknownActor }
            return entry.invoke
        }
        // Validate the entire envelope before executing a side-effecting method.
        var check = frame.body
        for type in method.arguments {
            guard try check.imRead(UInt32.self) == type else { throw IMActorError.malformed }
            _ = try check.imReadBytes(maximum: settings.maximumInboundFrameBytes)
        }
        try check.imRequireEnd()
        return try await IMRemoteCall.with(timeout: .milliseconds(Int64(frame.budgetMilliseconds))) {
            try await entry(method, frame.body)
        }
    }

    public func publish<Act>(_ actor: Act, as key: IMServiceKey<Act>) throws where Act.ActorSystem == IMActorSystem {
        try state.withLock { state in
            guard !state.stopping, actor.id.node == node, state.actors[actor.id.localID] != nil,
                  !key.name.isEmpty, key.name.utf8.count <= 1024,
                  state.services.count < 256 || state.services[key.name] != nil,
                  (state.services[key.name]?.count ?? 0) < 16 else { throw IMActorError.overloaded }
            state.services[key.name, default: []].insert(actor.id)
        }
    }
    public func lookup<Act>(_ key: IMServiceKey<Act>, at endpoint: IMEndpoint) async throws -> [Act] where Act.ActorSystem == IMActorSystem {
        if endpoint == node.endpoint {
            let ids = state.withLock { Array($0.services[key.name] ?? []) }
            return ids.compactMap { try? Act.resolve(id: $0, using: self) }
        }
        guard let transport = transport.withLock({ $0 }) else { throw IMActorError.shuttingDown }
        var bytes = ByteBuffer(); try bytes.imWriteString(key.name)
        let reply = try await transport.lookup(at: endpoint, body: bytes, deadline: IMRemoteCall.deadline ?? .now + .seconds(2))
        var body = try unwrap(reply); let count = try body.imRead(UInt32.self)
        guard count <= 16 else { throw IMActorError.overloaded }
        var result: [Act] = []
        for _ in 0..<count {
            let id = try IMActorID.decodeWire(from: &body)
            guard id.node.endpoint == endpoint else { throw IMActorError.forbidden }
            result.append(try Act.resolve(id: id, using: self))
        }
        try body.imRequireEnd(); return result
    }
    public func connect(host: String, port: Int) {
        let endpoint = IMEndpoint(host: host, port: port)
        guard endpoint != node.endpoint else { return }
        state.withLock { state in
            guard !state.stopping, state.connections[endpoint] == nil, state.connections.count < 256 else { return }
            state.connections[endpoint] = Task { [weak self] in
                guard let self else { return }
                if let transport = self.transport.withLock({ $0 }) { try? await transport.connect(to: endpoint) }
                self.state.withLock { $0.connections[endpoint] = nil }
            }
        }
    }
    public func retire(node: IMNode) { transport.withLock { $0 }?.retire(node) }
    package var peerSnapshot: IMPeerSnapshot { state.withLock { .init(revision: $0.revision, available: $0.peers, lossRevisions: $0.lossRevisions) } }
    public var peerEvents: AsyncStream<IMPeerSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.observers[id] = nil } }
            let installed = state.withLock { state in
                guard !state.stopping else { return false }
                state.observers[id] = continuation
                continuation.yield(.init(revision: state.revision, available: state.peers, lossRevisions: state.lossRevisions))
                return true
            }
            // finish invokes onTermination synchronously; it must not hold state.
            if !installed { continuation.finish() }
        }
    }
    package func peerChanged(_ node: IMNode, available: Bool) {
        state.withLock { state in
            guard !state.stopping else { return }
            if state.peers.count >= 512, state.peers[node] == nil {
                for old in Array(state.peers.keys) where state.peers[old] == false { state.peers[old] = nil; state.lossRevisions[old] = nil }
            }
            guard state.peers.count < 512 || state.peers[node] != nil else { return }
            guard state.peers[node] != available else { return }
            state.peers[node] = available; state.revision &+= 1
            if !available { state.lossRevisions[node] = state.revision }
            let snapshot = IMPeerSnapshot(revision: state.revision, available: state.peers, lossRevisions: state.lossRevisions)
            for observer in state.observers.values { observer.yield(snapshot) }
        }
    }
    public func watchRetirement(of id: IMActorID, notify: @escaping @Sendable (IMActorID) -> Void) throws -> UUID {
        let token = UUID()
        try state.withLock { state in
            guard !state.stopping, state.watches.count < 4096 || state.watches[id] != nil,
                  (state.watches[id]?.count ?? 0) < 16 else { throw IMActorError.overloaded }
            state.watches[id, default: [:]][token] = notify
        }
        return token
    }
    public func unwatchRetirement(of id: IMActorID, token: UUID) {
        state.withLock { state in
            state.watches[id]?[token] = nil
            if state.watches[id]?.isEmpty == true { state.watches[id] = nil }
        }
    }
    private func retired(_ id: IMActorID) {
        let callbacks = state.withLock { $0.watches.removeValue(forKey: id) ?? [:] }
        for callback in callbacks.values { callback(id) }
    }
    public func shutdown() async throws {
        let (tasks, observers) = state.withLock { state in
            state.stopping = true
            let observers = Array(state.observers.values)
            state.observers.removeAll(); state.watches.removeAll(); state.services.removeAll()
            return (Array(state.connections.values), observers)
        }
        for observer in observers { observer.finish() }
        for task in tasks { task.cancel() }
        try await transport.withLock { $0 }?.shutdown()
        for task in tasks { await task.value }
        state.withLock { $0.actors.removeAll(); $0.connections.removeAll() }
    }
}

extension IMActorError: DistributedActorSystemError {}
