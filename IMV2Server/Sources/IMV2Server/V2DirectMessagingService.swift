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
    private let roomShardIDs: [String]
    private let identifiers: V2DirectMessagingIDFactory
    private let now: @Sendable () -> Date

    public init(store: any V2DirectMessagingStore, capacityProfile: V2CapacityProfile, roomShardID: String, identifiers: V2DirectMessagingIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) throws {
        let shards = roomShardID
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...64).contains(shards.count),
              shards.allSatisfy({ !$0.isEmpty }),
              Set(shards).count == shards.count
        else { throw V2DirectMessagingPolicyError.invalidLimit }
        self.store = store
        self.capacityProfile = capacityProfile
        self.roomShardIDs = shards
        self.identifiers = identifiers
        self.now = now
    }

    public func open(actorUserID: UserID, operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2OpenDirectRoomOutcome {
        let command = try V2OpenDirectRoomCommand(actorUserID: actorUserID, operationID: operationID, targetUserID: targetUserID)
        return try await store.open(
            command: command,
            capacityProfile: capacityProfile,
            roomShardID: shardID(for: command),
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

    /// FNV-1a is deliberately fixed rather than Swift's randomized `Hasher`:
    /// every gateway replica and process restart must choose the same pool for
    /// an unordered user pair. Pair locking in the store remains the final
    /// creation fence, while spreading independent rooms removes a single
    /// shard-admission row as a process-wide serialization point.
    private func shardID(for command: V2OpenDirectRoomCommand) -> String {
        guard roomShardIDs.count > 1 else { return roomShardIDs[0] }
        let pair = [command.actorUserID.rawValue.lowercased(), command.targetUserID.rawValue.lowercased()].sorted()
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in (pair[0] + "\u{0}" + pair[1]).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return roomShardIDs[Int(hash % UInt64(roomShardIDs.count))]
    }
}
