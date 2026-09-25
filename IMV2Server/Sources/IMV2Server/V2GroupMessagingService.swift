import Foundation
import IMV2Core

/// 建群结果。
public enum V2CreateGroupRoomOutcome: Equatable, Sendable {
    /// 本次调用实际创建了房间。
    case created(V2GroupRoom)
    /// 同一操作已创建过房间，返回其原有结果。
    case idempotent(V2GroupRoom)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 初始成员列表非法。
    case invalidMembers
    /// 成员数量超过房间上限。
    case memberLimitReached
    /// 被限流，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 准入或存储当前不可用。
    case unavailable
}

/// 群房间创建的持久化能力。
///
/// 创建事务由存储负责：房间与资料行、初始群主与成员、操作记录以及准入租约必须一同提交。
/// 网关绝不能绕开该边界自行拼装出群房间。
public protocol V2GroupMessagingStore: Sendable {
    /// 创建群房间。
    ///
    /// - Parameters:
    ///   - command: 建群命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - roomShardID: 创建时选定的房间归属分片。
    ///   - roomID: 预分配的房间标识。
    ///   - eventID: 建群事件标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 建群结果。
    /// - Throws: 准入不足、成员非法或持久化失败时抛出。
    func create(
        command: V2CreateGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome
}

/// 只在控制面已原子校验并持久化精确初始受众之后使用的归属侧能力。
///
/// 它与普通 ``V2GroupMessagingStore/create(command:capacityProfile:roomShardID:roomID:eventID:now:)``
/// 分开声明，避免路由协调器意外依赖归属库中过期或不完整的身份副本。
public protocol V2ControlValidatedGroupMessagingStore: V2GroupMessagingStore {
    /// 以控制面校验过的成员列表创建群房间。
    ///
    /// - Parameters:
    ///   - command: 建群命令。
    ///   - validatedMemberUserIDs: 控制面已校验并冻结的成员列表。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - roomShardID: 创建时选定的房间归属分片。
    ///   - roomID: 预分配的房间标识。
    ///   - eventID: 建群事件标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 建群结果。
    /// - Throws: 成员列表与命令不符、准入不足或持久化失败时抛出。
    func createControlValidated(
        command: V2CreateGroupRoomCommand,
        validatedMemberUserIDs: [UserID],
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome
}

/// 面向已在 PostgreSQL 中分阶段写入并冻结的受众的可选存储能力。
///
/// 应用进程只携带权威计数；存储在房间引导事务内以集合式 SQL 消费不可变成员关系，
/// 因此无需把完整成员列表读回进程。
public protocol V2StagedGroupMessagingStore: Sendable {
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
    /// - Throws: 分阶段受众缺失、摘要不符或持久化失败时抛出。
    func createStaged(
        command: V2StagedGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome
}

/// 分阶段建群命令，只携带权威计数而不携带完整成员列表。
public struct V2StagedGroupRoomCommand: Equatable, Sendable {
    /// 发起建群的用户。
    public let actorUserID: UserID
    /// 建群操作标识。
    public let operationID: GroupRoomOperationID
    /// 房间标题，沿用公开命令的规范化结果。
    public let title: String
    /// 房间投递模式。
    public let capacityClass: V2GroupCapacityClass
    /// 分阶段成员数量。
    ///
    /// 该计数不含群主，与分阶段草稿关系保持一致。
    public let stagedMemberCount: Int

    /// 校验并保存分阶段建群命令。
    ///
    /// 标题复用公开命令的完全相同的规范化契约；成员数量需非负且小于 `Int.max`。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起建群的用户。
    ///   - operationID: 建群操作标识。
    ///   - title: 房间标题。
    ///   - capacityClass: 投递模式。
    ///   - stagedMemberCount: 不含群主的分阶段成员数量。
    /// - Throws: 标题不合法或成员数量越界时抛出
    ///   ``V2GroupMessagingPolicyError/invalidInitialMembership``。
    public init(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        title: String,
        capacityClass: V2GroupCapacityClass,
        stagedMemberCount: Int
    ) throws {
        // 复用公开命令的精确标题规范化契约。
        let validated = try V2CreateGroupRoomCommand(
            actorUserID: actorUserID,
            operationID: operationID,
            title: title,
            capacityClass: capacityClass,
            initialMemberUserIDs: []
        )
        guard stagedMemberCount >= 0, stagedMemberCount < Int.max else {
            throw V2GroupMessagingPolicyError.invalidInitialMembership
        }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.title = validated.title
        self.capacityClass = capacityClass
        self.stagedMemberCount = stagedMemberCount
    }

    /// 含群主的成员总数。
    public var allMemberCount: Int { stagedMemberCount + 1 }
}

/// 建群所需的标识生成器。
public struct V2GroupMessagingIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    /// 注入 UUID 来源。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.makeUUID = makeUUID
    }

    /// 生成房间与事件两个标识。
    ///
    /// - Returns: 本次建群使用的标识组合。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func make() throws -> (roomID: RoomID, eventID: EventID) {
        try (.init(makeUUID().uuidString), .init(makeUUID().uuidString))
    }
}

/// 群建群服务。
///
/// 建群是一条独立的持久化命令，而不是对隐含房间执行一串加人操作；
/// 这样即使响应丢失，初始权限与受众仍然是原子的。
public struct V2GroupMessagingService: Sendable {
    private let store: any V2GroupMessagingStore
    private let capacityProfile: V2CapacityProfile
    private let deliveryPolicy: V2GroupCapacityPolicy
    private let roomShardID: String
    private let identifiers: V2GroupMessagingIDFactory
    private let now: @Sendable () -> Date

    /// 组合建群存储、容量档位与投递策略。
    ///
    /// - Parameters:
    ///   - store: 建群持久化存储。
    ///   - capacityProfile: 固定容量档位。
    ///   - deliveryPolicy: 投递策略，默认使用标准值。
    ///   - roomShardID: 房间归属分片标识，去除首尾空白后需非空。
    ///   - identifiers: 标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 分片标识为空白时抛出
    ///   ``V2GroupMessagingPolicyError/invalidRoomShard``。
    public init(
        store: any V2GroupMessagingStore,
        capacityProfile: V2CapacityProfile,
        deliveryPolicy: V2GroupCapacityPolicy = .init(),
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

    /// 以显式成员列表创建群房间。
    ///
    /// 先用临时投递模式校验不可信的成员输入，再评估容量：格式非法的请求不会被错误地
    /// 归类为容量拒绝。命令构造会去重并剔除群主，随后以去重后的数量为准复核容量与投递策略。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起建群的用户。
    ///   - operationID: 建群操作标识。
    ///   - title: 房间标题。
    ///   - initialMemberUserIDs: 初始成员列表，不含群主。
    /// - Returns: 建群结果。
    /// - Throws: 成员格式非法或数量不一致时抛出
    ///   ``V2GroupMessagingPolicyError/invalidInitialMembership``；其余错误来自存储实现。
    public func create(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        title: String,
        initialMemberUserIDs: [UserID]
    ) async throws -> V2CreateGroupRoomOutcome {
        let initialMemberCount = initialMemberUserIDs.count + 1
        // 评估容量前先校验不可信的成员输入。
        // 格式错误的请求即使提交了大型数组，也不能被重新分类为容量拒绝。
        let provisionalMode = deliveryPolicy.capacityClass(forInitialMemberCount: initialMemberCount) ?? .large
        let command = try V2CreateGroupRoomCommand(
            actorUserID: actorUserID,
            operationID: operationID,
            title: title,
            capacityClass: provisionalMode,
            initialMemberUserIDs: initialMemberUserIDs
        )
        guard command.allMemberUserIDs.count <= capacityProfile.limits.maxEligibleMembers,
              let capacityClass = deliveryPolicy.capacityClass(forInitialMemberCount: command.allMemberUserIDs.count)
        else {
            return .memberLimitReached
        }
        // `V2CreateGroupRoomCommand` 会规范化并校验成员列表，
        // 因此完成重复项和所有者检查后，应以其计数为准。
        guard command.allMemberUserIDs.count == initialMemberCount,
              deliveryPolicy.acceptsInitialMemberCount(command.allMemberUserIDs.count, mode: capacityClass)
        else { throw V2GroupMessagingPolicyError.invalidInitialMembership }
        let derivedCommand = try V2CreateGroupRoomCommand(
            actorUserID: command.actorUserID,
            operationID: command.operationID,
            title: command.title,
            capacityClass: capacityClass,
            initialMemberUserIDs: command.initialMemberUserIDs
        )
        let ids = try identifiers.make()
        return try await store.create(
            command: derivedCommand,
            capacityProfile: capacityProfile,
            roomShardID: roomShardID,
            roomID: ids.roomID,
            eventID: ids.eventID,
            now: now()
        )
    }

    /// 以已冻结的分阶段受众创建群房间。
    ///
    /// 进程只按权威计数评估容量与投递模式；存储不支持分阶段建群时返回不可用，
    /// 而不是退化成读取完整成员列表。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起建群的用户。
    ///   - operationID: 建群操作标识。
    ///   - title: 房间标题。
    ///   - stagedMemberCount: 不含群主的分阶段成员数量。
    /// - Returns: 建群结果。
    /// - Throws: 成员数量为负时抛出
    ///   ``V2GroupMessagingPolicyError/invalidInitialMembership``；其余错误来自存储实现。
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
              let capacityClass = deliveryPolicy.capacityClass(forInitialMemberCount: memberCount),
              deliveryPolicy.acceptsInitialMemberCount(memberCount, mode: capacityClass)
        else { return .memberLimitReached }
        let command = try V2StagedGroupRoomCommand(
            actorUserID: actorUserID,
            operationID: operationID,
            title: title,
            capacityClass: capacityClass,
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
            now: now()
        )
    }
}

/// 群消息策略错误。
public enum V2GroupMessagingPolicyError: Error, Equatable, Sendable {
    /// 房间归属分片标识为空白。
    case invalidRoomShard
    /// 初始成员列表或数量不满足约束。
    case invalidInitialMembership
}
