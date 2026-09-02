import Foundation
import IMV2Compression
import IMV2Core

/// Authentication is an injected server boundary; the gateway never decodes a
/// user ID from an unauthenticated protobuf payload.
public struct V2GatewayAuthentication: Equatable, Sendable {
    public let userID: UserID
    public let expiresAt: Date?

    public init(userID: UserID, expiresAt: Date?) {
        self.userID = userID
        self.expiresAt = expiresAt
    }
}

public protocol V2GatewayAuthenticator: Sendable {
    /// Identity and expiry must come from one revocation-consistent read.
    /// A nil expiry is reserved for deliberately non-expiring adapters.
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication
}

public enum V2GatewaySessionError: Error, Equatable, Sendable {
    case invalidClientHello
    case invalidAuthenticatePayload
    case unsupportedCapabilityProfile
    case unsupportedCommand
    case sessionExpired
    case authenticatedConnectionLimit
}

/// Domain router boundary. It receives only a previously authenticated identity
/// and a validated protobuf envelope; it never sees TLS bytes or credentials.
public protocol V2GatewayCommandHandler: Sendable {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope
    /// Production transports supply their process-local connection identity
    /// so post-commit accelerators can suppress an echo to the exact request
    /// origin without suppressing the sender's other devices. Domain
    /// correctness must never depend on this optional transport hint.
    func handle(
        envelope: IMV2Envelope,
        identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?
    ) async throws -> IMV2Envelope
}

extension V2GatewayCommandHandler {
    public func handle(
        envelope: IMV2Envelope,
        identity: V2AuthenticatedConnection,
        originatingConnectionID _: UUID?
    ) async throws -> IMV2Envelope {
        try await handle(envelope: envelope, identity: identity)
    }
}

struct V2PreparedGroupEventCommandContext: Sendable {
    let requestID: UInt64
    let frameVersion: UInt8
    let compression: V2NegotiatedFrameCompression?
    let maximumUncompressedPayloadBytes: Int
    let compressionThresholdBytes: Int
    let maximumExpansionRatio: Int
    let cache: V2PreparedGroupEventPageCache
}

struct V2AuthenticatedGatewayFrameContract: Sendable {
    let protocolVersion: UInt8
    let compression: V2NegotiatedFrameCompression?
}

enum V2PreparedGroupEventGatewayResponse: Sendable {
    case envelope(IMV2Envelope)
    case prepared(V2PreparedGroupEventPageResponse)
}

protocol V2PreparedGroupEventCommandHandling: Sendable {
    func handlePreparedGroupEventPull(
        _ request: IMV2GroupEventPull,
        identity: V2AuthenticatedConnection,
        originatingConnectionID: UUID?,
        context: V2PreparedGroupEventCommandContext
    ) async throws -> V2PreparedGroupEventGatewayResponse
}

/// One fully validated request/response exchange. The session owns protobuf
/// decoding so transport-side lifecycle bookkeeping can inspect the same
/// envelope without parsing untrusted bytes a second time.
struct V2GatewaySessionExchange: Sendable {
    let request: IMV2Envelope
    let responseEnvelope: IMV2Envelope
    let response: V2Frame
}

private struct V2GatewaySessionResponse: Sendable {
    let envelope: IMV2Envelope
    let frame: V2Frame
}

/// Owns one verified V2 connection. The socket layer supplies/consumes frames;
/// this actor applies lifecycle fencing before any domain service is reached.
public actor V2GatewaySession {
    private var state: V2ConnectionStateMachine
    private let authenticator: any V2GatewayAuthenticator
    private let supportedVersions: Set<UInt8>
    private let capabilityProfile: String
    private let maximumProtobufMessageDepth: Int
    private let supportedFrameCompression: V2NegotiatedFrameCompression?
    private let maximumUncompressedPayloadBytes: Int
    private let compressionThresholdBytes: Int
    private let maximumCompressionExpansionRatio: Int
    private let preparedGroupEventPageCache: V2PreparedGroupEventPageCache?
    private let commandAdmission: any V2AuthenticatedGatewayCommandAdmitting
    private let now: @Sendable () -> Date
    private var authenticatedSessionExpiresAt: Date?
    private var negotiatedFrameCompression: V2NegotiatedFrameCompression?

    public init(
        limits: V2ConnectionLimits,
        authenticator: any V2GatewayAuthenticator,
        supportedVersions: Set<UInt8> = [UInt8(IMV2ProtocolVersion.current)],
        capabilityProfile: String,
        maximumProtobufMessageDepth: Int = V2ServerProtobufFrameCodec.defaultMaximumMessageDepth,
        supportedFrameCompression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = V2ServerProtobufFrameCodec.defaultMaximumUncompressedPayloadBytes,
        compressionThresholdBytes: Int = V2ServerProtobufFrameCodec.defaultCompressionThresholdBytes,
        maximumCompressionExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCache? = nil,
        commandAdmission: any V2AuthenticatedGatewayCommandAdmitting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.state = .init(limits: limits)
        self.authenticator = authenticator
        self.supportedVersions = supportedVersions
        self.capabilityProfile = capabilityProfile
        precondition(maximumProtobufMessageDepth > 0)
        precondition(maximumUncompressedPayloadBytes > 0)
        precondition(compressionThresholdBytes >= 0)
        precondition(maximumCompressionExpansionRatio > 0)
        self.maximumProtobufMessageDepth = maximumProtobufMessageDepth
        self.supportedFrameCompression = supportedFrameCompression
        self.maximumUncompressedPayloadBytes = maximumUncompressedPayloadBytes
        self.compressionThresholdBytes = compressionThresholdBytes
        self.maximumCompressionExpansionRatio = maximumCompressionExpansionRatio
        self.preparedGroupEventPageCache = preparedGroupEventPageCache
        self.commandAdmission = commandAdmission
        self.now = now
    }

    /// Production entry point. It decodes and validates the protobuf envelope
    /// exactly once, then dispatches according to the actor-isolated session
    /// phase. Returning the validated request lets the byte stream update its
    /// process-local subscriptions without becoming a second codec boundary.
    func receive(
        _ frame: V2Frame,
        handler: any V2GatewayCommandHandler,
        originatingConnectionID: UUID? = nil
    ) async throws -> V2GatewaySessionExchange {
        let envelope = try decode(frame)
        let response: V2GatewaySessionResponse
        switch state.phase {
        case .authenticated:
            response = try await receiveAuthenticated(
                frame,
                envelope: envelope,
                handler: handler,
                originatingConnectionID: originatingConnectionID
            )
        default:
            response = try await receiveBootstrap(frame, envelope: envelope)
        }
        return .init(
            request: envelope,
            responseEnvelope: response.envelope,
            response: response.frame
        )
    }

    /// Handles only bootstrap/authentication frames. Domain command routing is
    /// deliberately unavailable until this returns an authenticated session.
    public func receiveBootstrap(_ frame: V2Frame) async throws -> V2Frame {
        try await receiveBootstrap(frame, envelope: decode(frame)).frame
    }

    private func receiveBootstrap(
        _ frame: V2Frame,
        envelope: IMV2Envelope
    ) async throws -> V2GatewaySessionResponse {
        switch envelope.body {
        case .clientHello(let hello):
            let versions = Set(hello.supportedProtocolVersions.compactMap { UInt8(exactly: $0) })
            guard !versions.isEmpty else { throw V2GatewaySessionError.invalidClientHello }
            let profiles = Set(hello.supportedCapabilityProfiles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard profiles.contains(capabilityProfile) else { throw V2GatewaySessionError.unsupportedCapabilityProfile }
            let selected = try state.receiveClientHello(frame, clientSupportedVersions: versions, serverSupportedVersions: supportedVersions)
            if supportedFrameCompression == .zlib,
               hello.supportedFrameCompressions.contains(.zlib) {
                negotiatedFrameCompression = .zlib
            } else {
                negotiatedFrameCompression = nil
            }
            var response = IMV2Envelope()
            response.requestID = envelope.requestID
            response.protocolVersion = UInt32(selected)
            response.serverHello = .init()
            response.serverHello.selectedProtocolVersion = UInt32(selected)
            response.serverHello.selectedCapabilityProfile = capabilityProfile
            response.serverHello.serverTimeMs = Int64(now().timeIntervalSince1970 * 1_000)
            response.serverHello.selectedFrameCompression = negotiatedFrameCompression == .zlib ? .zlib : .unspecified
            return try .init(
                envelope: response,
                frame: V2ServerProtobufFrameCodec.encode(response, frameVersion: selected)
            )

        case .authenticate(let request):
            try state.receiveAuthenticate(frame)
            guard !request.accessToken.isEmpty else { throw V2GatewaySessionError.invalidAuthenticatePayload }
            let deviceID = try DeviceID(request.deviceID)
            let authentication = try await authenticator.authenticateSession(
                accessToken: request.accessToken,
                deviceID: deviceID
            )
            let userID = authentication.userID
            let expiresAt = authentication.expiresAt
            guard expiresAt.map({ $0 > now() }) ?? true else { throw V2GatewaySessionError.sessionExpired }
            try state.completeAuthentication(.init(userID: userID, deviceID: deviceID, capabilityProfile: capabilityProfile))
            authenticatedSessionExpiresAt = expiresAt
            guard case .authenticated(let version, _) = state.phase else { throw V2GatewaySessionError.unsupportedCommand }
            var response = IMV2Envelope()
            response.requestID = envelope.requestID
            response.protocolVersion = UInt32(version)
            response.authenticated = .init()
            response.authenticated.userID = userID.rawValue
            response.authenticated.deviceID = deviceID.rawValue
            response.authenticated.selectedCapabilityProfile = capabilityProfile
            response.authenticated.selectedFrameCompression = negotiatedFrameCompression == .zlib ? .zlib : .unspecified
            return try .init(
                envelope: response,
                frame: V2ServerProtobufFrameCodec.encode(response, frameVersion: version)
            )

        default:
            throw V2GatewaySessionError.unsupportedCommand
        }
    }

    public func authenticatedIdentity() -> V2AuthenticatedConnection? {
        guard case .authenticated(_, let identity) = state.phase else { return nil }
        return identity
    }

    public func authenticatedProtocolVersion() -> UInt8? {
        guard case .authenticated(let version, _) = state.phase else { return nil }
        return version
    }

    func authenticatedFrameContract() -> V2AuthenticatedGatewayFrameContract? {
        guard case .authenticated(let version, _) = state.phase else { return nil }
        return .init(
            protocolVersion: version,
            compression: negotiatedFrameCompression
        )
    }

    public func receiveAuthenticated(_ frame: V2Frame, handler: any V2GatewayCommandHandler) async throws -> V2Frame {
        try await receiveAuthenticated(
            frame,
            envelope: decode(frame),
            handler: handler,
            originatingConnectionID: nil
        ).frame
    }

    private func receiveAuthenticated(
        _ frame: V2Frame,
        envelope: IMV2Envelope,
        handler: any V2GatewayCommandHandler,
        originatingConnectionID: UUID?
    ) async throws -> V2GatewaySessionResponse {
        guard case .authenticated(let version, let identity) = state.phase else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        guard authenticatedSessionExpiresAt.map({ $0 > now() }) ?? true else {
            state.close()
            throw V2GatewaySessionError.sessionExpired
        }
        try state.receiveAuthenticatedRequest(frame)
        do {
            var response: IMV2Envelope
            var preparedFrame: V2Frame?
            if !(await commandAdmission.admit(identity: identity, now: now())) {
                response = IMV2Envelope()
                response.error = .init()
                response.error.code = "RATE_LIMITED"
                response.error.retryable = true
                response.error.retryAfterSeconds = 1
            } else if case .heartbeat = envelope.body {
                response = IMV2Envelope()
                response.heartbeatAck = .init()
                response.heartbeatAck.serverTimeMs = Int64(now().timeIntervalSince1970 * 1_000)
            } else if case .groupEventPull(let request) = envelope.body,
                      version >= 21,
                      let preparedGroupEventPageCache,
                      let preparedHandler = handler as? any V2PreparedGroupEventCommandHandling {
                switch try await preparedHandler.handlePreparedGroupEventPull(
                    request,
                    identity: identity,
                    originatingConnectionID: originatingConnectionID,
                    context: .init(
                        requestID: envelope.requestID,
                        frameVersion: version,
                        compression: negotiatedFrameCompression,
                        maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                        compressionThresholdBytes: compressionThresholdBytes,
                        maximumExpansionRatio: maximumCompressionExpansionRatio,
                        cache: preparedGroupEventPageCache
                    )
                ) {
                case .envelope(let ordinary):
                    response = ordinary
                case .prepared(let prepared):
                    guard prepared.frame.version == version,
                          prepared.frame.requestID == envelope.requestID,
                          prepared.frame.command == .groupEventPage
                    else { throw V2GatewaySessionError.unsupportedCommand }
                    preparedFrame = prepared.frame
                    // Lifecycle bookkeeping never inspects a pull response.
                    // Retain only its public cursor summary here; the actual
                    // client frame contains the complete shared event page.
                    response = IMV2Envelope()
                    response.groupEventPage = .init()
                    response.groupEventPage.roomID = prepared.roomID.rawValue
                    response.groupEventPage.nextRoomSequence = prepared.nextRoomSequence
                    response.groupEventPage.hasMore_p = prepared.hasMore
                }
            } else {
                response = try await handler.handle(
                    envelope: envelope,
                    identity: identity,
                    originatingConnectionID: originatingConnectionID
                )
            }
            response.requestID = envelope.requestID
            response.protocolVersion = UInt32(version)
            let responseCompression: V2NegotiatedFrameCompression? = if case .groupEventPage? = response.body {
                negotiatedFrameCompression
            } else {
                nil
            }
            let encoded = try preparedFrame ?? preparedGroupEventPageCache?.frame(
                for: response,
                frameVersion: version,
                compression: responseCompression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumCompressionExpansionRatio
            ) ?? V2ServerProtobufFrameCodec.encode(
                response,
                frameVersion: version,
                compression: responseCompression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumCompressionExpansionRatio
            )
            try state.completeResponse(requestID: envelope.requestID)
            return .init(envelope: response, frame: encoded)
        } catch {
            // The handler has not produced a response, so release the request
            // correlation before the connection decides whether to retry/close.
            try? state.completeResponse(requestID: envelope.requestID)
            throw error
        }
    }

    private func decode(_ frame: V2Frame) throws -> IMV2Envelope {
        try V2ServerProtobufFrameCodec.decode(
            frame,
            maximumMessageDepth: maximumProtobufMessageDepth,
            compression: negotiatedFrameCompression,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            maximumExpansionRatio: maximumCompressionExpansionRatio
        )
    }

    public func revokeDevice() { state.revokeDevice(); authenticatedSessionExpiresAt = nil }
    public func close() { state.close(); authenticatedSessionExpiresAt = nil }
}
