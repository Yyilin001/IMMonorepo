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
    public let revocationCredential: V2DeviceRevocationCredential
    public let revocationCredentialExpiresAt: Date

    public init(
        userID: UserID,
        deviceID: DeviceID,
        accessToken: String,
        accessTokenExpiresAt: Date,
        refreshCredential: String,
        revocationCredential: V2DeviceRevocationCredential,
        revocationCredentialExpiresAt: Date
    ) throws {
        guard !accessToken.isEmpty, !refreshCredential.isEmpty,
              accessTokenExpiresAt.timeIntervalSinceReferenceDate.isFinite,
              revocationCredentialExpiresAt.timeIntervalSinceReferenceDate.isFinite
        else { throw V2AuthSessionError.malformedCredentials }
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
        self.revocationCredentialExpiresAt = revocationCredentialExpiresAt
    }
}

/// The whole record is written in one Keychain item so a pending refresh ID
/// never gets separated from the credential it is rotating.
public struct V2AuthCredentialRecord: Codable, Equatable, Sendable {
    public let credentials: V2AuthCredentials
    public let pendingRefreshOperationID: UUID?
    /// Persisted before the independent revocation outbox is written. A cold
    /// start must finish this handoff instead of restoring login authority.
    public let pendingRevocationOperationID: UUID?

    public init(credentials: V2AuthCredentials, pendingRefreshOperationID: UUID? = nil,
                pendingRevocationOperationID: UUID? = nil) {
        self.credentials = credentials
        self.pendingRefreshOperationID = pendingRefreshOperationID
        self.pendingRevocationOperationID = pendingRevocationOperationID
    }

    func withPendingRefreshOperation(_ operationID: UUID) -> V2AuthCredentialRecord {
        .init(credentials: credentials, pendingRefreshOperationID: operationID,
              pendingRevocationOperationID: pendingRevocationOperationID)
    }

    func clearingPendingRefreshOperation(with credentials: V2AuthCredentials) -> V2AuthCredentialRecord {
        .init(credentials: credentials, pendingRevocationOperationID: pendingRevocationOperationID)
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
    public let revocationCredential: V2DeviceRevocationCredential
    public let operationID: UUID

    public init(userID: UserID, deviceID: DeviceID, refreshCredential: String, revocationCredential: V2DeviceRevocationCredential, operationID: UUID) {
        self.userID = userID
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
        self.revocationCredential = revocationCredential
        self.operationID = operationID
    }
}

/// An opaque process-local ownership fence, separate from the server's
/// durable device/session epoch. It contains no credential material.
public struct V2AuthSessionEpoch: Hashable, Sendable {
    fileprivate let owner: UUID
    fileprivate let generation: UInt64
}

/// One coherent credential view for the realtime TLS handshake. It is
/// intentionally ephemeral: the access token remains inside the connection
/// coordinator and is never a value for UI, persistence, or analytics.
public struct V2ClientRealtimeCredentials: Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let accessToken: String
    public let sessionEpoch: V2AuthSessionEpoch?

    public init(userID: UserID, deviceID: DeviceID, accessToken: String, sessionEpoch: V2AuthSessionEpoch? = nil) {
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.sessionEpoch = sessionEpoch
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
    case establishing
    case authenticated(accessTokenExpiresAt: Date)
    case refreshing
    case credentialsUnavailable
    case unauthenticated
}

/// Complete state for one observed account epoch. Once that epoch ends,
/// later account states cannot overwrite its final value in a bounded stream.
public struct V2AuthSessionSnapshot: Equatable, Sendable {
    public enum EndReason: Equatable, Sendable {
        case authenticationRequired, credentialDeletionPending, superseded
    }
    public enum Status: Equatable, Sendable {
        case active(V2AuthSessionState), ending, ended(EndReason)
    }
    public let epoch: V2AuthSessionEpoch
    public let status: Status
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
    private let revocationScheduler: any V2DeviceRevocationScheduling
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    private var record: V2AuthCredentialRecord?
    private var state: V2AuthSessionState = .uninitialized {
        didSet { publishCurrentState() }
    }
    private var didLoad = false
    private let epochOwner = UUID()
    private var sessionGeneration: UInt64 = 0
    private var credentialIOTail: (id: UUID, task: Task<Void, Never>)?
    private var pendingTerminalDeletion = false
    private var loadOperation: (id: UUID, generation: UInt64, task: V2SharedOperation<Void>)?
    private var refreshOperation: RefreshOperation?
    private struct Observer {
        let epoch: V2AuthSessionEpoch
        let continuation: AsyncStream<V2AuthSessionSnapshot>.Continuation
    }
    private var observers: [UUID: Observer] = [:]
    private var terminalSourceEpoch: V2AuthSessionEpoch?
    private var lastEnded: (epoch: V2AuthSessionEpoch, reason: V2AuthSessionSnapshot.EndReason)?

    public init(
        credentialStore: any V2CredentialStore,
        transport: any V2AuthTransport,
        revocationScheduler: any V2DeviceRevocationScheduling,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.revocationScheduler = revocationScheduler
        self.makeUUID = makeUUID
        self.now = now
    }

    public func currentState() -> V2AuthSessionState { state }

    public func sessionUpdates(for epoch: V2AuthSessionEpoch) -> AsyncStream<V2AuthSessionSnapshot> {
        let stream = AsyncStream<V2AuthSessionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        if epoch == currentEpoch(), !pendingTerminalDeletion {
            observers[id] = .init(epoch: epoch, continuation: stream.continuation)
            stream.continuation.yield(.init(epoch: epoch, status: .active(state)))
        } else if let ended = lastEnded, ended.epoch == epoch {
            stream.continuation.yield(.init(epoch: epoch, status: .ended(ended.reason)))
            stream.continuation.finish()
        } else if pendingTerminalDeletion, epoch == terminalSourceEpoch {
            observers[id] = .init(epoch: epoch, continuation: stream.continuation)
            stream.continuation.yield(.init(epoch: epoch, status: .ending))
        } else {
            let reason = lastEnded?.epoch == epoch ? lastEnded!.reason : .superseded
            stream.continuation.yield(.init(epoch: epoch, status: .ended(reason)))
            stream.continuation.finish()
        }
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream.stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func publishCurrentState() {
        guard !pendingTerminalDeletion else { return }
        let epoch = currentEpoch()
        for observer in observers.values where observer.epoch == epoch {
            observer.continuation.yield(.init(epoch: epoch, status: .active(state)))
        }
    }

    private func finishObservers(for epoch: V2AuthSessionEpoch, reason: V2AuthSessionSnapshot.EndReason) {
        lastEnded = (epoch, reason)
        for (id, observer) in observers where observer.epoch == epoch {
            observer.continuation.yield(.init(epoch: epoch, status: .ended(reason)))
            observer.continuation.finish()
            observers[id] = nil
        }
    }

    private func beginTerminalObservation(from epoch: V2AuthSessionEpoch) {
        terminalSourceEpoch = epoch
        for observer in observers.values where observer.epoch == epoch {
            observer.continuation.yield(.init(epoch: epoch, status: .ending))
        }
    }

    private func finishTerminalObservation(_ reason: V2AuthSessionSnapshot.EndReason) {
        if let epoch = terminalSourceEpoch { finishObservers(for: epoch, reason: reason) }
    }

    /// Reads the local credential state without rotating credentials or making
    /// a network request. Logout recovery must distinguish an absent record
    /// from protected data that is temporarily inaccessible.
    public func restoreState() async throws -> V2AuthSessionState {
        do { try await loadIfNeeded() }
        catch V2AuthSessionError.unauthenticated { return .unauthenticated }
        return state
    }


    /// Installs the first credential record supplied by the separately trusted
    /// account/device-registration boundary. It is intentionally the only way
    /// to establish a session from an unauthenticated state: callers must not
    /// write `V2CredentialStore` directly and thereby split credential state
    /// from this actor's refresh fence.
    public func currentEpoch() -> V2AuthSessionEpoch { .init(owner: epochOwner, generation: sessionGeneration) }

    public func requireCurrentEpoch(_ epoch: V2AuthSessionEpoch) throws {
        guard epoch == currentEpoch() else { throw V2AuthSessionError.sessionInvalidated }
    }

    /// Restore/activation classify a concluded old epoch without applying its
    /// terminal result to a newer account. Mutation fences still use the
    /// stricter requireCurrentEpoch above.
    public func requireAuthenticatedEpoch(_ epoch: V2AuthSessionEpoch) throws {
        if epoch != currentEpoch() {
            if let ended = lastEnded, ended.epoch == epoch {
                switch ended.reason {
                case .authenticationRequired: throw V2AuthSessionError.unauthenticated
                case .credentialDeletionPending: throw V2AuthSessionError.credentialsUnavailable
                case .superseded: break
                }
            }
            throw V2AuthSessionError.sessionInvalidated
        }
        switch state {
        case .authenticated, .refreshing: return
        case .unauthenticated: throw V2AuthSessionError.unauthenticated
        case .credentialsUnavailable: throw V2AuthSessionError.credentialsUnavailable
        case .uninitialized, .establishing: throw V2AuthSessionError.sessionInvalidated
        }
    }

    /// Reserve ownership before contacting the account provider. A later
    /// login intent or logout invalidates the result even if HTTP ignores cancel.
    public func beginEstablishment() -> V2AuthSessionEpoch {
        advanceGeneration()
        pendingTerminalDeletion = false
        record = nil
        didLoad = true
        state = .establishing
        return currentEpoch()
    }

    /// An app can reserve its expected owner before asynchronous registration
    /// preparation. Logout must not be undone by a later beginEstablishment.
    public func beginEstablishment(ifCurrent expectedEpoch: V2AuthSessionEpoch) throws -> V2AuthSessionEpoch {
        try Task.checkCancellation()
        try requireCurrentEpoch(expectedEpoch)
        return beginEstablishment()
    }

    /// Logout has persisted its intent before calling this fence. Retain the
    /// current credential only for its existing authenticated cleanup path.
    public func invalidateOutstandingWork() {
        advanceGeneration()
        if let record {
            state = .authenticated(accessTokenExpiresAt: record.credentials.accessTokenExpiresAt)
        } else {
            didLoad = false
            state = .uninitialized
        }
    }

    public func abandonEstablishment(ifCurrent epoch: V2AuthSessionEpoch) {
        guard epoch == currentEpoch(), state == .establishing else { return }
        didLoad = false
        state = .uninitialized
    }

    public func establish(_ credentials: V2AuthCredentials) async throws {
        let epoch = beginEstablishment()
        try await establish(credentials, ifCurrent: epoch)
    }

    public func establish(_ credentials: V2AuthCredentials, ifCurrent epoch: V2AuthSessionEpoch) async throws {
        try requireCurrentEpoch(epoch)
        try await save(.init(credentials: credentials), generation: epoch.generation)
        state = .authenticated(accessTokenExpiresAt: credentials.accessTokenExpiresAt)
    }

    /// Compare against durable ownership after queued credential effects. A
    /// late duplicate result must not revoke a session already adopted by a
    /// newer epoch. Read/epoch failures leave its recovery receipt untouched.
    func ownsCredentialSession(_ credentials: V2AuthCredentials) async throws -> Bool {
        let stored = try await credentialIO(generation: sessionGeneration) { try await $0.load() }
        guard let stored, stored.pendingRevocationOperationID == nil else { return false }
        return stored.credentials.userID == credentials.userID && stored.credentials.deviceID == credentials.deviceID &&
            stored.credentials.revocationCredential == credentials.revocationCredential &&
            stored.credentials.revocationCredentialExpiresAt == credentials.revocationCredentialExpiresAt
    }

    private func coherentCredentials() async throws -> (V2AuthCredentials, V2AuthSessionEpoch) {
        try await loadIfNeeded()
        guard let record else { throw V2AuthSessionError.unauthenticated }
        let epoch = currentEpoch()
        let credentials = record.credentials.accessTokenExpiresAt > now() ? record.credentials : try await refresh()
        try requireCurrentEpoch(epoch)
        return (credentials, epoch)
    }

    public func accessToken() async throws -> String { try await coherentCredentials().0.accessToken }

    public func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials {
        let (credentials, _) = try await coherentCredentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    public func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials {
        let credentials = try await mediaEdgeCredentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    public func deviceSessionCredentials() async throws -> V2ClientDeviceSessionCredentials {
        let credentials = try await mediaEdgeCredentials()
        return .init(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
    }

    public func realtimeCredentials() async throws -> V2ClientRealtimeCredentials {
        let (credentials, epoch) = try await coherentCredentials()
        return .init(userID: credentials.userID, deviceID: credentials.deviceID,
                     accessToken: credentials.accessToken, sessionEpoch: epoch)
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
        let credentials = try await operation.task.value
        try ensureGeneration(operation.sessionGeneration)
        return credentials
    }

    /// Resolve a business HTTP 401 through the existing single-flight refresh.
    /// A predecessor token cannot start another rotation or invalidate a
    /// successor credential/session when its response arrives late.
    func refreshAfterHTTPUnauthorized(ifCurrent epoch: V2AuthSessionEpoch,
                                      rejectedAccessToken: String, deviceID: DeviceID) async throws {
        try Task.checkCancellation()
        try requireCurrentEpoch(epoch)
        guard let record else { throw V2AuthSessionError.unauthenticated }
        guard record.credentials.deviceID == deviceID else { throw V2AuthSessionError.deviceMismatch }
        guard record.credentials.accessToken == rejectedAccessToken else { return }
        _ = try await refresh()
        try Task.checkCancellation()
        try requireCurrentEpoch(epoch)
    }

    /// A terminal revocation from any authenticated command ends the session.
    public func handleTerminalRejection() async throws { try await clearForTerminalState() }

    public func handleTerminalRejection(ifCurrent epoch: V2AuthSessionEpoch, rejectedAccessToken: String? = nil) async throws {
        try requireCurrentEpoch(epoch)
        if let rejectedAccessToken {
            // A TLS attempt may refer to a predecessor access token even
            // within the same session epoch. A refresh in flight owns the
            // successor decision; its old handshake cannot revoke that result.
            guard refreshOperation == nil, record?.credentials.accessToken == rejectedAccessToken else {
                throw V2AuthSessionError.sessionInvalidated
            }
        }
        try await clearForTerminalState()
    }

    /// Call when protected data becomes available again (for example after
    /// foregrounding). It does not clear any credential record.
    public func retryCredentialStoreAccess() {
        guard state == .credentialsUnavailable else { return }
        didLoad = false
        record = nil
        loadOperation = nil
        state = .uninitialized
    }

    private func advanceGeneration(endingCurrentEpoch: Bool = false) {
        if !endingCurrentEpoch {
            if let terminalSourceEpoch { finishObservers(for: terminalSourceEpoch, reason: .superseded) }
            for epoch in Set(observers.values.map(\.epoch)) { finishObservers(for: epoch, reason: .superseded) }
            terminalSourceEpoch = nil
        }
        sessionGeneration &+= 1
        loadOperation = nil
        refreshOperation?.task.cancel()
        refreshOperation = nil
    }

    private func ensureGeneration(_ generation: UInt64) throws {
        guard generation == sessionGeneration else { throw V2AuthSessionError.sessionInvalidated }
    }

    /// Serialize the actual store effects, not just their surrounding actor
    /// checks. An already-running stale save finishes before the new save or
    /// delete, so it cannot overwrite that later operation on disk.
    private func credentialIO<T: Sendable>(
        generation: UInt64,
        _ work: @escaping @Sendable (any V2CredentialStore) async throws -> T
    ) async throws -> T {
        let previous = credentialIOTail?.task
        let id = UUID()
        let task = Task { [credentialStore] in
            await previous?.value
            try self.ensureGeneration(generation)
            do {
                let result = try await work(credentialStore)
                try self.ensureGeneration(generation)
                return result
            } catch {
                try self.ensureGeneration(generation)
                throw error
            }
        }
        credentialIOTail = (id, Task { _ = await task.result })
        defer { if credentialIOTail?.id == id { credentialIOTail = nil } }
        return try await task.value
    }

    private func loadIfNeeded() async throws {
        guard state != .establishing else { throw V2AuthSessionError.sessionInvalidated }
        if pendingTerminalDeletion { try await deleteCurrentRecord(generation: sessionGeneration); return }
        guard !didLoad else {
            if state == .credentialsUnavailable { throw V2AuthSessionError.credentialsUnavailable }
            return
        }
        let generation = sessionGeneration
        let operation: (id: UUID, generation: UInt64, task: V2SharedOperation<Void>)
        if let existing = loadOperation, existing.generation == generation { operation = existing }
        else {
            let id = UUID()
            operation = (id, generation, V2SharedOperation {
                do { try await self.loadRecord(generation: generation) }
                catch { await self.finishLoad(id: id); throw error }
                await self.finishLoad(id: id)
            })
            loadOperation = operation
        }
        try await operation.task.value
    }

    private func finishLoad(id: UUID) {
        if loadOperation?.id == id { loadOperation = nil }
    }

    private func loadRecord(generation: UInt64) async throws {
        do {
            let loaded = try await credentialIO(generation: generation) { try await $0.load() }
            if loaded?.pendingRevocationOperationID != nil {
                pendingTerminalDeletion = true
                beginTerminalObservation(from: currentEpoch())
                try await deleteCurrentRecord(generation: generation)
                return
            }
            record = loaded
            didLoad = true
            state = loaded.map { .authenticated(accessTokenExpiresAt: $0.credentials.accessTokenExpiresAt) } ?? .unauthenticated
        } catch let error as V2CredentialStoreError {
            switch error {
            case .malformedRecord, .permanentlyInvalidated:
                pendingTerminalDeletion = true
                beginTerminalObservation(from: currentEpoch())
                try await deleteCurrentRecord(generation: generation)
                throw V2AuthSessionError.unauthenticated
            case .unavailable, .unexpectedStatus:
                state = .credentialsUnavailable
                throw V2AuthSessionError.credentialsUnavailable
            }
        }
    }

    private func save(_ next: V2AuthCredentialRecord, generation: UInt64) async throws {
        do {
            try await credentialIO(generation: generation) { [revocationScheduler, makeUUID] store in
                let prior: V2AuthCredentialRecord?
                do { prior = try await store.load() }
                catch V2CredentialStoreError.malformedRecord { prior = nil }
                catch V2CredentialStoreError.permanentlyInvalidated { prior = nil }
                if let prior {
                    let sameDevice = prior.credentials.deviceID == next.credentials.deviceID &&
                        prior.credentials.userID == next.credentials.userID
                    if sameDevice {
                        guard prior.pendingRevocationOperationID == nil else {
                            throw V2AuthSessionError.sessionInvalidated
                        }
                    } else {
                        // A prior login can remain durable after local-store
                        // setup fails. Replacement must hand it off even if
                        // explicit sign-out never marked that credential.
                        let operationID = prior.pendingRevocationOperationID ?? makeUUID()
                        if prior.pendingRevocationOperationID == nil {
                            try await store.save(.init(credentials: prior.credentials,
                                pendingRefreshOperationID: prior.pendingRefreshOperationID,
                                pendingRevocationOperationID: operationID))
                        }
                        try await revocationScheduler.enqueue(.init(credentials: prior.credentials, operationID: operationID))
                    }
                }
                try await store.save(next)
            }
            record = next
            didLoad = true
        } catch {
            try ensureGeneration(generation)
            state = .credentialsUnavailable
            throw V2AuthSessionError.credentialsUnavailable
        }
    }

    private func clearForTerminalState() async throws {
        let source = currentEpoch()
        advanceGeneration(endingCurrentEpoch: true)
        pendingTerminalDeletion = true
        beginTerminalObservation(from: source)
        record = nil
        didLoad = true
        state = .unauthenticated
        try await deleteCurrentRecord(generation: sessionGeneration)
    }

    private func deleteCurrentRecord(generation: UInt64) async throws {
        do {
            try await credentialIO(generation: generation) { [revocationScheduler, makeUUID] store in
                let stored: V2AuthCredentialRecord?
                do { stored = try await store.load() }
                catch V2CredentialStoreError.malformedRecord { stored = nil }
                catch V2CredentialStoreError.permanentlyInvalidated { stored = nil }
                if let stored {
                    let operationID = stored.pendingRevocationOperationID ?? makeUUID()
                    if stored.pendingRevocationOperationID == nil {
                        try await store.save(.init(credentials: stored.credentials,
                            pendingRefreshOperationID: stored.pendingRefreshOperationID,
                            pendingRevocationOperationID: operationID))
                    }
                    try await revocationScheduler.enqueue(.init(credentials: stored.credentials, operationID: operationID))
                }
                // All effects share one IO owner. A newer login cannot save
                // until this old-session handoff and deletion have drained.
                try await store.delete()
            }
            record = nil
            didLoad = true
            pendingTerminalDeletion = false
            state = .unauthenticated
            finishTerminalObservation(.authenticationRequired)
        } catch {
            try ensureGeneration(generation)
            state = .credentialsUnavailable
            finishTerminalObservation(.credentialDeletionPending)
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
            revocationCredential: pendingRecord.credentials.revocationCredential,
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
            task: V2SharedOperation { [weak self] in
                guard let self else { throw V2AuthSessionError.sessionInvalidated }
                let result: Result<V2AuthCredentials, Error>
                do {
                    result = .success(try await self.performRefresh(
                        operationID: operationID,
                        sessionGeneration: generation,
                        pendingRecord: pendingRecord,
                        recordToPersist: recordToPersist,
                        request: request
                    ))
                } catch { result = .failure(error) }
                // Finalize once inside the shared task. A resumed waiter must
                // never finalize a failed attempt again or disturb a retry
                // that reuses the same durable operation ID.
                return try await self.finish(
                    operationID: operationID,
                    sessionGeneration: generation,
                    sourceRecord: pendingRecord,
                    result: result
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
            try await credentialIO(generation: sessionGeneration) { try await $0.save(recordToPersist) }
            try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)
        }

        let refreshed = try await transport.refresh(request)
        guard refreshed.userID == pendingRecord.credentials.userID,
              refreshed.deviceID == pendingRecord.credentials.deviceID
        else { throw V2AuthSessionError.deviceMismatch }
        guard refreshed.revocationCredential == pendingRecord.credentials.revocationCredential,
              refreshed.revocationCredentialExpiresAt == pendingRecord.credentials.revocationCredentialExpiresAt
        else { throw V2AuthSessionError.malformedCredentials }
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)

        // A waiter receives success only after the entire successor record is
        // durable; this prevents a process kill from losing a completed refresh
        // rotation. The second fence prevents a stale response from recreating
        // credentials after terminal logout or a new authenticated session.
        let successor = pendingRecord.clearingPendingRefreshOperation(with: refreshed)
        try await credentialIO(generation: sessionGeneration) { try await $0.save(successor) }
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)
        return refreshed
    }

    private func ensureRefreshIsCurrent(operationID: UUID, sessionGeneration: UInt64) throws {
        guard self.sessionGeneration == sessionGeneration,
              refreshOperation?.operationID == operationID
        else { throw V2AuthSessionError.sessionInvalidated }
    }

    private func finish(
        operationID: UUID,
        sessionGeneration: UInt64,
        sourceRecord: V2AuthCredentialRecord,
        result: Result<V2AuthCredentials, Error>
    ) async throws -> V2AuthCredentials {
        try ensureRefreshIsCurrent(operationID: operationID, sessionGeneration: sessionGeneration)

        switch result {
        case .success(let refreshed):
            refreshOperation = nil
            record = sourceRecord.clearingPendingRefreshOperation(with: refreshed)
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
            if record != nil { state = .authenticated(accessTokenExpiresAt: sourceRecord.credentials.accessTokenExpiresAt) }
            throw error
        }
    }
}

private struct RefreshOperation {
    let operationID: UUID
    let sessionGeneration: UInt64
    let task: V2SharedOperation<V2AuthCredentials>
}
