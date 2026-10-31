import Foundation
import IMV2Core
import IMV2ServerContracts

/// Room-owner committed content identity, never nickname text or access.
public struct V2AuthorGroupNicknameChange: Sendable, Equatable {
    public let roomID: RoomID
    public let userID: UserID
    public let revision: UInt64
    public init(roomID: RoomID, userID: UserID, revision: UInt64) throws {
        guard roomID.uuidValue != nil, userID.uuidValue != nil, revision > 0, revision <= UInt64(Int64.max) else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        self.roomID = roomID; self.userID = userID; self.revision = revision
    }

    package init?(event: V2DirectRoomLiveEvent) {
        guard event.groupMembershipRevision != nil, event.projectionKind == "group_capability",
              event.payload.count <= 65_536, let payload = try? JSONDecoder().decode(Payload.self, from: event.payload),
              payload.event_type == "group.nickname_changed", payload.room_sequence == event.roomSequence,
              let room = UUID(uuidString: payload.room_id), RoomID(uuid: room) == event.roomID,
              let user = UUID(uuidString: payload.target_user_id),
              let value = try? Self(roomID: event.roomID, userID: .init(uuid: user), revision: payload.revision) else { return nil }
        self = value
    }
    private struct Payload: Decodable {
        let event_type: String, room_id: String, target_user_id: String
        let room_sequence: UInt64, revision: UInt64
    }
}

/// Content-free room permission changes. These reset recipient hints; fresh
/// Room Owner and control-plane reads still decide each resulting presentation.
package struct V2AuthorRoomPermissionChange: Sendable {
    package let roomID: RoomID
    package init?(event: V2DirectRoomLiveEvent) {
        guard event.groupMembershipRevision != nil, event.payload.count <= 65_536,
              let payload = try? JSONDecoder().decode(Payload.self, from: event.payload),
              payload.room_sequence == event.roomSequence,
              let room = UUID(uuidString: payload.room_id), RoomID(uuid: room) == event.roomID else { return nil }
        switch (event.projectionKind, payload.event_type) {
        case ("membership", "membership_changed"), ("group_capability", "group.role_permissions_changed"),
             ("group_capability", "group.member_role_changed"):
            roomID = event.roomID
        default: return nil
        }
    }
    private struct Payload: Decodable {
        let event_type: String, room_id: String
        let room_sequence: UInt64
    }
}
