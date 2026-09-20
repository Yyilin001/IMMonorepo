import Crypto
import Foundation
import IMV2Core

/// 尚未获得持久化创建意图时使用的稳定候选分片选择器。
///
/// 意图存储会在归属工作开始之前先持久化选择结果，
/// 因此之后的配置变化只会影响新操作，不会改变已有创建过程。
public struct V2GroupRoomShardSelector: Equatable, Sendable {
    /// 参与选择的候选分片标识，已规范化并排序。
    public let shardIDs: [String]

    /// 以 `IM_V2_GROUP_ROOM_SHARD_ID` 使用的逗号分隔形式构造。
    ///
    /// 既有房间路由是持久化的，绝不会被重新哈希；该有序集合只会在新的创建意图
    /// 尚未固定归属之前参与选择。
    ///
    /// - Parameter rawValue: 逗号分隔的分片标识，元素会去除首尾空白。
    /// - Throws: 分片数量、空白元素或重复项不满足约束时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
    public init(rawValue: String) throws {
        try self.init(shardIDs: rawValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    /// 以分片标识列表构造选择器。
    ///
    /// 标识会去除首尾空白并排序，使同一集合的不同输入顺序得到相同结果。
    ///
    /// - Parameter shardIDs: 非空、无空白元素且无重复的标识列表，数量需落在 `1...64`。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
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

    /// 为一次建群操作选择候选分片。
    ///
    /// 选择结果稳定：同一发起者与操作标识始终得到同一候选分片。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起建群的用户。
    ///   - operationID: 建群操作标识。
    /// - Returns: 选中的分片标识。
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

private struct GroupCreationFingerprintEnvelope: Encodable {
    let version: Int
    let actorUserID: String
    let operationID: String
    let title: String
    let capacityClass: String
    let initialMemberUserIDs: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case actorUserID = "actor_user_id"
        case operationID = "operation_id"
        case title
        case capacityClass = "capacity_class"
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
        capacityClass: command.capacityClass.rawValue,
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
    let capacityClass: String
    let stagedMemberCount: Int

    enum CodingKeys: String, CodingKey {
        case version
        case actorUserID = "actor_user_id"
        case operationID = "operation_id"
        case title
        case capacityClass = "capacity_class"
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
        capacityClass: command.capacityClass.rawValue,
        stagedMemberCount: command.stagedMemberCount
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Data(SHA256.hash(data: try encoder.encode(envelope)))
}
