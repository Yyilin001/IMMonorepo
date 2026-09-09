import Foundation
import IMV2Core
#if canImport(Security)
import Security
#endif

/// Contains no access/refresh credential and cannot authorize a new account.
public struct V2DeviceRevocationIntent: Codable, Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let credential: V2DeviceRevocationCredential
    public let expiresAt: Date
    public let operationID: UUID

    public init(credentials: V2AuthCredentials, operationID: UUID) {
        userID = credentials.userID
        deviceID = credentials.deviceID
        credential = credentials.revocationCredential
        expiresAt = credentials.revocationCredentialExpiresAt
        self.operationID = operationID
    }
}

public protocol V2DeviceRevocationScheduling: Sendable {
    func enqueue(_ intent: V2DeviceRevocationIntent) async throws
}

public struct V2DeviceRevocationJob: Codable, Equatable, Sendable {
    public enum PauseReason: String, Codable, Sendable { case invalidCredential, operationConflict, invalidRequest, invalidResponse }
    public let intent: V2DeviceRevocationIntent
    public let attempts: UInt32
    public let nextAttemptAt: Date
    public let pauseReason: PauseReason?
}

public enum V2DeviceRevocationQueueStatus: Equatable, Sendable { case empty, pending, paused }

public enum V2DeviceRevocationStoreError: Error, Equatable, Sendable {
    case unavailable, malformedRecord, capacityExceeded, conflict, invalidRequest
    case unexpectedStatus(Int32)
}

/// One owner per credential namespace. Each mutation synchronously replaces a
/// single Keychain item before returning; no network work occurs in this actor.
public actor V2DeviceRevocationStore: V2DeviceRevocationScheduling {
    private let persistence: any V2DeviceRevocationPersisting
    private static let maximumJobs = 256
    private var observers: [UUID: AsyncThrowingStream<Void, any Error>.Continuation] = [:]

    private var statusObservers: [UUID: AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error>.Continuation] = [:]

    public init(service: String) {
        persistence = V2KeychainDeviceRevocationPersistence(service: service)
    }

    init(persistence: any V2DeviceRevocationPersisting) { self.persistence = persistence }

    public func enqueue(_ intent: V2DeviceRevocationIntent) throws {
        guard intent.expiresAt.timeIntervalSinceReferenceDate.isFinite else { throw V2DeviceRevocationStoreError.invalidRequest }
        var ledger = try load()
        let key = intent.operationID.uuidString
        if let existing = ledger.jobs[key] {
            guard existing.intent == intent else { throw V2DeviceRevocationStoreError.conflict }
            return
        }
        guard !ledger.jobs.values.contains(where: { $0.intent.userID == intent.userID && $0.intent.deviceID == intent.deviceID }) else {
            throw V2DeviceRevocationStoreError.conflict
        }
        guard ledger.jobs.count < Self.maximumJobs else { throw V2DeviceRevocationStoreError.capacityExceeded }
        ledger.jobs[key] = .init(intent: intent, attempts: 0, nextAttemptAt: .distantPast, pauseReason: nil)
        try save(ledger)
    }

    /// Recovery may converge with an already-persisted explicit logout.
    /// Only exactly the same session authority can reuse that existing job.
    func enqueueRecovered(_ intent: V2DeviceRevocationIntent) throws {
        if let existing = try load().jobs.values.first(where: {
            $0.intent.userID == intent.userID && $0.intent.deviceID == intent.deviceID
        }) {
            guard existing.intent.credential == intent.credential, existing.intent.expiresAt == intent.expiresAt else {
                throw V2DeviceRevocationStoreError.conflict
            }
            return
        }
        try enqueue(intent)
    }

    public func jobs() throws -> [V2DeviceRevocationJob] {
        try load().jobs.values.sorted { $0.intent.operationID.uuidString < $1.intent.operationID.uuidString }
    }

    public func due(at now: Date, limit: Int = 4) throws -> [V2DeviceRevocationJob] {
        guard now.timeIntervalSinceReferenceDate.isFinite, (1...32).contains(limit) else { throw V2DeviceRevocationStoreError.invalidRequest }
        // A local clock is not proof of server expiry. Only a server result
        // can settle an intent; an expired local deadline remains retryable.
        return Array(try load().jobs.values.filter { $0.pauseReason == nil && $0.nextAttemptAt <= now }.sorted {
            if $0.nextAttemptAt != $1.nextAttemptAt { return $0.nextAttemptAt < $1.nextAttemptAt }
            return $0.intent.operationID.uuidString < $1.intent.operationID.uuidString
        }.prefix(limit))
    }

    @discardableResult
    public func recordFailure(_ job: V2DeviceRevocationJob, retryAt: Date,
        pauseReason: V2DeviceRevocationJob.PauseReason? = nil) throws -> Bool {
        try Task.checkCancellation()
        guard retryAt.timeIntervalSinceReferenceDate.isFinite else { throw V2DeviceRevocationStoreError.invalidRequest }
        var ledger = try load()
        let key = job.intent.operationID.uuidString
        guard ledger.jobs[key] == job else { return false }
        ledger.jobs[key] = .init(intent: job.intent, attempts: job.attempts == .max ? .max : job.attempts + 1,
            nextAttemptAt: retryAt, pauseReason: pauseReason)
        try save(ledger)
        return true
    }

    @discardableResult
    public func complete(_ job: V2DeviceRevocationJob) throws -> Bool {
        try Task.checkCancellation()
        var ledger = try load()
        let key = job.intent.operationID.uuidString
        guard ledger.jobs[key] == job else { return false }
        ledger.jobs[key] = nil
        try save(ledger)
        return true
    }

    /// User-requested recovery only. Retains proof, operation and attempt
    /// count; normal backoff jobs are deliberately unaffected.
    public func retryPaused() throws {
        try Task.checkCancellation()
        var ledger = try load()
        var changed = false
        for (key, job) in ledger.jobs where job.pauseReason != nil {
            ledger.jobs[key] = .init(intent: job.intent, attempts: job.attempts,
                nextAttemptAt: .distantPast, pauseReason: nil)
            changed = true
        }
        if changed { try save(ledger) }
    }

    /// Only aggregate state crosses into presentation. Subscription and its
    /// initial snapshot share the persistence owner's actor turn.
    public func statusUpdates() -> AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error> {
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
        if ledger.jobs.isEmpty { return .empty }
        return ledger.jobs.values.contains { $0.pauseReason != nil } ? .paused : .pending
    }

    func retrySchedule() -> V2CommandRetrySchedule {
        .init(nextAttemptAt: { try await self.jobs().filter { $0.pauseReason == nil }.map(\.nextAttemptAt).min() },
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

    private func load() throws -> Ledger {
        guard let data = try persistence.load() else { return .init() }
        guard let ledger = try? JSONDecoder().decode(Ledger.self, from: data), ledger.version == 1,
              ledger.jobs.count <= Self.maximumJobs,
              ledger.jobs.allSatisfy({ key, job in
                  key == job.intent.operationID.uuidString && job.intent.expiresAt.timeIntervalSinceReferenceDate.isFinite &&
                      job.nextAttemptAt.timeIntervalSinceReferenceDate.isFinite
              }) else { throw V2DeviceRevocationStoreError.malformedRecord }
        let targets = ledger.jobs.values.map { Target(userID: $0.intent.userID, deviceID: $0.intent.deviceID) }
        guard Set(targets).count == targets.count else { throw V2DeviceRevocationStoreError.malformedRecord }
        return ledger
    }

    private func save(_ ledger: Ledger) throws {
        if ledger.jobs.isEmpty { try persistence.delete() }
        else { try persistence.save(JSONEncoder().encode(ledger)) }
        for observer in observers.values { observer.yield(()) }
        let snapshot = status(ledger)
        for observer in statusObservers.values { observer.yield(snapshot) }
    }

    private struct Target: Hashable { let userID: UserID; let deviceID: DeviceID }
    private struct Ledger: Codable { var version = 1; var jobs: [String: V2DeviceRevocationJob] = [:] }
}

protocol V2DeviceRevocationPersisting: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

private struct V2KeychainDeviceRevocationPersistence: V2DeviceRevocationPersisting {
    let service: String
#if canImport(Security)
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "device-revocation-outbox-v1"]
    }
    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2DeviceRevocationStoreError.malformedRecord }
        return data
    }
    func save(_ data: Data) throws {
        // This item contains only revocation authority, never login authority.
        // Device-only availability after first unlock permits deferred cleanup.
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        let inserted = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw error(inserted) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private func error(_ status: OSStatus) -> V2DeviceRevocationStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        default: .unexpectedStatus(status)
        }
    }
#else
    func load() throws -> Data? { throw V2DeviceRevocationStoreError.unavailable }
    func save(_: Data) throws { throw V2DeviceRevocationStoreError.unavailable }
    func delete() throws { throw V2DeviceRevocationStoreError.unavailable }
#endif
}
