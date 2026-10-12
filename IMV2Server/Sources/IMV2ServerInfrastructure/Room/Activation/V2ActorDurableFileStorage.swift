import Foundation
import IMV2ActorCluster
import NIOPosix
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Exclusive bounded durable bytes shared by control voting and recovery journals.
/// Accepted operations retain the OS lock until their actual worker settles.
package actor V2ActorDurableFileStorage{
    private let path: URL
    private let lock: V2ActorDurableFileLock
    private let pool: NIOThreadPool
    private let maximumBytes: Int
    private var closed = false
    private var active = 0
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var drained: [CheckedContinuation<Void, Never>] = []
    private var closeTask: Task<Void, any Error>?

    private init(path: URL, lock: V2ActorDurableFileLock, pool: NIOThreadPool, maximumBytes: Int) {
        self.path = path; self.lock = lock; self.pool = pool; self.maximumBytes = maximumBytes
    }
    package static func provision(at path: URL, initial: Data, maximumBytes: Int,
                                  pool: NIOThreadPool, validate: @escaping @Sendable (Data) throws -> Void) async throws -> V2ActorDurableFileStorage {
        try await open(at: path, maximumBytes: maximumBytes, pool: pool, initial: initial, validate: validate)
    }
    package static func open(at path: URL, maximumBytes: Int, pool: NIOThreadPool,
                             validate: @escaping @Sendable (Data) throws -> Void) async throws -> V2ActorDurableFileStorage {
        try await open(at: path, maximumBytes: maximumBytes, pool: pool, initial: nil, validate: validate)
    }
    private static func open(at path: URL, maximumBytes: Int, pool: NIOThreadPool,
                             initial: Data?, validate: @escaping @Sendable (Data) throws -> Void) async throws -> V2ActorDurableFileStorage {
        guard path.isFileURL, path.path.hasPrefix("/"), !path.lastPathComponent.isEmpty, maximumBytes > 0 else {
            throw V2PlacementRaftError.invalidConfiguration
        }
        let lock = try await pool.runIfActive {
            let lock = try V2ActorDurableFileLock(path: path)
            do {
                if let initial {
                    guard !initial.isEmpty, initial.count <= maximumBytes else { throw V2PlacementRaftError.capacity }
                    try validate(initial)
                    try write(initial, to: path, creating: true)
                }
                try validate(read(path, maximumBytes: maximumBytes))
                return lock
            } catch { try? lock.release(); throw error }
        }
        return .init(path: path, lock: lock, pool: pool, maximumBytes: maximumBytes)
    }
    package func load() async throws -> Data {
        try await acquire()
        defer { finish() }
        return try await pool.runIfActive { [path, lock, maximumBytes] in
            try lock.requireOpen()
            return try Self.read(path, maximumBytes: maximumBytes)
        }
    }
    package func update<Value: Sendable>(_ operation: @escaping @Sendable (Data) throws -> (Data?, Value)) async throws -> Value {
        try await acquire()
        defer { finish() }
        return try await pool.runIfActive { [path, lock, maximumBytes] in
            try lock.requireOpen()
            let (next, result) = try operation(Self.read(path, maximumBytes: maximumBytes))
            if let next {
                guard !next.isEmpty, next.count <= maximumBytes else { throw V2PlacementRaftError.capacity }
                try Self.write(next, to: path, creating: false)
            } else {
                // A prior rename might have succeeded before directory fsync
                // failed. Retry must confirm durability before returning a
                // stable recovery identity or permitting external exclusion.
                try Self.synchronizeCurrent(path)
            }
            return result
        }
    }
    package func close() async throws {
        closed = true
        if active > 0 { await withCheckedContinuation { drained.append($0) } }
        if closeTask == nil {
            closeTask = Task { [pool, lock] in try await pool.runIfActive { try lock.release() } }
        }
        try await closeTask!.value
    }
    /// Called only after the descriptor has durably removed this generation
    /// from its live set and all of the owner's file workers have drained.
    /// Exact names only; unexpected gate contents or links fail closed.
    package static func removeGeneration(journal: URL, inventory: URL, gate: URL,
                                         pool: NIOThreadPool) async throws {
        try await pool.runIfActive {
            var info = stat()
            let gateExists = lstat(gate.path, &info) == 0
            if !gateExists && errno != ENOENT { throw posixError() }
            let gateFiles = ["hello.pb", "release.pb"]
            if gateExists {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o077 == 0 else {
                    throw V2PlacementRaftError.invalidState
                }
                let allowed = Set(gateFiles + gateFiles.map { $0 + ".lock" })
                guard Set(try FileManager.default.contentsOfDirectory(atPath: gate.path)).isSubset(of: allowed) else {
                    throw V2PlacementRaftError.invalidState
                }
            }
            let paths = [journal, inventory] + (gateExists ? gateFiles.map { gate.appendingPathComponent($0) } : [])
            var locks: [V2ActorDurableFileLock] = []
            defer { for lock in locks { try? lock.release() } }
            for path in paths {
                locks.append(try V2ActorDurableFileLock(path: path))
                if lstat(path.path, &info) == 0 {
                    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw V2PlacementRaftError.invalidState }
                } else if errno != ENOENT { throw posixError() }
            }
            for path in paths {
                if unlink(path.path) != 0 && errno != ENOENT { throw posixError() }
            }
            // Confirm data deletion before unlocking/removing sidecars.
            for parent in Set(paths.map { $0.deletingLastPathComponent() }) { try synchronizeDirectory(parent) }
            for lock in locks { try lock.release() }
            for path in paths {
                if unlink(path.path + ".lock") != 0 && errno != ENOENT { throw posixError() }
            }
            for parent in Set(paths.map { $0.deletingLastPathComponent() }) { try synchronizeDirectory(parent) }
            if gateExists && rmdir(gate.path) != 0 && errno != ENOENT { throw posixError() }
            try synchronizeDirectory(gate.deletingLastPathComponent())
        }
    }
    private func acquire() async throws {
        guard !closed else { throw V2PlacementRaftError.closed }
        guard waiting.count < 128 else { throw V2PlacementRaftError.capacity }
        active += 1
        if !busy { busy = true; return }
        // Accepted operations retain their place and the file lock until the
        // real worker settles, including cancellation and concurrent close.
        await withCheckedContinuation { waiting.append($0) }
    }
    private func finish() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        active -= 1
        if active == 0 {
            let pending = drained; drained.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    private static func read(_ path: URL, maximumBytes: Int) throws -> Data {
        let fd = path.path.withCString { systemOpen($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw posixError() }
        defer { _ = systemClose(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0 else { throw posixError() }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_size > 0,
              attributes.st_size <= maximumBytes else { throw V2PlacementRaftError.invalidState }
        var bytes = Data(count: Int(attributes.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = systemRead(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw count == 0 ? POSIXError(.EIO) : posixError() }
                offset += count
            }
        }
        return bytes
    }
    private static func write(_ bytes: Data, to path: URL, creating: Bool) throws {
        let directory = path.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".actor-" + UUID().uuidString)
        let fd = temporary.path.withCString { systemOpen($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw posixError() }
        defer { _ = systemClose(fd); _ = temporary.path.withCString { unlink($0) } }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = systemWrite(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw count == 0 ? POSIXError(.EIO) : posixError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
        let installed: Int32
        if creating {
            // link is exclusive: provisioning cannot replace existing history.
            installed = temporary.path.withCString { source in path.path.withCString { target in link(source, target) } }
        } else {
            installed = temporary.path.withCString { source in path.path.withCString { target in rename(source, target) } }
        }
        guard installed == 0 else { throw posixError() }
        try synchronizeDirectory(directory)
    }
    private static func synchronizeCurrent(_ path: URL) throws {
        let fd = path.path.withCString { systemOpen($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw posixError() }
        defer { _ = systemClose(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
        try synchronizeDirectory(path.deletingLastPathComponent())
    }
    private static func synchronizeDirectory(_ directory: URL) throws {
        let directoryFD = directory.path.withCString { systemOpen($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw posixError() }
        defer { _ = systemClose(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw posixError() }
    }
    private static func posixError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
}

/// Only the owning storage's final close task (or failed open) calls release.
/// Capturing this box retains the OS lock through actual worker completion.
private final class V2ActorDurableFileLock: @unchecked Sendable {
    private let descriptor: Int32
    private var released = false
    init(path: URL) throws {
        let fd = (path.path + ".lock").withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO); _ = systemClose(fd); throw error
        }
        descriptor = fd
    }
    func requireOpen() throws { guard !released else { throw V2PlacementRaftError.closed } }
    func release() throws {
        guard !released else { return }
        released = true
        let unlocked = flock(descriptor, LOCK_UN), ended = systemClose(descriptor)
        guard unlocked == 0, ended == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    deinit { if !released { _ = flock(descriptor, LOCK_UN); _ = systemClose(descriptor) } }
}

private func systemClose(_ fd: Int32) -> Int32 {
#if canImport(Darwin)
    Darwin.close(fd)
#else
    Glibc.close(fd)
#endif
}
private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(fd, buffer, count)
#else
    Glibc.read(fd, buffer, count)
#endif
}
private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.write(fd, buffer, count)
#else
    Glibc.write(fd, buffer, count)
#endif
}

private func systemOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
#if canImport(Darwin)
    Darwin.open(path, flags, mode)
#else
    Glibc.open(path, flags, mode)
#endif
}
