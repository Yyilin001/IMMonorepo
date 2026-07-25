import Foundation
#if canImport(Security)
import Security
#endif

/// A non-secret, device-only installation marker. Its value is stored both in
/// the device-only Keychain and in the V2 SQLite store. A copied database
/// therefore cannot become trusted on a different installation.
public struct V2LocalInstallationBinding: Codable, Equatable, Sendable {
    public let value: UUID

    public init(value: UUID) { self.value = value }
}

public enum V2InstallationBindingStoreError: Error, Equatable, Sendable {
    case unavailable
    case malformedRecord
    case permanentlyInvalidated
    case unexpectedStatus(Int32)
}

public protocol V2InstallationBindingStore: Sendable {
    func load() async throws -> V2LocalInstallationBinding?
    func save(_ binding: V2LocalInstallationBinding) async throws
    func delete() async throws
}

/// Stores the binding in an item that never migrates through iCloud Keychain
/// or device restore. It is intentionally separate from refresh credentials:
/// credential rotation must not alter the local-store trust anchor.
#if canImport(Security)
public actor V2KeychainInstallationBindingStore: V2InstallationBindingStore {
    private let service: String
    private let account: String

    public init(service: String, account: String = "local-installation-binding") {
        self.service = service
        self.account = account
    }

    public func load() throws -> V2LocalInstallationBinding? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw map(status) }
        guard let data = result as? Data else { throw V2InstallationBindingStoreError.malformedRecord }
        do {
            return try JSONDecoder().decode(V2LocalInstallationBinding.self, from: data)
        } catch {
            throw V2InstallationBindingStoreError.malformedRecord
        }
    }

    public func save(_ binding: V2LocalInstallationBinding) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(binding)
        } catch {
            throw V2InstallationBindingStoreError.malformedRecord
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw map(updateStatus) }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw map(insertStatus) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func map(_ status: OSStatus) -> V2InstallationBindingStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        case errSecAuthFailed: .permanentlyInvalidated
        default: .unexpectedStatus(status)
        }
    }
}
#else
/// Linux test containers must not emulate a device-only Keychain. Returning a
/// typed unavailable error keeps the production trust-boundary fail-closed.
public actor V2KeychainInstallationBindingStore: V2InstallationBindingStore {
    public init(service _: String, account _: String = "local-installation-binding") {}

    public func load() throws -> V2LocalInstallationBinding? {
        throw V2InstallationBindingStoreError.unavailable
    }

    public func save(_: V2LocalInstallationBinding) throws {
        throw V2InstallationBindingStoreError.unavailable
    }

    public func delete() throws {
        throw V2InstallationBindingStoreError.unavailable
    }
}
#endif

public enum V2LocalStoreBootstrapError: Error, Equatable, Sendable {
    case installationBindingUnavailable
}

/// The sole production entry point for opening a V2 local store. It serializes
/// trust-anchor decisions and never treats an unavailable Keychain as evidence
/// that a database was imported.
public actor V2LocalStoreBootstrapper {
    private let bindingStore: any V2InstallationBindingStore
    private let makeBinding: @Sendable () -> V2LocalInstallationBinding

    public init(
        bindingStore: any V2InstallationBindingStore,
        makeBinding: @escaping @Sendable () -> V2LocalInstallationBinding = { .init(value: UUID()) }
    ) {
        self.bindingStore = bindingStore
        self.makeBinding = makeBinding
    }

    public func open(databaseURL: URL) async throws -> GRDBV2LocalSyncStore {
        var binding: V2LocalInstallationBinding
        do {
            if let existing = try await bindingStore.load() {
                binding = existing
            } else {
                // A database with no device-only anchor is untrusted. Remove
                // only the exact V2 artifacts, then establish a fresh anchor.
                try eraseDatabaseArtifacts(at: databaseURL)
                binding = makeBinding()
                try await bindingStore.save(binding)
            }
        } catch let error as V2InstallationBindingStoreError {
            switch error {
            case .unavailable, .unexpectedStatus:
                throw V2LocalStoreBootstrapError.installationBindingUnavailable
            case .malformedRecord, .permanentlyInvalidated:
                // A permanently unusable device-only anchor cannot establish
                // trust in an existing database. Remove it only after the
                // Keychain boundary has made this terminal classification.
                try await bindingStore.delete()
                try eraseDatabaseArtifacts(at: databaseURL)
                binding = makeBinding()
                try await bindingStore.save(binding)
            }
        }

        do {
            return try GRDBV2LocalSyncStore(databaseURL: databaseURL, installationBinding: binding)
        } catch V2ClientLocalStorageError.installationBindingMismatch {
            // Existing device anchor plus a non-matching database is an import
            // or restore, not a migratable cache. Recreate once with the same
            // device anchor; a second failure is surfaced to the caller.
            try eraseDatabaseArtifacts(at: databaseURL)
            return try GRDBV2LocalSyncStore(databaseURL: databaseURL, installationBinding: binding)
        }
    }

    private func eraseDatabaseArtifacts(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        for artifact in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }
    }
}
