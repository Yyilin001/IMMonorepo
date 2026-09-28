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
