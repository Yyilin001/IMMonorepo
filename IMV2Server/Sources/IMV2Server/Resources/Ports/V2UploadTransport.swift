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
