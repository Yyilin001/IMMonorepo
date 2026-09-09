import Foundation

/// Effective policies observed together at one current room revision. This is
/// a complete baseline, not an event claiming that both roles changed at that
/// revision. Empty sets mean deny all; defaults must be resolved by the owner.
public struct V2GroupRolePolicyBaseline: Equatable, Sendable {
    public let roomID: RoomID
    public let permissionRevision: UInt64
    public let membershipRevision: UInt64
    public let roomSequence: UInt64
    public let adminPermissions: Set<V2GroupPermission>
    public let memberPermissions: Set<V2GroupPermission>

    public init(
        roomID: RoomID,
        permissionRevision: UInt64,
        membershipRevision: UInt64,
        roomSequence: UInt64,
        adminPermissions: Set<V2GroupPermission>,
        memberPermissions: Set<V2GroupPermission>
    ) throws {
        guard UUID(uuidString: roomID.rawValue) != nil else { throw V2CoreError.invalidIdentifier }
        guard permissionRevision > 0, permissionRevision <= UInt64(Int64.max) else { throw V2CoreError.invalidPositiveValue }
        guard membershipRevision <= UInt64(Int64.max), roomSequence <= UInt64(Int64.max) else { throw V2CoreError.invalidNonNegativeValue }
        self.roomID = roomID
        self.permissionRevision = permissionRevision
        self.membershipRevision = membershipRevision
        self.roomSequence = roomSequence
        self.adminPermissions = adminPermissions
        self.memberPermissions = memberPermissions
    }
}
