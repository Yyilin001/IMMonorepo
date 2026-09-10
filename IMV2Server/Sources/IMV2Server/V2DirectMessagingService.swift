import Foundation
import IMV2Core

/// 陌生人消息限流策略。
public struct V2StrangerMessagePolicy: Equatable, Sendable {
    /// 单个窗口内允许的最大消息数。
    public let maximumMessagesPerWindow: Int
    /// 计数窗口长度。
    public let window: TimeInterval

    /// 校验并保存限流策略。
    ///
    /// - Parameters:
    ///   - maximumMessagesPerWindow: 窗口内最大消息数，需大于零。
    ///   - window: 计数窗口长度，需可表示为整秒且能编码为 PostgreSQL 时间戳。
    /// - Throws: 任一取值越界时抛出
    ///   ``V2DirectMessagingPolicyError/invalidLimit``。
    public init(maximumMessagesPerWindow: Int, window: TimeInterval) throws {
        guard maximumMessagesPerWindow > 0, v2RateLimitDurationIsRepresentable(window) else { throw V2DirectMessagingPolicyError.invalidLimit }
        self.maximumMessagesPerWindow = maximumMessagesPerWindow
        self.window = window
    }
}

/// 私聊策略错误。
public enum V2DirectMessagingPolicyError: Error, Equatable, Sendable { case invalidLimit }

/// 新建私聊房间使用的有序、由部署方控制的归属集合。
///
/// 选中的归属会随房间一并持久化，因此该路由器只在创建时使用；
/// 已有房间的变更绝不能反过来查询它来重新选路。
public struct V2DirectRoomShardRouter: Equatable, Sendable {
    /// 分片标识非法。
    public enum Error: Swift.Error, Equatable, Sendable { case invalidShardIDs }

    /// 参与轮转的候选分片标识，顺序即路由契约的一部分。
    public let shardIDs: [String]

    /// 以逗号分隔的形式构造，保持与既有 `IM_V2_DIRECT_ROOM_SHARD_ID` 配置的兼容。
    ///
    /// 顺序属于路由契约的一部分：调整顺序必须走一次显式的路由发布流程。
    ///
    /// - Parameter rawValue: 逗号分隔的分片标识，元素会去除首尾空白。
    /// - Throws: 分片数量、空白元素或重复项不满足约束时抛出
    ///   ``V2DirectRoomShardRouter/Error/invalidShardIDs``。
    public init(rawValue: String) throws {
        let shardIDs = rawValue
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        try self.init(shardIDs: shardIDs)
    }

    /// 以分片标识列表构造路由器。
    ///
    /// - Parameter shardIDs: 非空、无空白元素且无重复的标识列表，数量需落在 `1...64`。
    /// - Throws: 任一约束不满足时抛出 ``V2DirectRoomShardRouter/Error/invalidShardIDs``。
    public init(shardIDs: [String]) throws {
        guard (1...64).contains(shardIDs.count),
              shardIDs.allSatisfy({ !$0.isEmpty }),
              Set(shardIDs).count == shardIDs.count
        else { throw Error.invalidShardIDs }
        self.shardIDs = shardIDs
    }

    /// 为无序用户对选择分片。
    ///
    /// 这里刻意固定使用 FNV-1a 而非 Swift 随机化的 `Hasher`：每个网关副本与每次进程重启
    /// 都必须为同一对用户选出相同的归属。仅配置一个分片时直接返回该标识。
    ///
    /// - Parameters:
    ///   - firstUserID: 用户对中的一方。
    ///   - secondUserID: 用户对中的另一方。
    /// - Returns: 选中的分片标识。
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

/// 打开私聊房间的结果。
public enum V2OpenDirectRoomOutcome: Equatable, Sendable {
    /// 本次调用实际创建了房间。
    case opened(V2DirectRoom)
    /// 该用户对的房间已存在，返回其原有结果。
    case idempotent(V2DirectRoom)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 准入或存储当前不可用。
    case unavailable
}

/// 设置陌生人消息权限的结果。
public enum V2SetStrangerMessagePermissionOutcome: Equatable, Sendable {
    /// 本次调用实际更新了权限。
    case updated(permission: V2StrangerMessagePermission, updatedAt: Date)
    /// 同一操作已提交过，返回其原有结果。
    case idempotent(permission: V2StrangerMessagePermission, updatedAt: Date)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
}

/// 设置被添加好友权限的结果。
public enum V2SetUserAddPermissionOutcome: Equatable, Sendable {
    /// 本次调用实际更新了权限。
    case updated(permission: V2UserAddPermission, updatedAt: Date)
    /// 同一操作已提交过，返回其原有结果。
    case idempotent(permission: V2UserAddPermission, updatedAt: Date)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
}

/// 私聊房间与相关权限的持久化能力。
public protocol V2DirectMessagingStore: Sendable {
    /// 打开或复用一对用户的私聊房间。
    ///
    /// - Parameters:
    ///   - command: 打开私聊房间命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - roomShardID: 创建时选定的房间归属分片。
    ///   - roomID: 本次预分配的房间标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 打开结果。
    /// - Throws: 准入不足、归属冲突或持久化失败时抛出。
    func open(
        command: V2OpenDirectRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        now: Date
    ) async throws -> V2OpenDirectRoomOutcome

    /// 设置陌生人对当前用户的私聊消息权限。
    ///
    /// - Parameters:
    ///   - command: 权限变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
    func setStrangerMessagePermission(
        command: V2SetStrangerMessagePermissionCommand,
        now: Date
    ) async throws -> V2SetStrangerMessagePermissionOutcome

    /// 设置陌生人对当前用户发起添加的好友权限。
    ///
    /// - Parameters:
    ///   - command: 权限变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
    func setUserAddPermission(
        command: V2SetUserAddPermissionCommand,
        now: Date
    ) async throws -> V2SetUserAddPermissionOutcome
}

/// 私聊房间标识生成器。
public struct V2DirectMessagingIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    /// 注入 UUID 来源，默认使用系统实现。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包，测试可注入确定性实现。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    /// 生成一个房间标识。
    ///
    /// - Returns: 新房间标识。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func makeRoomID() throws -> RoomID { try .init(makeUUID().uuidString) }
}

/// 私聊消息服务。
///
/// 私聊房间对每个无序用户对唯一且稳定。用户对加锁与初始准入状态由存储边界负责，
/// 因此调用方无法并发地为同一对用户创建出两个房间。
public struct V2DirectMessagingService: Sendable {
    private let store: any V2DirectMessagingStore
    private let capacityProfile: V2CapacityProfile
    private let roomShardRouter: V2DirectRoomShardRouter
    private let identifiers: V2DirectMessagingIDFactory
    private let now: @Sendable () -> Date

    /// 以逗号分隔的分片配置构造服务。
    ///
    /// - Parameters:
    ///   - store: 私聊持久化存储。
    ///   - capacityProfile: 固定容量档位。
    ///   - roomShardID: 逗号分隔的房间分片配置。
    ///   - identifiers: 房间标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 分片配置非法时抛出
    ///   ``V2DirectRoomShardRouter/Error/invalidShardIDs``。
    public init(store: any V2DirectMessagingStore, capacityProfile: V2CapacityProfile, roomShardID: String, identifiers: V2DirectMessagingIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) throws {
        try self.init(
            store: store,
            capacityProfile: capacityProfile,
            roomShardRouter: .init(rawValue: roomShardID),
            identifiers: identifiers,
            now: now
        )
    }

    /// 以已构建的路由器构造服务。
    ///
    /// - Parameters:
    ///   - store: 私聊持久化存储。
    ///   - capacityProfile: 固定容量档位。
    ///   - roomShardRouter: 新建房间使用的归属路由器。
    ///   - identifiers: 房间标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2DirectMessagingStore, capacityProfile: V2CapacityProfile, roomShardRouter: V2DirectRoomShardRouter, identifiers: V2DirectMessagingIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) throws {
        self.store = store
        self.capacityProfile = capacityProfile
        self.roomShardRouter = roomShardRouter
        self.identifiers = identifiers
        self.now = now
    }

    /// 打开与目标用户的私聊房间。
    ///
    /// 房间归属在创建时按用户对计算并随房间持久化，后续变更不会再重新选路。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起打开的用户。
    ///   - operationID: 幂等操作标识。
    ///   - targetUserID: 目标用户。
    /// - Returns: 打开结果。
    /// - Throws: 命令构造失败、标识生成失败或存储失败时抛出。
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

    /// 设置陌生人消息权限。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起设置的用户。
    ///   - operationID: 幂等操作标识。
    ///   - permission: 目标权限取值。
    /// - Returns: 变更结果。
    /// - Throws: 命令构造失败或存储失败时抛出。
    public func setStrangerMessagePermission(actorUserID: UserID, operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> V2SetStrangerMessagePermissionOutcome {
        try await store.setStrangerMessagePermission(command: .init(actorUserID: actorUserID, operationID: operationID, permission: permission), now: now())
    }

    /// 设置被添加好友权限。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起设置的用户。
    ///   - operationID: 幂等操作标识。
    ///   - permission: 目标权限取值。
    /// - Returns: 变更结果。
    /// - Throws: 命令构造失败或存储失败时抛出。
    public func setUserAddPermission(actorUserID: UserID, operationID: UserAddPreferenceOperationID, permission: V2UserAddPermission) async throws -> V2SetUserAddPermissionOutcome {
        try await store.setUserAddPermission(command: .init(actorUserID: actorUserID, operationID: operationID, permission: permission), now: now())
    }

}
