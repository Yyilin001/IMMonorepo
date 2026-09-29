import IMV2ServerContracts
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

public enum V2GroupMessagingPolicyError: Error, Equatable, Sendable {
    /// 房间归属分片标识为空白。
    case invalidRoomShard
    /// 初始成员列表或数量不满足约束。
    case invalidInitialMembership
}
