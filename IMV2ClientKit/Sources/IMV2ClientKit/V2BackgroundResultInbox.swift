import Darwin
import Foundation
import CryptoKit
import os

/// Minimal cross-process handoff. This dedicated tree uses UntilFirstAuthentication;
/// the business database, original sources and credentials keep their original protection.
public struct V2BackgroundResultInbox: Sendable {
    public let directory: URL
    private let root: URL
    private let protectionWriter:any V2ResourceFileProtectionWriting
    private static let io = OSAllocatedUnfairLock(initialState: ())
    public init(root: URL, sessionID: UUID, protectionWriter:any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) throws {
        self.protectionWriter=protectionWriter
        guard root.isFileURL, root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        self.root = root.standardizedFileURL
        directory=self.root.appendingPathComponent(sessionID.uuidString,isDirectory:true)
        try Self.io.withLock { [self] _ in
            for item in [self.root, directory] {
                if try !exists(item, type: .typeDirectory) {
                    try FileManager.default.createDirectory(at:item,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                }
                try requireDirectory(item)
                try protectionWriter.apply(.untilFirstAuthentication,to:item)
                try V2LocalBackupExclusion.apply(to:item)
            }
            try V2ResourceDirectoryIO.synchronize(self.root)
        }
    }
    public func write(_ result:V2BackgroundTransferResult) throws {
        let data=try JSONEncoder().encode(result)
        guard data.count<=2048 else { throw V2BackgroundTransferError.mappingConflict }
        try Self.io.withLock { [self] _ in
            try requireOwnedDirectories()
            let file = resultURL(result.mappingID)
            let replacing = try exists(file, type: .typeRegular)
            if !replacing {
                guard try entries().count < 128 else { throw V2BackgroundTransferError.capacityExceeded }
            }
            let staged = directory.appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            try data.write(to: staged, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            try protectionWriter.apply(.untilFirstAuthentication, to: staged)
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            try output.synchronize()
            guard rename(staged.path, file.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            // A directory sync error leaves the fully prepared receipt in place.
            try V2ResourceDirectoryIO.synchronize(directory)
        }
    }
    public func results() throws -> [V2BackgroundTransferResult] {
        try Self.io.withLock { [self] _ in
            try requireOwnedDirectories()
            return try entries().sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
                try readReceipt(at: $0)
            }
        }
    }

    func result(for id: UUID) throws -> V2BackgroundTransferResult? {
        try Self.io.withLock { [self] _ in
            try requireOwnedDirectories()
            do { return try readReceipt(at: resultURL(id)) }
            catch V2ResourceStorageError.unsafeFile { return nil }
        }
    }

    private func readReceipt(at file: URL) throws -> V2BackgroundTransferResult? {
        guard try exists(file, type: .typeRegular) else { return nil }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let data = try input.read(upToCount: 2049) ?? Data()
        guard data.count <= 2048,
              let result = try? JSONDecoder().decode(V2BackgroundTransferResult.self, from: data),
              result.mappingID.uuidString == file.deletingPathExtension().lastPathComponent else {
            // Only the journal/driver may establish completion. Missing evidence
            // goes through their existing reconciliation and retry path.
            try removeRegular(file)
            return nil
        }
        return result
    }
    public func remove(_ id:UUID) throws {
        try Self.io.withLock { [self] _ in
            try requireOwnedDirectories()
            try removeRegular(resultURL(id))
        }
    }
    /// Reconciliation ignores invalid leaf entries, just like discovery. Never follow or unlink them.
    func discardReceipt(for id: UUID) throws {
        try Self.io.withLock { [self] _ in
            try requireOwnedDirectories()
            do { try removeRegular(resultURL(id)) }
            catch V2ResourceStorageError.unsafeFile { return }
        }
    }
    private func resultURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".result") }
    private func requireOwnedDirectories() throws { try requireDirectory(root); try requireDirectory(directory) }
    private func requireDirectory(_ url: URL) throws {
        guard try exists(url, type: .typeDirectory) else { throw V2ResourceStorageError.unavailable }
    }
    private func exists(_ url: URL, type: FileAttributeType) throws -> Bool {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return false }
        guard attributes[.type] as? FileAttributeType == type else { throw V2ResourceStorageError.unsafeFile }
        return true
    }
    private func entries() throws -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]) else { throw V2ResourceStorageError.unavailable }
        var files: [URL] = [], scanned = 0
        for case let file as URL in iterator {
            guard scanned < 256 else { throw V2BackgroundTransferError.capacityExceeded }
            scanned += 1
            guard file.pathExtension == "result" else { continue }
            // Ignore unsafe entries during discovery. Direct access still rejects them.
            guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
                  try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { continue }
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  id.uuidString == file.deletingPathExtension().lastPathComponent else {
                try removeRegular(file)
                continue
            }
            guard files.count < 128 else { throw V2BackgroundTransferError.capacityExceeded }
            files.append(file)
        }
        return files
    }
    private func removeRegular(_ file: URL) throws {
        guard try exists(file, type: .typeRegular) else { return }
        try FileManager.default.removeItem(at: file)
        try V2ResourceDirectoryIO.synchronize(directory)
    }
    public static func originDigest(_ url:URL?) -> String? {
        guard let url,let host=url.host,url.scheme?.lowercased()=="https" else { return nil }
        return SHA256.hash(data:Data("https|\(host.lowercased())|\(url.port ?? 443)".utf8)).map { String(format:"%02x",$0) }.joined()
    }
}
