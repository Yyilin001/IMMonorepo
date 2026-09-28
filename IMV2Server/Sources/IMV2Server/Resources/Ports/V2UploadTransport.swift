import Foundation
import IMV2Core

/// Sessions pin this binding at allocation; targets are never persisted.
public struct V2ResourceTransportCapabilities: Sendable {
    public let modes: [V2ResourceTransferMode]
    public let maximumBytes: Int64
    public init(modes: [V2ResourceTransferMode], maximumBytes: Int64) { self.modes=modes;self.maximumBytes=maximumBytes }
}
public protocol V2UploadTransport: Sendable {
    var binding: V2StorageBinding { get }
    var capabilities: V2ResourceTransportCapabilities { get }
    func plan(mode: V2ResourceTransferMode, mediaID: MediaID, contentType: String, byteCount: Int64, checksum: V2ResourceChecksum, expiresAt: Date) async throws -> V2ResourceTransferPlan
    func completedBytes(mediaID: MediaID, byteCount: Int64) async throws -> V2ResourceByteStream
    func importBytes(mediaID: MediaID, contentType: String, byteCount: Int64, bytes: V2ResourceByteStream) async throws
    func abort(mediaID: MediaID) async throws
}

/// Native part storage is authoritative. Missing part targets are fresh leases;
/// part receipts identify immutable provider objects, never signed URLs.
public protocol V2MultipartUploadTransport: V2UploadTransport {
    var maximumParts: Int { get }
    func partPlans(mediaID: MediaID, contentType: String, byteCount: Int64, checksum: V2ResourceChecksum,
                   requestedParts: [Int], expiresAt: Date) async throws -> [V2ResourceTransferPlan]
    func confirmedParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum) async throws -> [V2ResourceUploadPart]
    func completedParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum,
                        parts: [V2ResourceUploadPart]) async throws -> V2ResourceByteStream
    func abortParts(mediaID: MediaID, byteCount: Int64, checksum: V2ResourceChecksum) async throws
}

/// Explicit delegation support: exact immutable attachment parts, finite signed leases,
/// and a native PUT ingress which never redirects. No presentation/control lease is reused.
public protocol V2BackgroundUploadTransport: V2MultipartUploadTransport {
    func backgroundPartPlans(mediaID: MediaID, contentType: String, byteCount: Int64,
        checksum: V2ResourceChecksum, requestedParts: [Int], sessionID: MediaUploadSessionID,
        generation: Int64, issuedAt: Date, expiresAt: Date) async throws -> [V2ResourceTransferPlan]
}
