import IMV2Core

/// A current-state read for recovering policy projections whose per-role
/// history is missing. The caller authenticates the device; the selected room
/// owner independently checks current membership before releasing a baseline.
public protocol V2GroupRolePolicyBaselineReading: Sendable {
    func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupRolePolicyBaseline
}

public enum V2GroupRolePolicyBaselineError: Error, Equatable, Sendable {
    case roomNotFound
    case actorNotMember
    case corruptPersistenceState
}
