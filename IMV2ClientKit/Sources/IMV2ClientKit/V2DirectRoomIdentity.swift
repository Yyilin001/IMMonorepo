import Foundation
import IMV2Core

/// Device-local association between a direct room and the public identity that
/// the signed-in user explicitly resolved before opening it. This is a cache
/// of an authorized lookup, not a contact graph or a sync projection.
public struct V2ClientDirectRoomIdentity: Equatable, Sendable {
    public let roomID: RoomID
    public let publicIdentity: V2PublicIdentity
    public let updatedAt: Date

    public init(roomID: RoomID, publicIdentity: V2PublicIdentity, updatedAt: Date) {
        self.roomID = roomID
        self.publicIdentity = publicIdentity
        self.updatedAt = updatedAt
    }
}

/// Authoritative direct-room profile received through the user's incremental
/// sync or snapshot baseline. It is distinct from the local explicit-lookup
/// cache, so a reset can replace only server-owned state.
public struct V2ClientDirectRoomProfileProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let publicIdentity: V2PublicIdentity
    public let revision: UInt64
    public let updatedAt: Date

    public init(
        sourceEventID: EventID, roomID: RoomID,
        publicIdentity: V2PublicIdentity, revision: UInt64, updatedAt: Date
    ) {
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.publicIdentity = publicIdentity
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public init(record: V2ClientSyncRecord) throws {
        guard record.projectionKind == "direct_room_profile" else { throw V2ClientProjectionError.invalidMessagePayload }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard payload.revision > 0, payload.updatedAtMilliseconds >= 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        sourceEventID = record.sourceEventID
        roomID = try .init(payload.roomID)
        publicIdentity = try .init(
            userID: .init(payload.targetUserID),
            handle: .init(payload.publicHandle),
            displayName: payload.displayName,
            accountKind: payload.accountKind
        )
        revision = payload.revision
        updatedAt = Date(timeIntervalSince1970: TimeInterval(payload.updatedAtMilliseconds) / 1_000)
    }

    private struct Wire: Decodable {
        let roomID: String
        let targetUserID: String
        let publicHandle: String
        let displayName: String
        let accountKind: V2AccountKind
        let revision: UInt64
        let updatedAtMilliseconds: Int64

        enum CodingKeys: String, CodingKey {
            case roomID = "room_id"
            case targetUserID = "target_user_id"
            case publicHandle = "public_handle"
            case displayName = "display_name"
            case accountKind = "account_kind"
            case revision
            case updatedAtMilliseconds = "updated_at_ms"
        }
    }
}
