import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Deterministic private local adapter. Unique immutable keys and permanent delete fences
/// provide exact-version semantics without a vendor version API.
public struct V2LocalResourceStorage: V2ObjectStorage {
    public let binding: V2StorageBinding
    private let root: URL
    public init(root: URL, binding: V2StorageBinding) throws {
        guard root.isFileURL else { throw V2ResourceProviderError.configurationInvalid }
        self.root = root.standardizedFileURL; self.binding = binding
    }
    static func stream(file: URL) async throws -> V2ResourceByteStream {
        let input = try await V2PinnedLocalMediaFile.blocking { try V2PinnedLocalMediaFile(file: file) }
        return input.stream()
    }
    public func allocate(placementID: UUID = UUID()) throws -> V2StoredObjectReference {
        try .init(placementID: placementID, binding: binding, handle: Data(placementID.uuidString.lowercased().utf8))
    }
    private func url(_ reference: V2StoredObjectReference) throws -> URL {
        guard reference.binding == binding, reference.formatVersion == 1,
              String(data: reference.handle, encoding: .utf8) == reference.placementID.uuidString.lowercased()
        else { throw V2ResourceProviderError.configurationInvalid }
        return root.appendingPathComponent(reference.placementID.uuidString.lowercased())
    }
    public func inspect(_ reference: V2StoredObjectReference) async throws -> V2StoredObjectFacts {
        let file = try url(reference)
        return try await V2PinnedLocalMediaFile.blocking {
            try Self.withLock(file) {
                try Self.requireNotDeleted(file)
                let input = try Self.openResource(file)
                return try .init(reference: reference, byteCount: input.byteCount, sha256: input.digest())
            }
        }
    }
    public func read(_ reference: V2StoredObjectReference) async throws -> V2ResourceByteStream {
        let file = try url(reference)
        let input = try await V2PinnedLocalMediaFile.blocking {
            try Self.withLock(file) {
                try Self.requireNotDeleted(file)
                return try Self.openResource(file)
            }
        }
        return input.stream()
    }
    public func write(_ reference: V2StoredObjectReference, byteCount: Int64, sha256: Data, bytes: V2ResourceByteStream) async throws -> V2StoredObjectFacts {
        guard byteCount > 0, sha256.count == 32 else { throw V2ResourceProviderError.integrityMismatch }
        let file = try url(reference)
        let temporary = file.appendingPathExtension(UUID().uuidString + ".partial")
        let writer = try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return try LocalResourceWriter(file: temporary)
        }.value
        do {
            var count: Int64 = 0
            var hash = SHA256()
            while let chunk = try await bytes.next() {
                guard !chunk.isEmpty, Int64(chunk.count) <= byteCount - count else { throw V2ResourceProviderError.integrityMismatch }
                count += Int64(chunk.count); hash.update(data: chunk)
                try await writer.append(chunk)
            }
            guard count == byteCount, Data(hash.finalize()) == sha256 else { throw V2ResourceProviderError.integrityMismatch }
            try await writer.finish()
            try await Task.detached(priority: .utility) {
                try Self.withLock(file) {
                    guard !FileManager.default.fileExists(atPath: file.appendingPathExtension("deleted").path) else { throw V2ResourceProviderError.preconditionFailed }
                    if FileManager.default.fileExists(atPath: file.path) {
                        guard (try? ForwardMediaFileIO.digest(file, byteCount: byteCount)) == sha256 else { throw V2ResourceProviderError.integrityMismatch }
                    } else {
                        // All publishers and deleters share this object lock. A same-directory
                        // rename publishes one link without leaving a second alias after a crash.
                        guard rename(temporary.path, file.path) == 0 else {
                            throw POSIXError(.init(rawValue: errno) ?? .EIO)
                        }
                        try ForwardMediaFileIO.syncDirectory(file.deletingLastPathComponent())
                    }
                }
            }.value
            await writer.discard()
            return try .init(reference: reference, byteCount: byteCount, sha256: sha256)
        } catch {
            await writer.discard()
            throw error
        }
    }
    public func delete(_ reference: V2StoredObjectReference) async throws {
        let file = try url(reference)
        try await Task.detached(priority: .utility) {
            try Self.withLock(file) {
                let tombstone = file.appendingPathExtension("deleted")
                if !FileManager.default.fileExists(atPath: tombstone.path) {
                    try Data().write(to: tombstone, options: .withoutOverwriting)
                }
                try ForwardMediaFileIO.syncDirectory(file.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                try ForwardMediaFileIO.syncDirectory(file.deletingLastPathComponent())
            }
        }.value
    }
    private static func openResource(_ file: URL) throws -> V2PinnedLocalMediaFile {
        do { return try V2PinnedLocalMediaFile(file: file) }
        catch is V2LocalFilesystemMediaProviderError { throw V2ResourceProviderError.notFound }
    }
    private static func requireNotDeleted(_ file: URL) throws {
        var attributes = stat()
        guard lstat(file.appendingPathExtension("deleted").path, &attributes) < 0 else {
            throw V2ResourceProviderError.notFound
        }
        guard errno == ENOENT else { throw V2ResourceProviderError.temporarilyUnavailable }
    }
    private static func withLock<T>(_ file: URL, body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw V2ResourceProviderError.temporarilyUnavailable }
        defer { _ = close(directory) }
        let fd = (file.lastPathComponent + ".lock").withCString { name in
            let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            let created = openat(directory, name, flags | O_CREAT | O_EXCL, 0o600)
            guard created < 0 else { return created }
            // Another publisher may create the permanent lock concurrently. Open
            // that entry without creation; never replace it or follow a link.
            guard errno == EEXIST || errno == ENOENT else { return Int32(-1) }
            return openat(directory, name, flags)
        }
        guard fd >= 0 else { throw V2ResourceProviderError.temporarilyUnavailable }
        defer { _ = close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_nlink == 1 else { throw V2ResourceProviderError.temporarilyUnavailable }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw V2ResourceProviderError.temporarilyUnavailable }
            try Task.checkCancellation()
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}

private actor LocalResourceWriter {
    private let file: URL
    private let handle: FileHandle
    init(file: URL) throws {
        try Data().write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        self.file = file; handle = try FileHandle(forWritingTo: file)
    }
    func append(_ data: Data) async throws {
        let handle = self.handle
        try await Task.detached(priority: .utility) { try handle.write(contentsOf: data) }.value
    }
    func finish() async throws {
        let handle = self.handle
        try await Task.detached(priority: .utility) { try handle.synchronize(); try handle.close() }.value
    }
    func discard() async {
        let handle = self.handle; let file = self.file
        await Task.detached(priority: .utility) { try? handle.close(); try? FileManager.default.removeItem(at: file) }.value
    }
}
