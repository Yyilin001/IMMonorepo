import Foundation

public enum V2RealtimeSessionCoordinatorError: Error, Equatable, Sendable {
    /// The gateway conclusively rejected the current device credential. The
    /// coordinator has removed it from `V2AuthSession`; present re-auth UI.
    case authenticationRequired
    /// A TLS peer authenticated a different account/device than the coherent
    /// tuple supplied by the local credential owner. This is never accepted.
    case identityMismatch
}

/// App-facing owner of the transition from device credentials to an
/// authenticated realtime connection. It serializes concurrent connect calls,
/// refreshes expired access credentials through `V2AuthSession`, and never
/// exposes the access token outside the transport boundary.
public actor V2RealtimeSessionCoordinator: V2RealtimeSessionConnecting {
    private let authSession: V2AuthSession
    private let connection: any V2RealtimeConnection
    private let supportedCapabilityProfiles: Set<String>
    private var activeAttempt: ConnectionAttempt?

    public init(
        authSession: V2AuthSession,
        connection: any V2RealtimeConnection,
        supportedCapabilityProfiles: Set<String>
    ) {
        precondition(!supportedCapabilityProfiles.isEmpty)
        self.authSession = authSession
        self.connection = connection
        self.supportedCapabilityProfiles = supportedCapabilityProfiles
    }

    /// All concurrent callers await one handshake. A caller cancellation does
    /// not cancel the shared attempt; explicit `disconnect()` owns shutdown.
    public func connect() async throws -> V2AuthenticatedClientSession {
        let attempt: ConnectionAttempt
        if let activeAttempt {
            attempt = activeAttempt
        } else {
            let id = UUID()
            let task = Task { [authSession, connection, supportedCapabilityProfiles] in
                let credentials = try await authSession.realtimeCredentials()
                do {
                    let established = try await connection.connectAndAuthenticate(
                        accessToken: credentials.accessToken,
                        deviceID: credentials.deviceID,
                        supportedCapabilityProfiles: supportedCapabilityProfiles
                    )
                    guard established.userID == credentials.userID,
                          established.deviceID == credentials.deviceID
                    else {
                        await connection.disconnect()
                        throw V2RealtimeSessionCoordinatorError.identityMismatch
                    }
                    return established
                } catch let error as V2TLSFrameConnectionError where error == .authenticationFailed {
                    try await authSession.handleTerminalRejection()
                    throw V2RealtimeSessionCoordinatorError.authenticationRequired
                }
            }
            attempt = .init(id: id, task: task)
            activeAttempt = attempt
        }

        let result = await attempt.task.result
        if activeAttempt?.id == attempt.id {
            activeAttempt = nil
        }
        return try result.get()
    }

    /// Explicit app lifecycle shutdown. It invalidates a pending shared
    /// attempt and asks the concrete transport to close its socket/read loop.
    public func disconnect() async {
        activeAttempt?.task.cancel()
        activeAttempt = nil
        await connection.disconnect()
    }
}

private struct ConnectionAttempt {
    let id: UUID
    let task: Task<V2AuthenticatedClientSession, Error>
}
