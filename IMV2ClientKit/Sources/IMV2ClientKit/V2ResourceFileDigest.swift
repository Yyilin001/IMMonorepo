import Foundation
import Crypto

/// Hashes bounded chunks on the transfer actor, never retaining the whole file.
public enum V2ResourceFileDigest {
    public static func sha256(fileURL: URL, expectedByteCount: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation()
            guard Int64(bytes.count) <= expectedByteCount - count else { throw V2ClientMediaTransferError.byteCountMismatch }
            count += Int64(bytes.count)
            hash.update(data: bytes)
        }
        guard count == expectedByteCount else { throw V2ClientMediaTransferError.byteCountMismatch }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
