import Foundation
import IMV2Core

/// The same bounded dimensions travel from local selection to upload request.
public typealias V2LocalResourceImageDimensions = V2ResourcePixelDimensions

/// Selection identity is independent of an upload operation and of deduplicated bytes.
public struct V2LocalResourceAssetID: Hashable, Codable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

public enum V2LocalResourceAssetPurpose: Equatable, Sendable {
    case messageDraft(RoomID)
    case personalAvatar
    case groupAvatar(RoomID)
}

public enum V2LocalResourceReadContext: Sendable {
    case selection(V2LocalResourceAssetID)
    case upload(UUID)
    case profileIntent(UUID)
}

/// Namespaces prevent a draft and upload sharing a UUID from deleting each
/// other's claim during the atomic handoff.
enum V2LocalResourceOriginalConsumer: Sendable {
    case upload(UUID)
    case profileIntent(UUID)
    var id: UUID { switch self { case .upload(let id), .profileIntent(let id): id } }
    var kind: String { switch self { case .upload: "upload"; case .profileIntent: "profileIntent" } }
}

/// Immutable account-local metadata. A local URL is deliberately not persisted.
public struct V2LocalResourceAsset: Equatable, Sendable, Identifiable {
    public enum Availability: Equatable, Sendable { case importing, local, unavailable }
    public let id: V2LocalResourceAssetID
    public let displayName: V2ResourceDisplayName
    public let contentType: V2ResourceContentType
    public let byteCount: Int64
    public let checksum: V2ResourceChecksum
    public let purpose: V2LocalResourceAssetPurpose
    public let availability: Availability
    public let selectionActive: Bool
    public let createdAt: Date
    public let imageDimensions: V2LocalResourceImageDimensions?
    let fileID: V2LocalResourceFileID?
    let plannedFileID: V2LocalResourceFileID
}
