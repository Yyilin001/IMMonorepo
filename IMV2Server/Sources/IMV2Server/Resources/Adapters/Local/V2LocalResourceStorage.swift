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
        let reader = try await Task.detached(priority: .utility) { try LocalResourceReader(file: file) }.value
        return .init { try await reader.next() }
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
        return try await Task.detached(priority: .utility) {
            try Self.withLock(file) {
                guard !FileManager.default.fileExists(atPath: file.appendingPathExtension("deleted").path),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let size = attributes[.size] as? NSNumber else { throw V2ResourceProviderError.notFound }
                let digest = try ForwardMediaFileIO.digest(file, byteCount: size.int64Value)
                return try .init(reference: reference, byteCount: size.int64Value, sha256: digest)
            }
        }.value
    }
    public func read(_ reference: V2StoredObjectReference) async throws -> V2ResourceByteStream {
        let file = try url(reference)
        let reader = try await Task.detached(priority: .utility) {
            try Self.withLock(file) {
                guard !FileManager.default.fileExists(atPath: file.appendingPathExtension("deleted").path) else { throw V2ResourceProviderError.notFound }
                return try LocalResourceReader(file: file)
            }
        }.value
        return .init { try await reader.next() }
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
                        try FileManager.default.linkItem(at: temporary, to: file)
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
    private static func withLock<T>(_ file: URL, body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw V2ResourceProviderError.temporarilyUnavailable }
        defer { _ = close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw V2ResourceProviderError.temporarilyUnavailable }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}

private actor LocalResourceReader {
    private let handle: FileHandle
    init(file: URL) throws { handle = try FileHandle(forReadingFrom: file) }
    deinit { try? handle.close() }
    func next() async throws -> Data? {
        let handle = self.handle
        return try await Task.detached(priority: .utility) {
            let value = try handle.read(upToCount: 65_536)
            return value?.isEmpty == true ? nil : value
        }.value
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
