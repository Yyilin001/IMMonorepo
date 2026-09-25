import IMV2Core

public enum V2RoomActivationAcquisition: Equatable, Sendable {
    /// 刚提交的新纪元。宿主仍须完成恢复才能进入就绪状态。
    case acquired(V2RoomActivationLease)
    /// 已存在另一份有效授权，也可能是授予此宿主实例的授权。
    case occupied(V2RoomActivationLease)
}

public enum V2RoomActivationLeaseError: Error, Equatable, Sendable {
    case roomNotFound
    case ownerChanged
    case activationChanged
    case leaseExpired
    case epochExhausted
    /// 数据库可能已提交新租约，但没有返回令牌。
    /// 调用方必须重新定位围栏，不能宣称已回滚。
    case outcomeUnknown
}

/// 实际房间数据库是激活位置的唯一权威。
///
/// 实现会先取得房间围栏，再读取当前数据库时钟。
/// 释放后仍保留纪元计数器，并持有与业务写入相同的围栏直到自身事务提交。
public protocol V2RoomActivationLeaseStore: Sendable {
    /// 只返回在数据库观测时刻仍有效的租约。
    func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease?

    /// 不因发现或 RPC 故障而抢占尚未过期的租约。
    func acquire(
        roomID: RoomID,
        owner: V2RoomDataOwner,
        host: V2ActorHostIdentity,
        duration: V2ActorMilliseconds
    ) async throws -> V2RoomActivationAcquisition

    /// 匹配但已过期的令牌必须获取新纪元，不能续期。
    func renew(
        token: V2RoomActivationToken,
        duration: V2ActorMilliseconds
    ) async throws -> V2RoomActivationLease

    /// 返回 false 表示此令牌已不再拥有租约；绝不释放后继实例的租约。
    func release(token: V2RoomActivationToken) async throws -> Bool
}

/// 数据所有者查询封装在运行时内部；调用方只提供 RoomID。
public protocol V2RoomDataOwnerResolving: Sendable {
    func owner(for roomID: RoomID) async throws -> V2RoomDataOwner
}

public enum V2RoomActivationPhase: String, Codable, Sendable {
    case acquiring
    case restoring
    case ready
    case draining
    case uncertain
    case stopped
}
