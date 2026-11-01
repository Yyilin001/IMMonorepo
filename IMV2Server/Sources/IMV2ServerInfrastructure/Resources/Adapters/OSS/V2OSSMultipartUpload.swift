import Crypto
import Foundation
import IMV2Core
import IMV2ServerApplication

/// Each part is an immutable native PUT object. Deterministic identities survive a
/// restart without a provider upload ID; cancellation seals every possible part key.
extension V2OSSUploadTransport: V2MultipartUploadTransport {
    public var maximumParts: Int { 32 }
    private static let partBytes: Int64 = 8 * 1_024 * 1_024

    private func partCount(_ byteCount: Int64) throws -> Int {
        guard byteCount > 0, byteCount <= capabilities.maximumBytes else { throw V2ResourceProviderError.unsupportedCapability }
        return Int((byteCount + Self.partBytes - 1) / Self.partBytes)
    }

    private func partKey(mediaID: MediaID, checksum: V2ResourceChecksum, number: Int) -> String {
        client.configuration.prefix + "uploads/" + mediaID.description + "/parts/" + checksum.value + "/" + String(number)
    }

    private func confirmedPart(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum, number: Int) async throws -> V2ResourceUploadPart? {
        try Task.checkCancellation()
        do {
            let head = try await client.head(key: partKey(mediaID: mediaID, checksum: checksum, number: number))
            let length = min(Self.partBytes, byteCount - Int64(number - 1) * Self.partBytes)
            guard head.byteCount == length else { throw V2ResourceProviderError.integrityMismatch }
            return try .init(number: number, byteCount: length, receipt: head.etag)
        } catch V2ResourceProviderError.notFound { return nil }
    }

    public func partPlans(mediaID: MediaID, contentType: String, byteCount: Int64, checksum: V2ResourceChecksum,
                          requestedParts: [Int], expiresAt: Date) async throws -> [V2ResourceTransferPlan] {
        try await makePartPlans(mediaID: mediaID, contentType: contentType, byteCount: byteCount, checksum: checksum,
            requestedParts: requestedParts, expiresAt: expiresAt, grant: { _ in nil })
    }

    func makePartPlans(mediaID: MediaID, contentType: String, byteCount: Int64, checksum: V2ResourceChecksum,
                       requestedParts: [Int], expiresAt: Date,
                       grant: (Int) throws -> V2ResourceBackgroundAuthorization?) async throws -> [V2ResourceTransferPlan] {
        let count = try partCount(byteCount)
        guard requestedParts.count <= 16, Set(requestedParts).count == requestedParts.count,
              requestedParts.allSatisfy({ (1...count).contains($0) }) else { throw V2ResourceProviderError.preconditionFailed }
        var plans: [V2ResourceTransferPlan] = []
        for number in requestedParts.isEmpty ? Array(1...count) : requestedParts {
            guard try await confirmedPart(mediaID: mediaID, byteCount: byteCount, checksum: checksum, number: number) == nil else { continue }
            let start = Int64(number - 1) * Self.partBytes
            let length = min(Self.partBytes, byteCount - start)
            let authorization = try grant(number)
            let signed = try await signedPut(key: partKey(mediaID: mediaID, checksum: checksum, number: number),
                contentType: contentType, byteCount: length, expiresAt: expiresAt)
            plans.append(try .init(mode: .httpPartPut, url: signed.url, headers: signed.headers, expiresAt: expiresAt,
                expectedByteCount: length, byteRange: .init(lowerBound: start, upperBound: start + length - 1),
                partNumber: number, backgroundAuthorization: authorization))
            // Default progression grants only the next missing part. Explicit requests are bounded to 16.
            if requestedParts.isEmpty { break }
        }
        try Task.checkCancellation()
        return plans
    }

    public func confirmedParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum) async throws -> [V2ResourceUploadPart] {
        var parts: [V2ResourceUploadPart] = []
        for number in 1...(try partCount(byteCount)) {
            if let part = try await confirmedPart(mediaID: mediaID, byteCount: byteCount, checksum: checksum, number: number) { parts.append(part) }
        }
        try Task.checkCancellation()
        return parts
    }

    public func completedParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum,
                               parts: [V2ResourceUploadPart]) async throws -> V2ResourceByteStream {
        let count = try partCount(byteCount)
        guard parts.count == count else { throw V2ResourceProviderError.preconditionFailed }
        let confirmed = try await confirmedParts(mediaID: mediaID, byteCount: byteCount, checksum: checksum)
        guard confirmed.count == count, parts == confirmed,
              let digest = V2OSSObjectStorage.digest(checksum.value) else { throw V2ResourceProviderError.preconditionFailed }
        let reader = V2OSSMultipartReader(parts: confirmed, byteCount: byteCount, digest: digest) { part in
            try await client.read(key: partKey(mediaID: mediaID, checksum: checksum, number: part.number),
                expectedBytes: part.byteCount, expectedETag: part.receipt)
        }
        return .init { try await reader.next() }
    }

    public func abortParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum) async throws {
        // Include missing parts: an already issued PUT may still be in flight.
        for number in 1...(try partCount(byteCount)) {
            try Task.checkCancellation()
            try await client.tombstone(key: partKey(mediaID: mediaID, checksum: checksum, number: number))
        }
    }
}

private actor V2OSSMultipartReader {
    private let parts: [V2ResourceUploadPart]
    private let byteCount: Int64
    private let digest: Data
    private let open: @Sendable (V2ResourceUploadPart) async throws -> V2ResourceByteStream
    private var index = 0
    private var input: V2ResourceByteStream?
    private var consumed: Int64 = 0
    private var hash = SHA256()
    private var reading = false
    private var failed = false

    init(parts: [V2ResourceUploadPart], byteCount: Int64, digest: Data,
         open: @escaping @Sendable (V2ResourceUploadPart) async throws -> V2ResourceByteStream) {
        self.parts = parts; self.byteCount = byteCount; self.digest = digest; self.open = open
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        guard !reading, !failed else { throw V2ResourceProviderError.preconditionFailed }
        reading = true
        defer { reading = false }
        do {
            while index < parts.count {
                if input == nil { input = try await open(parts[index]) }
                if let chunk = try await input!.next() {
                    try Task.checkCancellation()
                    guard !chunk.isEmpty, Int64(chunk.count) <= byteCount - consumed else { throw V2ResourceProviderError.integrityMismatch }
                    consumed += Int64(chunk.count); hash.update(data: chunk)
                    if consumed == byteCount, Data(hash.finalize()) != digest { throw V2ResourceProviderError.integrityMismatch }
                    return chunk
                }
                input = nil; index += 1
            }
            guard consumed == byteCount else { throw V2ResourceProviderError.integrityMismatch }
            return nil
        } catch { failed = true; input = nil; throw error }
    }
}
