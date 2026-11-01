import Foundation
import IMV2Core
import IMV2ServerApplication

public struct V2OSSUploadTransport: V2BackgroundUploadTransport {
    public var binding: V2StorageBinding { client.configuration.binding }
    public let capabilities = V2ResourceTransportCapabilities(modes: [.httpPartPut, .httpPut], maximumBytes: 256 * 1_024 * 1_024)
    let client: V2OSSClient
    public init(client: V2OSSClient) { self.client = client }

    private func key(_ mediaID: MediaID) -> String {
        client.configuration.prefix + "uploads/" + mediaID.description
    }
    public func plan(mode: V2ResourceTransferMode, mediaID: MediaID, contentType: String, byteCount: Int64,
                     checksum: V2ResourceChecksum, expiresAt: Date) async throws -> V2ResourceTransferPlan {
        guard mode == .httpPut, byteCount > 0, byteCount <= capabilities.maximumBytes else {
            throw V2ResourceProviderError.unsupportedCapability
        }
        let signed = try await signedPut(key: key(mediaID), contentType: contentType, byteCount: byteCount, expiresAt: expiresAt)
        return try .init(mode: .httpPut, url: signed.url, headers: signed.headers,
            expiresAt: expiresAt, expectedByteCount: byteCount, checksum: checksum)
    }

    func signedPut(key: String, contentType: String, byteCount: Int64, expiresAt: Date) async throws -> (url: URL, headers: [V2ResourceTransferHeader]) {
        let headers = ["content-type": contentType, "x-oss-forbid-overwrite": "true", "x-oss-object-acl": "private"]
        var signedHeaders = headers
        signedHeaders["content-length"] = String(byteCount)
        let url = try await client.signer().presignedURL(endpoint: client.configuration.endpoint,
            method: "PUT", key: key, headers: signedHeaders, additionalHeaders: ["content-length"],
            now: Date(), expiresAt: expiresAt)
        return (url, try headers.sorted { $0.key < $1.key }.map { try .init(name: $0.key, value: $0.value) })
    }
    public func backgroundPlans(mode: V2ResourceTransferMode, mediaID: MediaID, contentType: String, byteCount: Int64,
        checksum: V2ResourceChecksum, requestedParts: [Int], sessionID: MediaUploadSessionID,
        generation: Int64, issuedAt: Date, expiresAt: Date) async throws -> [V2ResourceTransferPlan] {
        if mode == .httpPartPut {
            return try await makePartPlans(mediaID: mediaID, contentType: contentType, byteCount: byteCount,
                checksum: checksum, requestedParts: requestedParts, expiresAt: expiresAt) { number in
                try .init(id: UUID(), sessionID: sessionID, generation: generation, mediaID: mediaID,
                    partNumber: number, issuedAt: issuedAt, expiresAt: expiresAt)
            }
        }
        guard mode == .httpPut, requestedParts.isEmpty else { throw V2ResourceProviderError.unsupportedCapability }
        let grant = try V2ResourceBackgroundAuthorization(id: UUID(), sessionID: sessionID, generation: generation,
            mediaID: mediaID, scope: .whole(byteCount: byteCount, checksum: checksum), issuedAt: issuedAt, expiresAt: expiresAt)
        let signed = try await plan(mode: mode, mediaID: mediaID, contentType: contentType,
            byteCount: byteCount, checksum: checksum, expiresAt: expiresAt)
        return [try .init(mode: mode, url: signed.url, headers: signed.headers, expiresAt: expiresAt,
            expectedByteCount: byteCount, checksum: checksum, backgroundAuthorization: grant)]
    }

    public func completedBytes(mediaID: MediaID, byteCount: Int64) async throws -> V2ResourceByteStream {
        try await client.read(key: key(mediaID), expectedBytes: byteCount)
    }
    public func importBytes(mediaID: MediaID, contentType: String, byteCount: Int64, bytes: V2ResourceByteStream) async throws {
        guard byteCount > 0, byteCount <= capabilities.maximumBytes else { throw V2ResourceProviderError.unsupportedCapability }
        let file = try await V2ResourceSpoolFile.create(bytes: bytes, byteCount: byteCount)
        do {
            let response = try await client.request("PUT", key: key(mediaID),
                headers: ["content-type": contentType, "x-oss-forbid-overwrite": "true", "x-oss-object-acl": "private"],
                body: file.stream(), byteCount: byteCount)
            if response.status != 409 && response.status != 412 { try V2OSSClient.require(response) }
            // Import retry must prove the existing staging object is the same content.
            let stored = try await client.read(key: key(mediaID), expectedBytes: byteCount, expectedHash: file.sha256)
            while let _ = try await stored.next() {}
            await file.remove()
        } catch { await file.remove(); throw error }
    }
    public func abort(mediaID: MediaID) async throws { try await client.tombstone(key: key(mediaID)) }
}
