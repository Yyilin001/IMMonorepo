import Foundation
import IMV2Core

/// Read-only local projection for a group announcement.  This is separate
/// from the command/result types so SwiftUI never needs to decode event JSON.
public struct V2ClientGroupAnnouncement: Equatable, Sendable {
    public let roomID: RoomID
    public let body: String
    public let revision: UInt64
    public let updatedAt: Date

    public init(roomID: RoomID, body: String, revision: UInt64, updatedAt: Date) {
        self.roomID = roomID
        self.body = body
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct V2ClientGroupRolePolicy: Equatable, Sendable {
    public let roomID: RoomID
    public let role: V2RoomMembershipRole
    public let permissions: Set<V2GroupPermission>
    public let revision: UInt64

    public init(roomID: RoomID, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, revision: UInt64) {
        self.roomID = roomID
        self.role = role
        self.permissions = permissions
        self.revision = revision
    }
}

/// Parses the durable room-event payloads for group controls.  Keeping this
/// separate from UI models ensures the same validation is used by standard
/// fan-out, hybrid room-log pulls, and foreground previews.
enum V2ClientGroupCapabilityProjection {
    struct Header: Decodable { let eventType: String; enum CodingKeys: String, CodingKey { case eventType = "event_type" } }
    struct MemberRole: Decodable { let roomID: String; let targetUserID: String; let role: String; let membershipRevision: UInt64; enum CodingKeys: String, CodingKey { case roomID = "room_id", targetUserID = "target_user_id", role, membershipRevision = "membership_revision" } }

    static func header(_ data: Data) throws -> Header { do { return try JSONDecoder().decode(Header.self, from: data) } catch { throw V2ClientProjectionError.invalidMessagePayload } }
}
