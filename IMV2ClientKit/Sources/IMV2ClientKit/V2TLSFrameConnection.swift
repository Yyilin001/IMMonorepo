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

/// A single application-owned consumer waits for best-effort live hints. A
/// hint is never state: callers must follow it with normal pull/ACK sync.
public protocol V2SyncAvailabilityHintSource: Sendable {
    func nextAvailabilityHint() async throws -> V2SyncAvailabilityHint
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
public actor V2TLSFrameConnection: V2AuthenticatedFrameTransport, V2SyncAvailabilityHintSource, V2RealtimeConnection {
    private let endpoint: V2RealtimeEndpoint
    private let limits: V2FrameLimits
    private let maximumProtobufMessageDepth: Int
    private var decoder: V2FrameDecoder
    private var bufferedFrames: [V2Frame] = []
    private var connection: NWConnection?
    private var authenticatedVersion: UInt8?
    private var responseWaiters: [UInt64: CheckedContinuation<V2Frame, Error>] = [:]
    private var availabilityWaiter: CheckedContinuation<V2SyncAvailabilityHint, Error>?
    private var pendingAvailabilityHint: V2SyncAvailabilityHint?
    private var readerTask: Task<Void, Never>?

    public init(
        endpoint: V2RealtimeEndpoint,
        frameLimits: V2FrameLimits,
        maximumProtobufMessageDepth: Int = V2ProtobufFrameCodec.defaultMaximumMessageDepth
    ) {
        precondition(maximumProtobufMessageDepth > 0)
        self.endpoint = endpoint
        self.limits = frameLimits
        self.maximumProtobufMessageDepth = maximumProtobufMessageDepth
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

    private func sendBootstrap(_ envelope: IMV2Envelope, version: UInt8) async throws -> IMV2Envelope {
        let response = try await exchangeBootstrap(try V2ProtobufFrameCodec.encode(envelope, frameVersion: version))
        let decoded = try V2ProtobufFrameCodec.decode(response, maximumMessageDepth: maximumProtobufMessageDepth)
        guard decoded.requestID == envelope.requestID else { throw V2TLSFrameConnectionError.unexpectedResponse }
        if case .error = decoded.body { throw V2TLSFrameConnectionError.authenticationFailed }
        return decoded
    }

    private func exchangeBootstrap(_ frame: V2Frame) async throws -> V2Frame {
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
        guard let connection else { throw V2TLSFrameConnectionError.notConnected }
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
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
            guard case .syncAvailable(let hint)? = envelope.body else { throw V2TLSFrameConnectionError.unexpectedResponse }
            let value = V2SyncAvailabilityHint(eventID: hint.eventID, highWatermark: hint.highWatermark)
            if let availabilityWaiter {
                self.availabilityWaiter = nil
                availabilityWaiter.resume(returning: value)
            } else if pendingAvailabilityHint == nil || value.highWatermark >= pendingAvailabilityHint!.highWatermark {
                pendingAvailabilityHint = value
            }
            return
        }
        guard let waiter = responseWaiters.removeValue(forKey: frame.requestID) else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        waiter.resume(returning: frame)
    }

    private func failRequest(_ requestID: UInt64) {
        responseWaiters.removeValue(forKey: requestID)?.resume(throwing: V2TLSFrameConnectionError.connectionFailed)
    }

    private func cancelRequest(_ requestID: UInt64) {
        responseWaiters.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
    }

    private func cancelAvailabilityWait() {
        availabilityWaiter?.resume(throwing: CancellationError())
        availabilityWaiter = nil
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
public actor V2TLSFrameConnection: V2AuthenticatedFrameTransport, V2SyncAvailabilityHintSource, V2RealtimeConnection {
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

    public func disconnect() {}
}
#endif
