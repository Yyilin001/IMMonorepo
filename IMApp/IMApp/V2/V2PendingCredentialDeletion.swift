import Foundation
import CryptoKit

/// Only non-sensitive intent is persisted, never tokens or account identity.
/// Failure to read or commit the marker must not be treated as signed out.
protocol V2PendingCredentialDeletionStoring: Sendable {
    func isPending() async throws -> Bool
    func markPending() async throws
    func clearPending() async throws
}

enum V2PendingCredentialDeletionError: Error { case invalidRecord }

/// Atomic file replacement and an explicit flush finish before the caller
/// may delete credentials. A cleared record remains authoritative over an
/// old UserDefaults flag, including when preference removal has not flushed.
actor V2FilePendingCredentialDeletionStore: V2PendingCredentialDeletionStoring {
    static func fileURL(databaseURL: URL, legacyKey: String) -> URL {
        let serviceHash = SHA256.hash(data: Data(legacyKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return databaseURL.appendingPathExtension("credential-deletion-" + serviceHash + ".json")
    }
    private struct Record: Codable {
        let version: Int
        let pending: Bool
    }
    private let url: URL
    private let defaults: UserDefaults
    private let legacyKey: String

    init(url: URL, defaults: UserDefaults = .standard, legacyKey: String) {
        self.url = url
        self.defaults = defaults
        self.legacyKey = legacyKey
    }

    func isPending() throws -> Bool {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile {
            guard defaults.bool(forKey: legacyKey) else { return false }
            try markPending()
            return true
        }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw V2PendingCredentialDeletionError.invalidRecord }
        guard record.version == 1 else { throw V2PendingCredentialDeletionError.invalidRecord }
        return record.pending
    }

    func markPending() throws { try write(pending: true) }
    func clearPending() throws { try write(pending: false) }

    private func write(pending: Bool) throws {
        _ = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(Record(version: 1, pending: pending)).write(to: url, options: .atomic)
        try V2DeviceLocalStoragePolicy.applyToManagedFile(url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        defaults.removeObject(forKey: legacyKey)
    }
}
