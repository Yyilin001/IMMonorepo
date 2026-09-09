import Foundation
import IMV2Compression
import IMV2Core
#if canImport(Network) && canImport(Security)
import Network
import Security
import Synchronization
#endif

public struct V2RealtimeEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, port > 0 else {
            throw V2TLSFrameConnectionError.invalidEndpoint
        }
        self.host = host
        self.port = port
    }
}

public struct V2AuthenticatedClientSession: Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let protocolVersion: UInt8
    public let capabilityProfile: String
    public let frameCompression: V2NegotiatedFrameCompression?
    public let connectionID: UUID?

    public init(
        userID: UserID,
        deviceID: DeviceID,
        protocolVersion: UInt8,
        capabilityProfile: String,
        frameCompression: V2NegotiatedFrameCompression? = nil,
        connectionID: UUID? = nil
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.protocolVersion = protocolVersion
        self.capabilityProfile = capabilityProfile
        self.frameCompression = frameCompression
        self.connectionID = connectionID
    }
}

public enum V2TLSFrameConnectionError: Error, Equatable, Sendable {
    case invalidEndpoint
    case notConnected
    case connectionFailed
    case connectionClosed
    case requestTimedOut
    case unsupportedVersion
    case authenticationFailed
    case invalidHandshake
    case unsupportedCompression
    case unsupportedFrameFlags
    case unexpectedResponse
    case concurrentAvailabilityConsumer
    case tooManyPendingRequests
}

public struct V2SyncAvailabilityHint: Equatable, Sendable {
    public let eventID: UInt64
    public let highWatermark: UInt64

    public init(eventID: UInt64, highWatermark: UInt64) {
        self.eventID = eventID
        self.highWatermark = highWatermark
    }
}

/// Non-authoritative foreground wake for one Hybrid room.  A contiguous
/// direct-room event can be applied immediately; every absence, duplicate or
/// gap still follows the durable room-event cursor pull.
public struct V2GroupEventAvailabilityHint: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64
    public let liveEvents: [V2ClientGroupEvent]

    /// Compatibility view for callers that only understand the legacy
    /// single-event accelerator. A real batch deliberately appears absent to
    /// such a caller so it safely takes the durable room-log recovery path.
    public var liveEvent: V2ClientGroupEvent? {
        liveEvents.count == 1 ? liveEvents[0] : nil
    }

    public init(
        roomID: RoomID,
        highWatermark: UInt64,
        liveEvents: [V2ClientGroupEvent] = []
    ) {
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.liveEvents = liveEvents
    }

    public init(roomID: RoomID, highWatermark: UInt64, liveEvent: V2ClientGroupEvent?) {
        self.roomID = roomID
        self.highWatermark = highWatermark
        liveEvents = liveEvent.map { [$0] } ?? []
    }

    /// There is one active group-detail consumer per connection, but it may
    /// be projecting a previous frame while Network.framework receives the
    /// next one. Preserve a bounded contiguous batch instead of replacing the
    /// older acceleration payload and manufacturing a cursor gap locally.
    func coalescing(with newer: Self) -> Self {
        guard roomID == newer.roomID else { return newer }
        guard newer.highWatermark >= highWatermark else { return self }
        guard newer.highWatermark > highWatermark else {
            return liveEvents.isEmpty && !newer.liveEvents.isEmpty ? newer : self
        }
        guard !liveEvents.isEmpty, !newer.liveEvents.isEmpty else {
            return .init(roomID: roomID, highWatermark: newer.highWatermark)
        }
        var merged = liveEvents
        var lastSequence = merged.last!.roomSequence
        for event in newer.liveEvents where event.roomSequence > lastSequence {
            guard event.roomSequence == lastSequence + 1,
                  merged.count < V2GroupEventLogLimits.maximumPageSize
            else {
                return .init(roomID: roomID, highWatermark: newer.highWatermark)
            }
            merged.append(event)
            lastSequence = event.roomSequence
        }
        guard lastSequence == newer.highWatermark else {
            return .init(roomID: roomID, highWatermark: newer.highWatermark)
        }
        return .init(
            roomID: roomID,
            highWatermark: newer.highWatermark,
            liveEvents: merged
        )
    }
}

/// A single application-owned consumer waits for best-effort live hints. A
/// hint is never state: callers must follow it with normal pull/ACK sync.
public protocol V2SyncAvailabilityHintSource: Sendable {
    func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint
}

/// There is one foreground Hybrid detail listener per connection. Keeping it
/// separate from user-sync availability prevents one room's wake from waking
/// a whole account sync loop.
public protocol V2GroupEventAvailabilityHintSource: Sendable {
    func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint
}

public enum V2LiveActivityEvent: Equatable, Sendable {
    case presence(V2PresenceState)
    case typing(V2TypingState)
}

/// A foreground conversation owns the single consumer. Activity events are
/// lossy leases, never a substitute for durable message synchronization.
public protocol V2LiveActivityEventSource: Sendable {
    func nextLiveActivityEvent() async throws -> V2LiveActivityEvent
}

/// Narrow connection lifecycle boundary used by the app-facing coordinator.
/// It keeps session/keychain policy out of Network.framework and lets tests
/// verify handshake identity handling without opening a local socket.
public protocol V2RealtimeConnection: Sendable {
    func connectAndAuthenticate(
        accessToken: String,
        deviceID: DeviceID,
        supportedCapabilityProfiles: Set<String>
    ) async throws -> V2AuthenticatedClientSession
    func disconnect() async
}

/// Stable app-runtime boundary over a concrete realtime connection. Keeping
/// this separate from frame transport lets lifecycle tests avoid a socket while
/// the actual TLS actor remains the only production implementation.
public protocol V2RealtimeSessionConnecting: Sendable {
    func connect() async throws -> V2AuthenticatedClientSession
    func disconnect() async
}

/// Apple-platform TLS 1.3 framed transport. Network.framework performs normal
/// platform trust validation; IM bytes are never sent until the TLS connection
/// reaches `.ready`. This actor owns bounded request correlation and fences
/// all socket callbacks by connection generation.
#if canImport(Network) && canImport(Security)
/// Injectable byte boundary; the production adapter retains TLS 1.3 and
/// platform trust validation. Test peers can delay an old socket callback.
protocol V2TLSByteConnection: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    func receive(maximumLength: Int) async throws -> Data
    func cancel()
}

struct V2NetworkTLSByteConnection: V2TLSByteConnection {
    let connection: NWConnection
    private let queue: DispatchQueue
    init(endpoint: V2RealtimeEndpoint) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(tls: tls, tcp: .init())
        connection = NWConnection(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!, using: parameters)
        queue = .global(qos: .utility)
    }
    // Internal byte-boundary injection for Network.framework callback tests.
    // The public endpoint initializer above always configures validated TLS.
    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = Mutex<CheckedContinuation<Void, Error>?>(continuation)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state {
                case .ready: result = .success(())
                case .failed, .cancelled: result = .failure(V2TLSFrameConnectionError.connectionFailed)
                default: return
                }
                // Framework state callbacks can already be queued when the
                // handler is cleared. Complete this readiness bridge once.
                let waiter = pending.withLock { value in
                    let waiter = value
                    value = nil
                    return waiter
                }
                connection.stateUpdateHandler = nil
                waiter?.resume(with: result)
            }
            connection.start(queue: queue)
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed) }
            })
        }
    }
    func receive(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { bytes, _, _, error in
                if error != nil { continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed) }
                else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: V2TLSFrameConnectionError.connectionClosed) }
            }
        }
    }
    func cancel() { connection.cancel() }
}

public actor V2TLSFrameConnection: V2AuthenticatedFrameTransport, V2SyncAvailabilityHintSource, V2GroupEventAvailabilityHintSource, V2LiveActivityEventSource, V2RealtimeConnection {
    private let connectionFactory: @Sendable () -> any V2TLSByteConnection
    private let maximumPendingRequests: Int
    private let limits: V2FrameLimits
    private let maximumProtobufMessageDepth: Int
    private let requestTimeout: Duration
    /// Never leaves this actor. A suspended reader retains its own generation's
    /// buffer object, so it cannot append old bytes into a replacement decoder.
    private final class InboundState {
        let generation: UUID
        var decoder: V2FrameDecoder
        var frames: [V2Frame] = []
        init(generation: UUID, limits: V2FrameLimits) {
            self.generation = generation
            decoder = .init(limits: limits)
        }
    }
    private var inboundState: InboundState?
    private var connection: (any V2TLSByteConnection)?
    private var connectionID: UUID?
    private var authenticatedVersion: UInt8?
    private var negotiatedFrameCompression: V2NegotiatedFrameCompression?
    private struct PendingResponse {
        let id: UUID
        var continuation: CheckedContinuation<V2Frame, Error>?
        let deadline: Task<Void, Never>
        let sendTask: Task<Void, Never>
    }
    private struct Waiter<Value: Sendable> {
        let id: UUID
        let continuation: CheckedContinuation<Value, Error>
        func resume(returning value: Value) { continuation.resume(returning: value) }
        func resume(throwing error: any Error) { continuation.resume(throwing: error) }
    }
    // A nil continuation means cancelledOnWire. Its deadline and capacity
    // slot remain owned by this connection until the reply or generation close.
    private var responseWaiters: [UInt64: PendingResponse] = [:]
    private var availabilityWaiter: Waiter<V2SyncAvailabilityHint>?
    private var pendingAvailabilityHint: V2SyncAvailabilityHint?
    private var groupEventAvailabilityWaiter: Waiter<V2GroupEventAvailabilityHint>?
    private var pendingGroupEventAvailabilityHint: V2GroupEventAvailabilityHint?
    private var liveActivityWaiter: Waiter<V2LiveActivityEvent>?
    private var pendingLiveActivityEvents: [V2LiveActivityEvent] = []
    private var readerTask: Task<Void, Never>?

    public init(
        endpoint: V2RealtimeEndpoint,
        frameLimits: V2FrameLimits,
        maximumProtobufMessageDepth: Int = V2ProtobufFrameCodec.defaultMaximumMessageDepth,
        requestTimeout: Duration = .seconds(20),
        maximumPendingRequests: Int = 256
    ) {
        precondition(maximumProtobufMessageDepth > 0)
        self.connectionFactory = { V2NetworkTLSByteConnection(endpoint: endpoint) }
        precondition(maximumPendingRequests > 0 && requestTimeout > .zero)
        self.maximumPendingRequests = maximumPendingRequests
        self.limits = frameLimits
        self.maximumProtobufMessageDepth = maximumProtobufMessageDepth
        self.requestTimeout = requestTimeout
    }

    init(
        connectionFactory: @escaping @Sendable () -> any V2TLSByteConnection,
        frameLimits: V2FrameLimits,
        requestTimeout: Duration = .seconds(20),
        maximumPendingRequests: Int = 256
    ) {
        precondition(maximumPendingRequests > 0 && requestTimeout > .zero)
        self.connectionFactory = connectionFactory
        self.maximumPendingRequests = maximumPendingRequests
        limits = frameLimits
        maximumProtobufMessageDepth = V2ProtobufFrameCodec.defaultMaximumMessageDepth
        self.requestTimeout = requestTimeout
    }

    public func connectAndAuthenticate(accessToken: String, deviceID: DeviceID, supportedCapabilityProfiles: Set<String>) async throws -> V2AuthenticatedClientSession {
        guard !accessToken.isEmpty, !supportedCapabilityProfiles.isEmpty else { throw V2TLSFrameConnectionError.authenticationFailed }
        guard connection == nil else { throw V2TLSFrameConnectionError.connectionFailed }
        let generation = UUID()
        do {
            try await connect(generation: generation)
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello = .init()
            hello.clientHello.supportedProtocolVersions = [UInt32(IMV2ProtocolVersion.current)]
            hello.clientHello.supportedCapabilityProfiles = Array(supportedCapabilityProfiles).sorted()
            hello.clientHello.deviceID = deviceID.rawValue
            hello.clientHello.supportedFrameCompressions = [.zlib]
            let helloResponse = try await sendBootstrap(hello, version: 0, generation: generation)
            guard case .serverHello(let serverHello)? = helloResponse.body,
                  let version = UInt8(exactly: serverHello.selectedProtocolVersion),
                  version == UInt8(IMV2ProtocolVersion.current),
                  supportedCapabilityProfiles.contains(serverHello.selectedCapabilityProfile)
            else { throw V2TLSFrameConnectionError.unsupportedVersion }
            try requireGeneration(generation)
            switch serverHello.selectedFrameCompression {
            case .unspecified:
                negotiatedFrameCompression = nil
            case .zlib:
                negotiatedFrameCompression = .zlib
            case .UNRECOGNIZED:
                throw V2TLSFrameConnectionError.unsupportedCompression
            }

            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = UInt32(version)
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = accessToken
            authenticate.authenticate.deviceID = deviceID.rawValue
            let authenticated = try await sendBootstrap(authenticate, version: version, generation: generation)
            guard case .authenticated(let response)? = authenticated.body,
                  response.deviceID == deviceID.rawValue,
                  response.selectedCapabilityProfile == serverHello.selectedCapabilityProfile,
                  response.selectedFrameCompression == serverHello.selectedFrameCompression,
                  let userID = try? UserID(response.userID)
            else { throw V2TLSFrameConnectionError.authenticationFailed }
            try requireGeneration(generation)
            authenticatedVersion = version
            guard let connection else { throw V2TLSFrameConnectionError.connectionClosed }
            startReader(connection, generation: generation)
            return .init(
                userID: userID,
                deviceID: deviceID,
                protocolVersion: version,
                capabilityProfile: response.selectedCapabilityProfile,
                frameCompression: negotiatedFrameCompression,
                connectionID: generation
            )
        } catch {
            closeTransport(error: error, expectedGeneration: generation)
            throw error
        }
    }

    public func request(_ frame: V2Frame) async throws -> V2Frame {
        guard let version = authenticatedVersion, frame.version == version else { throw V2TLSFrameConnectionError.notConnected }
        return try await sendAndAwaitResponse(frame)
    }

    public func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint {
        try Task.checkCancellation()
        if let expected = V2ConnectionRequestScope.connectionID, expected != connectionID {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        if let pendingAvailabilityHint {
            self.pendingAvailabilityHint = nil
            return pendingAvailabilityHint
        }
        let waiterID = UUID()
        let generation = connectionID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard availabilityWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                availabilityWaiter = .init(id: waiterID, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelAvailabilityWait(id: waiterID, generation: generation) }
        })
    }

    public func nextLiveActivityEvent() async throws -> V2LiveActivityEvent {
        try Task.checkCancellation()
        if let expected = V2ConnectionRequestScope.connectionID, expected != connectionID {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        if !pendingLiveActivityEvents.isEmpty { return pendingLiveActivityEvents.removeFirst() }
        let waiterID = UUID()
        let generation = connectionID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard liveActivityWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                liveActivityWaiter = .init(id: waiterID, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelLiveActivityWait(id: waiterID, generation: generation) }
        })
    }

    public func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        try Task.checkCancellation()
        if let expected = V2ConnectionRequestScope.connectionID, expected != connectionID {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        if let pendingGroupEventAvailabilityHint {
            self.pendingGroupEventAvailabilityHint = nil
            return pendingGroupEventAvailabilityHint
        }
        let waiterID = UUID()
        let generation = connectionID
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard groupEventAvailabilityWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                groupEventAvailabilityWaiter = .init(id: waiterID, continuation: continuation)
            }
        }, onCancel: {
            Task { await self.cancelGroupEventAvailabilityWait(id: waiterID, generation: generation) }
        })
    }

    public func disconnect() async {
        let reader = readerTask
        let sends = responseWaiters.values.map(\.sendTask)
        closeTransport(error: V2TLSFrameConnectionError.connectionClosed)
        // State is already detached. Drain outside closeTransport so a reader
        // failure never waits for its own task and a replacement may proceed.
        await reader?.value
        for send in sends { await send.value }
    }

    private func requireGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard connectionID == generation, connection != nil else { throw V2TLSFrameConnectionError.connectionClosed }
    }

    private func connect(generation: UUID) async throws {
        try Task.checkCancellation()
        let connection = connectionFactory()
        self.connection = connection
        connectionID = generation
        inboundState = .init(generation: generation, limits: limits)
        try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await connection.start() }
                group.addTask { [requestTimeout] in
                    try await Task.sleep(for: requestTimeout)
                    connection.cancel()
                    throw V2TLSFrameConnectionError.requestTimedOut
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }, onCancel: { connection.cancel() })
        try requireGeneration(generation)
    }

    private func sendBootstrap(_ envelope: IMV2Envelope, version: UInt8, generation: UUID) async throws -> IMV2Envelope {
        let response = try await exchangeBootstrap(try V2ProtobufFrameCodec.encode(envelope, frameVersion: version), generation: generation)
        let decoded = try V2ProtobufFrameCodec.decode(response, maximumMessageDepth: maximumProtobufMessageDepth)
        guard decoded.requestID == envelope.requestID else { throw V2TLSFrameConnectionError.unexpectedResponse }
        if case .error = decoded.body { throw V2TLSFrameConnectionError.authenticationFailed }
        return decoded
    }

    private func exchangeBootstrap(_ frame: V2Frame, generation: UUID) async throws -> V2Frame {
        do {
            return try await withThrowingTaskGroup(of: V2Frame.self) { group in
                group.addTask { [self] in
                    try await exchangeBootstrapWithoutDeadline(frame, generation: generation)
                }
                group.addTask { [requestTimeout, weak self] in
                    try await Task.sleep(for: requestTimeout)
                    // `nextFrame` is continuation-based. Closing transport
                    // is what makes its pending receive complete promptly.
                    await self?.closeTransport(error: V2TLSFrameConnectionError.requestTimedOut, expectedGeneration: generation)
                    throw V2TLSFrameConnectionError.requestTimedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw V2TLSFrameConnectionError.connectionFailed
                }
                return result
            }
        } catch let error as V2TLSFrameConnectionError where error == .requestTimedOut {
            closeTransport(error: error, expectedGeneration: generation)
            throw error
        }
    }

    private func exchangeBootstrapWithoutDeadline(_ frame: V2Frame, generation: UUID) async throws -> V2Frame {
        guard let connection else { throw V2TLSFrameConnectionError.notConnected }
        try requireGeneration(generation)
        try await send(frame, on: connection)
        try requireGeneration(generation)
        while true {
            let response = try await nextFrame(connection: connection, generation: generation)
            guard response.flags.isEmpty else { throw V2TLSFrameConnectionError.unsupportedFrameFlags }
            if response.requestID == frame.requestID { return response }
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
    }

    private func sendAndAwaitResponse(_ frame: V2Frame) async throws -> V2Frame {
        guard let connection, let generation = connectionID else { throw V2TLSFrameConnectionError.notConnected }
        if let expected = V2ConnectionRequestScope.connectionID, expected != generation {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        try Task.checkCancellation()
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard responseWaiters[frame.requestID] == nil, frame.requestID != 0 else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.unexpectedResponse)
                    return
                }
                guard responseWaiters.count < maximumPendingRequests else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.tooManyPendingRequests)
                    return
                }
                let deadline = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.expireRequest(frame.requestID, id: id, generation: generation)
                }
                let sendTask = Task { [weak self] in
                    do { try await connection.send(bytes) }
                    catch { await self?.failRequest(frame.requestID, id: id, generation: generation) }
                }
                responseWaiters[frame.requestID] = .init(id: id, continuation: continuation, deadline: deadline, sendTask: sendTask)
            }
        }, onCancel: {
            Task { await self.cancelRequest(frame.requestID, id: id, generation: generation) }
        })
    }

    private func send(_ frame: V2Frame, on connection: any V2TLSByteConnection) async throws {
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        try await withTaskCancellationHandler(operation: {
            try await connection.send(bytes)
        }, onCancel: { connection.cancel() })
    }

    private func startReader(_ connection: any V2TLSByteConnection, generation: UUID) {
        readerTask?.cancel()
        readerTask = Task { await receiveLoop(connection: connection, generation: generation) }
    }

    private func receiveLoop(connection: any V2TLSByteConnection, generation: UUID) async {
        do {
            while !Task.isCancelled {
                let frame = try await nextFrame(connection: connection, generation: generation)
                try requireGeneration(generation)
                try acceptInbound(frame)
            }
        } catch is CancellationError {
            // Explicit disconnect owns continuation completion.
        } catch {
            closeTransport(error: V2TLSFrameConnectionError.connectionClosed, expectedGeneration: generation)
        }
    }

    private func acceptInbound(_ frame: V2Frame) throws {
        if frame.requestID == 0 {
            guard frame.flags.isEmpty else {
                throw V2TLSFrameConnectionError.unsupportedFrameFlags
            }
            let envelope = try V2ProtobufFrameCodec.decode(frame, maximumMessageDepth: maximumProtobufMessageDepth)
            switch envelope.body {
            case .syncAvailable(let hint):
                let value = V2SyncAvailabilityHint(eventID: hint.eventID, highWatermark: hint.highWatermark)
                if let availabilityWaiter {
                    self.availabilityWaiter = nil
                    availabilityWaiter.resume(returning: value)
                } else if pendingAvailabilityHint == nil || value.highWatermark >= pendingAvailabilityHint!.highWatermark {
                    pendingAvailabilityHint = value
                }
            case .groupEventAvailable(let hint):
                let value = try V2GroupEventAvailabilityHint(
                    roomID: .init(hint.roomID),
                    highWatermark: hint.highWatermark,
                    liveEvents: Self.liveGroupEvents(from: hint)
                )
                if let groupEventAvailabilityWaiter {
                    self.groupEventAvailabilityWaiter = nil
                    groupEventAvailabilityWaiter.resume(returning: value)
                } else if let pendingGroupEventAvailabilityHint {
                    self.pendingGroupEventAvailabilityHint = pendingGroupEventAvailabilityHint
                        .coalescing(with: value)
                } else {
                    pendingGroupEventAvailabilityHint = value
                }
            case .presenceChanged(let state):
                let value = try V2LiveActivityEvent.presence(.init(roomID: .init(state.roomID), targetUserID: .init(state.targetUserID), isOnline: state.isOnline, expiresAt: Date(timeIntervalSince1970: TimeInterval(state.expiresAtMs) / 1_000)))
                acceptLiveActivityEvent(value)
            case .typingStateChanged(let state):
                let value = try V2LiveActivityEvent.typing(.init(roomID: .init(state.roomID), userID: .init(state.userID), isTyping: state.isTyping, expiresAt: Date(timeIntervalSince1970: TimeInterval(state.expiresAtMs) / 1_000)))
                acceptLiveActivityEvent(value)
            default:
                throw V2TLSFrameConnectionError.unexpectedResponse
            }
            return
        }
        guard frame.flags.isEmpty || frame.flags == [.headerBoundRequestID] else {
            throw V2TLSFrameConnectionError.unsupportedFrameFlags
        }
        guard let waiter = responseWaiters.removeValue(forKey: frame.requestID) else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        waiter.deadline.cancel()
        waiter.sendTask.cancel()
        waiter.continuation?.resume(returning: frame)
    }

    /// A malformed optional acceleration payload is never a transport error:
    /// treating it as a normal metadata wake preserves the durable recovery
    /// path and prevents an untrusted payload from advancing a cursor.
    static func liveGroupEvents(from hint: IMV2GroupEventAvailable) -> [V2ClientGroupEvent] {
        if !hint.liveEvents.isEmpty {
            let events = hint.liveEvents.compactMap(Self.liveGroupEvent(from:))
            guard events.count == hint.liveEvents.count,
                  events.last?.roomSequence == hint.highWatermark,
                  zip(events, events.dropFirst()).allSatisfy({
                      $1.roomSequence == $0.roomSequence + 1
                  })
            else { return [] }
            return events
        }
        guard hint.roomSequence == hint.highWatermark else { return [] }
        return Self.liveGroupEvent(
            sourceEventID: hint.sourceEventID,
            roomSequence: hint.roomSequence,
            projectionKind: hint.projectionKind,
            payload: hint.eventPayload
        ).map { [$0] } ?? []
    }

    private static func liveGroupEvent(from event: IMV2GroupEvent) -> V2ClientGroupEvent? {
        liveGroupEvent(
            sourceEventID: event.sourceEventID,
            roomSequence: event.roomSequence,
            projectionKind: event.projectionKind,
            payload: event.payload
        )
    }

    private static func liveGroupEvent(
        sourceEventID: String,
        roomSequence: UInt64,
        projectionKind: String,
        payload: Data
    ) -> V2ClientGroupEvent? {
        guard !sourceEventID.isEmpty,
              roomSequence > 0,
              !projectionKind.isEmpty,
              !payload.isEmpty,
              let sourceEventID = try? EventID(sourceEventID)
        else { return nil }
        return try? .init(
            sourceEventID: sourceEventID,
            roomSequence: roomSequence,
            projectionKind: projectionKind,
            payload: payload
        )
    }

    private func failRequest(_ requestID: UInt64, id: UUID, generation: UUID) {
        guard connectionID == generation, responseWaiters[requestID]?.id == id else { return }
        closeTransport(error: V2TLSFrameConnectionError.connectionFailed, expectedGeneration: generation)
    }

    private func expireRequest(_ requestID: UInt64, id: UUID, generation: UUID) {
        guard connectionID == generation, responseWaiters[requestID]?.id == id else { return }
        // Includes cancelledOnWire entries. Never recycle an expired request
        // ID while the same stream can still deliver its old response.
        closeTransport(error: V2TLSFrameConnectionError.requestTimedOut, expectedGeneration: generation)
    }

    private func cancelRequest(_ requestID: UInt64, id: UUID, generation: UUID) {
        guard connectionID == generation, responseWaiters[requestID]?.id == id else { return }
        let continuation = responseWaiters[requestID]?.continuation
        responseWaiters[requestID]?.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelAvailabilityWait(id: UUID, generation: UUID?) {
        guard connectionID == generation, availabilityWaiter?.id == id else { return }
        availabilityWaiter?.resume(throwing: CancellationError())
        availabilityWaiter = nil
    }

    private func cancelGroupEventAvailabilityWait(id: UUID, generation: UUID?) {
        guard connectionID == generation, groupEventAvailabilityWaiter?.id == id else { return }
        groupEventAvailabilityWaiter?.resume(throwing: CancellationError())
        groupEventAvailabilityWaiter = nil
    }

    private func cancelLiveActivityWait(id: UUID, generation: UUID?) {
        guard connectionID == generation, liveActivityWaiter?.id == id else { return }
        liveActivityWaiter?.resume(throwing: CancellationError())
        liveActivityWaiter = nil
    }

    private func acceptLiveActivityEvent(_ event: V2LiveActivityEvent) {
        if let liveActivityWaiter {
            self.liveActivityWaiter = nil
            liveActivityWaiter.resume(returning: event)
        } else {
            pendingLiveActivityEvents.append(event)
            if pendingLiveActivityEvents.count > 16 { pendingLiveActivityEvents.removeFirst(pendingLiveActivityEvents.count - 16) }
        }
    }

    private func closeTransport(error: Error, expectedGeneration: UUID? = nil) {
        if let expectedGeneration, connectionID != expectedGeneration { return }
        // Fence callbacks before cancelling their socket/tasks. Old work may
        // finish later, but cannot observe or clear a replacement generation.
        connectionID = nil
        readerTask?.cancel()
        readerTask = nil
        connection?.cancel()
        connection = nil
        authenticatedVersion = nil
        negotiatedFrameCompression = nil
        inboundState = nil
        let waiters = responseWaiters.values
        responseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.deadline.cancel()
            waiter.sendTask.cancel()
            waiter.continuation?.resume(throwing: error)
        }
        availabilityWaiter?.resume(throwing: error)
        availabilityWaiter = nil
        pendingAvailabilityHint = nil
        groupEventAvailabilityWaiter?.resume(throwing: error)
        groupEventAvailabilityWaiter = nil
        pendingGroupEventAvailabilityHint = nil
        liveActivityWaiter?.resume(throwing: error)
        liveActivityWaiter = nil
        pendingLiveActivityEvents.removeAll(keepingCapacity: false)
    }

    private func nextFrame(connection: any V2TLSByteConnection, generation: UUID) async throws -> V2Frame {
        try requireGeneration(generation)
        guard let state = inboundState, state.generation == generation else {
            throw V2TLSFrameConnectionError.connectionClosed
        }
        if !state.frames.isEmpty { return try normalizeInboundFrame(state.frames.removeFirst()) }
        while true {
            let frames: [V2Frame]
            if state.decoder.hasBufferedBytes {
                let bufferedFrames = try state.decoder.append(Data())
                if bufferedFrames.isEmpty {
                    let chunk = try await receiveChunk(connection: connection)
                    try requireGeneration(generation)
                    frames = try state.decoder.append(chunk)
                } else {
                    frames = bufferedFrames
                }
            } else {
                let chunk = try await receiveChunk(connection: connection)
                try requireGeneration(generation)
                frames = try state.decoder.append(chunk)
            }
            if let first = frames.first {
                state.frames.append(contentsOf: frames.dropFirst())
                return try normalizeInboundFrame(first)
            }
        }
    }

    /// The transport consumes the negotiated wire representation once and
    /// returns an ordinary protobuf frame to higher layers. This keeps every
    /// existing domain decoder and request-correlation boundary unchanged.
    private func normalizeInboundFrame(_ frame: V2Frame) throws -> V2Frame {
        guard !frame.flags.isEmpty else { return frame }
        let knownFlags: V2FrameFlags = [.compressed, .headerBoundRequestID]
        guard frame.flags.subtracting(knownFlags).isEmpty else {
            throw V2TLSFrameConnectionError.unsupportedFrameFlags
        }
        guard frame.flags.contains(.compressed) else { return frame }
        guard negotiatedFrameCompression == .zlib else {
            if frame.flags.contains(.compressed) {
                throw V2TLSFrameConnectionError.unsupportedCompression
            }
            throw V2TLSFrameConnectionError.unsupportedFrameFlags
        }
        let payload: Data
        do {
            payload = try V2ZlibFrameCompression.decompress(
                frame.payload,
                maximumOutputBytes: limits.maximumPayloadBytes,
                maximumExpansionRatio: V2ZlibFrameCompression.defaultMaximumExpansionRatio
            )
        } catch {
            throw V2TLSFrameConnectionError.unsupportedCompression
        }
        return .init(
            version: frame.version,
            flags: frame.flags.subtracting(.compressed),
            command: frame.command,
            requestID: frame.requestID,
            payload: payload
        )
    }

    private func receiveChunk(connection: any V2TLSByteConnection) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await connection.receive(maximumLength: limits.maximumPayloadBytes + V2Frame.headerLength)
        }, onCancel: { connection.cancel() })
    }

}
#else
/// The production transport is intentionally unavailable on non-Apple
/// platforms. Linux remains useful for pure protocol, persistence, and
/// synchronization regression tests, but may not silently downgrade TLS.
public actor V2TLSFrameConnection: V2AuthenticatedFrameTransport, V2SyncAvailabilityHintSource, V2GroupEventAvailabilityHintSource, V2RealtimeConnection {
    public init(
        endpoint _: V2RealtimeEndpoint,
        frameLimits _: V2FrameLimits,
        maximumProtobufMessageDepth: Int = V2ProtobufFrameCodec.defaultMaximumMessageDepth
    ) {
        precondition(maximumProtobufMessageDepth > 0)
    }

    public func connectAndAuthenticate(accessToken _: String, deviceID _: DeviceID, supportedCapabilityProfiles _: Set<String>) async throws -> V2AuthenticatedClientSession {
        throw V2TLSFrameConnectionError.notConnected
    }

    public func request(_: V2Frame) async throws -> V2Frame {
        throw V2TLSFrameConnectionError.notConnected
    }

    public func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint {
        throw V2TLSFrameConnectionError.notConnected
    }

    public func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        throw V2TLSFrameConnectionError.notConnected
    }

    public func disconnect() {}
}
#endif
