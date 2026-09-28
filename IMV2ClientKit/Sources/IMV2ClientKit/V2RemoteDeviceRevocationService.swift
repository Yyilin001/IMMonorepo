import Foundation
import IMV2Core
#if canImport(Security)
import Security
#endif

public enum V2RemoteDeviceRevocationJournalError: Error, Sendable { case locked, unavailable, corrupt, capacityExceeded, confirmationExpired, conflictingPending, invalidOwner }
public protocol V2RemoteDeviceRevocationMetadataStoring: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}
/// Dedicated security metadata; contains no access/refresh/revocation credential.
public struct V2KeychainRemoteDeviceRevocationMetadataStore: V2RemoteDeviceRevocationMetadataStoring {
    private let service: String
    private let account: String
    public init(installationBinding: V2LocalInstallationBinding, accountID: UserID, currentDeviceID: DeviceID) {
        service = "im.v2.remote-device-revocations." + installationBinding.value.uuidString
        account = accountID.rawValue + ":" + currentDeviceID.rawValue
    }
    #if canImport(Security)
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false] }
    public func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data else { throw V2RemoteDeviceRevocationJournalError.corrupt }; return data
    }
    public func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(q as CFDictionary, nil))
        } else { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        if status == errSecSuccess { return }
        if status == errSecInteractionNotAllowed { throw V2RemoteDeviceRevocationJournalError.locked }
        throw V2RemoteDeviceRevocationJournalError.unavailable
    }
    #else
    public func read() throws -> Data? { throw V2RemoteDeviceRevocationJournalError.unavailable }
    public func write(_ data: Data) throws { throw V2RemoteDeviceRevocationJournalError.unavailable }
    #endif
}
public struct V2RemoteDeviceRevocationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { command.operationID }
    public let command: V2RemoteDeviceRevocationCommand
    public fileprivate(set) var receipt: V2RemoteDeviceRevocationReceipt?
    public fileprivate(set) var unknown: Bool
    public fileprivate(set) var needsAttention: Bool
    fileprivate var attempts: Int
    fileprivate var roundEndsAt: Date
    fileprivate var nextActionAt: Date
}
/// One account activation owns this security queue. Restart never restores submit authorization.
public actor V2RemoteDeviceRevocationService {
    private let accountID: UserID
    private let deviceID: DeviceID
    private let storage: any V2RemoteDeviceRevocationMetadataStoring
    private let client: any V2RemoteDeviceRevocationClient
    private var records: [V2RemoteDeviceRevocationRecord]?
    private var submitDeadlines: [UUID: ContinuousClock.Instant] = [:]
    private var roundDeadlines: [UUID: ContinuousClock.Instant] = [:]
    private var observed: (V2RemoteDeviceRevocationBaseline, ContinuousClock.Instant)?
    private var subscribers: [UUID: AsyncStream<[V2RemoteDeviceRevocationRecord]>.Continuation] = [:]
    private var wake: AsyncStream<Void>.Continuation?
    private var running = false
    private var closed = false
    public init(accountID: UserID, currentDeviceID: DeviceID, storage: any V2RemoteDeviceRevocationMetadataStoring, client: any V2RemoteDeviceRevocationClient) {
        self.accountID = accountID; deviceID = currentDeviceID; self.storage = storage; self.client = client
    }
    public func readBaseline() async throws -> V2RemoteDeviceRevocationBaseline {
        guard !closed else { throw CancellationError() }
        let baseline = try await client.baseline()
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard baseline.actorUserID == accountID, baseline.currentDeviceID == deviceID else { throw V2RemoteDeviceRevocationJournalError.invalidOwner }
        let remaining = min(120, Double(baseline.expiresAtMilliseconds) / 1_000 - Date().timeIntervalSince1970)
        guard remaining > 0 else { throw V2RemoteDeviceRevocationJournalError.confirmationExpired }
        observed = (baseline, ContinuousClock.now.advanced(by: .milliseconds(Int64(remaining * 1_000))))
        return baseline
    }
    public func enqueue(_ command: V2RemoteDeviceRevocationCommand) throws {
        guard !closed else { throw CancellationError() }
        try load()
        guard let observed, observed.0 == command.baseline, ContinuousClock.now < observed.1,
              Date().timeIntervalSince1970 * 1_000 < Double(command.firstSubmissionDeadlineMilliseconds),
              command.baseline.actorUserID == accountID, command.baseline.currentDeviceID == deviceID else { throw V2RemoteDeviceRevocationJournalError.confirmationExpired }
        var updated = records!
        if let existing = updated.first(where: { $0.id == command.operationID }) {
            guard existing.command == command else { throw V2RemoteDeviceRevocationJournalError.corrupt }; return
        }
        let targets = Set(command.targetDeviceIDs)
        guard !updated.contains(where: { $0.receipt == nil && !Set($0.command.targetDeviceIDs).isDisjoint(with: targets) }) else { throw V2RemoteDeviceRevocationJournalError.conflictingPending }
        guard updated.filter({ $0.receipt == nil }).count < 8 else { throw V2RemoteDeviceRevocationJournalError.capacityExceeded }
        // Keep a small terminal history; unknown metadata is never evicted.
        let terminals = updated.filter { $0.receipt != nil }.suffix(8)
        updated = updated.filter { $0.receipt == nil } + Array(terminals)
        updated.append(.init(command: command, receipt: nil, unknown: false, needsAttention: false, attempts: 0, roundEndsAt: Date().addingTimeInterval(60), nextActionAt: Date()))
        try persist(updated)
        roundDeadlines[command.operationID] = .now.advanced(by: .seconds(60))
        submitDeadlines[command.operationID] = observed.1
        wake?.yield(())
    }
    public func resume(_ id: UUID) throws {
        guard !closed else { throw CancellationError() }
        try load(); guard let index = records!.firstIndex(where: { $0.id == id && $0.receipt == nil }) else { return }
        var updated = records!; updated[index].needsAttention = false; updated[index].attempts = 0; updated[index].roundEndsAt = Date().addingTimeInterval(60)
        updated[index].nextActionAt = max(updated[index].nextActionAt, Date())
        // Explicit continuation permits only original proof/query-close, not new authorization.
        submitDeadlines[id] = nil; roundDeadlines[id] = .now.advanced(by: .seconds(60)); try persist(updated); wake?.yield(())
    }
    public func updates() throws -> AsyncStream<[V2RemoteDeviceRevocationRecord]> {
        guard !closed else { throw CancellationError() }
        try load(); guard subscribers.count < 8 else { throw V2RemoteDeviceRevocationJournalError.capacityExceeded }
        let id = UUID(); let pair = AsyncStream<[V2RemoteDeviceRevocationRecord]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = pair.continuation; pair.continuation.yield(records!)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return pair.stream
    }
    /// Invalidates this activation without deleting original security intents or proofs.
    /// The account runtime still owns cancellation and draining of any physical request.
    public func close() {
        closed = true
        observed = nil
        submitDeadlines.removeAll()
        wake?.finish()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
    private func load() throws {
        guard records == nil else { return }
        let data = try storage.read()
        guard (data?.count ?? 0) <= 524_288 else { throw V2RemoteDeviceRevocationJournalError.corrupt }
        let decoded = try data.map { try JSONDecoder().decode([V2RemoteDeviceRevocationRecord].self, from: $0) } ?? []
        guard decoded.count <= 16, decoded.filter({ $0.receipt == nil }).count <= 8, Set(decoded.map(\.id)).count == decoded.count,
              decoded.allSatisfy({ $0.command.baseline.actorUserID == accountID && $0.command.baseline.currentDeviceID == deviceID && $0.attempts >= 0 && $0.attempts <= 5 && ($0.receipt?.validates($0.command) ?? true) }) else { throw V2RemoteDeviceRevocationJournalError.corrupt }
        records = decoded
        for record in decoded where record.receipt == nil {
            let remaining = max(0, min(60, record.roundEndsAt.timeIntervalSinceNow))
            roundDeadlines[record.id] = .now.advanced(by: .milliseconds(Int64(remaining * 1_000)))
        }
    }
    private func persist(_ updated: [V2RemoteDeviceRevocationRecord]) throws {
        let bytes = try JSONEncoder().encode(updated)
        guard bytes.count <= 524_288 else { throw V2RemoteDeviceRevocationJournalError.capacityExceeded }
        try storage.write(bytes); records = updated
        for continuation in subscribers.values { continuation.yield(updated) }
    }
    public func run() async throws {
        guard !closed else { throw CancellationError() }
        guard !running else { throw V2RemoteDeviceRevocationJournalError.unavailable }
        running = true; defer { running = false; wake?.finish(); wake = nil }
        try load()
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)); wake = pair.continuation
        var iterator = pair.stream.makeAsyncIterator()
        while !Task.isCancelled && !closed {
            var expired = records!
            for index in expired.indices where expired[index].receipt == nil && !expired[index].needsAttention {
                if Date() >= expired[index].roundEndsAt || roundDeadlines[expired[index].id].map({ ContinuousClock.now >= $0 }) != false { expired[index].needsAttention = true }
            }
            if expired != records! { try persist(expired) }
            if let record = records!.first(where: { $0.receipt == nil && !$0.needsAttention && $0.nextActionAt <= Date() }) { try await execute(record.id); continue }
            let due = records!.filter { $0.receipt == nil && !$0.needsAttention }.map(\.nextActionAt).min()
            let timer = due.map { date in Task { let delay = max(0, min(60, date.timeIntervalSinceNow)); try? await Task.sleep(for: .milliseconds(Int64(delay * 1_000))); if !Task.isCancelled { pair.continuation.yield(()) } } }
            _ = await iterator.next(); timer?.cancel()
            try Task.checkCancellation()
        }
        throw CancellationError()
    }
    private func schedule(_ record: inout V2RemoteDeviceRevocationRecord, serverFloor: Date?) {
        let now = Date()
        let next = V2NetworkWorkPolicy.commandRecovery.nextAttempt(now: now,
            startedAt: record.roundEndsAt.addingTimeInterval(-60), attemptsCompleted: record.attempts,
            randomUnit: Double.random(in: 0...1), serverRetryNotBefore: serverFloor)
        record.nextActionAt = max(next ?? now, serverFloor ?? now)
        record.needsAttention = next == nil || roundDeadlines[record.id].map({ ContinuousClock.now >= $0 }) != false
    }
    private func execute(_ id: UUID) async throws {
        guard let index = records!.firstIndex(where: { $0.id == id }) else { return }
        var updated = records!; var record = updated[index]
        if record.attempts >= 5 || Date() >= record.roundEndsAt || roundDeadlines[id].map({ ContinuousClock.now >= $0 }) != false { record.needsAttention = true; updated[index] = record; try persist(updated); return }
        let canSubmit = !record.unknown && submitDeadlines[id].map({ ContinuousClock.now < $0 }) == true && Date().timeIntervalSince1970 * 1_000 < Double(record.command.firstSubmissionDeadlineMilliseconds)
        record.unknown = true; record.attempts += 1; updated[index] = record
        try persist(updated) // Write ahead before any physical request.
        let result: V2RemoteDeviceRevocationResult
        do {
            let frozen = record.command
            var deadline = min(roundDeadlines[id]!, ContinuousClock.now.advanced(by: .seconds(15)))
            if canSubmit {
                let wallRemaining = max(0, min(120, Double(frozen.firstSubmissionDeadlineMilliseconds) / 1_000 - Date().timeIntervalSince1970))
                deadline = min(deadline, submitDeadlines[id]!, .now.advanced(by: .milliseconds(Int64(wallRemaining * 1_000))))
            }
            result = try await V2HTTPRequestDeadline.run(until: deadline, service: "deviceSessions", certainty: .outcomeUnknown) { [client] in
                if canSubmit { return try await client.submit(frozen) }
                return try await client.recover(frozen, action: .closeIfAbsent)
            }
        } catch {
            // A replacement activation may already own this metadata store.
            // Leave the write-ahead unknown record for its original-ID recovery.
            guard !closed else { throw CancellationError() }
            try Task.checkCancellation()
            guard let current = records!.firstIndex(where: { $0.id == id }) else { throw error }
            var next = records!
            schedule(&next[current], serverFloor: (error as? V2HTTPFailure)?.retryAfter)
            if error is CancellationError { next[current].needsAttention = true }
            try persist(next)
            if error is CancellationError { throw error }
            return
        }
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        guard let current = records!.firstIndex(where: { $0.id == id }) else { throw V2RemoteDeviceRevocationJournalError.corrupt }
        var next = records!
        switch result {
        case .receipt(let receipt):
            guard receipt.validates(record.command) else { throw V2RemoteDeviceRevocationJournalError.corrupt }
            next[current].receipt = receipt; next[current].needsAttention = false; submitDeadlines[id] = nil
        case .unresolved:
            schedule(&next[current], serverFloor: nil)
        case .fingerprintConflict: next[current].needsAttention = true
        }
        try persist(next)
    }
}
