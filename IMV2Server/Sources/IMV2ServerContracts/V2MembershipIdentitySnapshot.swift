import Foundation
import IMV2Core

/// 用于把授权事实桥接进房间归属事务的控制面身份快照。
///
/// 归属存储仍会自行完成全部房间内角色、修订与成员关系校验，
/// 该快照不会替代这些检查。
public struct V2MembershipIdentitySnapshot: Equatable, Sendable {
    /// 发起者用户。
    public let actorUserID: UserID
    /// 目标用户。
    public let targetUserID: UserID
    /// 发起者账号是否有效。
    public let actorIsActive: Bool
    /// 目标账号是否有效。
    public let targetIsActive: Bool

    /// 保存身份快照。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起者用户。
    ///   - targetUserID: 目标用户。
    ///   - actorIsActive: 发起者账号是否有效。
    ///   - targetIsActive: 目标账号是否有效。
    public init(
        actorUserID: UserID,
        targetUserID: UserID,
        actorIsActive: Bool,
        targetIsActive: Bool
    ) {
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.actorIsActive = actorIsActive
        self.targetIsActive = targetIsActive
    }
}

/// 成员身份快照读取能力。
public protocol V2MembershipIdentitySnapshotValidating: Sendable {
    /// 读取一次成员身份快照。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起者用户。
    ///   - targetUserID: 目标用户。
    /// - Returns: 两个身份事实的快照。
    /// - Throws: 控制面存储不可用时抛出。
    func snapshot(
        actorUserID: UserID,
        targetUserID: UserID
    ) async throws -> V2MembershipIdentitySnapshot
}
