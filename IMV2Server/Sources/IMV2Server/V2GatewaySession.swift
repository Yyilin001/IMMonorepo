import Foundation
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
    func authenticate(accessToken: String, deviceID: DeviceID) async throws -> UserID
    /// Production authenticators return the verified access-token expiry. A
    /// nil value is reserved for non-expiring test/auth adapters.
    func authenticatedSessionExpiresAt(accessToken: String, deviceID: DeviceID) async throws -> Date?
    /// Production implementations override this combined read so identity and
    /// expiry come from one revocation-consistent database snapshot.
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication
}

public extension V2GatewayAuthenticator {
    func authenticatedSessionExpiresAt(accessToken _: String, deviceID _: DeviceID) async throws -> Date? { nil }
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        .init(
            userID: try await authenticate(accessToken: accessToken, deviceID: deviceID),
            expiresAt: try await authenticatedSessionExpiresAt(accessToken: accessToken, deviceID: deviceID)
        )
    }
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
}

/// Owns one verified V2 connection. The socket layer supplies/consumes frames;
/// this actor applies lifecycle fencing before any domain service is reached.
public actor V2GatewaySession {
    private var state: V2ConnectionStateMachine
    private let authenticator: any V2GatewayAuthenticator
    private let supportedVersions: Set<UInt8>
    private let capabilityProfile: String
    private let maximumProtobufMessageDepth: Int
    private let commandAdmission: (any V2AuthenticatedGatewayCommandAdmitting)?
    private let now: @Sendable () -> Date
    private var authenticatedSessionExpiresAt: Date?

    public init(
        limits: V2ConnectionLimits,
        authenticator: any V2GatewayAuthenticator,
        supportedVersions: Set<UInt8> = [UInt8(IMV2ProtocolVersion.current)],
        capabilityProfile: String,
        maximumProtobufMessageDepth: Int = V2ServerProtobufFrameCodec.defaultMaximumMessageDepth,
        commandAdmission: (any V2AuthenticatedGatewayCommandAdmitting)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.state = .init(limits: limits)
        self.authenticator = authenticator
        self.supportedVersions = supportedVersions
        self.capabilityProfile = capabilityProfile
        precondition(maximumProtobufMessageDepth > 0)
        self.maximumProtobufMessageDepth = maximumProtobufMessageDepth
        self.commandAdmission = commandAdmission
        self.now = now
    }

    /// Handles only bootstrap/authentication frames. Domain command routing is
    /// deliberately unavailable until this returns an authenticated session.
    public func receiveBootstrap(_ frame: V2Frame) async throws -> V2Frame {
        let envelope = try V2ServerProtobufFrameCodec.decode(frame, maximumMessageDepth: maximumProtobufMessageDepth)
        switch envelope.body {
        case .clientHello(let hello):
            let versions = Set(hello.supportedProtocolVersions.compactMap { UInt8(exactly: $0) })
            guard !versions.isEmpty else { throw V2GatewaySessionError.invalidClientHello }
            let profiles = Set(hello.supportedCapabilityProfiles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            guard profiles.contains(capabilityProfile) else { throw V2GatewaySessionError.unsupportedCapabilityProfile }
            let selected = try state.receiveClientHello(frame, clientSupportedVersions: versions, serverSupportedVersions: supportedVersions)
            var response = IMV2Envelope()
            response.requestID = envelope.requestID
            response.protocolVersion = UInt32(selected)
            response.serverHello = .init()
            response.serverHello.selectedProtocolVersion = UInt32(selected)
            response.serverHello.selectedCapabilityProfile = capabilityProfile
            response.serverHello.serverTimeMs = Int64(now().timeIntervalSince1970 * 1_000)
            return try V2ServerProtobufFrameCodec.encode(response, frameVersion: selected)

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
            return try V2ServerProtobufFrameCodec.encode(response, frameVersion: version)

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

    public func receiveAuthenticated(_ frame: V2Frame, handler: any V2GatewayCommandHandler) async throws -> V2Frame {
        let envelope = try V2ServerProtobufFrameCodec.decode(frame, maximumMessageDepth: maximumProtobufMessageDepth)
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
            if let commandAdmission,
               !(await commandAdmission.admit(identity: identity, now: now())) {
                response = IMV2Envelope()
                response.error = .init()
                response.error.code = "RATE_LIMITED"
                response.error.retryable = true
                response.error.retryAfterSeconds = 1
            } else if case .heartbeat = envelope.body {
                response = IMV2Envelope()
                response.heartbeatAck = .init()
                response.heartbeatAck.serverTimeMs = Int64(now().timeIntervalSince1970 * 1_000)
            } else {
                response = try await handler.handle(envelope: envelope, identity: identity)
            }
            response.requestID = envelope.requestID
            response.protocolVersion = UInt32(version)
            let encoded = try V2ServerProtobufFrameCodec.encode(response, frameVersion: version)
            try state.completeResponse(requestID: envelope.requestID)
            return encoded
        } catch {
            // The handler has not produced a response, so release the request
            // correlation before the connection decides whether to retry/close.
            try? state.completeResponse(requestID: envelope.requestID)
            throw error
        }
    }

    public func revokeDevice() { state.revokeDevice(); authenticatedSessionExpiresAt = nil }
    public func close() { state.close(); authenticatedSessionExpiresAt = nil }
}
