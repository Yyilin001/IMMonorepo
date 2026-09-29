import IMV2Core

/// 用于恢复缺失逐角色历史的策略投影的当前状态读取接口。
///
/// 调用方只负责设备认证；所选房间归属会在返回基线前独立复核发起者的当前成员身份，
/// 因此已退群或从未入群的用户不会拿到基线。
public protocol V2GroupRolePolicyBaselineReading: Sendable {
    /// 读取房间当前的角色策略基线。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起读取的用户，需为当前成员。
    /// - Returns: 与房间当前状态一致的策略基线。
    /// - Throws: 房间不存在、发起者非成员或持久化状态损坏时抛出。
    func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupRolePolicyBaseline
}

/// 角色策略基线读取错误。
public enum V2GroupRolePolicyBaselineError: Error, Equatable, Sendable {
    /// 房间在归属存储中不存在。
    case roomNotFound
    /// 发起读取的用户不是该房间的当前成员。
    case actorNotMember
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
