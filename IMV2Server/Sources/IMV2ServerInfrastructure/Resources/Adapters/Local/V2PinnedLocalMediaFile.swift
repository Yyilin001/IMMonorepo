import Crypto
import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Pins one ordinary file beneath an opened directory. The configured directory's
/// ancestors must be trusted; its entries may be renamed/replaced by another process.
/// The immutable descriptor is only closed at deinit, and pread never shares an offset.
/// A strong reference held by each blocking operation prevents concurrent close/reuse.
final class V2PinnedLocalMediaFile: @unchecked Sendable {
    private let descriptor: Int32
    let byteCount: Int64

    init(file: URL, purgeMarkerDirectory: String? = nil) throws {
        guard file.isFileURL, !file.lastPathComponent.isEmpty,
              file.lastPathComponent != ".", file.lastPathComponent != ".." else {
            throw V2LocalFilesystemMediaProviderError.objectUnavailable
        }
        let directory = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw V2LocalFilesystemMediaProviderError.objectUnavailable }
        defer { _ = close(directory) }
        if let purgeMarkerDirectory {
            try Self.requireNotPurged(in: directory, state: purgeMarkerDirectory, name: file.lastPathComponent)
        }
        let opened = openat(directory, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard opened >= 0 else { throw V2LocalFilesystemMediaProviderError.objectUnavailable }
        do {
            var attributes = stat()
            guard fstat(opened, &attributes) == 0,
                  attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  attributes.st_size >= 0, attributes.st_nlink == 1 else {
                throw V2LocalFilesystemMediaProviderError.objectUnavailable
            }
            if let purgeMarkerDirectory {
                try Self.requireNotPurged(in: directory, state: purgeMarkerDirectory, name: file.lastPathComponent)
            }
            descriptor = opened
            byteCount = Int64(attributes.st_size)
        } catch {
            _ = close(opened)
            throw error
        }
    }

    deinit { _ = close(descriptor) }

    private static func requireNotPurged(in directory: Int32, state: String, name: String) throws {
        let stateDirectory = openat(directory, state, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if stateDirectory < 0 {
            guard errno == ENOENT else { throw V2LocalFilesystemMediaProviderError.objectUnavailable }
            return
        }
        defer { _ = close(stateDirectory) }
        var attributes = stat()
        let result = fstatat(stateDirectory, name + ".purged", &attributes, AT_SYMLINK_NOFOLLOW)
        guard result < 0, errno == ENOENT else { throw V2LocalFilesystemMediaProviderError.objectUnavailable }
    }

    /// A short read is allowed; an early EOF or changed length is never accepted.
    func read(offset: Int64, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset <= byteCount, maximumBytes > 0 else {
            throw V2LocalFilesystemMediaProviderError.objectUnavailable
        }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, Int64(attributes.st_size) == byteCount else {
            throw V2LocalFilesystemMediaProviderError.objectUnavailable
        }
        guard offset < byteCount else { return Data() }
        var data = Data(count: Int(min(Int64(min(maximumBytes, 65_536)), byteCount - offset)))
        let count: Int = try data.withUnsafeMutableBytes { buffer in
            while true {
                let count = pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
                if count < 0, errno == EINTR { try Task.checkCancellation(); continue }
                guard count > 0 else { throw V2LocalFilesystemMediaProviderError.objectUnavailable }
                return count
            }
        }
        data.count = count
        return data
    }

    func digest() throws -> Data {
        var hash = SHA256()
        var offset: Int64 = 0
        repeat {
            let chunk = try read(offset: offset, maximumBytes: 65_536)
            guard !chunk.isEmpty else { break }
            hash.update(data: chunk)
            offset += Int64(chunk.count)
        } while offset < byteCount
        return Data(hash.finalize())
    }

    func allBytes() throws -> Data {
        var result = Data()
        repeat {
            let chunk = try read(offset: Int64(result.count), maximumBytes: 65_536)
            guard !chunk.isEmpty else { break }
            result.append(chunk)
        } while Int64(result.count) < byteCount
        return result
    }

    func stream() -> V2ResourceByteStream {
        let reader = V2PinnedLocalMediaReader(file: self)
        return .init { try await reader.next() }
    }

    /// Owns and drains blocking filesystem work, including cancellation.
    static func blocking<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let operation = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler {
            let value = try await operation.value
            try Task.checkCancellation()
            return value
        } onCancel: { operation.cancel() }
    }
}

private actor V2PinnedLocalMediaReader {
    private let file: V2PinnedLocalMediaFile
    private var offset: Int64 = 0
    private var reading = false
    init(file: V2PinnedLocalMediaFile) { self.file = file }
    func next() async throws -> Data? {
        try Task.checkCancellation()
        guard !reading else { throw V2ResourceProviderError.preconditionFailed }
        reading = true
        defer { reading = false }
        let file = file, offset = offset
        let bytes = try await V2PinnedLocalMediaFile.blocking { try file.read(offset: offset, maximumBytes: 65_536) }
        self.offset += Int64(bytes.count)
        return bytes.isEmpty ? nil : bytes
    }
}
