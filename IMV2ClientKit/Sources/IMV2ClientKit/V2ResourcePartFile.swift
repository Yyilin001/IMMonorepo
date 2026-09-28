import Foundation

/// A short-lived bounded file slice. Only the stable source and server-confirmed
/// part receipts belong in the journal; signed targets never do.
enum V2ResourcePartFile {
    static func create(source: URL, lowerBound: Int64, byteCount: Int64) async throws -> URL {
        guard lowerBound >= 0, byteCount > 0, byteCount <= 16 * 1_024 * 1_024 else { throw V2ClientMediaTransferError.invalidTarget }
        let task = Task.detached(priority: .utility) {
            try Self.copy(source:source,lowerBound:lowerBound,byteCount:byteCount)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func copy(source:URL,lowerBound:Int64,byteCount:Int64) throws -> URL {
        try V2ResourceStagingBudget.withCopy(directory:source.deletingLastPathComponent(),additionalBytes:byteCount) {
            let destination = source.deletingLastPathComponent().appendingPathComponent(".part-\(UUID().uuidString)")
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
            try Task.checkCancellation()
            try Data().write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath:destination.path)
            var protected = destination
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
            try V2SystemResourceFileProtectionWriter().apply(.complete,to:destination)
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try input.seek(toOffset: UInt64(lowerBound))
            var remaining = byteCount
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: Int(min(65_536,remaining))), !data.isEmpty else { throw V2ClientMediaTransferError.byteCountMismatch }
                try output.write(contentsOf: data); remaining -= Int64(data.count)
            }
            try output.synchronize(); completed = true
            return destination
        }
    }
}
