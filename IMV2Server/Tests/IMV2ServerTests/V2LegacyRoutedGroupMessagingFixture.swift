import Foundation
import IMV2Core
@testable import IMV2Server

/// 面向内联受众的跨库建群协调器。
///
/// 它先固定控制面意图，再执行唯一选中的归属存储，最后确定规范房间路由。
/// 客户端提交的数据库地址或临时哈希都不会被接受。
///
/// 分阶段建群通过带摘要的控制面成员分页传输到归属存储。
public struct V2RoutedGroupMessagingStore:
    V2GroupMessagingStore,
    V2StagedGroupMessagingStore
{
    private let intentStore: any V2GroupRoomCreationIntentStore
    private let selector: V2GroupRoomShardSelector
    private let ownerStores:
        [String: any V2ControlValidatedStagedGroupMessagingStore]

    /// 组合创建意图存储与各归属存储。
    ///
    /// - Parameters:
    ///   - intentStore: 持久化创建意图的控制面存储。
    ///   - ownerStores: 逻辑分片标识到归属建群存储的映射，需非空。
    /// - Throws: 归属映射为空时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
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

    /// 创建群房间。
    ///
    /// 先固定控制面意图，再只向选中的归属存储发起一次建群，最后确定规范房间路由。
    ///
    /// - Parameters:
    ///   - command: 建群命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - roomShardID: 创建时选定的房间归属分片。
    ///   - roomID: 预分配的房间标识。
    ///   - eventID: 建群事件标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 建群结果。
    /// - Throws: 归属未配置、意图冲突或归属存储失败时抛出。
    public func create(
        command: V2CreateGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID _: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        let candidate = try V2GroupRoomCreationIntent(
            actorUserID: command.actorUserID,
            operationID: command.operationID,
            roomID: roomID,
            eventID: eventID,
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

    /// 以已冻结的分阶段受众创建群房间。
    ///
    /// - Parameters:
    ///   - command: 分阶段建群命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - roomShardID: 创建时选定的房间归属分片。
    ///   - roomID: 预分配的房间标识。
    ///   - eventID: 建群事件标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 建群结果。
    /// - Throws: 归属未配置、创建意图准备失败或归属存储返回错误时抛出。
    public func createStaged(
        command: V2StagedGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID _: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        let candidate = try V2GroupRoomCreationIntent(
            actorUserID: command.actorUserID,
            operationID: command.operationID,
            roomID: roomID,
            eventID: eventID,
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
