import Foundation
import IMV2Core

public enum V2CreateGroupRoomOutcome: Equatable, Sendable {
    case created(V2GroupRoom)
    case idempotent(V2GroupRoom)
    case idempotencyConflict
    case invalidMembers
    case memberLimitReached
    case rateLimited(retryAfterSeconds: Int)
    case unavailable
}

/// Storage owns the creation transaction: room/profile rows, initial owner
/// and members, operation record, and admission lease must commit together.
/// A gateway must never synthesize a group room independently of this boundary.
public protocol V2GroupMessagingStore: Sendable {
    func create(
        command: V2CreateGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome
}

/// Owner-side capability used only after the control database has atomically
/// validated and persisted the exact initial audience. Keeping this separate
/// from ordinary `create` prevents a routed coordinator from accidentally
/// depending on stale or incomplete identity replicas in the owner database.
public protocol V2ControlValidatedGroupMessagingStore: V2GroupMessagingStore {
    func createControlValidated(
        command: V2CreateGroupRoomCommand,
        validatedMemberUserIDs: [UserID],
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome
}

/// Optional storage capability for audiences that have already been staged
/// and frozen in PostgreSQL. The application process carries only the
/// authoritative count; the store consumes the immutable member relation
/// with set-based SQL inside the room bootstrap transaction.
public protocol V2StagedGroupMessagingStore: Sendable {
    func createStaged(
        command: V2StagedGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome
}

public struct V2StagedGroupRoomCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let title: String
    public let deliveryMode: V2GroupDeliveryMode
    /// Excludes the owner, matching the staged draft relation.
    public let stagedMemberCount: Int

    public init(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        title: String,
        deliveryMode: V2GroupDeliveryMode,
        stagedMemberCount: Int
    ) throws {
        // Reuse the public command's exact title normalization contract.
        let validated = try V2CreateGroupRoomCommand(
            actorUserID: actorUserID,
            operationID: operationID,
            title: title,
            deliveryMode: deliveryMode,
            initialMemberUserIDs: []
        )
        guard stagedMemberCount >= 0, stagedMemberCount < Int.max else {
            throw V2GroupMessagingPolicyError.invalidInitialMembership
        }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.title = validated.title
        self.deliveryMode = deliveryMode
        self.stagedMemberCount = stagedMemberCount
    }

    public var allMemberCount: Int { stagedMemberCount + 1 }
}

public struct V2GroupMessagingIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.makeUUID = makeUUID
    }

    public func make() throws -> (roomID: RoomID, eventID: EventID, planID: FanoutPlanID) {
        try (.init(makeUUID().uuidString), .init(makeUUID().uuidString), .init(makeUUID().uuidString))
    }
}

/// Group bootstrap is a distinct durable command, not a sequence of member
/// additions against an implicit room. This keeps the initial authority and
/// audience atomic even if a response is lost.
public struct V2GroupMessagingService: Sendable {
    private let store: any V2GroupMessagingStore
    private let capacityProfile: V2CapacityProfile
    private let deliveryPolicy: V2GroupDeliveryPolicy
    private let roomShardID: String
    private let identifiers: V2GroupMessagingIDFactory
    private let now: @Sendable () -> Date

    public init(
        store: any V2GroupMessagingStore,
        capacityProfile: V2CapacityProfile,
        deliveryPolicy: V2GroupDeliveryPolicy = .init(),
        roomShardID: String,
        identifiers: V2GroupMessagingIDFactory = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let shard = roomShardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shard.isEmpty else { throw V2GroupMessagingPolicyError.invalidRoomShard }
        self.store = store
        self.capacityProfile = capacityProfile
        self.deliveryPolicy = deliveryPolicy
        self.roomShardID = shard
        self.identifiers = identifiers
        self.now = now
    }

    public func create(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        title: String,
        initialMemberUserIDs: [UserID]
    ) async throws -> V2CreateGroupRoomOutcome {
        let initialMemberCount = initialMemberUserIDs.count + 1
        // Validate untrusted membership input before evaluating capacity.  A
        // malformed request must not be reclassified as an apparent limit
        // rejection merely because it also has a large submitted array.
        let provisionalMode = deliveryPolicy.deliveryMode(forInitialMemberCount: initialMemberCount) ?? .largeGroupHybrid
        let command = try V2CreateGroupRoomCommand(
            actorUserID: actorUserID,
            operationID: operationID,
            title: title,
            deliveryMode: provisionalMode,
            initialMemberUserIDs: initialMemberUserIDs
        )
        guard command.allMemberUserIDs.count <= capacityProfile.limits.maxEligibleMembers,
              let deliveryMode = deliveryPolicy.deliveryMode(forInitialMemberCount: command.allMemberUserIDs.count)
        else {
            return .memberLimitReached
        }
        // `V2CreateGroupRoomCommand` canonicalizes and validates the member
        // list, so its count is the authority after duplicate/owner checks.
        guard command.allMemberUserIDs.count == initialMemberCount,
              deliveryPolicy.acceptsInitialMemberCount(command.allMemberUserIDs.count, mode: deliveryMode)
        else { throw V2GroupMessagingPolicyError.invalidInitialMembership }
        let derivedCommand = try V2CreateGroupRoomCommand(
            actorUserID: command.actorUserID,
            operationID: command.operationID,
            title: command.title,
            deliveryMode: deliveryMode,
            initialMemberUserIDs: command.initialMemberUserIDs
        )
        let ids = try identifiers.make()
        return try await store.create(
            command: derivedCommand,
            capacityProfile: capacityProfile,
            roomShardID: roomShardID,
            roomID: ids.roomID,
            eventID: ids.eventID,
            planID: ids.planID,
            now: now()
        )
    }

    public func createStaged(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        title: String,
        stagedMemberCount: Int
    ) async throws -> V2CreateGroupRoomOutcome {
        guard stagedMemberCount >= 0 else { throw V2GroupMessagingPolicyError.invalidInitialMembership }
        guard stagedMemberCount < Int.max else { return .memberLimitReached }
        let memberCount = stagedMemberCount + 1
        guard memberCount <= capacityProfile.limits.maxEligibleMembers,
              let deliveryMode = deliveryPolicy.deliveryMode(forInitialMemberCount: memberCount),
              deliveryPolicy.acceptsInitialMemberCount(memberCount, mode: deliveryMode)
        else { return .memberLimitReached }
        let command = try V2StagedGroupRoomCommand(
            actorUserID: actorUserID,
            operationID: operationID,
            title: title,
            deliveryMode: deliveryMode,
            stagedMemberCount: stagedMemberCount
        )
        guard let stagedStore = store as? any V2StagedGroupMessagingStore else {
            return .unavailable
        }
        let ids = try identifiers.make()
        return try await stagedStore.createStaged(
            command: command,
            capacityProfile: capacityProfile,
            roomShardID: roomShardID,
            roomID: ids.roomID,
            eventID: ids.eventID,
            planID: ids.planID,
            now: now()
        )
    }
}

public enum V2GroupMessagingPolicyError: Error, Equatable, Sendable {
    case invalidRoomShard
    case invalidInitialMembership
}
