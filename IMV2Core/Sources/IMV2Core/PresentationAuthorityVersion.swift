import Foundation

/// An observation version, never an authorization credential. Control sequence
/// is the common committed presentation journal head; room counters belong to
/// the Room Owner. It reveals no relationship or block direction/reason.
public struct V2PresentationAuthorityVersion: Codable, Equatable, Sendable {
    public let controlSequence: UInt64
    public let roomID: RoomID?
    public let membershipRevision: UInt64
    public let permissionRevision: UInt64

    public init(controlSequence: UInt64, roomID: RoomID?, membershipRevision: UInt64, permissionRevision: UInt64) throws {
        guard controlSequence <= UInt64(Int64.max), membershipRevision <= UInt64(Int64.max),
              permissionRevision <= UInt64(Int64.max),
              roomID != nil || (membershipRevision == 0 && permissionRevision == 0)
        else { throw V2ResourceValidationError.invalidPresentationLease }
        self.controlSequence = controlSequence; self.roomID = roomID
        self.membershipRevision = membershipRevision; self.permissionRevision = permissionRevision
    }

    public func isAtLeast(_ other: Self) -> Bool {
        controlSequence >= other.controlSequence && (other.roomID == nil || roomID == other.roomID)
            && membershipRevision >= other.membershipRevision && permissionRevision >= other.permissionRevision
    }

    /// Preserve every observed floor when two independently owned domains race.
    public func merged(with other: Self) throws -> Self {
        guard roomID == nil || other.roomID == nil || roomID == other.roomID else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        return try .init(controlSequence: max(controlSequence, other.controlSequence), roomID: roomID ?? other.roomID,
            membershipRevision: max(membershipRevision, other.membershipRevision), permissionRevision: max(permissionRevision, other.permissionRevision))
    }

    public func matches(_ context: V2ProfileViewContext, permittingMissingDirectRoom: Bool = false) -> Bool {
        switch context {
        case .relationship: roomID == nil
        case .room(let room), .groupJoinReview(let room): roomID == room
        case .directConversation: roomID != nil || permittingMissingDirectRoom
        }
    }

    private enum CodingKeys: String, CodingKey { case controlSequence, roomID, membershipRevision, permissionRevision }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(controlSequence: values.decode(UInt64.self, forKey: .controlSequence),
            roomID: values.decodeIfPresent(RoomID.self, forKey: .roomID),
            membershipRevision: values.decode(UInt64.self, forKey: .membershipRevision),
            permissionRevision: values.decode(UInt64.self, forKey: .permissionRevision))
    }
}

/// A versioned negative observation for one lookup context. It contains no
/// private denial reason and grants no access when replayed or cached.
public struct V2PresentationDenial: Codable, Equatable, Sendable {
    public let key: V2ProfileViewLookupKey
    public let authorityVersion: V2PresentationAuthorityVersion
    public init(key: V2ProfileViewLookupKey, authorityVersion: V2PresentationAuthorityVersion) throws {
        guard authorityVersion.matches(key.context, permittingMissingDirectRoom: true) else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        self.key = key; self.authorityVersion = authorityVersion
    }
    private enum CodingKeys: String, CodingKey { case key, authorityVersion }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: values.decode(V2ProfileViewLookupKey.self, forKey: .key),
            authorityVersion: values.decode(V2PresentationAuthorityVersion.self, forKey: .authorityVersion))
    }
}
