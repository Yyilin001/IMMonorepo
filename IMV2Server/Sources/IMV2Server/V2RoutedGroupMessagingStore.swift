import Crypto
import Foundation
import IMV2Core

/// Stable candidate selection for a group creation that has not yet acquired
/// a durable intent. The intent store persists the result before owner work,
/// so later configuration changes affect only new operations.
public struct V2GroupRoomShardSelector: Equatable, Sendable {
    public let shardIDs: [String]

    /// Deployment form used by `IM_V2_GROUP_ROOM_SHARD_ID`. Existing room
    /// routes are durable and never re-hashed; this ordered set is consulted
    /// only before a new creation intent has fixed its owner.
    public init(rawValue: String) throws {
        try self.init(shardIDs: rawValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    public init(shardIDs: [String]) throws {
        let normalized = shardIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard (1 ... 64).contains(normalized.count),
              normalized.allSatisfy({ !$0.isEmpty }),
              Set(normalized).count == normalized.count
        else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        self.shardIDs = normalized.sorted()
    }

    public func shardID(
        actorUserID: UserID,
        operationID: GroupRoomOperationID
    ) -> String {
        guard shardIDs.count > 1 else { return shardIDs[0] }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in (
            actorUserID.rawValue.lowercased()
                + "\u{0}"
                + operationID.rawValue.lowercased()
        ).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return shardIDs[Int(hash % UInt64(shardIDs.count))]
    }
}

/// Cross-database group creation coordinator for inline audiences. It fixes a
/// control-plane intent, executes exactly one selected owner store, then
/// finalizes the canonical room route. No database address or fresh hash is
/// accepted from the client.
///
/// Staged 100k-member creation is deliberately not claimed here yet: its
/// member manifest needs a paged control-to-owner transfer with independent
/// digests before this type can safely conform to
/// `V2StagedGroupMessagingStore`.
public struct V2RoutedGroupMessagingStore:
    V2GroupMessagingStore,
    V2StagedGroupMessagingStore
{
    private let intentStore: any V2GroupRoomCreationIntentStore
    private let selector: V2GroupRoomShardSelector
    private let ownerStores:
        [String: any V2ControlValidatedStagedGroupMessagingStore]

    public init(
        intentStore: any V2GroupRoomCreationIntentStore,
        ownerStores: [String: any V2ControlValidatedStagedGroupMessagingStore]
    ) throws {
        guard !ownerStores.isEmpty else {
            throw V2RoomShardStorageRegistryError.invalidLocation
        }
        let selector = try V2GroupRoomShardSelector(
            shardIDs: Array(ownerStores.keys)
        )
        self.intentStore = intentStore
        self.selector = selector
        self.ownerStores = ownerStores
    }

    public func create(
        command: V2CreateGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID _: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        let candidate = try V2GroupRoomCreationIntent(
            actorUserID: command.actorUserID,
            operationID: command.operationID,
            roomID: roomID,
            eventID: eventID,
            planID: planID,
            roomShardID: selector.shardID(
                actorUserID: command.actorUserID,
                operationID: command.operationID
            ),
            routeEpoch: 0,
            requestFingerprint: groupCreationFingerprint(command),
            audienceMemberCount: command.allMemberUserIDs.count
        )
        let intent: V2GroupRoomCreationIntent
        switch try await intentStore.prepare(
            candidate,
            memberUserIDs: command.allMemberUserIDs,
            now: now
        ) {
        case .prepared(let prepared), .idempotent(let prepared):
            intent = prepared
        case .idempotencyConflict:
            return .idempotencyConflict
        case .invalidMembers:
            return .invalidMembers
        }
        guard let owner = ownerStores[intent.roomShardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        let validatedMemberUserIDs = try await intentStore.memberUserIDs(
            for: intent
        )
        guard validatedMemberUserIDs == command.allMemberUserIDs else {
            // SHA-256 equality was already checked by `prepare`; comparing the
            // canonical relation as well turns any corrupt/incomplete manifest
            // into a hard topology failure before owner state is mutated.
            throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
        }
        let outcome = try await owner.createControlValidated(
            command: command,
            validatedMemberUserIDs: validatedMemberUserIDs,
            capacityProfile: capacityProfile,
            roomShardID: intent.roomShardID,
            roomID: intent.roomID,
            eventID: intent.eventID,
            planID: intent.planID,
            now: now
        )
        switch outcome {
        case .created(let group), .idempotent(let group):
            guard group.roomID == intent.roomID else {
                throw V2GroupRoomCreationIntentStoreError.routeConflict
            }
            _ = try await intentStore.finalizeCommitted(intent, now: now)
        case .idempotencyConflict, .invalidMembers, .memberLimitReached,
             .rateLimited, .unavailable:
            break
        }
        return outcome
    }

    public func createStaged(
        command: V2StagedGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID _: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        let candidate = try V2GroupRoomCreationIntent(
            actorUserID: command.actorUserID,
            operationID: command.operationID,
            roomID: roomID,
            eventID: eventID,
            planID: planID,
            roomShardID: selector.shardID(
                actorUserID: command.actorUserID,
                operationID: command.operationID
            ),
            routeEpoch: 0,
            requestFingerprint: stagedGroupCreationFingerprint(command),
            audienceMemberCount: command.allMemberCount
        )
        let intent: V2GroupRoomCreationIntent
        switch try await intentStore.prepareStaged(
            candidate,
            command: command,
            now: now
        ) {
        case .prepared(let prepared), .idempotent(let prepared):
            intent = prepared
        case .idempotencyConflict:
            return .idempotencyConflict
        case .invalidMembers:
            return .invalidMembers
        }
        guard let owner = ownerStores[intent.roomShardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }

        var pageNumber = 0
        var afterUserID: UserID?
        var transferredCount = 0
        while true {
            try Task.checkCancellation()
            let slice = try await intentStore.memberUserIDSlice(
                for: intent,
                afterUserID: afterUserID,
                limit: V2GroupRoomCreationManifestPage.maximumMemberCount
            )
            // Bound the cumulative count before writing any page. The
            // manifest must advance its cursor and finish exactly at the
            // immutable intent count, including when resuming a partial copy.
            let remainingCount = intent.audienceMemberCount - transferredCount
            guard !slice.memberUserIDs.isEmpty,
                  slice.memberUserIDs.count <= remainingCount,
                  slice.memberUserIDs.count <= V2GroupRoomCreationManifestPage.maximumMemberCount,
                  Set(slice.memberUserIDs).count == slice.memberUserIDs.count,
                  afterUserID.map({ cursor in slice.memberUserIDs.allSatisfy { $0 > cursor } }) ?? true,
                  slice.hasMore == (slice.memberUserIDs.count < remainingCount) else {
                throw V2GroupRoomCreationIntentStoreError
                    .corruptPersistenceState
            }
            let page = try V2GroupRoomCreationManifestPage(
                pageNumber: pageNumber,
                memberUserIDs: slice.memberUserIDs,
                isFinal: !slice.hasMore
            )
            try await owner.stageControlValidatedAudience(
                intent: intent,
                page: page,
                now: now
            )
            transferredCount += page.memberUserIDs.count
            afterUserID = page.memberUserIDs.last
            if page.isFinal { break }
            pageNumber += 1
        }
        guard transferredCount == intent.audienceMemberCount else {
            throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
        }
        let outcome = try await owner.createControlValidatedStaged(
            command: command,
            intent: intent,
            capacityProfile: capacityProfile,
            now: now
        )
        switch outcome {
        case .created(let group), .idempotent(let group):
            guard group.roomID == intent.roomID else {
                throw V2GroupRoomCreationIntentStoreError.routeConflict
            }
            _ = try await intentStore.finalizeCommitted(intent, now: now)
        case .idempotencyConflict, .invalidMembers, .memberLimitReached,
             .rateLimited, .unavailable:
            break
        }
        return outcome
    }
}

private struct GroupCreationFingerprintEnvelope: Encodable {
    let version: Int
    let actorUserID: String
    let operationID: String
    let title: String
    let deliveryMode: String
    let initialMemberUserIDs: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case actorUserID = "actor_user_id"
        case operationID = "operation_id"
        case title
        case deliveryMode = "delivery_mode"
        case initialMemberUserIDs = "initial_member_user_ids"
    }
}

private func groupCreationFingerprint(
    _ command: V2CreateGroupRoomCommand
) throws -> Data {
    let envelope = GroupCreationFingerprintEnvelope(
        version: 1,
        actorUserID: command.actorUserID.rawValue.lowercased(),
        operationID: command.operationID.rawValue.lowercased(),
        title: command.title,
        deliveryMode: command.deliveryMode.rawValue,
        initialMemberUserIDs: command.initialMemberUserIDs
            .map { $0.rawValue.lowercased() }
            .sorted()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Data(SHA256.hash(data: try encoder.encode(envelope)))
}

private struct StagedGroupCreationFingerprintEnvelope: Encodable {
    let version: Int
    let actorUserID: String
    let operationID: String
    let title: String
    let deliveryMode: String
    let stagedMemberCount: Int

    enum CodingKeys: String, CodingKey {
        case version
        case actorUserID = "actor_user_id"
        case operationID = "operation_id"
        case title
        case deliveryMode = "delivery_mode"
        case stagedMemberCount = "staged_member_count"
    }
}

private func stagedGroupCreationFingerprint(
    _ command: V2StagedGroupRoomCommand
) throws -> Data {
    let envelope = StagedGroupCreationFingerprintEnvelope(
        version: 1,
        actorUserID: command.actorUserID.rawValue.lowercased(),
        operationID: command.operationID.rawValue.lowercased(),
        title: command.title,
        deliveryMode: command.deliveryMode.rawValue,
        stagedMemberCount: command.stagedMemberCount
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Data(SHA256.hash(data: try encoder.encode(envelope)))
}
