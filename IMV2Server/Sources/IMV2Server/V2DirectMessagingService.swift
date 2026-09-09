import Foundation
import IMV2Core

public struct V2StrangerMessagePolicy: Equatable, Sendable {
    public let maximumMessagesPerWindow: Int
    public let window: TimeInterval

    public init(maximumMessagesPerWindow: Int, window: TimeInterval) throws {
        guard maximumMessagesPerWindow > 0, v2RateLimitDurationIsRepresentable(window) else { throw V2DirectMessagingPolicyError.invalidLimit }
        self.maximumMessagesPerWindow = maximumMessagesPerWindow
        self.window = window
    }
}

public enum V2DirectMessagingPolicyError: Error, Equatable, Sendable { case invalidLimit }

/// An ordered, deployment-controlled set of owners for newly-created direct
/// rooms. The selected owner is persisted on the room, so this router is used
/// only at creation time; it must never be consulted to re-route an existing
/// room mutation.
public struct V2DirectRoomShardRouter: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable, Sendable { case invalidShardIDs }

    public let shardIDs: [String]

    /// The comma-separated form is kept for deployment compatibility with the
    /// existing `IM_V2_DIRECT_ROOM_SHARD_ID` setting. Its order is part of the
    /// route contract: changing it requires an explicit route rollout.
    public init(rawValue: String) throws {
        let shardIDs = rawValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        try self.init(shardIDs: shardIDs)
    }

    public init(shardIDs: [String]) throws {
        guard (1...64).contains(shardIDs.count),
              shardIDs.allSatisfy({ !$0.isEmpty }),
              Set(shardIDs).count == shardIDs.count
        else { throw Error.invalidShardIDs }
        self.shardIDs = shardIDs
    }

    /// FNV-1a is deliberately fixed rather than Swift's randomized `Hasher`:
    /// every gateway replica and process restart must choose the same owner
    /// for an unordered user pair.
    public func shardID(for firstUserID: UserID, and secondUserID: UserID) -> String {
        guard shardIDs.count > 1 else { return shardIDs[0] }
        let pair = [firstUserID.rawValue.lowercased(), secondUserID.rawValue.lowercased()].sorted()
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in (pair[0] + "\u{0}" + pair[1]).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return shardIDs[Int(hash % UInt64(shardIDs.count))]
    }
}

public enum V2OpenDirectRoomOutcome: Equatable, Sendable {
    case opened(V2DirectRoom)
    case idempotent(V2DirectRoom)
    case idempotencyConflict
    case unavailable
}

public enum V2SetStrangerMessagePermissionOutcome: Equatable, Sendable {
    case updated(permission: V2StrangerMessagePermission, updatedAt: Date)
    case idempotent(permission: V2StrangerMessagePermission, updatedAt: Date)
    case idempotencyConflict
}

public enum V2SetUserAddPermissionOutcome: Equatable, Sendable {
    case updated(permission: V2UserAddPermission, updatedAt: Date)
    case idempotent(permission: V2UserAddPermission, updatedAt: Date)
    case idempotencyConflict
}

public protocol V2DirectMessagingStore: Sendable {
    func open(
        command: V2OpenDirectRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        now: Date
    ) async throws -> V2OpenDirectRoomOutcome

    func setStrangerMessagePermission(
        command: V2SetStrangerMessagePermissionCommand,
        now: Date
    ) async throws -> V2SetStrangerMessagePermissionOutcome

    func setUserAddPermission(
        command: V2SetUserAddPermissionCommand,
        now: Date
    ) async throws -> V2SetUserAddPermissionOutcome
}

public struct V2DirectMessagingIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }
    public func makeRoomID() throws -> RoomID { try .init(makeUUID().uuidString) }
}

/// Direct rooms are stable per unordered user pair. The storage boundary owns
/// pair locking and initial admission state, so callers cannot race into two
/// rooms for the same users.
public struct V2DirectMessagingService: Sendable {
    private let store: any V2DirectMessagingStore
    private let capacityProfile: V2CapacityProfile
    private let roomShardRouter: V2DirectRoomShardRouter
    private let identifiers: V2DirectMessagingIDFactory
    private let now: @Sendable () -> Date

    public init(store: any V2DirectMessagingStore, capacityProfile: V2CapacityProfile, roomShardID: String, identifiers: V2DirectMessagingIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) throws {
        try self.init(
            store: store,
            capacityProfile: capacityProfile,
            roomShardRouter: .init(rawValue: roomShardID),
            identifiers: identifiers,
            now: now
        )
    }

    public init(store: any V2DirectMessagingStore, capacityProfile: V2CapacityProfile, roomShardRouter: V2DirectRoomShardRouter, identifiers: V2DirectMessagingIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) throws {
        self.store = store
        self.capacityProfile = capacityProfile
        self.roomShardRouter = roomShardRouter
        self.identifiers = identifiers
        self.now = now
    }

    public func open(actorUserID: UserID, operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2OpenDirectRoomOutcome {
        let command = try V2OpenDirectRoomCommand(actorUserID: actorUserID, operationID: operationID, targetUserID: targetUserID)
        return try await store.open(
            command: command,
            capacityProfile: capacityProfile,
            roomShardID: roomShardRouter.shardID(for: command.actorUserID, and: command.targetUserID),
            roomID: try identifiers.makeRoomID(),
            now: now()
        )
    }

    public func setStrangerMessagePermission(actorUserID: UserID, operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> V2SetStrangerMessagePermissionOutcome {
        try await store.setStrangerMessagePermission(command: .init(actorUserID: actorUserID, operationID: operationID, permission: permission), now: now())
    }

    public func setUserAddPermission(actorUserID: UserID, operationID: UserAddPreferenceOperationID, permission: V2UserAddPermission) async throws -> V2SetUserAddPermissionOutcome {
        try await store.setUserAddPermission(command: .init(actorUserID: actorUserID, operationID: operationID, permission: permission), now: now())
    }

}
