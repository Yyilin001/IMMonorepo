import Foundation
import CryptoKit

/// Minimal cross-process handoff. This directory alone uses UntilFirstAuthentication;
/// the business database, original sources and credentials keep their original protection.
public struct V2BackgroundResultInbox: Sendable {
    public let directory: URL
    private let protectionWriter:any V2ResourceFileProtectionWriting
    public init(root: URL, sessionID: UUID, protectionWriter:any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) throws {
        self.protectionWriter=protectionWriter
        directory=root.appendingPathComponent(sessionID.uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var excluded=directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
        try protectionWriter.apply(.untilFirstAuthentication,to:directory)
    }
    public func write(_ result:V2BackgroundTransferResult) throws {
        let data=try JSONEncoder().encode(result)
        guard data.count<=2048 else { throw V2BackgroundTransferError.mappingConflict }
        let file=directory.appendingPathComponent(result.mappingID.uuidString+".result")
        // Duplicates replace the same opaque result, bounding inbox growth per system mapping.
        do {
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        try protectionWriter.apply(.untilFirstAuthentication,to:file)
        let output=try FileHandle(forWritingTo:file);defer {try? output.close()};try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at:file)
            throw error
        }
    }
    public func results() throws -> [V2BackgroundTransferResult] {
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey])
            .filter { $0.pathExtension=="result" }.sorted { $0.lastPathComponent<$1.lastPathComponent }
        guard files.count<=128 else { throw V2BackgroundTransferError.capacityExceeded }
        return try files.map { file in
            guard try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 2048 else { throw V2BackgroundTransferError.mappingConflict }
            return try JSONDecoder().decode(V2BackgroundTransferResult.self,from:Data(contentsOf:file))
        }
    }
    public func remove(_ id:UUID) throws { let file=directory.appendingPathComponent(id.uuidString+".result");if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) } }
    public static func originDigest(_ url:URL?) -> String? {
        guard let url,let host=url.host,url.scheme?.lowercased()=="https" else { return nil }
        return SHA256.hash(data:Data("https|\(host.lowercased())|\(url.port ?? 443)".utf8)).map { String(format:"%02x",$0) }.joined()
    }
}
