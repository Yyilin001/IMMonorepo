import Foundation
import IMV2Core
import SQLKit

/// Common content-publication policy for send and edit. The caller must hold
/// the room row (or its equivalent authorization fence) until its write commits.
/// Role, mute, membership and freeze mutations acquire that same room lock.
/// Global account identity is supplied by the control-plane boundary.
func v2AuthorizeContentWrite(
    roomID: UUID,
    isGroup: Bool,
    frozenAt: Date?,
    actorIsActive: Bool,
    actorRole: String?,
    isMuted: Bool,
    sql: any SQLDatabase
) async throws {
    guard frozenAt == nil else { throw V2RoomWriteStoreError.roomFrozen }
    guard actorIsActive, let actorRole,
          let role = V2RoomMembershipRole(rawValue: actorRole)
    else { throw V2RoomWriteStoreError.actorNotEligible }
    if isGroup {
        let permissions = try await v2ResolvedGroupPermissions(roomID: roomID, role: role, sql: sql)
        guard V2GroupPermissionDefaults.allows(role: role, permission: .sendMessages, configured: permissions)
        else { throw V2RoomWriteStoreError.actorNotEligible }
    }
    guard !isMuted else { throw V2RoomWriteStoreError.actorMuted }
}
