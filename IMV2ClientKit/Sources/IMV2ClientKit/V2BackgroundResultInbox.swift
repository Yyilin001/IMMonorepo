import Foundation
import CryptoKit
import Synchronization

/// Minimal cross-process handoff. This dedicated tree uses UntilFirstAuthentication;
/// the business database, original sources and credentials keep their original protection.
public struct V2BackgroundResultInbox: Sendable {
    public let directory: URL
    private let root: URL
    private let protectionWriter:any V2ResourceFileProtectionWriting
    private static let io = Mutex(())
    public init(root: URL, sessionID: UUID, protectionWriter:any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) throws {
        self.protectionWriter=protectionWriter
        guard root.isFileURL, root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        self.root = root.standardizedFileURL
        directory=self.root.appendingPathComponent(sessionID.uuidString,isDirectory:true)
        try Self.io.withLock { _ in
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
        try Self.io.withLock { _ in
            try requireOwnedDirectories()
            let file = resultURL(result.mappingID)
            let replacing = try exists(file, type: .typeRegular)
            if !replacing {
                guard try entries().count < 128 else { throw V2BackgroundTransferError.capacityExceeded }
            }
            var published = false
            do {
                try data.write(to:file,options:.atomic)
                published = true
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                try protectionWriter.apply(.untilFirstAuthentication,to:file)
                let output=try FileHandle(forWritingTo:file);defer {try? output.close()};try output.synchronize()
                try V2ResourceDirectoryIO.synchronize(directory)
            } catch {
                // A failed atomic write cannot justify deleting a pre-existing
                // receipt or an unexpected directory at the destination.
                if published { try? removeRegular(file) }
                throw error
            }
        }
    }
    public func results() throws -> [V2BackgroundTransferResult] {
        try Self.io.withLock { _ in
            try requireOwnedDirectories()
            return try entries().sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                let data = try input.read(upToCount: 2049) ?? Data()
                guard !data.isEmpty, data.count <= 2048,
                      let result = try? JSONDecoder().decode(V2BackgroundTransferResult.self, from: data),
                      result.mappingID.uuidString == file.deletingPathExtension().lastPathComponent else {
                    throw V2BackgroundTransferError.mappingConflict
                }
                return result
            }
        }
    }
    public func remove(_ id:UUID) throws {
        try Self.io.withLock { _ in
            try requireOwnedDirectories()
            try removeRegular(resultURL(id))
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
            guard files.count < 128 else { throw V2BackgroundTransferError.capacityExceeded }
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  id.uuidString == file.deletingPathExtension().lastPathComponent else { throw V2BackgroundTransferError.mappingConflict }
            guard try exists(file, type: .typeRegular) else { throw V2BackgroundTransferError.mappingConflict }
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
