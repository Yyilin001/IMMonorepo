import Foundation

/// A group's delivery contract is selected at creation and is intentionally
/// immutable.  A message therefore has exactly one durable synchronization
/// source for the lifetime of its room.
public enum V2GroupDeliveryMode: String, CaseIterable, Codable, Equatable, Sendable {
    case standardFanout = "standard_fanout"
    case largeGroupHybrid = "large_group_hybrid"
}

/// Creation-time limits, kept separate from transient admission capacity so
/// callers cannot accidentally make a large-group choice by tuning a worker
/// or a PostgreSQL pool setting.
public struct V2GroupDeliveryPolicy: Equatable, Sendable {
    public static let standardFanoutMaximumMembers = 5_000
    public static let largeGroupHybridMaximumMembers = 100_000

    public init() {}

    public func maximumMembers(for mode: V2GroupDeliveryMode) -> Int {
        switch mode {
        case .standardFanout: Self.standardFanoutMaximumMembers
        case .largeGroupHybrid: Self.largeGroupHybridMaximumMembers
        }
    }

    public func accepts(memberCount: Int, mode: V2GroupDeliveryMode) -> Bool {
        memberCount > 0 && memberCount <= maximumMembers(for: mode)
    }

    /// The product contract is intentionally deterministic: the mode is
    /// selected once from the initial audience and can never be changed.
    public func deliveryMode(forInitialMemberCount memberCount: Int) -> V2GroupDeliveryMode? {
        guard memberCount > 0, memberCount <= Self.largeGroupHybridMaximumMembers else { return nil }
        return memberCount <= Self.standardFanoutMaximumMembers ? .standardFanout : .largeGroupHybrid
    }

    /// A group mode is a server-derived consequence of its creation audience,
    /// never a client-selected capacity preference.  Keeping this predicate
    /// alongside the derivation prevents the two boundaries from drifting.
    public func acceptsInitialMemberCount(_ memberCount: Int, mode: V2GroupDeliveryMode) -> Bool {
        deliveryMode(forInitialMemberCount: memberCount) == mode
    }
}

/// Initial group membership is immutable input to a durable creation
/// operation. Later member changes use the revision-fenced membership command
/// rather than mutating this creation record.
public struct V2CreateGroupRoomCommand: Equatable, Sendable {
    public static let maximumTitleUTF8Bytes = 120

    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public let deliveryMode: V2GroupDeliveryMode
    /// Canonical, sorted, non-owner initial members. Canonicalization makes an
    /// idempotent retry insensitive to equivalent input ordering.
    public let initialMemberUserIDs: [UserID]

    public init(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        title: String,
        deliveryMode: V2GroupDeliveryMode,
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
        self.deliveryMode = deliveryMode
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
    public let deliveryMode: V2GroupDeliveryMode
    /// Authoritative total count. Staged 100k creation does not materialize
    /// every member identifier in the application response merely to report
    /// this scalar.
    public let memberCount: Int
    public let memberUserIDs: [UserID]
    public let createdAt: Date

    public init(roomID: RoomID, ownerUserID: UserID, title: String, deliveryMode: V2GroupDeliveryMode, memberUserIDs: [UserID], memberCount: Int? = nil, createdAt: Date) {
        let resolvedMemberCount = memberCount ?? memberUserIDs.count
        precondition(resolvedMemberCount >= memberUserIDs.count && resolvedMemberCount > 0)
        self.roomID = roomID
        self.ownerUserID = ownerUserID
        self.title = title
        self.deliveryMode = deliveryMode
        self.memberCount = resolvedMemberCount
        self.memberUserIDs = memberUserIDs.sorted()
        self.createdAt = createdAt
    }
}

public enum V2GroupMessagingValidationError: Error, Equatable, Sendable {
    case invalidTitle
    case invalidInitialMembers
}
