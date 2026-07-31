import Foundation
import IMV2Core

public struct V2StrangerMessagePolicy: Equatable, Sendable {
    public let maximumMessagesPerWindow: Int
    public let window: TimeInterval

    public init(maximumMessagesPerWindow: Int, window: TimeInterval) throws {
        guard maximumMessagesPerWindow > 0, window > 0 else { throw V2DirectMessagingPolicyError.invalidLimit }
        self.maximumMessagesPerWindow = maximumMessagesPerWindow
        self.window = window
    }
}

public enum V2DirectMessagingPolicyError: Error, Equatable, Sendable { case invalidLimit }

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
    private let roomShardID: String
    private let identifiers: V2DirectMessagingIDFactory
    private let now: @Sendable () -> Date

    public init(store: any V2DirectMessagingStore, capacityProfile: V2CapacityProfile, roomShardID: String, identifiers: V2DirectMessagingIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) throws {
        let shard = roomShardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shard.isEmpty else { throw V2DirectMessagingPolicyError.invalidLimit }
        self.store = store
        self.capacityProfile = capacityProfile
        self.roomShardID = shard
        self.identifiers = identifiers
        self.now = now
    }

    public func open(actorUserID: UserID, operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2OpenDirectRoomOutcome {
        let command = try V2OpenDirectRoomCommand(actorUserID: actorUserID, operationID: operationID, targetUserID: targetUserID)
        return try await store.open(command: command, capacityProfile: capacityProfile, roomShardID: roomShardID, roomID: try identifiers.makeRoomID(), now: now())
    }

    public func setStrangerMessagePermission(actorUserID: UserID, operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> V2SetStrangerMessagePermissionOutcome {
        try await store.setStrangerMessagePermission(command: .init(actorUserID: actorUserID, operationID: operationID, permission: permission), now: now())
    }

    public func setUserAddPermission(actorUserID: UserID, operationID: UserAddPreferenceOperationID, permission: V2UserAddPermission) async throws -> V2SetUserAddPermissionOutcome {
        try await store.setUserAddPermission(command: .init(actorUserID: actorUserID, operationID: operationID, permission: permission), now: now())
    }
}
