import Foundation
import IMV2ActorContracts
import IMV2Core

/// 由组合根提供的类型化引导派发。它选择固定分片，
/// 不查找未知房间，也不调用普通的 RoomRef。
public struct V2ActorCreationBootstrapPort: Sendable {
    public let execute: @Sendable (V2ActorRoomBootstrapCommand, ContinuousClock.Instant) async throws -> V2ActorRoomCreationResult
    public let stage: @Sendable (V2ActorGroupCreationIntentWire, V2ActorGroupCreationManifestPageWire,
                                 ContinuousClock.Instant) async throws -> Void

    public init(execute: @escaping @Sendable (V2ActorRoomBootstrapCommand, ContinuousClock.Instant) async throws -> V2ActorRoomCreationResult,
                stage: @escaping @Sendable (V2ActorGroupCreationIntentWire, V2ActorGroupCreationManifestPageWire,
                                            ContinuousClock.Instant) async throws -> Void) {
        self.execute = execute
        self.stage = stage
    }
}

/// 控制意图在引导操作触及所有者之前，固定放置位置、房间／事件 ID、指纹和受众。
/// 恢复时重复执行相同流程。
struct V2ActorGroupCreationStore: V2GroupMessagingStore, V2StagedGroupMessagingStore {
    let intents: any V2GroupRoomCreationIntentStore
    let selector: V2GroupRoomShardSelector
    let bootstrap: V2ActorCreationBootstrapPort
    let deadline: ContinuousClock.Instant

    func create(command: V2CreateGroupRoomCommand, capacityProfile: V2CapacityProfile,
                roomShardID _: String, roomID: RoomID, eventID: EventID,
                now: Date) async throws -> V2CreateGroupRoomOutcome {
        let candidate = try V2GroupRoomCreationIntent(actorUserID: command.actorUserID,
            operationID: command.operationID, roomID: roomID, eventID: eventID,
            roomShardID: selector.shardID(actorUserID: command.actorUserID,
                                           operationID: command.operationID),
            routeEpoch: 0, requestFingerprint: groupCreationFingerprint(command),
            audienceMemberCount: command.allMemberUserIDs.count)
        let intent: V2GroupRoomCreationIntent
        switch try await intents.prepare(candidate, memberUserIDs: command.allMemberUserIDs, now: now) {
        case .prepared(let value), .idempotent(let value): intent = value
        case .idempotencyConflict: return .idempotencyConflict
        case .invalidMembers: return .invalidMembers
        }
        let frozen = try await intents.memberUserIDs(for: intent)
        guard frozen == command.allMemberUserIDs else {
            throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
        }
        let request = V2ActorGroupBootstrapWire(actorUserID: command.actorUserID,
            operationID: command.operationID, title: command.title,
            capacityClass: command.capacityClass,
            initialMemberUserIDs: command.initialMemberUserIDs,
            validatedMemberUserIDs: frozen, intent: .init(domain: intent))
        guard case .group(let wire) = try await bootstrap.execute(.group(request), deadline) else {
            throw V2GroupRoomCreationIntentStoreError.routeConflict
        }
        let outcome = try wire.toDomain()
        try await finalizeIfCommitted(outcome, intent: intent, now: now)
        return outcome
    }

    func createStaged(command: V2StagedGroupRoomCommand,
                      capacityProfile: V2CapacityProfile, roomShardID _: String,
                      roomID: RoomID, eventID: EventID,
                      now: Date) async throws -> V2CreateGroupRoomOutcome {
        let candidate = try V2GroupRoomCreationIntent(actorUserID: command.actorUserID,
            operationID: command.operationID, roomID: roomID, eventID: eventID,
            roomShardID: selector.shardID(actorUserID: command.actorUserID,
                                           operationID: command.operationID),
            routeEpoch: 0, requestFingerprint: stagedGroupCreationFingerprint(command),
            audienceMemberCount: command.allMemberCount)
        let intent: V2GroupRoomCreationIntent
        switch try await intents.prepareStaged(candidate, command: command, now: now) {
        case .prepared(let value), .idempotent(let value): intent = value
        case .idempotencyConflict: return .idempotencyConflict
        case .invalidMembers: return .invalidMembers
        }
        var pageNumber = 0
        var after: UserID?
        var transferred = 0
        while true {
            try Task.checkCancellation()
            let slice = try await intents.memberUserIDSlice(for: intent, afterUserID: after,
                limit: V2GroupRoomCreationManifestPage.maximumMemberCount)
            let remaining = intent.audienceMemberCount - transferred
            guard remaining > 0, !slice.memberUserIDs.isEmpty,
                  slice.memberUserIDs.count <= remaining,
                  slice.memberUserIDs.count <= V2GroupRoomCreationManifestPage.maximumMemberCount,
                  Set(slice.memberUserIDs).count == slice.memberUserIDs.count,
                  after.map({ prior in slice.memberUserIDs.allSatisfy { $0 > prior } }) ?? true,
                  slice.hasMore == (slice.memberUserIDs.count < remaining) else {
                throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
            }
            let page = try V2GroupRoomCreationManifestPage(pageNumber: pageNumber,
                memberUserIDs: slice.memberUserIDs, isFinal: !slice.hasMore)
            try await bootstrap.stage(.init(domain: intent), .init(domain: page), deadline)
            transferred += page.memberUserIDs.count
            after = page.memberUserIDs.last
            if page.isFinal { break }
            pageNumber += 1
        }
        guard transferred == intent.audienceMemberCount else {
            throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
        }
        let request = V2ActorStagedGroupBootstrapWire(actorUserID: command.actorUserID,
            operationID: command.operationID, title: command.title,
            capacityClass: command.capacityClass,
            stagedMemberCount: command.stagedMemberCount, intent: .init(domain: intent))
        guard case .group(let wire) = try await bootstrap.execute(.stagedGroup(request), deadline) else {
            throw V2GroupRoomCreationIntentStoreError.routeConflict
        }
        let outcome = try wire.toDomain()
        try await finalizeIfCommitted(outcome, intent: intent, now: now)
        return outcome
    }

    private func finalizeIfCommitted(_ outcome: V2CreateGroupRoomOutcome,
                                     intent: V2GroupRoomCreationIntent,
                                     now: Date) async throws {
        switch outcome {
        case .created(let room), .idempotent(let room):
            guard room.roomID == intent.roomID else {
                throw V2GroupRoomCreationIntentStoreError.routeConflict
            }
            _ = try await intents.finalizeCommitted(intent, now: now)
        case .idempotencyConflict, .invalidMembers, .memberLimitReached,
             .rateLimited, .unavailable:
            break
        }
    }
}
