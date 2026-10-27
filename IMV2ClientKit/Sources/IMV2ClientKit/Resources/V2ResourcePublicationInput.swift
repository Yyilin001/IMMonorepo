import Crypto
import Foundation

/// Source bytes remain caller-owned. The file owner writes only its journaled
/// partial and publishes one immutable copy, including in-memory photo output.
enum V2ResourcePublicationInput: Sendable {
    case file(URL)
    case data(Data)

    func checksum(expectedBytes: Int64) throws -> String {
        switch self {
        case .file(let url): return try V2ResourceFileDigest.sha256(fileURL: url, expectedByteCount: expectedBytes)
        case .data(let data):
            guard data.count == expectedBytes else { throw V2ResourceStorageError.integrityMismatch }
            var hash = SHA256()
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                let end = min(data.endIndex, offset + 65_536)
                hash.update(data: data[offset..<end]); offset = end
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    func write(to output: FileHandle, expectedBytes: Int64) throws {
        switch self {
        case .file(let url):
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var written: Int64 = 0
            while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation()
                guard Int64(chunk.count) <= expectedBytes - written else { throw V2ResourceStorageError.integrityMismatch }
                try output.write(contentsOf: chunk); written += Int64(chunk.count)
            }
            guard written == expectedBytes else { throw V2ResourceStorageError.integrityMismatch }
        case .data(let data):
            guard data.count == expectedBytes else { throw V2ResourceStorageError.integrityMismatch }
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                let end = min(data.endIndex, offset + 65_536)
                try output.write(contentsOf: data[offset..<end]); offset = end
            }
        }
    }
}
