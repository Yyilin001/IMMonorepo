import Foundation
import IMV2Core

/// Every derived SQLite artifact belongs to the same primary-store lifetime.
/// Removal is only valid after all owners have drained and both pools closed.
public struct V2LocalDatabaseArtifacts: Sendable, Equatable {
    public let primary: URL
    public var search: URL {
        let name = primary.lastPathComponent == "V2.sqlite"
            ? "V2Search.sqlite" : primary.deletingPathExtension().lastPathComponent + ".search.sqlite"
        return primary.deletingLastPathComponent().appending(path: name)
    }
    public var files: [URL] {
        [primary, search].flatMap { url in
            [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        }
    }
    public init(primary: URL) { self.primary = primary }

    func removeClosedFiles(fileManager: FileManager = .default) throws {
        for url in files where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

/// An opaque incarnation, never an account name, determines deletion scope.
/// A later login by the same user therefore cannot reuse a retired directory.
public struct V2AccountStorageScope: Equatable, Sendable {
    public let incarnation: UUID
    public let accountID: UserID
    public let directory: URL
    public var database: V2LocalDatabaseArtifacts { .init(primary: directory.appending(path: "V2.sqlite")) }
    public var mediaStagingDirectory: URL { directory.appending(path: "media-staging", directoryHint: .isDirectory) }
    public var mediaCacheDirectory: URL { directory.appending(path: "media-cache", directoryHint: .isDirectory) }
}

public enum V2AccountStorageError: Error, Equatable, Sendable {
    case invalidManifest, scopeMismatch, cleanupRequired, storesAlreadyOpened
}

/// Filesystem half of the account lifecycle. Its owner must stop admitting
/// work, retire the scope, drain tasks and close stores before completing
/// cleanup. A new process resumes retired directories before opening a pool.
/// No network, Keychain or account credentials are stored in this catalog.
public actor V2AccountStorageDirectory {
    private struct Entry: Codable, Equatable {
        let version: Int
        let incarnation: UUID
        let accountID: String
    }
    private let root: URL
    private let fileManager = FileManager.default
    private var prepared = false
    private var hasIssuedScope = false
    private var recovered = false

    public init(root: URL) { self.root = root.standardizedFileURL }
    private var activeURL: URL { root.appending(path: "active.json") }
    private var retiredDirectory: URL { root.appending(path: "retired", directoryHint: .isDirectory) }
    private func markerURL(_ id: UUID) -> URL { retiredDirectory.appending(path: id.uuidString + ".json") }
    private func scope(_ entry: Entry) throws -> V2AccountStorageScope {
        guard entry.version == 1 else { throw V2AccountStorageError.invalidManifest }
        return .init(incarnation: entry.incarnation, accountID: try UserID(entry.accountID),
                     directory: root.appending(path: entry.incarnation.uuidString, directoryHint: .isDirectory))
    }
    private func read(_ url: URL) throws -> Entry? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
            _ = try scope(entry)
            return entry
        } catch { throw V2AccountStorageError.invalidManifest }
    }
    private func prepare() throws {
        guard !prepared else { return }
        try fileManager.createDirectory(at: retiredDirectory, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: root)
        prepared = true
    }
    private func active() throws -> Entry? {
        guard let entry = try read(activeURL) else { return nil }
        // The marker is committed first. A crash before removing active.json
        // must not reopen the directory whose deletion has already begun.
        if fileManager.fileExists(atPath: markerURL(entry.incarnation).path) { return nil }
        return entry
    }

    public func openScope(accountID: UserID) throws -> V2AccountStorageScope {
        try prepare()
        if !recovered { try resumeCleanupBeforeOpeningStores() }
        hasIssuedScope = true
        if let entry = try active() {
            guard entry.accountID == accountID.rawValue else { throw V2AccountStorageError.cleanupRequired }
            return try scope(entry)
        }
        let entry = Entry(version: 1, incarnation: UUID(), accountID: accountID.rawValue)
        let result = try scope(entry)
        try fileManager.createDirectory(at: result.directory, withIntermediateDirectories: false)
        try V2LocalBackupExclusion.apply(to: result.directory)
        try JSONEncoder().encode(entry).write(to: activeURL, options: .atomic)
        return result
    }

    /// Persist the fence before the caller awaits any task cancellation. The
    /// supplied scope must have been issued by this exact catalog.
    public func retire(_ candidate: V2AccountStorageScope) throws {
        try prepare()
        let entry = Entry(version: 1, incarnation: candidate.incarnation, accountID: candidate.accountID.rawValue)
        guard try scope(entry) == candidate else { throw V2AccountStorageError.scopeMismatch }
        if let marker = try read(markerURL(candidate.incarnation)) {
            guard marker == entry else { throw V2AccountStorageError.scopeMismatch }
            return
        }
        guard try active() == entry else { throw V2AccountStorageError.scopeMismatch }
        try JSONEncoder().encode(entry).write(to: markerURL(entry.incarnation), options: .atomic)
        try fileManager.removeItem(at: activeURL)
    }

    /// The asynchronous close boundary makes deletion reviewable: no unlink
    /// occurs unless closing succeeds. A failed close preserves the marker.
    /// New incarnations may be opened while this old scope is draining.
    public func completeCleanup(
        _ candidate: V2AccountStorageScope,
        afterClosing close: @Sendable () async throws -> Void
    ) async throws {
        guard try validateRetired(candidate) else { return }
        try await close()
        guard try validateRetired(candidate) else { return }
        try removeRetired(candidate)
    }

    /// Call only before this process has opened any account pool. Markers are
    /// the durable proof that those old directories must never be reopened.
    public func resumeCleanupBeforeOpeningStores() throws {
        guard !hasIssuedScope else { throw V2AccountStorageError.storesAlreadyOpened }
        try prepare()
        for url in try fileManager.contentsOfDirectory(at: retiredDirectory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "json", let entry = try read(url), url.lastPathComponent == markerURL(entry.incarnation).lastPathComponent else {
                throw V2AccountStorageError.invalidManifest
            }
            try removeRetired(scope(entry))
        }
        recovered = true
    }

    private func validateRetired(_ candidate: V2AccountStorageScope) throws -> Bool {
        let expected = Entry(version: 1, incarnation: candidate.incarnation, accountID: candidate.accountID.rawValue)
        guard try scope(expected) == candidate else { throw V2AccountStorageError.scopeMismatch }
        guard let entry = try read(markerURL(candidate.incarnation)) else {
            guard !fileManager.fileExists(atPath: candidate.directory.path),
                  try active()?.incarnation != candidate.incarnation else { throw V2AccountStorageError.scopeMismatch }
            return false
        }
        guard entry == expected else { throw V2AccountStorageError.scopeMismatch }
        return true
    }
    private func removeRetired(_ candidate: V2AccountStorageScope) throws {
        // Never consult the current account name for the deletion target.
        if fileManager.fileExists(atPath: candidate.directory.path) { try fileManager.removeItem(at: candidate.directory) }
        if try read(activeURL)?.incarnation == candidate.incarnation { try fileManager.removeItem(at: activeURL) }
        try fileManager.removeItem(at: markerURL(candidate.incarnation))
    }
}
