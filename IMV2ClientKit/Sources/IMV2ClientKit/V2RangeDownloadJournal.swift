import Foundation
import Crypto

public enum V2RangeDownloadError: Error, Equatable, Sendable {
    case invalidRange, versionChanged, invalidJournal, responseTooLarge
}

/// No provider URL, headers or authorization is persisted.
struct V2RangeDownloadJournal: Codable, Sendable {
    let expectedBytes: Int64
    let checksum: String
    var offset: Int64
    var prefixChecksum: String
    var etag: String?
}

/// A synchronous file boundary protected because URLSession callbacks cross
/// executor threads. Only one request may mutate this journal at a time.
final class V2RangeDownloadFile: @unchecked Sendable {
    private let lock = NSLock()
    let partial: URL
    let journalURL: URL
    private let target: V2ClientMediaTransferTarget
    private var journal: V2RangeDownloadJournal
    private var handle: FileHandle
    private var hash = SHA256()
    private var responseExpectedBytes: Int64 = 0
    private var responseBytes: Int64 = 0
    private var checkpointOffset: Int64 = 0
    private var discardsResponseBody = false
    private var discardedBytes = 0
    var offset: Int64 { lock.withLock { journal.offset } }
    var acceptedResponseBytes: Int64 { lock.withLock { responseExpectedBytes } }
    var etag: String? { lock.withLock { journal.etag } }
    init(destination: URL,target: V2ClientMediaTransferTarget) throws {
        self.target = target
        partial = destination.appendingPathExtension("range-part")
        journalURL = destination.appendingPathExtension("range-journal")
        let empty = SHA256.hash(data: Data()).map { String(format:"%02x",$0) }.joined()
        journal = .init(expectedBytes: target.expectedByteCount,checksum: target.checksum.value,offset: 0,prefixChecksum: empty,etag: nil)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(),withIntermediateDirectories: true)
        for candidate in [partial,journalURL] where manager.fileExists(atPath: candidate.path) {
            guard (try manager.attributesOfItem(atPath: candidate.path)[.type] as? FileAttributeType) == .typeRegular else { throw V2RangeDownloadError.invalidJournal }
        }
        let savedHandle = try? FileHandle(forReadingFrom: journalURL)
        let savedData = try? savedHandle?.read(upToCount: 4097)
        try? savedHandle?.close()
        if let data = savedData, data.count <= 4096,
           let saved = try? JSONDecoder().decode(V2RangeDownloadJournal.self,from: data),
           saved.expectedBytes == target.expectedByteCount, saved.checksum == target.checksum.value,
           saved.offset >= 0, saved.offset <= saved.expectedBytes, (saved.etag == nil || Self.strongETag(saved.etag) != nil), manager.fileExists(atPath: partial.path) {
            journal = saved
        } else {
            try? manager.removeItem(at: partial)
            try? manager.removeItem(at: journalURL)
        }
        if !manager.fileExists(atPath: partial.path) { guard manager.createFile(atPath: partial.path,contents: nil) else { throw V2ClientMediaTransferError.fileSystemFailure } }
        handle = try FileHandle(forUpdating: partial)
        let actual = try handle.seekToEnd()
        if actual < UInt64(journal.offset) { try reset() }
        else {
            try handle.truncate(atOffset: UInt64(journal.offset))
            try handle.seek(toOffset: 0)
            var count: Int64 = 0
            while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                hash.update(data: bytes); count += Int64(bytes.count)
            }
            if count != journal.offset || digest(hash) != journal.prefixChecksum { try reset() }
            else { checkpointOffset = journal.offset; try handle.seek(toOffset: UInt64(journal.offset)) }
        }
        try protect(partial)
    }
    deinit { try? handle.close() }
    private func digest(_ value: SHA256) -> String { value.finalize().map { String(format:"%02x",$0) }.joined() }
    private func protect(_ url: URL) throws {
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = url; try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],ofItemAtPath: url.path)
        #endif
    }
    private func reset() throws {
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0); hash = SHA256()
        journal.offset = 0; journal.prefixChecksum = digest(hash); journal.etag = nil; checkpointOffset = 0
        try checkpoint()
    }
    private func checkpoint() throws {
        try handle.synchronize()
        journal.prefixChecksum = digest(hash)
        try JSONEncoder().encode(journal).write(to: journalURL,options: .atomic)
        try protect(journalURL)
        checkpointOffset = journal.offset
    }
    func accept(_ response: HTTPURLResponse,requestedStart: Int64,requestedEnd: Int64) throws {
        try lock.withLock {
            responseBytes = 0; discardsResponseBody = false; discardedBytes = 0
            let incomingETag = Self.strongETag(response.value(forHTTPHeaderField: "ETag"))
            switch response.statusCode {
            case 200:
                try reset(); journal.etag = incomingETag
                responseExpectedBytes = target.expectedByteCount
            case 206:
                let range = try Self.range(response.value(forHTTPHeaderField: "Content-Range"))
                guard range.0 == requestedStart, range.1 <= requestedEnd, range.2 == target.expectedByteCount,
                      range.0 == journal.offset else { throw V2RangeDownloadError.invalidRange }
                if let etag = journal.etag, incomingETag != etag { throw V2RangeDownloadError.versionChanged }
                journal.etag = incomingETag
                responseExpectedBytes = range.1 - range.0 + 1
            case 416:
                guard response.value(forHTTPHeaderField:"Content-Range") == "bytes */\(target.expectedByteCount)",
                      journal.offset == target.expectedByteCount else { throw V2RangeDownloadError.invalidRange }
                responseExpectedBytes = 0; discardsResponseBody = true
            case 401,403: throw V2ClientMediaTransferError.authorizationDenied
            default: throw V2HTTPFailure.status(response,service: "mediaProvider")
            }
            if let encoding = response.value(forHTTPHeaderField:"Content-Encoding"), encoding.lowercased() != "identity" { throw V2RangeDownloadError.invalidRange }
            guard response.expectedContentLength < 0 || (discardsResponseBody ? response.expectedContentLength <= 64 * 1024 : response.expectedContentLength == responseExpectedBytes) else { throw V2ClientMediaTransferError.byteCountMismatch }
        }
    }
    func append(_ bytes: Data) throws {
        try lock.withLock {
            if discardsResponseBody {
                guard bytes.count <= 64 * 1024 - discardedBytes else { throw V2RangeDownloadError.responseTooLarge }
                discardedBytes += bytes.count; return
            }
            guard Int64(bytes.count) <= responseExpectedBytes - responseBytes,
                  Int64(bytes.count) <= journal.expectedBytes - journal.offset else { throw V2RangeDownloadError.responseTooLarge }
            try handle.write(contentsOf: bytes); hash.update(data: bytes)
            journal.offset += Int64(bytes.count); responseBytes += Int64(bytes.count)
            if journal.offset - checkpointOffset >= 1024 * 1024 { try checkpoint() }
        }
    }
    func finishResponse() throws {
        try lock.withLock {
            guard responseBytes == responseExpectedBytes else { throw V2ClientMediaTransferError.byteCountMismatch }
            try checkpoint()
        }
    }
    func discardProgress() throws { try lock.withLock { try reset() } }
    func preserveProgress() throws { try lock.withLock { try checkpoint() } }
    func publish(to destination: URL) throws {
        try lock.withLock {
            guard journal.offset == target.expectedByteCount, digest(hash) == target.checksum.value else {
                try reset(); throw V2ClientMediaTransferError.checksumMismatch
            }
            try handle.synchronize(); try handle.close()
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw V2ClientMediaTransferError.destinationAlreadyExists }
            try FileManager.default.moveItem(at: partial,to: destination)
            try? FileManager.default.removeItem(at: journalURL)
        }
    }
    private static func strongETag(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 256, raw.first == "\"",raw.last == "\"",
              raw.utf8.dropFirst().dropLast().allSatisfy({ $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80 }) else { return nil }
        return raw
    }
    private static func range(_ raw: String?) throws -> (Int64,Int64,Int64) {
        guard let raw,raw.utf8.count <= 128,raw.hasPrefix("bytes ") else { throw V2RangeDownloadError.invalidRange }
        let parts = raw.dropFirst(6).split(separator: "/",omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw V2RangeDownloadError.invalidRange }
        let interval = parts[0].split(separator: "-",omittingEmptySubsequences: false)
        guard interval.count == 2, [interval[0],interval[1],parts[1]].allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let start = Int64(interval[0]),let end = Int64(interval[1]),let total = Int64(parts[1]),
              start >= 0,end >= start,total > end else { throw V2RangeDownloadError.invalidRange }
        return (start,end,total)
    }
}
