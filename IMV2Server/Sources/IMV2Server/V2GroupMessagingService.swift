import Foundation
import IMV2Core

public enum V2CreateGroupRoomOutcome: Equatable, Sendable {
    case created(V2GroupRoom)
    case idempotent(V2GroupRoom)
    case idempotencyConflict
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
    private let roomShardID: String
    private let identifiers: V2GroupMessagingIDFactory
    private let now: @Sendable () -> Date

    public init(
        store: any V2GroupMessagingStore,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        identifiers: V2GroupMessagingIDFactory = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let shard = roomShardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shard.isEmpty else { throw V2GroupMessagingPolicyError.invalidRoomShard }
        self.store = store
        self.capacityProfile = capacityProfile
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
        let command = try V2CreateGroupRoomCommand(
            actorUserID: actorUserID,
            operationID: operationID,
            title: title,
            initialMemberUserIDs: initialMemberUserIDs
        )
        guard command.allMemberUserIDs.count <= capacityProfile.limits.maxEligibleMembers else {
            return .memberLimitReached
        }
        let ids = try identifiers.make()
        return try await store.create(
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
}
