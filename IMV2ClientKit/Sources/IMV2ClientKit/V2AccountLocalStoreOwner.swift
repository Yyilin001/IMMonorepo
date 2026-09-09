import Crypto
import Foundation
import IMV2Core

public enum V2AccountLocalStoreError: Error, Equatable, Sendable {
    case unattributedLegacyStore, migrationConflict, staleStore
}

/// One session bootstrapper owns this actor. Account directories retain their
/// outbox across ordinary logout; explicit erasure is a separate operation.
/// Transitions are serialized across awaits, and cleanup identifies the exact
/// store object, so a delayed A close cannot close a later A incarnation.
public actor V2AccountLocalStoreOwner {
    private struct Migration: Codable {
        let version: Int
        let accountID: String
        let incarnation: UUID
    }
    private let root: URL
    private let legacy: V2LocalDatabaseArtifacts
    private let bootstrapper: V2LocalStoreBootstrapper
    private var catalogs: [UserID: V2AccountStorageDirectory] = [:]
    private var current: (scope: V2AccountStorageScope, store: GRDBV2LocalSyncStore)?
    private var tail: (id: UUID, task: Task<Void, Never>)?
    private var migrationFinished = false

    public init(root: URL, legacyDatabaseURL: URL, bootstrapper: V2LocalStoreBootstrapper) {
        self.root = root
        legacy = .init(primary: legacyDatabaseURL)
        self.bootstrapper = bootstrapper
    }

    public func open(accountID: UserID) async throws -> GRDBV2LocalSyncStore {
        try await serialize { try await self.performOpen(accountID: accountID) }
    }

    public func scope(for store: GRDBV2LocalSyncStore) throws -> V2AccountStorageScope {
        guard let current, current.store === store else { throw V2AccountLocalStoreError.staleStore }
        return current.scope
    }

    public func close(_ store: GRDBV2LocalSyncStore) async throws {
        try await serialize {
            // Close that captured object even if it is no longer current.
            // Never look up the deletion/close target by current account name.
            try await store.close()
            await self.forgetIfCurrent(store)
        }
    }

    private func forgetIfCurrent(_ store: GRDBV2LocalSyncStore) {
        if current?.store === store { current = nil }
    }

    private func serialize<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail?.task
        let id = UUID()
        let operation = Task { await previous?.value; return try await work() }
        tail = (id, Task { _ = await operation.result })
        defer { if tail?.id == id { tail = nil } }
        return try await operation.value
    }

    private func catalog(for accountID: UserID) -> V2AccountStorageDirectory {
        if let existing = catalogs[accountID] { return existing }
        // UserID is a domain identifier, not a filesystem path component.
        let key = SHA256.hash(data: Data(accountID.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let catalog = V2AccountStorageDirectory(root: root.appending(path: key, directoryHint: .isDirectory))
        catalogs[accountID] = catalog
        return catalog
    }

    private func performOpen(accountID: UserID) async throws -> GRDBV2LocalSyncStore {
        if let current, current.scope.accountID == accountID { return current.store }
        if let current { try await current.store.close(); self.current = nil }
        try await migrateLegacyIfNeeded()
        let scope = try await catalog(for: accountID).openScope(accountID: accountID)
        let store = try await bootstrapper.open(databaseURL: scope.database.primary, userID: accountID)
        current = (scope, store)
        return store
    }

    private var migrationURL: URL { root.appending(path: "legacy-import.json") }

    private func migrateLegacyIfNeeded() async throws {
        guard !migrationFinished else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: root)
        let migration: Migration
        if fm.fileExists(atPath: migrationURL.path) {
            migration = try JSONDecoder().decode(Migration.self, from: Data(contentsOf: migrationURL))
            guard migration.version == 1 else { throw V2AccountStorageError.invalidManifest }
        } else if fm.fileExists(atPath: legacy.primary.path) {
            // Validate the installation before reading an account identity.
            // Passing no user never relabels an existing account as the login.
            guard let old = try await bootstrapper.openTrustedLegacyStore(databaseURL: legacy.primary) else {
                migrationFinished = true
                return
            }
            let storedAccount: UserID?
            do {
                storedAccount = try await old.boundAccountID()
                if storedAccount != nil { try await old.requireMessageSearchIndexRebuild() }
            }
            catch { try await old.close(); throw error }
            try await old.close()
            guard let account = storedAccount else { throw V2AccountLocalStoreError.unattributedLegacyStore }
            let scope = try await catalog(for: account).openScope(accountID: account)
            guard !fm.fileExists(atPath: scope.database.primary.path) else { throw V2AccountLocalStoreError.migrationConflict }
            migration = .init(version: 1, accountID: account.rawValue, incarnation: scope.incarnation)
            try JSONEncoder().encode(migration).write(to: migrationURL, options: .atomic)
        } else {
            // An orphan FTS has no independently trusted account association.
            for file in legacy.files.dropFirst(3) where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            migrationFinished = true
            return
        }
        let account = try UserID(migration.accountID)
        let scope = try await catalog(for: account).openScope(accountID: account)
        guard scope.incarnation == migration.incarnation else { throw V2AccountLocalStoreError.migrationConflict }
        guard fm.fileExists(atPath: legacy.primary.path) || fm.fileExists(atPath: scope.database.primary.path) else {
            throw V2AccountLocalStoreError.migrationConflict
        }
        // Each rename is atomic on this application-support volume. The
        // committed marker lets restart finish any prefix before opening pools.
        for (source, destination) in zip(legacy.files.prefix(3), scope.database.files.prefix(3)) {
            if fm.fileExists(atPath: source.path) {
                guard !fm.fileExists(atPath: destination.path) else { throw V2AccountLocalStoreError.migrationConflict }
                try fm.moveItem(at: source, to: destination)
            }
        }
        // Rebuild search from the validated primary; never import global FTS.
        try legacy.removeClosedFiles()
        try fm.removeItem(at: migrationURL)
        migrationFinished = true
    }
}
