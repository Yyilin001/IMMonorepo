import Foundation
import IMV2Core
#if canImport(Network) && canImport(Security)
import Network
import Security
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
}

public struct V2SyncAvailabilityHint: Equatable, Sendable {
    public let eventID: UInt64
    public let highWatermark: UInt64

    public init(eventID: UInt64, highWatermark: UInt64) {
        self.eventID = eventID
        self.highWatermark = highWatermark
    }
}

/// Non-authoritative foreground wake for one Hybrid room. The client follows
/// it with its durable room-event cursor pull before changing local state.
public struct V2GroupEventAvailabilityHint: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64

    public init(roomID: RoomID, highWatermark: UInt64) {
        self.roomID = roomID
        self.highWatermark = highWatermark
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
/// reaches `.ready`. Requests are serialized by this actor, matching the
/// SyncEngine's deterministic apply/ACK behavior.
#if canImport(Network) && canImport(Security)
public actor V2TLSFrameConnection: V2AuthenticatedFrameTransport, V2SyncAvailabilityHintSource, V2GroupEventAvailabilityHintSource, V2RealtimeConnection {
    private let endpoint: V2RealtimeEndpoint
    private let limits: V2FrameLimits
    private let maximumProtobufMessageDepth: Int
    private let requestTimeout: Duration
    private var decoder: V2FrameDecoder
    private var bufferedFrames: [V2Frame] = []
    private var connection: NWConnection?
    private var authenticatedVersion: UInt8?
    private var responseWaiters: [UInt64: CheckedContinuation<V2Frame, Error>] = [:]
    private var availabilityWaiter: CheckedContinuation<V2SyncAvailabilityHint, Error>?
    private var pendingAvailabilityHint: V2SyncAvailabilityHint?
    private var groupEventAvailabilityWaiter: CheckedContinuation<V2GroupEventAvailabilityHint, Error>?
    private var pendingGroupEventAvailabilityHint: V2GroupEventAvailabilityHint?
    private var readerTask: Task<Void, Never>?

    public init(
        endpoint: V2RealtimeEndpoint,
        frameLimits: V2FrameLimits,
        maximumProtobufMessageDepth: Int = V2ProtobufFrameCodec.defaultMaximumMessageDepth,
        requestTimeout: Duration = .seconds(20)
    ) {
        precondition(maximumProtobufMessageDepth > 0)
        self.endpoint = endpoint
        self.limits = frameLimits
        self.maximumProtobufMessageDepth = maximumProtobufMessageDepth
        self.requestTimeout = requestTimeout
        self.decoder = .init(limits: frameLimits)
    }

    public func connectAndAuthenticate(accessToken: String, deviceID: DeviceID, supportedCapabilityProfiles: Set<String>) async throws -> V2AuthenticatedClientSession {
        guard !accessToken.isEmpty, !supportedCapabilityProfiles.isEmpty else { throw V2TLSFrameConnectionError.authenticationFailed }
        try await connectIfNeeded()
        do {
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello = .init()
            hello.clientHello.supportedProtocolVersions = [UInt32(IMV2ProtocolVersion.current)]
            hello.clientHello.supportedCapabilityProfiles = Array(supportedCapabilityProfiles).sorted()
            hello.clientHello.deviceID = deviceID.rawValue
            let helloResponse = try await sendBootstrap(hello, version: 0)
            guard case .serverHello(let serverHello)? = helloResponse.body,
                  let version = UInt8(exactly: serverHello.selectedProtocolVersion),
                  version == UInt8(IMV2ProtocolVersion.current),
                  supportedCapabilityProfiles.contains(serverHello.selectedCapabilityProfile)
            else { throw V2TLSFrameConnectionError.unsupportedVersion }

            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = UInt32(version)
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = accessToken
            authenticate.authenticate.deviceID = deviceID.rawValue
            let authenticated = try await sendBootstrap(authenticate, version: version)
            guard case .authenticated(let response)? = authenticated.body,
                  response.deviceID == deviceID.rawValue,
                  response.selectedCapabilityProfile == serverHello.selectedCapabilityProfile,
                  let userID = try? UserID(response.userID)
            else { throw V2TLSFrameConnectionError.authenticationFailed }
            authenticatedVersion = version
            guard let connection else { throw V2TLSFrameConnectionError.connectionClosed }
            startReader(connection)
            return .init(userID: userID, deviceID: deviceID, protocolVersion: version, capabilityProfile: response.selectedCapabilityProfile)
        } catch {
            disconnect()
            throw error
        }
    }

    public func request(_ frame: V2Frame) async throws -> V2Frame {
        guard let version = authenticatedVersion, frame.version == version else { throw V2TLSFrameConnectionError.notConnected }
        return try await sendAndAwaitResponse(frame)
    }

    public func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint {
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        if let pendingAvailabilityHint {
            self.pendingAvailabilityHint = nil
            return pendingAvailabilityHint
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard availabilityWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                availabilityWaiter = continuation
            }
        }, onCancel: {
            Task { await self.cancelAvailabilityWait() }
        })
    }

    public func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        guard authenticatedVersion != nil, connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        if let pendingGroupEventAvailabilityHint {
            self.pendingGroupEventAvailabilityHint = nil
            return pendingGroupEventAvailabilityHint
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard groupEventAvailabilityWaiter == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.concurrentAvailabilityConsumer)
                    return
                }
                groupEventAvailabilityWaiter = continuation
            }
        }, onCancel: {
            Task { await self.cancelGroupEventAvailabilityWait() }
        })
    }

    public func disconnect() {
        closeTransport(error: V2TLSFrameConnectionError.connectionClosed)
    }

    private func connectIfNeeded() async throws {
        if connection != nil { return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(tls: tls, tcp: .init())
        let connection = NWConnection(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!, using: parameters)
        self.connection = connection
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                connection.stateUpdateHandler = nil
                                continuation.resume()
                            case .failed, .cancelled:
                                connection.stateUpdateHandler = nil
                                continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed)
                            default:
                                break
                            }
                        }
                        connection.start(queue: .global(qos: .utility))
                    }
                }
                group.addTask { [requestTimeout] in
                    try await Task.sleep(for: requestTimeout)
                    // Cancelling a task does not necessarily interrupt an
                    // outstanding Network.framework receive, so actively
                    // close the socket to release the competing waiter.
                    connection.cancel()
                    throw V2TLSFrameConnectionError.requestTimedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw V2TLSFrameConnectionError.connectionFailed
                }
                return result
            }
        } catch let error as V2TLSFrameConnectionError where error == .requestTimedOut {
            closeTransport(error: error)
            throw error
        }
    }

    private func sendBootstrap(_ envelope: IMV2Envelope, version: UInt8) async throws -> IMV2Envelope {
        let response = try await exchangeBootstrap(try V2ProtobufFrameCodec.encode(envelope, frameVersion: version))
        let decoded = try V2ProtobufFrameCodec.decode(response, maximumMessageDepth: maximumProtobufMessageDepth)
        guard decoded.requestID == envelope.requestID else { throw V2TLSFrameConnectionError.unexpectedResponse }
        if case .error = decoded.body { throw V2TLSFrameConnectionError.authenticationFailed }
        return decoded
    }

    private func exchangeBootstrap(_ frame: V2Frame) async throws -> V2Frame {
        do {
            return try await withThrowingTaskGroup(of: V2Frame.self) { group in
                group.addTask { [self] in
                    try await exchangeBootstrapWithoutDeadline(frame)
                }
                group.addTask { [requestTimeout, weak self] in
                    try await Task.sleep(for: requestTimeout)
                    // `nextFrame` is continuation-based. Closing transport
                    // is what makes its pending receive complete promptly.
                    await self?.closeTransport(error: V2TLSFrameConnectionError.requestTimedOut)
                    throw V2TLSFrameConnectionError.requestTimedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw V2TLSFrameConnectionError.connectionFailed
                }
                return result
            }
        } catch let error as V2TLSFrameConnectionError where error == .requestTimedOut {
            closeTransport(error: error)
            throw error
        }
    }

    private func exchangeBootstrapWithoutDeadline(_ frame: V2Frame) async throws -> V2Frame {
        guard let connection else { throw V2TLSFrameConnectionError.notConnected }
        try await send(frame, on: connection)
        while true {
            let response = try await nextFrame(connection: connection)
            guard !response.flags.contains(.compressed) else { throw V2TLSFrameConnectionError.unsupportedCompression }
            guard response.flags.isEmpty else { throw V2TLSFrameConnectionError.unsupportedFrameFlags }
            if response.requestID == frame.requestID { return response }
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
    }

    private func sendAndAwaitResponse(_ frame: V2Frame) async throws -> V2Frame {
        guard connection != nil else { throw V2TLSFrameConnectionError.notConnected }
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        do {
            return try await withThrowingTaskGroup(of: V2Frame.self) { group in
                group.addTask { [self] in
                    try await awaitResponse(frame: frame, bytes: bytes)
                }
                group.addTask { [requestTimeout] in
                    try await Task.sleep(for: requestTimeout)
                    throw V2TLSFrameConnectionError.requestTimedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw V2TLSFrameConnectionError.connectionFailed
                }
                return result
            }
        } catch let error as V2TLSFrameConnectionError where error == .requestTimedOut {
            // A response deadline means this correlation can no longer be
            // trusted. Closing also releases every other pending waiter and
            // lets the app-level supervisor establish a fresh TLS session.
            closeTransport(error: error)
            throw error
        }
    }

    private func awaitResponse(frame: V2Frame, bytes: Data) async throws -> V2Frame {
        guard let connection else { throw V2TLSFrameConnectionError.notConnected }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<V2Frame, Error>) in
                guard responseWaiters[frame.requestID] == nil else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.unexpectedResponse)
                    return
                }
                responseWaiters[frame.requestID] = continuation
                connection.send(content: bytes, completion: .contentProcessed { error in
                    guard error != nil else { return }
                    Task { await self.failRequest(frame.requestID) }
                })
            }
        }, onCancel: {
            Task { await self.cancelRequest(frame.requestID) }
        })
    }

    private func send(_ frame: V2Frame, on connection: NWConnection) async throws {
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed) }
            })
        }
    }

    private func startReader(_ connection: NWConnection) {
        readerTask?.cancel()
        readerTask = Task { await receiveLoop(connection: connection) }
    }

    private func receiveLoop(connection: NWConnection) async {
        do {
            while !Task.isCancelled {
                let frame = try await nextFrame(connection: connection)
                try acceptInbound(frame)
            }
        } catch is CancellationError {
            // Explicit disconnect owns continuation completion.
        } catch {
            closeTransport(error: V2TLSFrameConnectionError.connectionClosed)
        }
    }

    private func acceptInbound(_ frame: V2Frame) throws {
        guard !frame.flags.contains(.compressed) else { throw V2TLSFrameConnectionError.unsupportedCompression }
        guard frame.flags.isEmpty else { throw V2TLSFrameConnectionError.unsupportedFrameFlags }
        if frame.requestID == 0 {
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
                let value = try V2GroupEventAvailabilityHint(roomID: .init(hint.roomID), highWatermark: hint.highWatermark)
                if let groupEventAvailabilityWaiter {
                    self.groupEventAvailabilityWaiter = nil
                    groupEventAvailabilityWaiter.resume(returning: value)
                } else if pendingGroupEventAvailabilityHint == nil || value.highWatermark >= pendingGroupEventAvailabilityHint!.highWatermark {
                    pendingGroupEventAvailabilityHint = value
                }
            default:
                throw V2TLSFrameConnectionError.unexpectedResponse
            }
            return
        }
        guard let waiter = responseWaiters.removeValue(forKey: frame.requestID) else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        waiter.resume(returning: frame)
    }

    private func failRequest(_ requestID: UInt64) {
        // A failed NWConnection send means the stream can no longer provide a
        // trustworthy ordering boundary. Closing releases *all* waiters and
        // makes the owning runtime reconnect instead of leaving a seemingly
        // healthy session with only one request failed.
        guard responseWaiters[requestID] != nil else { return }
        closeTransport(error: V2TLSFrameConnectionError.connectionFailed)
    }

    private func cancelRequest(_ requestID: UInt64) {
        responseWaiters.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
    }

    private func cancelAvailabilityWait() {
        availabilityWaiter?.resume(throwing: CancellationError())
        availabilityWaiter = nil
    }

    private func cancelGroupEventAvailabilityWait() {
        groupEventAvailabilityWaiter?.resume(throwing: CancellationError())
        groupEventAvailabilityWaiter = nil
    }

    private func closeTransport(error: Error) {
        readerTask?.cancel()
        readerTask = nil
        connection?.cancel()
        connection = nil
        authenticatedVersion = nil
        bufferedFrames.removeAll(keepingCapacity: false)
        decoder = .init(limits: limits)
        let waiters = responseWaiters.values
        responseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(throwing: error) }
        availabilityWaiter?.resume(throwing: error)
        availabilityWaiter = nil
        pendingAvailabilityHint = nil
        groupEventAvailabilityWaiter?.resume(throwing: error)
        groupEventAvailabilityWaiter = nil
        pendingGroupEventAvailabilityHint = nil
    }

    private func nextFrame(connection: NWConnection) async throws -> V2Frame {
        if !bufferedFrames.isEmpty { return bufferedFrames.removeFirst() }
        while true {
            let bytes = try await receiveChunk(connection: connection)
            let frames = try decoder.append(bytes)
            if let first = frames.first {
                bufferedFrames.append(contentsOf: frames.dropFirst())
                return first
            }
        }
    }

    private func receiveChunk(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: limits.maximumPayloadBytes + V2Frame.headerLength) { bytes, _, complete, error in
                if let error {
                    _ = error
                    continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed)
                } else if let bytes, !bytes.isEmpty {
                    continuation.resume(returning: bytes)
                } else if complete {
                    continuation.resume(throwing: V2TLSFrameConnectionError.connectionClosed)
                } else {
                    continuation.resume(throwing: V2TLSFrameConnectionError.connectionClosed)
                }
            }
        }
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
