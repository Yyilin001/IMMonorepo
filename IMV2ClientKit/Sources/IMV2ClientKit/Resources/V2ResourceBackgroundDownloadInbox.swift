import Foundation
import IMV2Core
import Synchronization

/// Synchronous OS-callback boundary of FileStore. Its small AFU permit is
/// written only after durable capacity admission, before the task can resume.
/// Receiving bytes never opens business SQLite or confers read permission.
struct V2ResourceBackgroundDownloadInbox: Sendable {
    struct Permit: Codable, Equatable, Sendable {
        enum State: Codable, Equatable, Sendable {
            case prepared
            case installed(Int)
            case received(Int)
            var identifier: Int? { switch self { case .prepared: nil; case .installed(let id), .received(let id): id } }
        }
        let version: Int
        let reservationID: UUID, mappingID: UUID, sessionID: UUID
        let grant: V2ResourceBackgroundDownloadAuthorization
        let originDigest: String
        var state: State
        var expectedBytes: Int64 { grant.expectedByteCount }
        var checksum: V2ResourceChecksum { grant.checksum }
        var expiresAtMilliseconds: Int64 { grant.expiresAtMilliseconds }
    }
    let directory: URL
    private let root: URL
    private let sessionID: UUID
    private let protection: any V2ResourceFileProtectionWriting
    private static let io = Mutex(())
    init(root: URL, sessionID: UUID, protection: any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) {
        self.root = root.standardizedFileURL; self.sessionID = sessionID; self.protection = protection
        directory = root.appending(path: "downloads").appending(path: sessionID.uuidString)
    }
    func prepare(reservation: UUID, mapping: UUID, grant: V2ResourceBackgroundDownloadAuthorization, origin: String) throws {
        try Self.io.withLock { _ in
            guard Double(grant.expiresAtMilliseconds) > Date().timeIntervalSince1970 * 1000 else { throw V2BackgroundTransferError.invalidAuthorization }
            try prepareDirectories()
            guard !FileManager.default.fileExists(atPath: permitURL(mapping).path), try entries().count < 16 else { throw V2BackgroundTransferError.capacityExceeded }
            try write(.init(version: 1, reservationID: reservation, mappingID: mapping, sessionID: sessionID,
                grant: grant, originDigest: origin, state: .prepared))
        }
    }
    func install(mapping: UUID, identifier: Int) throws {
        try Self.io.withLock { _ in
            guard identifier >= 0 else { throw V2BackgroundTransferError.mappingConflict }
            var permit = try read(mapping)
            if let existing = permit.state.identifier {
                guard existing == identifier else { throw V2BackgroundTransferError.mappingConflict }; return
            }
            permit.state = .installed(identifier)
            try write(permit)
        }
    }
    func permit(_ mapping: UUID) throws -> Permit { try Self.io.withLock { _ in try read(mapping) } }
    func permits() throws -> [Permit] {
        try Self.io.withLock { _ in
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try entries().map { try read($0) }
        }
    }
    func fileURL(_ mapping: UUID) -> URL { directory.appending(path: "files").appending(path: mapping.uuidString) }

    /// Called synchronously before URLSession releases its temporary URL.
    /// No hashing or authorization occurs while locked; full verification and
    /// a fresh access grant remain prerequisites for account publication.
    func receive(_ location: URL, mapping: UUID, identifier: Int, origin: String?) throws {
        try Self.io.withLock { _ in
            var permit = try read(mapping)
            guard permit.state == .installed(identifier), origin == permit.originDigest else { throw V2BackgroundTransferError.mappingConflict }
            let facts = try location.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard facts.isRegularFile == true, facts.isSymbolicLink == false, let size = facts.fileSize,
                  Int64(size) == permit.expectedBytes else { throw V2ClientMediaTransferError.byteCountMismatch }
            let target = fileURL(mapping)
            // Only existing, admitted directories may receive. A late callback
            // cannot recreate a retired account or revive a revoked permit.
            try requireDirectory(target.deletingLastPathComponent())
            guard !FileManager.default.fileExists(atPath: target.path) else { throw V2BackgroundTransferError.mappingConflict }
            try FileManager.default.moveItem(at: location, to: target)
            try protection.apply(.untilFirstAuthentication, to: target)
            try V2LocalBackupExclusion.apply(to: target)
            let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }; try handle.synchronize()
            try V2ResourceDirectoryIO.synchronize(target.deletingLastPathComponent())
            permit.state = .received(identifier)
            try write(permit)
        }
    }
    /// FileStore calls only after the actual task drained and all account byte
    /// consumers ended. Revoke first, so callbacks cannot recreate the file.
    func discard(_ mapping: UUID) throws {
        try Self.io.withLock { _ in
            try remove(permitURL(mapping))
            try remove(fileURL(mapping))
        }
    }
    func allocatedBytes(_ mapping: UUID) throws -> Int64 {
        try Self.io.withLock { _ in
            try [fileURL(mapping), permitURL(mapping)].reduce(Int64(0)) { total, file in
                guard FileManager.default.fileExists(atPath: file.path) else { return total }
                try requireRegular(file)
                let facts = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey,.fileAllocatedSizeKey,.fileSizeKey])
                return total + Int64(facts.totalFileAllocatedSize ?? facts.fileAllocatedSize ?? facts.fileSize ?? 0)
            }
        }
    }
    private func entries() throws -> [UUID] {
        try requireDirectory(directory)
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]) else { throw V2ResourceStorageError.unavailable }
        var result: [UUID] = [], count = 0
        for case let url as URL in iterator {
            guard count < 256 else { throw V2BackgroundTransferError.capacityExceeded }; count += 1
            if url.pathExtension == "permit" {
                guard result.count < 16, let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw V2BackgroundTransferError.mappingConflict }
                result.append(id)
            }
        }
        return result
    }
    private func read(_ mapping: UUID) throws -> Permit {
        let file = permitURL(mapping)
        try requireRegular(file)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 2048 else { throw V2BackgroundTransferError.mappingConflict }
        let data = try Data(contentsOf: file, options: .uncached)
        guard data.count <= 2048 else { throw V2BackgroundTransferError.mappingConflict }
        let permit = try JSONDecoder().decode(Permit.self, from: data)
        guard permit.version == 1, permit.mappingID == mapping, permit.sessionID == sessionID,
              permit.expectedBytes > 0, permit.expectedBytes <= 512 * 1024 * 1024,
              permit.originDigest.utf8.count == 64, permit.originDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              permit.state.identifier.map({ $0 >= 0 }) ?? true else { throw V2BackgroundTransferError.mappingConflict }
        return permit
    }
    private func write(_ permit: Permit) throws {
        try requireDirectory(directory)
        let data = try JSONEncoder().encode(permit)
        guard data.count <= 2048 else { throw V2BackgroundTransferError.mappingConflict }
        let file = permitURL(permit.mappingID)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try protection.apply(.untilFirstAuthentication, to: file)
        try V2LocalBackupExclusion.apply(to: file)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
        try V2ResourceDirectoryIO.synchronize(directory)
    }
    private func prepareDirectories() throws {
        for item in [root, root.appending(path: "downloads"), directory, directory.appending(path: "files")] {
            guard item.deletingLastPathComponent().resolvingSymlinksInPath().path == item.deletingLastPathComponent().standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
            if !FileManager.default.fileExists(atPath: item.path) {
                try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try requireDirectory(item)
            try protection.apply(.untilFirstAuthentication, to: item)
            try V2LocalBackupExclusion.apply(to: item)
        }
    }
    private func requireDirectory(_ url: URL) throws {
        let facts = try url.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
        guard facts.isDirectory == true, facts.isSymbolicLink == false, url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
    }
    private func requireRegular(_ url: URL) throws {
        try requireDirectory(url.deletingLastPathComponent())
        let facts = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
        guard facts.isRegularFile == true, facts.isSymbolicLink == false else { throw V2ResourceStorageError.unsafeFile }
    }
    private func remove(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try requireRegular(file)
        try FileManager.default.removeItem(at: file)
        try V2ResourceDirectoryIO.synchronize(file.deletingLastPathComponent())
    }
    private func permitURL(_ mapping: UUID) -> URL { directory.appending(path: mapping.uuidString + ".permit") }
}
