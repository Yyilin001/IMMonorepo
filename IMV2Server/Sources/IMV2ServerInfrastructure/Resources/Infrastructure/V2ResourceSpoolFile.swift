import Crypto
import Foundation
import IMV2ServerApplication

/// Private bounded disk staging for providers which must verify bytes before publication.
struct V2ResourceSpoolFile: Sendable {
    let url: URL
    let sha256: Data

    static func create(bytes: V2ResourceByteStream, byteCount: Int64) async throws -> Self {
        guard byteCount > 0, byteCount <= 256 * 1_024 * 1_024 else { throw V2ResourceProviderError.integrityMismatch }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-resource-spool-" + UUID().uuidString)
        let url = directory.appendingPathComponent("body")
        let handle = try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                return try FileHandle(forWritingTo: url)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }.value
        do {
            var count: Int64 = 0
            var hash = SHA256()
            while let chunk = try await bytes.next() {
                guard !chunk.isEmpty, Int64(chunk.count) <= byteCount - count else { throw V2ResourceProviderError.integrityMismatch }
                count += Int64(chunk.count); hash.update(data: chunk)
                try await Task.detached(priority: .utility) { try handle.write(contentsOf: chunk) }.value
            }
            guard count == byteCount else { throw V2ResourceProviderError.integrityMismatch }
            try await Task.detached(priority: .utility) { try handle.close() }.value
            return .init(url: url, sha256: Data(hash.finalize()))
        } catch {
            await Task.detached(priority: .utility) { try? handle.close(); try? FileManager.default.removeItem(at: directory) }.value
            throw error
        }
    }
    func stream() async throws -> V2ResourceByteStream {
        let url = url
        let reader = try await Task.detached(priority: .utility) { try SpoolReader(url: url) }.value
        return .init { try await reader.next() }
    }
    func remove() async {
        let directory = url.deletingLastPathComponent()
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
    }
}

private actor SpoolReader {
    let handle: FileHandle
    var reading = false
    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    func next() async throws -> Data? {
        guard !reading else { throw V2ResourceProviderError.preconditionFailed }
        reading = true
        defer { reading = false }
        let handle = handle
        return try await Task.detached(priority: .utility) {
            let bytes = try handle.read(upToCount: 65_536)
            return bytes?.isEmpty == false ? bytes : nil
        }.value
    }
}
