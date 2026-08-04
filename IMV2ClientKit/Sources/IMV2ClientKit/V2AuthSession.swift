import Foundation
import IMV2Core

/// Secret-bearing device credentials. Values must never be logged, attached to
/// analytics, or included in user-facing errors.
public struct V2AuthCredentials: Codable, Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshCredential: String

    public init(
        userID: UserID,
        deviceID: DeviceID,
        accessToken: String,
        accessTokenExpiresAt: Date,
        refreshCredential: String
    ) throws {
        guard !accessToken.isEmpty, !refreshCredential.isEmpty,
              accessTokenExpiresAt.timeIntervalSinceReferenceDate.isFinite
        else { throw V2AuthSessionError.malformedCredentials }
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshCredential = refreshCredential
    }
}

/// The whole record is written in one Keychain item so a pending refresh ID
/// never gets separated from the credential it is rotating.
public struct V2AuthCredentialRecord: Codable, Equatable, Sendable {
    public let credentials: V2AuthCredentials
    public let pendingRefreshOperationID: UUID?

    public init(credentials: V2AuthCredentials, pendingRefreshOperationID: UUID? = nil) {
        self.credentials = credentials
        self.pendingRefreshOperationID = pendingRefreshOperationID
    }

    func withPendingRefreshOperation(_ operationID: UUID) -> V2AuthCredentialRecord {
        .init(credentials: credentials, pendingRefreshOperationID: operationID)
    }

    func clearingPendingRefreshOperation(with credentials: V2AuthCredentials) -> V2AuthCredentialRecord {
        .init(credentials: credentials, pendingRefreshOperationID: nil)
    }
}

public enum V2CredentialStoreError: Error, Equatable, Sendable {
    /// For example protected data/keychain service is temporarily unavailable.
    case unavailable
    case malformedRecord
    case permanentlyInvalidated
    case unexpectedStatus(Int32)
}

public protocol V2CredentialStore: Sendable {
    func load() async throws -> V2AuthCredentialRecord?
    func save(_ record: V2AuthCredentialRecord) async throws
    func delete() async throws
}

public struct V2RefreshRequest: Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let refreshCredential: String
    public let operationID: UUID

    public init(userID: UserID, deviceID: DeviceID, refreshCredential: String, operationID: UUID) {
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
        self.operationID = operationID
    }
}

/// One coherent credential view for the realtime TLS handshake. It is
/// intentionally ephemeral: the access token remains inside the connection
/// coordinator and is never a value for UI, persistence, or analytics.
public struct V2ClientRealtimeCredentials: Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let accessToken: String

    public init(userID: UserID, deviceID: DeviceID, accessToken: String) {
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
    }
}

public enum V2AuthTransportError: Error, Equatable, Sendable {
    /// The server has conclusively rejected the credential; it is unsafe to retry.
    case terminalRejection
}

public protocol V2AuthTransport: Sendable {
    func refresh(_ request: V2RefreshRequest) async throws -> V2AuthCredentials
}

public enum V2AuthSessionState: Equatable, Sendable {
    case uninitialized
    case authenticated(accessTokenExpiresAt: Date)
    case refreshing
    case credentialsUnavailable
    case unauthenticated
}

public enum V2AuthSessionError: Error, Equatable, Sendable {
    case unauthenticated
    case credentialsUnavailable
    case malformedCredentials
    case deviceMismatch
    case sessionInvalidated
}

/// Sole owner of device-bound credentials and refresh rotation. The actor makes
/// local mutations serial; its unstructured refresh task remains alive if one
/// of multiple callers cancels its own wait.
public actor V2AuthSession: V2ClientMediaEdgeCredentialProvider, V2ClientPushEndpointCredentialProvider, V2ClientDeviceSessionCredentialProvider {
    private let credentialStore: any V2CredentialStore
    private let transport: any V2AuthTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    private var record: V2AuthCredentialRecord?
    private var state: V2AuthSessionState = .uninitialized
    private var didLoad = false
    private var sessionGeneration: UInt64 = 0
    private var refreshOperation: RefreshOperation?

    public init(
        credentialStore: any V2CredentialStore,
        transport: any V2AuthTransport,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
    }

    public func currentState() -> V2AuthSessionState { state }

    /// Installs the first credential record supplied by the separately trusted
    /// account/device-registration boundary. It is intentionally the only way
    /// to establish a session from an unauthenticated state: callers must not
    /// write `V2CredentialStore` directly and thereby split credential state
    /// from this actor's refresh fence.
    public func establish(_ credentials: V2AuthCredentials) async throws {
        sessionGeneration &+= 1
        refreshOperation?.task.cancel()
        refreshOperation = nil
        try await save(.init(credentials: credentials))
        state = .authenticated(accessTokenExpiresAt: credentials.accessTokenExpiresAt)
    }

    public func accessToken() async throws -> String {
        try await loadIfNeeded()
        guard let record else { throw V2AuthSessionError.unauthenticated }
        guard record.credentials.accessTokenExpiresAt > now() else {
            return try await refresh().accessToken
        }
        return record.credentials.accessToken
    }

    /// Obtains one coherent, device-bound credential pair for the separate
    /// media edge. Keeping these values together prevents a refresh from
    /// combining a new bearer token with a stale device identity.
    public func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials {
        try await loadIfNeeded()
        guard let record else { throw V2AuthSessionError.unauthenticated }
        let credentials: V2AuthCredentials
        if record.credentials.accessTokenExpiresAt > now() {
            credentials = record.credentials
        } else {
            credentials = try await refresh()
        }
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    /// Uses the same refresh-fenced credential view as the media edge, so a
    /// Push registration cannot combine a fresh bearer token with an old
    /// device identity after credential rotation.
    public func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials {
        let credentials = try await mediaEdgeCredentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    public func deviceSessionCredentials() async throws -> V2ClientDeviceSessionCredentials {
        let credentials = try await mediaEdgeCredentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    /// Obtains a matched account/device/token tuple for the TLS handshake. A
    /// caller cannot combine a token returned before a refresh with an
    /// identity read after it. The tuple is deliberately non-Codable and must
    /// stay in the connection boundary.
    public func realtimeCredentials() async throws -> V2ClientRealtimeCredentials {
        try await loadIfNeeded()
        guard let record else { throw V2AuthSessionError.unauthenticated }
        let credentials: V2AuthCredentials
        if record.credentials.accessTokenExpiresAt > now() {
            credentials = record.credentials
        } else {
            credentials = try await refresh()
        }
        return .init(
            userID: credentials.userID,
            deviceID: credentials.deviceID,
            accessToken: credentials.accessToken
        )
    }

    /// Reuses a persisted pending operation ID on cold start. Retryable
    /// transport errors deliberately retain it for the next refresh attempt.
    public func refresh() async throws -> V2AuthCredentials {
        try await loadIfNeeded()
        guard let currentRecord = record else { throw V2AuthSessionError.unauthenticated }
        let operation: RefreshOperation
        if let existing = refreshOperation {
            operation = existing
        } else {
            operation = startRefresh(from: currentRecord)
            refreshOperation = operation
        }
        return try await finish(operation, result: operation.task.result)
    }

    /// A terminal revocation from any authenticated command ends the session.
    public func handleTerminalRejection() async throws {
        try await clearForTerminalState()
    }

    /// Call when protected data becomes available again (for example after
    /// foregrounding). It does not clear any credential record.
    public func retryCredentialStoreAccess() {
        guard state == .credentialsUnavailable else { return }
        didLoad = false
        record = nil
        state = .uninitialized
    }

    private func loadIfNeeded() async throws {
        guard !didLoad else {
            if state == .credentialsUnavailable { throw V2AuthSessionError.credentialsUnavailable }
            return
        }
        do {
            record = try await credentialStore.load()
            didLoad = true
            state = record.map { .authenticated(accessTokenExpiresAt: $0.credentials.accessTokenExpiresAt) } ?? .unauthenticated
        } catch let error as V2CredentialStoreError {
            switch error {
            case .malformedRecord, .permanentlyInvalidated:
                do {
                    try await credentialStore.delete()
                    record = nil
                    didLoad = true
                    state = .unauthenticated
                    throw V2AuthSessionError.unauthenticated
                } catch let sessionError as V2AuthSessionError {
                    throw sessionError
                } catch {
                    state = .credentialsUnavailable
                    throw V2AuthSessionError.credentialsUnavailable
                }
            case .unavailable, .unexpectedStatus:
                state = .credentialsUnavailable
                throw V2AuthSessionError.credentialsUnavailable
            }
        }
    }

    private func save(_ next: V2AuthCredentialRecord) async throws {
        do {
            try await credentialStore.save(next)
            record = next
            didLoad = true
        } catch {
            state = .credentialsUnavailable
            throw V2AuthSessionError.credentialsUnavailable
        }
    }

    private func clearForTerminalState() async throws {
        sessionGeneration &+= 1
        refreshOperation?.task.cancel()
        refreshOperation = nil
        do {
            try await credentialStore.delete()
            record = nil
            didLoad = true
            state = .unauthenticated
        } catch {
            state = .credentialsUnavailable
            throw V2AuthSessionError.credentialsUnavailable
        }
    }

    private func startRefresh(from currentRecord: V2AuthCredentialRecord) -> RefreshOperation {
        let generation = sessionGeneration
        let operationID: UUID
        let recordToPersist: V2AuthCredentialRecord?
        let pendingRecord: V2AuthCredentialRecord
        if let pending = currentRecord.pendingRefreshOperationID {
            operationID = pending
            pendingRecord = currentRecord
            recordToPersist = nil
        } else {
            operationID = makeUUID()
            pendingRecord = currentRecord.withPendingRefreshOperation(operationID)
            recordToPersist = pendingRecord
        }
        // Make the in-memory state use the same operation ID before any await.
        // The actor-owned task writes it durably before contacting the server.
        record = pendingRecord
        let request = V2RefreshRequest(
            userID: pendingRecord.credentials.userID,
            deviceID: pendingRecord.credentials.deviceID,
            refreshCredential: pendingRecord.credentials.refreshCredential,
            operationID: operationID
        )
        state = .refreshing
        // This unstructured task must outlive an individual caller's
        // cancellation so all callers share exactly one credential rotation
        // for the device. It remains actor-owned so every external write is
        // fenced against logout or newly established credentials.
        return .init(
            operationID: operationID,
            sessionGeneration: generation,
            sourceRecord: pendingRecord,
            task: Task { [weak self] in
                guard let self else { throw V2AuthSessionError.sessionInvalidated }
                return try await self.performRefresh(
                    operationID: operationID,
                    sessionGeneration: generation,
                    pendingRecord: pendingRecord,
                    recordToPersist: recordToPersist,
                    request: request
                )
            }
        )
    }

    private func performRefresh(
        operationID: UUID,
        sessionGeneration: UInt64,
        pendingRecord: V2AuthCredentialRecord,
        recordToPersist: V2AuthCredentialRecord?,
        request: V2RefreshRequest
    ) async throws -> V2AuthCredentials {
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)
        if let recordToPersist {
            try await credentialStore.save(recordToPersist)
            try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)
        }

        let refreshed = try await transport.refresh(request)
        guard refreshed.userID == pendingRecord.credentials.userID,
              refreshed.deviceID == pendingRecord.credentials.deviceID
        else { throw V2AuthSessionError.deviceMismatch }
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)

        // A waiter receives success only after the entire successor record is
        // durable; this prevents a process kill from losing a completed refresh
        // rotation. The second fence prevents a stale response from recreating
        // credentials after terminal logout or a new authenticated session.
        try await credentialStore.save(pendingRecord.clearingPendingRefreshOperation(with: refreshed))
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)
        return refreshed
    }

    private func ensureRefreshIsCurrent(operationID: UUID, sessionGeneration: UInt64) throws {
        guard self.sessionGeneration == sessionGeneration,
              refreshOperation?.operationID == operationID
        else { throw V2AuthSessionError.sessionInvalidated }
    }

    private func finish(
        _ operation: RefreshOperation,
        result: Result<V2AuthCredentials, Error>
    ) async throws -> V2AuthCredentials {
        guard operation.sessionGeneration == sessionGeneration else {
            throw V2AuthSessionError.sessionInvalidated
        }
        guard let active = refreshOperation else {
            // Another waiter has already persisted this operation's result.
            guard let record, record.pendingRefreshOperationID == nil,
                  record.credentials.userID == operation.sourceRecord.credentials.userID,
                  record.credentials.deviceID == operation.sourceRecord.credentials.deviceID
            else { throw V2AuthSessionError.sessionInvalidated }
            return record.credentials
        }
        guard active.operationID == operation.operationID else {
            throw V2AuthSessionError.sessionInvalidated
        }

        switch result {
        case .success(let refreshed):
            refreshOperation = nil
            record = operation.sourceRecord.clearingPendingRefreshOperation(with: refreshed)
            didLoad = true
            state = .authenticated(accessTokenExpiresAt: refreshed.accessTokenExpiresAt)
            return refreshed
        case .failure(let error):
            refreshOperation = nil
            if error is V2CredentialStoreError {
                state = .credentialsUnavailable
                throw V2AuthSessionError.credentialsUnavailable
            }
            if let transportError = error as? V2AuthTransportError,
               transportError == .terminalRejection
            {
                try await clearForTerminalState()
                throw V2AuthSessionError.unauthenticated
            }
            // The pending record remains intact; neither a network failure nor
            // a malformed server response is permission to log the user out.
            if record != nil { state = .authenticated(accessTokenExpiresAt: operation.sourceRecord.credentials.accessTokenExpiresAt) }
            throw error
        }
    }
}

private struct RefreshOperation {
    let operationID: UUID
    let sessionGeneration: UInt64
    let sourceRecord: V2AuthCredentialRecord
    let task: Task<V2AuthCredentials, Error>
}
