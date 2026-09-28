import Foundation
import IMV2Core

/// 资料展示（联系人备注与群昵称）的存储边界。
///
/// 实现负责把已认证的展示更新落到持久存储；HTTP/领域适配器只做输入校验与结果转换。
public protocol V2ProfilePresentationManaging: Sendable {
    /// 按目标用户游标分页读取账号所有者维护的联系人备注。
    ///
    /// - Parameters:
    ///   - ownerUserID: 拥有这批备注的用户。
    ///   - afterTargetUserID: 分页起点之后的目标用户，首页传 `nil`。
    ///   - limit: 本次最多返回的条目数。
    /// - Returns: 备注分页，含下一页游标。
    /// - Throws: 存储不可用或持久化状态损坏时抛出。
    func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int) async throws -> V2ContactAliasPage
    /// 写入或清除某个联系人的备注名。
    ///
    /// - Parameters:
    ///   - ownerUserID: 拥有该备注的用户。
    ///   - targetUserID: 被备注的目标用户。
    ///   - operationID: 该次操作的稳定标识，用于幂等重试。
    ///   - expectedRevision: 期望的当前修订，`nil` 表示此前不存在该记录。
    ///   - remarkName: 新的备注名；传 `nil` 表示清除。
    /// - Returns: 写入后的备注记录。
    /// - Throws: 修订冲突、载荷不匹配或存储失败时抛出。
    func updateContactAlias(_ command:V2ContactAliasUpdateCommand) async throws -> V2ContactAliasUpdateReceipt
    func recoverContactAlias(_ request:V2ContactAliasRecoveryRequest) async throws -> V2ContactAliasRecoveryResult
    func contactAliasSnapshot(ownerUserID:UserID,targetUserID:UserID) async throws -> V2ContactAliasSnapshot
    /// 按成员游标分页读取群昵称展示。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起读取的成员。
    ///   - roomID: 目标群组房间。
    ///   - afterUserID: 分页起点之后的成员，首页传 `nil`。
    ///   - limit: 本次最多返回的条目数。
    /// - Returns: 群昵称分页，含下一页游标。
    /// - Throws: 无权限、存储不可用或持久化状态损坏时抛出。
    func groupNicknames(actorUserID: UserID, roomID: RoomID, afterUserID: UserID?, limit: Int) async throws -> V2GroupNicknamePage
    /// 更新发起者本人在某群组内的昵称。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起更新的成员。
    ///   - roomID: 目标群组房间。
    ///   - operationID: 该次操作的稳定标识，用于幂等重试。
    ///   - expectedRevision: 期望的当前修订，`nil` 表示此前不存在该记录。
    ///   - nickname: 新的群昵称；传 `nil` 表示清除。
    /// - Returns: 更新后的群成员展示。
    /// - Throws: 修订冲突、载荷不匹配或存储失败时抛出。
    func updateOwnGroupNickname(_ command:V2GroupNicknameUpdateCommand) async throws -> V2GroupNicknameUpdateReceipt
    func recoverGroupNickname(_ request:V2GroupNicknameRecoveryRequest) async throws -> V2GroupNicknameRecoveryResult
    func ownGroupNicknameSnapshot(actorUserID:UserID,roomID:RoomID) async throws -> V2GroupNicknameSnapshot
}

/// 联系人备注的一页结果。
public struct V2ContactAliasPage: Equatable, Sendable {
    /// 本页备注记录。
    public let values: [V2ContactAlias]
    /// 下一页游标；已到末尾时为 `nil`。
    public let nextCursor: UserID?
    /// 创建分页结果。
    ///
    /// - Parameters:
    ///   - values: 本页备注记录。
    ///   - nextCursor: 下一页游标。
    public init(values: [V2ContactAlias], nextCursor: UserID?) {
        self.values = values
        self.nextCursor = nextCursor
    }
}

/// 房间权威内部的昵称候选页，不代表控制域资料可见性或展示授权。
/// HTTP 必须再次经过 V2ResourceProfilePresentationService，不得直接返回本值。
public struct V2GroupNicknamePage: Equatable, Sendable {
    /// 本页群成员展示记录。
    public let values: [V2GroupMemberPresentation]
    /// 下一页游标；已到末尾时为 `nil`。
    public let nextCursor: UserID?
    /// 创建分页结果。
    ///
    /// - Parameters:
    ///   - values: 本页群成员展示记录。
    ///   - nextCursor: 下一页游标。
    public init(values: [V2GroupMemberPresentation], nextCursor: UserID?) {
        self.values = values
        self.nextCursor = nextCursor
    }
}

/// 资料展示写入与读取的错误分类。
public enum V2ProfilePresentationError: Error, Equatable, Sendable {
    /// 依赖的存储暂时不可用。
    case unavailable
    /// 调用者无权读取或修改该展示信息。
    case forbidden
    /// 展示修订冲突；关联值为当前服务端修订。
    case revisionConflict(V2ProfileRevision?)
    /// 同一操作标识提交了与首次不同的载荷。
    case operationPayloadMismatch
    /// 展示内容不合法（例如超长或包含非法字符）。
    case invalidPresentation
    /// 持久化状态与预期不一致。
    case corruptPersistenceState
}
