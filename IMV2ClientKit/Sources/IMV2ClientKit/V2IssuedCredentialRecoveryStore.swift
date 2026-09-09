import Foundation
#if canImport(Security)
import Security
#endif

/// Tracks received authority before the login owner can adopt it. This store
/// contains only revocation capability; never access/refresh credentials.
public protocol V2IssuedCredentialRecovering: Sendable {
    func receive(_ credentials: V2AuthCredentials, operationID: UUID) async throws -> V2DeviceRevocationIntent
    func adopt(_ receipt: V2DeviceRevocationIntent) async throws
    func abandon(_ receipt: V2DeviceRevocationIntent) async throws
}

public enum V2IssuedCredentialRecoveryError: Error, Equatable, Sendable {
    case unavailable, malformedRecord, conflict, capacityExceeded
    case unexpectedStatus(Int32)
}

public actor V2IssuedCredentialRecoveryStore: V2IssuedCredentialRecovering {
    private let persistence: any V2IssuedCredentialRecoveryPersisting
    private let revocations: V2DeviceRevocationStore

    public init(service: String, revocations: V2DeviceRevocationStore) {
        persistence = V2KeychainIssuedCredentialRecoveryPersistence(service: service)
        self.revocations = revocations
    }

    init(persistence: any V2IssuedCredentialRecoveryPersisting, revocations: V2DeviceRevocationStore) {
        self.persistence = persistence; self.revocations = revocations
    }

    public func receive(_ credentials: V2AuthCredentials, operationID: UUID) throws -> V2DeviceRevocationIntent {
        let intent = V2DeviceRevocationIntent(credentials: credentials, operationID: operationID)
        var ledger = try load()
        let key = operationID.uuidString
        if let existing = ledger.records[key] {
            guard existing.intent == intent, existing.disposition == .awaitingAdoption else { throw V2IssuedCredentialRecoveryError.conflict }
            return intent
        }
        guard ledger.records.count < 256 else { throw V2IssuedCredentialRecoveryError.capacityExceeded }
        ledger.records[key] = .init(intent: intent, disposition: .awaitingAdoption)
        try save(ledger)
        return intent
    }

    public func adopt(_ receipt: V2DeviceRevocationIntent) throws {
        var ledger = try load()
        guard let existing = ledger.records[receipt.operationID.uuidString] else { throw V2IssuedCredentialRecoveryError.conflict }
        guard existing.intent == receipt, existing.disposition == .awaitingAdoption else { throw V2IssuedCredentialRecoveryError.conflict }
        ledger.records[receipt.operationID.uuidString] = nil
        try save(ledger)
    }

    public func abandon(_ receipt: V2DeviceRevocationIntent) async throws {
        var ledger = try load()
        guard let existing = ledger.records[receipt.operationID.uuidString] else { return }
        guard existing.intent == receipt else { throw V2IssuedCredentialRecoveryError.conflict }
        if existing.disposition != .abandoned {
            ledger.records[receipt.operationID.uuidString] = .init(intent: receipt, disposition: .abandoned)
            try save(ledger)
        }
        try await drainAbandoned()
    }

    /// Run once at cold startup, before admitting interactive registration.
    /// Do not run against an in-flight registration in this process.
    public func recoverUnclaimed(ownedBy record: V2AuthCredentialRecord?) async throws {
        var ledger = try load()
        var changed = false
        for (key, entry) in ledger.records where entry.disposition == .awaitingAdoption {
            let credentials = record?.credentials
            let adopted = record?.pendingRevocationOperationID == nil &&
                credentials?.userID == entry.intent.userID && credentials?.deviceID == entry.intent.deviceID &&
                credentials?.revocationCredential == entry.intent.credential &&
                credentials?.revocationCredentialExpiresAt == entry.intent.expiresAt
            if adopted { ledger.records[key] = nil }
            else { ledger.records[key] = .init(intent: entry.intent, disposition: .abandoned) }
            changed = true
        }
        if changed { try save(ledger) }
        try await drainAbandoned()
    }

    public func drainAbandoned() async throws {
        let abandoned = try load().records.values.filter { $0.disposition == .abandoned }
        for entry in abandoned {
            // The queue may already contain a logout for the same session.
            // Preserve its operation, retry count and pause state in that case.
            try await revocations.enqueueRecovered(entry.intent)
            var ledger = try load()
            let key = entry.intent.operationID.uuidString
            guard ledger.records[key] == entry else { continue }
            ledger.records[key] = nil
            try save(ledger)
        }
    }

    private func load() throws -> Ledger {
        guard let data = try persistence.load() else { return .init() }
        guard let ledger = try? JSONDecoder().decode(Ledger.self, from: data), ledger.version == 1,
              ledger.records.count <= 256,
              ledger.records.allSatisfy({ key, record in
                  key == record.intent.operationID.uuidString && record.intent.expiresAt.timeIntervalSinceReferenceDate.isFinite
              }) else { throw V2IssuedCredentialRecoveryError.malformedRecord }
        return ledger
    }
    private func save(_ ledger: Ledger) throws {
        if ledger.records.isEmpty { try persistence.delete() }
        else { try persistence.save(JSONEncoder().encode(ledger)) }
    }
    private enum Disposition: String, Codable { case awaitingAdoption, abandoned }
    private struct Record: Codable, Equatable { let intent: V2DeviceRevocationIntent; let disposition: Disposition }
    private struct Ledger: Codable { var version = 1; var records: [String: Record] = [:] }
}

protocol V2IssuedCredentialRecoveryPersisting: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

private struct V2KeychainIssuedCredentialRecoveryPersistence: V2IssuedCredentialRecoveryPersisting {
    let service: String
#if canImport(Security)
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "received-device-credentials-v1"]
    }
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2IssuedCredentialRecoveryError.malformedRecord }
        return data
    }
    func save(_ data: Data) throws {
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        let added = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw error(added) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private func error(_ status: OSStatus) -> V2IssuedCredentialRecoveryError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        default: .unexpectedStatus(status)
        }
    }
#else
    func load() throws -> Data? { throw V2IssuedCredentialRecoveryError.unavailable }
    func save(_: Data) throws { throw V2IssuedCredentialRecoveryError.unavailable }
    func delete() throws { throw V2IssuedCredentialRecoveryError.unavailable }
#endif
}
