import Foundation

public struct V2ConnectionLimits: Equatable, Sendable {
    public let maximumInFlightRequests: Int
    public init(maximumInFlightRequests: Int) throws {
        guard maximumInFlightRequests > 0 else { throw V2ConnectionStateError.invalidLimits }
        self.maximumInFlightRequests = maximumInFlightRequests
    }
}

public struct V2AuthenticatedConnection: Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    /// Negotiated before authentication; domain handlers use this value to
    /// ensure every sync representation is one the device declared it can
    /// interpret.
    public let capabilityProfile: String
    public init(userID: UserID, deviceID: DeviceID, capabilityProfile: String) {
        self.userID = userID
        self.deviceID = deviceID
        self.capabilityProfile = capabilityProfile
    }
}

public enum V2ConnectionPhase: Equatable, Sendable {
    case tlsConnected
    case versionNegotiated(UInt8)
    case awaitingAuthentication(UInt8, requestID: UInt64)
    case authenticated(UInt8, V2AuthenticatedConnection)
    case closing
    case closed
}

public enum V2ConnectionStateError: Error, Equatable, Sendable {
    case invalidLimits, unexpectedCommand, bootstrapVersionMustBeZero, unsupportedVersion
    case requestIDMustBeNonZero, duplicateRequestID, tooManyInFlightRequests, responseWasNotInFlight
}

/// Transport-independent lifecycle and request-ID fence for one TLS connection.
public struct V2ConnectionStateMachine: Sendable {
    public private(set) var phase: V2ConnectionPhase = .tlsConnected
    public private(set) var inFlightRequestIDs: Set<UInt64> = []
    private let limits: V2ConnectionLimits

    public init(limits: V2ConnectionLimits) { self.limits = limits }

    public mutating func receiveClientHello(_ frame: V2Frame, clientSupportedVersions: Set<UInt8>, serverSupportedVersions: Set<UInt8>) throws -> UInt8 {
        guard phase == .tlsConnected else { throw V2ConnectionStateError.unexpectedCommand }
        guard frame.command == .clientHello, frame.version == 0 else { throw V2ConnectionStateError.bootstrapVersionMustBeZero }
        guard frame.requestID != 0 else { throw V2ConnectionStateError.requestIDMustBeNonZero }
        guard let selected = clientSupportedVersions.intersection(serverSupportedVersions).max() else { throw V2ConnectionStateError.unsupportedVersion }
        phase = .versionNegotiated(selected)
        return selected
    }

    public mutating func receiveAuthenticate(_ frame: V2Frame) throws {
        guard case .versionNegotiated(let version) = phase, frame.command == .authenticate, frame.version == version else { throw V2ConnectionStateError.unexpectedCommand }
        try reserve(frame.requestID)
        phase = .awaitingAuthentication(version, requestID: frame.requestID)
    }

    public mutating func completeAuthentication(_ identity: V2AuthenticatedConnection) throws {
        guard case .awaitingAuthentication(let version, let requestID) = phase else { throw V2ConnectionStateError.unexpectedCommand }
        inFlightRequestIDs.remove(requestID)
        phase = .authenticated(version, identity)
    }

    public mutating func receiveAuthenticatedRequest(_ frame: V2Frame) throws {
        guard case .authenticated(let version, _) = phase, frame.version == version,
              frame.command != .clientHello, frame.command != .authenticate else { throw V2ConnectionStateError.unexpectedCommand }
        try reserve(frame.requestID)
    }

    public mutating func completeResponse(requestID: UInt64) throws {
        guard inFlightRequestIDs.remove(requestID) != nil else { throw V2ConnectionStateError.responseWasNotInFlight }
    }

    public mutating func revokeDevice() { inFlightRequestIDs.removeAll(); phase = .closing }
    public mutating func close() { inFlightRequestIDs.removeAll(); phase = .closed }

    private mutating func reserve(_ requestID: UInt64) throws {
        guard requestID != 0 else { throw V2ConnectionStateError.requestIDMustBeNonZero }
        guard !inFlightRequestIDs.contains(requestID) else { throw V2ConnectionStateError.duplicateRequestID }
        guard inFlightRequestIDs.count < limits.maximumInFlightRequests else { throw V2ConnectionStateError.tooManyInFlightRequests }
        inFlightRequestIDs.insert(requestID)
    }
}
