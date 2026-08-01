import Foundation

/// All group capability changes are room-scoped commands: they receive a
/// room sequence and are delivered to every eligible member in that order.
public struct V2PinnedMessageCommand: Equatable, Sendable {
    public let operationID: PinnedMessageOperationID; public let roomID: RoomID; public let messageID: MessageID; public let isPinned: Bool
    public init(operationID: PinnedMessageOperationID, roomID: RoomID, messageID: MessageID, isPinned: Bool) { self.operationID = operationID; self.roomID = roomID; self.messageID = messageID; self.isPinned = isPinned }
}

public struct V2PinnedMessage: Equatable, Sendable {
    public let roomID: RoomID; public let messageID: MessageID; public let isPinned: Bool; public let roomSequence: UInt64; public let updatedAt: Date
    public init(roomID: RoomID, messageID: MessageID, isPinned: Bool, roomSequence: UInt64, updatedAt: Date) { self.roomID = roomID; self.messageID = messageID; self.isPinned = isPinned; self.roomSequence = roomSequence; self.updatedAt = updatedAt }
}

public struct V2GroupAnnouncementCommand: Equatable, Sendable {
    public static let maximumUTF8Bytes = 4_096
    public let operationID: GroupAnnouncementOperationID; public let roomID: RoomID; public let body: String; public let expectedRevision: UInt64
    public init(operationID: GroupAnnouncementOperationID, roomID: RoomID, body: String, expectedRevision: UInt64) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2GroupPermissionValidationError.emptyAnnouncement }
        guard body.lengthOfBytes(using: .utf8) <= Self.maximumUTF8Bytes else { throw V2GroupPermissionValidationError.announcementTooLarge }
        self.operationID = operationID; self.roomID = roomID; self.body = body; self.expectedRevision = expectedRevision
    }
}

public struct V2GroupAnnouncement: Equatable, Sendable {
    public let roomID: RoomID; public let body: String; public let revision: UInt64; public let roomSequence: UInt64; public let updatedAt: Date
    public init(roomID: RoomID, body: String, revision: UInt64, roomSequence: UInt64, updatedAt: Date) { self.roomID = roomID; self.body = body; self.revision = revision; self.roomSequence = roomSequence; self.updatedAt = updatedAt }
}

public struct V2GroupRolePermissionsCommand: Equatable, Sendable {
    public let operationID: GroupPermissionOperationID; public let roomID: RoomID; public let role: V2RoomMembershipRole; public let permissions: Set<V2GroupPermission>; public let expectedRevision: UInt64
    public init(operationID: GroupPermissionOperationID, roomID: RoomID, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, expectedRevision: UInt64) throws {
        guard role != .owner else { throw V2GroupPermissionValidationError.ownerPolicyIsImmutable }
        guard expectedRevision > 0 else { throw V2CoreError.invalidPositiveValue }
        self.operationID = operationID; self.roomID = roomID; self.role = role; self.permissions = permissions; self.expectedRevision = expectedRevision
    }
}

public struct V2GroupRolePermissionsChange: Equatable, Sendable {
    public let roomID: RoomID; public let role: V2RoomMembershipRole; public let permissions: Set<V2GroupPermission>; public let revision: UInt64; public let roomSequence: UInt64
    public init(roomID: RoomID, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, revision: UInt64, roomSequence: UInt64) { self.roomID = roomID; self.role = role; self.permissions = permissions; self.revision = revision; self.roomSequence = roomSequence }
}

public struct V2GroupMemberRoleCommand: Equatable, Sendable {
    public let operationID: GroupRoleOperationID; public let roomID: RoomID; public let targetUserID: UserID; public let role: V2RoomMembershipRole; public let expectedMembershipRevision: UInt64
    public init(operationID: GroupRoleOperationID, roomID: RoomID, targetUserID: UserID, role: V2RoomMembershipRole, expectedMembershipRevision: UInt64) throws {
        guard role != .owner else { throw V2GroupPermissionValidationError.memberRoleCannotBeOwner }
        guard expectedMembershipRevision > 0 else { throw V2CoreError.invalidPositiveValue }
        self.operationID = operationID; self.roomID = roomID; self.targetUserID = targetUserID; self.role = role; self.expectedMembershipRevision = expectedMembershipRevision
    }
}

public struct V2GroupMemberRoleChange: Equatable, Sendable {
    public let roomID: RoomID; public let targetUserID: UserID; public let role: V2RoomMembershipRole; public let membershipRevision: UInt64; public let roomSequence: UInt64
    public init(roomID: RoomID, targetUserID: UserID, role: V2RoomMembershipRole, membershipRevision: UInt64, roomSequence: UInt64) { self.roomID = roomID; self.targetUserID = targetUserID; self.role = role; self.membershipRevision = membershipRevision; self.roomSequence = roomSequence }
}
