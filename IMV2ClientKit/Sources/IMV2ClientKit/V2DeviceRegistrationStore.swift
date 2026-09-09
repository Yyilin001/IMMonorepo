import Foundation
import Crypto
import IMV2Core
#if canImport(Security)
import Security
#endif

public struct V2DeviceRegistrationCancellationJob: Codable, Equatable, Sendable {
    public enum PauseReason: String, Codable, Sendable { case invalidRequest, invalidResponse }
    public let cancellation: V2DeviceRegistrationCancellation
    public let attempts: UInt32
    public let nextAttemptAt: Date
    public let pauseReason: PauseReason?
}

/// Owns registration identities, separately from the installation anchor and
/// established credentials. Keep one owner per app credential namespace.
/// Keychain operations have no suspension points, so preparation, comparison
/// and completion cannot interleave within this owner.
public actor V2DeviceRegistrationStore {
    private let persistence: any V2DeviceRegistrationPersisting
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private var observers: [UUID: AsyncThrowingStream<Void, any Error>.Continuation] = [:]
    private var statusObservers: [UUID: AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error>.Continuation] = [:]

    public init(service: String) {
        persistence = V2KeychainDeviceRegistrationPersistence(service: service)
        makeUUID = UUID.init
        now = Date.init
    }

    init(persistence: any V2DeviceRegistrationPersisting, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init) {
        self.persistence = persistence
        self.makeUUID = makeUUID
        self.now = now
    }

    /// Persist before requesting the account assertion. A retry for the same
    /// account reuses both identifiers; another account gets its own pending
    /// registration without overwriting an interrupted attempt.
    public func prepare(accountHandle: String) throws -> V2PreparedDeviceRegistration {
        let scope = try Self.scope(accountHandle)
        var ledger = try load()
        let registration: V2PendingDeviceCredentialRegistration
        if let pending = ledger.pending[scope], pending.cancellation.issueBefore > now() {
            registration = pending
        } else {
            if let expired = ledger.pending.removeValue(forKey: scope) {
                try abandon(expired.cancellation, in: &ledger)
            }
            // One reserved entry lets a full legacy archive obtain a fresh
            // factor and clean itself. Normal registration cannot use it.
            guard ledger.count < 256 || (ledger.count == 256 && ledger.legacy[scope] != nil) else {
                throw V2DeviceCredentialRegistrationOperationStoreError.capacityExceeded
            }
            registration = try .prepare(deviceID: DeviceID(makeUUID().uuidString), operationID: makeUUID(), now: now())
            ledger.pending[scope] = registration
            try save(ledger)
        }
        return .init(registration: registration, scope: scope, owner: self)
    }

    /// Used only after the app has fenced interactive authentication and
    /// completed local logout. Late finalizers cannot clear a later record.
    public func discardPendingRegistrations() throws {
        var ledger = try load()
        for pending in ledger.pending.values { try abandon(pending.cancellation, in: &ledger) }
        ledger.pending.removeAll()
        try save(ledger)
    }

    /// These records survive logout and expiry rotation until a cancellation
    /// worker confirms the server result. Reading them does not change retries.
    public func pendingCancellations() throws -> [V2DeviceRegistrationCancellation] {
        try cancellationJobs().map(\.cancellation)
    }

    public func completeCancellation(_ cancellation: V2DeviceRegistrationCancellation) throws {
        var ledger = try load()
        guard ledger.abandoned[cancellation.operationID.uuidString]?.cancellation == cancellation else { return }
        ledger.abandoned[cancellation.operationID.uuidString] = nil
        try save(ledger)
    }

    public func legacyRecoveryCount() throws -> Int { try load().legacy.count }

    fileprivate func legacy(for registration: V2PendingDeviceCredentialRegistration, scope: String) throws -> V2LegacyDeviceRegistration? {
        try Task.checkCancellation()
        let ledger = try load()
        guard ledger.pending[scope] == registration else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        return ledger.legacy[scope]
    }

    fileprivate func completeLegacy(_ legacy: V2LegacyDeviceRegistration, registration: V2PendingDeviceCredentialRegistration, scope: String) throws {
        try Task.checkCancellation()
        var ledger = try load()
        guard ledger.pending[scope] == registration else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        guard let current = ledger.legacy[scope] else { return }
        guard current == legacy else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        ledger.legacy[scope] = nil
        try save(ledger)
    }

    /// Cold startup only, before admitting interactive registration. Device
    /// IDs are unique server session identities and never reused by this store.
    /// A pending local finalizer for the durable owned device is not abandoned.
    public func recoverUnclaimed(ownedBy record: V2AuthCredentialRecord?) throws {
        var ledger = try load()
        guard !ledger.pending.isEmpty else { return }
        for pending in ledger.pending.values {
            let owned = record?.pendingRevocationOperationID == nil && record?.credentials.deviceID == pending.deviceID
            if !owned { try abandon(pending.cancellation, in: &ledger) }
        }
        ledger.pending.removeAll()
        try save(ledger)
    }

    public func cancellationJobs() throws -> [V2DeviceRegistrationCancellationJob] {
        try load().abandoned.values.sorted { $0.cancellation.operationID.uuidString < $1.cancellation.operationID.uuidString }
    }

    func dueCancellations(at now: Date) throws -> [V2DeviceRegistrationCancellationJob] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        return Array(try cancellationJobs().filter { $0.pauseReason == nil && $0.nextAttemptAt <= now }.sorted {
            if $0.nextAttemptAt != $1.nextAttemptAt { return $0.nextAttemptAt < $1.nextAttemptAt }
            return $0.cancellation.operationID.uuidString < $1.cancellation.operationID.uuidString
        }.prefix(4))
    }

    func completeCancellationJob(_ job: V2DeviceRegistrationCancellationJob) throws {
        try Task.checkCancellation()
        var ledger = try load()
        let key = job.cancellation.operationID.uuidString
        guard ledger.abandoned[key] == job else { return }
        ledger.abandoned[key] = nil
        try save(ledger)
    }

    func recordCancellationFailure(_ job: V2DeviceRegistrationCancellationJob, retryAt: Date,
        pauseReason: V2DeviceRegistrationCancellationJob.PauseReason? = nil) throws {
        try Task.checkCancellation()
        guard retryAt.timeIntervalSinceReferenceDate.isFinite else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        var ledger = try load()
        let key = job.cancellation.operationID.uuidString
        guard ledger.abandoned[key] == job else { return }
        ledger.abandoned[key] = .init(cancellation: job.cancellation, attempts: job.attempts == .max ? .max : job.attempts + 1,
            nextAttemptAt: retryAt, pauseReason: pauseReason)
        try save(ledger)
    }

    public func retryPausedCancellations() throws {
        try Task.checkCancellation()
        var ledger = try load()
        var changed = false
        for (key, job) in ledger.abandoned where job.pauseReason != nil {
            ledger.abandoned[key] = .init(cancellation: job.cancellation, attempts: job.attempts, nextAttemptAt: .distantPast, pauseReason: nil)
            changed = true
        }
        if changed { try save(ledger) }
    }

    public func cancellationStatusUpdates() -> AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error> {
        let id = UUID()
        let stream = AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        do {
            let ledger = try load()
            statusObservers[id] = stream.continuation
            stream.continuation.yield(status(ledger))
            stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeStatusObserver(id) } }
        } catch { stream.continuation.finish(throwing: error) }
        return stream.stream
    }

    private func removeStatusObserver(_ id: UUID) { statusObservers[id] = nil }
    private func status(_ ledger: Ledger) -> V2DeviceRevocationQueueStatus {
        if ledger.abandoned.isEmpty { return .empty }
        return ledger.abandoned.values.contains { $0.pauseReason != nil } ? .paused : .pending
    }

    func cancellationRetrySchedule() -> V2CommandRetrySchedule {
        .init(nextAttemptAt: { try await self.cancellationJobs().filter { $0.pauseReason == nil }.map(\.nextAttemptAt).min() },
            updates: { await self.updates() })
    }

    private func updates() -> AsyncThrowingStream<Void, any Error> {
        let id = UUID()
        let stream = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func abandon(_ cancellation: V2DeviceRegistrationCancellation, in ledger: inout Ledger) throws {
        let key = cancellation.operationID.uuidString
        if let prior = ledger.abandoned[key] {
            guard prior.cancellation == cancellation else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
            return // Preserve an existing job's retry and pause state.
        }
        ledger.abandoned[key] = .init(cancellation: cancellation, attempts: 0, nextAttemptAt: .distantPast, pauseReason: nil)
    }

    fileprivate func requirePending(_ registration: V2PendingDeviceCredentialRegistration, scope: String) throws {
        guard try load().pending[scope] == registration else {
            throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord
        }
    }

    fileprivate func finish(_ registration: V2PendingDeviceCredentialRegistration, scope: String) throws {
        var ledger = try load()
        guard ledger.pending[scope] == registration else { return }
        ledger.pending[scope] = nil
        try save(ledger)
    }

    private func load() throws -> Ledger {
        guard let data = try persistence.load() else { return .init() }
        if let ledger = try? JSONDecoder().decode(Ledger.self, from: data), ledger.version == 3,
           ledger.count <= 257, ledger.pending.keys.allSatisfy(Self.validScope),
           ledger.legacy.keys.allSatisfy(Self.validScope),
           ledger.legacy.values.allSatisfy({ UUID(uuidString: $0.deviceID.rawValue) != nil }),
           ledger.abandoned.allSatisfy({ $0.key == $0.value.cancellation.operationID.uuidString && $0.value.nextAttemptAt.timeIntervalSinceReferenceDate.isFinite }) {
            return ledger
        }
        if let old = try? JSONDecoder().decode(ProofLedger.self, from: data), old.version == 2,
           old.pending.count + old.abandoned.count + old.legacy.count <= 256,
           old.pending.keys.allSatisfy(Self.validScope), old.legacy.keys.allSatisfy(Self.validScope),
           old.legacy.values.allSatisfy({ UUID(uuidString: $0.deviceID.rawValue) != nil }),
           old.abandoned.allSatisfy({ $0.key == $0.value.operationID.uuidString }) {
            var upgraded = Ledger()
            upgraded.pending = old.pending
            upgraded.legacy = old.legacy
            for cancellation in old.abandoned.values { try abandon(cancellation, in: &upgraded) }
            try save(upgraded)
            return upgraded
        }
        // Old IDs cannot be upgraded into authority over a request already
        // sent. Keep them as explicit legacy recovery evidence and rotate.
        guard let old = try? JSONDecoder().decode(LegacyLedger.self, from: data), old.version == 1,
              old.pending.count <= 256, old.pending.keys.allSatisfy(Self.validScope),
              old.pending.values.allSatisfy({ UUID(uuidString: $0.deviceID.rawValue) != nil })
        else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        var upgraded = Ledger()
        upgraded.legacy = old.pending
        try save(upgraded)
        return upgraded
    }

    private func save(_ ledger: Ledger) throws {
        if ledger.count == 0 { try persistence.delete() }
        else { try persistence.save(JSONEncoder().encode(ledger)) }
        for observer in observers.values { observer.yield(()) }
        let snapshot = status(ledger)
        for observer in statusObservers.values { observer.yield(snapshot) }
    }

    private static func validScope(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func scope(_ accountHandle: String) throws -> String {
        let canonical = accountHandle.lowercased()
        let bytes = Array(canonical.utf8)
        guard (3 ... 64).contains(bytes.count), bytes.allSatisfy({
            (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 || $0 == 45
        }) else { throw V2AccountAuthenticationError.invalidAccountHandle }
        // Account handles are not persisted in plaintext. This digest is only
        // a local lookup key; it is not an authentication or privacy proof.
        return SHA256.hash(data: Data(("password-account-v1\0" + canonical).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private struct Ledger: Codable {
        var version = 3
        var pending: [String: V2PendingDeviceCredentialRegistration] = [:]
        var abandoned: [String: V2DeviceRegistrationCancellationJob] = [:]
        var legacy: [String: LegacyRegistration] = [:]
        var count: Int { pending.count + abandoned.count + legacy.count }
    }
    private struct ProofLedger: Decodable {
        let version: Int
        let pending: [String: V2PendingDeviceCredentialRegistration]
        let abandoned: [String: V2DeviceRegistrationCancellation]
        let legacy: [String: LegacyRegistration]
    }
    private struct LegacyLedger: Decodable {
        let version: Int
        let pending: [String: LegacyRegistration]
    }
    private typealias LegacyRegistration = V2LegacyDeviceRegistration
}

/// One immutable registration lease shared by the factor and credential
/// issuer. Every persistence operation remains bound to this exact attempt.
public struct V2PreparedDeviceRegistration: V2DeviceIdentityProvider, V2DeviceCredentialRegistrationOperationStore {
    private let registration: V2PendingDeviceCredentialRegistration
    private let scope: String
    private let owner: V2DeviceRegistrationStore

    fileprivate init(registration: V2PendingDeviceCredentialRegistration, scope: String, owner: V2DeviceRegistrationStore) {
        self.registration = registration
        self.scope = scope
        self.owner = owner
    }

    public func deviceID() async throws -> DeviceID {
        try await owner.requirePending(registration, scope: scope)
        return registration.deviceID
    }

    public func load() async throws -> V2PendingDeviceCredentialRegistration? {
        try await owner.requirePending(registration, scope: scope)
        return registration
    }

    public func save(_ pending: V2PendingDeviceCredentialRegistration) async throws {
        guard pending == registration else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        try await owner.requirePending(registration, scope: scope)
    }

    public func delete() async throws {
        try await owner.finish(registration, scope: scope)
    }

    public func recoveringLegacyRegistration(using provider: any V2DeviceBoundAccountAssertionProvider,
        client: any V2LegacyRegistrationCancellationClient) -> any V2DeviceBoundAccountAssertionProvider {
        LegacyRecoveringAssertionProvider(lease: self, provider: provider, client: client)
    }

    fileprivate func legacy() async throws -> V2LegacyDeviceRegistration? {
        try await owner.legacy(for: registration, scope: scope)
    }

    fileprivate func completeLegacy(_ legacy: V2LegacyDeviceRegistration) async throws {
        try await owner.completeLegacy(legacy, registration: registration, scope: scope)
    }
}

private struct LegacyRecoveringAssertionProvider: V2DeviceBoundAccountAssertionProvider {
    let lease: V2PreparedDeviceRegistration
    let provider: any V2DeviceBoundAccountAssertionProvider
    let client: any V2LegacyRegistrationCancellationClient

    func accountAssertion(for deviceID: DeviceID) async throws -> String {
        try Task.checkCancellation()
        guard try await lease.deviceID() == deviceID else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        let legacy = try await lease.legacy()
        try Task.checkCancellation()
        let assertion = try await provider.accountAssertion(for: deviceID)
        try Task.checkCancellation()
        _ = try await lease.deviceID()
        if let legacy {
            try await client.cancel(legacy, accountAssertion: assertion, assertionDeviceID: deviceID)
            try Task.checkCancellation()
            try await lease.completeLegacy(legacy)
        }
        try Task.checkCancellation()
        return assertion
    }
}

/// Synchronous persistence is deliberate: the owning actor performs each
/// whole ledger transition without an await between read and write.
protocol V2DeviceRegistrationPersisting: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

private struct V2KeychainDeviceRegistrationPersistence: V2DeviceRegistrationPersisting {
    let service: String

    #if canImport(Security)
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "device-registration-ledger-v1"]
    }

    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        return data
    }

    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw error(added) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    private func error(_ status: OSStatus) -> V2DeviceCredentialRegistrationOperationStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        case errSecAuthFailed: .permanentlyInvalidated
        default: .unexpectedStatus(status)
        }
    }
    #else
    func load() throws -> Data? { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    func save(_: Data) throws { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    func delete() throws { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    #endif
}
