import Crypto
import Foundation
import IMV2ServerApplication

/// Immutable writes and zero-byte tombstones share the same OSS key. On an unversioned
/// bucket, forbid-overwrite and tombstone replacement linearize even across processes.
/// Never apply lifecycle expiration or external DELETE to these keys: that removes fences.
public struct V2OSSObjectStorage: V2ObjectStorage {
    public var binding: V2StorageBinding { client.configuration.binding }
    let client: V2OSSClient
    public init(client: V2OSSClient) { self.client = client }

    public func allocate(placementID: UUID = UUID()) throws -> V2StoredObjectReference {
        try .init(placementID: placementID, binding: binding,
                  handle: Data(placementID.uuidString.lowercased().utf8))
    }
    func key(_ reference: V2StoredObjectReference) throws -> String {
        guard reference.binding == binding, reference.formatVersion == 1,
              reference.handle == Data(reference.placementID.uuidString.lowercased().utf8)
        else { throw V2ResourceProviderError.configurationInvalid }
        return client.configuration.prefix + "objects/" + reference.placementID.uuidString.lowercased()
    }
    public func inspect(_ reference: V2StoredObjectReference) async throws -> V2StoredObjectFacts {
        let head = try await client.head(key: key(reference))
        guard let hex = head.headers["x-oss-meta-im-sha256"], let hash = Self.digest(hex) else {
            throw V2ResourceProviderError.integrityMismatch
        }
        return try .init(reference: reference, byteCount: head.byteCount, sha256: hash)
    }
    public func read(_ reference: V2StoredObjectReference) async throws -> V2ResourceByteStream {
        let facts = try await inspect(reference)
        return try await client.read(key: key(reference), expectedBytes: facts.byteCount, expectedHash: facts.sha256)
    }
    public func write(_ reference: V2StoredObjectReference, byteCount: Int64, sha256: Data,
                      bytes: V2ResourceByteStream) async throws -> V2StoredObjectFacts {
        let key = try key(reference)
        guard byteCount > 0, byteCount <= 256 * 1_024 * 1_024, sha256.count == 32 else {
            throw V2ResourceProviderError.integrityMismatch
        }
        // Validate the entire stream before granting final immutable object identity.
        let spool = try await V2ResourceSpoolFile.create(bytes: bytes, byteCount: byteCount)
        do {
            guard spool.sha256 == sha256 else { throw V2ResourceProviderError.integrityMismatch }
            let response = try await client.request("PUT", key: key,
                headers: ["x-oss-forbid-overwrite": "true", "x-oss-object-acl": "private",
                          "x-oss-meta-im-sha256": V2OSSSigner.hex(sha256), "content-type": "application/octet-stream"],
                body: spool.stream(), byteCount: byteCount)
            if response.status != 409 && response.status != 412 { try V2OSSClient.require(response) }
            let facts: V2StoredObjectFacts
            do { facts = try await inspect(reference) }
            catch V2ResourceProviderError.notFound { throw V2ResourceProviderError.preconditionFailed }
            guard facts.byteCount == byteCount, facts.sha256 == sha256 else { throw V2ResourceProviderError.integrityMismatch }
            await spool.remove()
            return facts
        } catch {
            await spool.remove()
            throw error
        }
    }
    public func delete(_ reference: V2StoredObjectReference) async throws {
        try await client.tombstone(key: key(reference))
    }
    static func digest(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return Data(stride(from: 0, to: 64, by: 2).map { index in
            let high = bytes[index] <= 57 ? bytes[index] - 48 : bytes[index] - 87
            let low = bytes[index + 1] <= 57 ? bytes[index + 1] - 48 : bytes[index + 1] - 87
            return high * 16 + low
        })
    }
}

extension V2OSSClient {
    func head(key: String) async throws -> (byteCount: Int64, etag: String, headers: [String: String]) {
        let response = try await request("HEAD", key: key)
        try Self.require(response)
        guard response.headers["x-oss-meta-im-deleted"] != "true" else { throw V2ResourceProviderError.notFound }
        guard let size = response.headers["content-length"].flatMap(Int64.init), size > 0,
              let etag = response.headers["etag"], !etag.isEmpty else { throw V2ResourceProviderError.integrityMismatch }
        return (size, etag, response.headers)
    }
    func tombstone(key: String) async throws {
        let response = try await request("PUT", key: key,
            headers: ["x-oss-meta-im-deleted": "true", "x-oss-object-acl": "private", "content-type": "application/octet-stream"])
        try Self.require(response)
    }
    func read(key: String, expectedBytes: Int64, expectedHash: Data? = nil, expectedETag: String? = nil) async throws -> V2ResourceByteStream {
        let head = try await head(key: key)
        guard head.byteCount == expectedBytes else { throw V2ResourceProviderError.integrityMismatch }
        guard expectedETag == nil || head.etag == expectedETag else { throw V2ResourceProviderError.preconditionFailed }
        let reader = V2OSSRangeReader(size: expectedBytes, etag: head.etag, expectedHash: expectedHash) { start, end in
            try await self.request("GET", key: key,
                headers: ["range": "bytes=\(start)-\(end)", "if-match": head.etag],
                maximumResponseBytes: V2OSSRangeReader.maximumRangeBytes)
        }
        return .init { try await reader.next() }
    }
}

/// Fetch bounded 1 MiB ranges and expose the storage port's 64 KiB chunks.
/// ETag fences every range; SHA-256 validates the complete object.
actor V2OSSRangeReader {
    static let maximumRangeBytes = 1_024 * 1_024
    private let readRange: @Sendable (Int64, Int64) async throws -> V2OSSResponse
    let size: Int64
    let etag: String
    let expectedHash: Data?
    var offset: Int64 = 0
    var hash = SHA256()
    var reading = false
    var failed = false
    private var buffer = Data()
    private var bufferOffset = 0
    init(size: Int64, etag: String, expectedHash: Data?,
         readRange: @escaping @Sendable (Int64, Int64) async throws -> V2OSSResponse) {
        self.size = size; self.etag = etag; self.expectedHash = expectedHash; self.readRange = readRange
    }
    func next() async throws -> Data? {
        try Task.checkCancellation()
        guard !reading, !failed else { throw V2ResourceProviderError.preconditionFailed }
        guard offset < size || bufferOffset < buffer.count else { return nil }
        reading = true
        defer { reading = false }
        do {
            if buffer.isEmpty {
                let length = min(size - offset, Int64(Self.maximumRangeBytes))
                let end = offset + length - 1
                let response = try await readRange(offset, end)
                try Task.checkCancellation()
                try V2OSSClient.require(response, statuses: [206])
                guard response.headers["content-range"] == "bytes \(offset)-\(end)/\(size)",
                      response.headers["etag"] == etag, Int64(response.body.count) == length
                else { throw V2ResourceProviderError.integrityMismatch }
                hash.update(data: response.body)
                offset = end + 1
                if offset == size, let expectedHash, Data(hash.finalize()) != expectedHash {
                    throw V2ResourceProviderError.integrityMismatch
                }
                buffer = response.body
            }
            let end = min(buffer.count, bufferOffset + 65_536)
            let chunk = buffer.subdata(in: bufferOffset..<end)
            bufferOffset = end
            if bufferOffset == buffer.count { buffer = Data(); bufferOffset = 0 }
            return chunk
        } catch { failed = true; buffer = Data(); bufferOffset = 0; throw error }
    }
}
