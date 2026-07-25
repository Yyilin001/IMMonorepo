import Foundation

/// Initial group membership is immutable input to a durable creation
/// operation. Later member changes use the revision-fenced membership command
/// rather than mutating this creation record.
public struct V2CreateGroupRoomCommand: Equatable, Sendable {
    public static let maximumTitleUTF8Bytes = 120

    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    /// Canonical, sorted, non-owner initial members. Canonicalization makes an
    /// idempotent retry insensitive to equivalent input ordering.
    public let initialMemberUserIDs: [UserID]

    public init(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        title: String,
        initialMemberUserIDs: [UserID]
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= Self.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw V2GroupMessagingValidationError.invalidTitle }

        guard !initialMemberUserIDs.contains(actorUserID),
              Set(initialMemberUserIDs).count == initialMemberUserIDs.count
        else { throw V2GroupMessagingValidationError.invalidInitialMembers }

        self.actorUserID = actorUserID
        self.operationID = operationID
        self.title = normalizedTitle
        self.initialMemberUserIDs = initialMemberUserIDs.sorted()
    }

    public var allMemberUserIDs: [UserID] {
        ([actorUserID] + initialMemberUserIDs).sorted()
    }
}

public struct V2GroupRoom: Equatable, Sendable {
    public let roomID: RoomID
    public let ownerUserID: UserID
    public let title: String
    public let memberUserIDs: [UserID]
    public let createdAt: Date

    public init(roomID: RoomID, ownerUserID: UserID, title: String, memberUserIDs: [UserID], createdAt: Date) {
        self.roomID = roomID
        self.ownerUserID = ownerUserID
        self.title = title
        self.memberUserIDs = memberUserIDs.sorted()
        self.createdAt = createdAt
    }
}

public enum V2GroupMessagingValidationError: Error, Equatable, Sendable {
    case invalidTitle
    case invalidInitialMembers
}
