import Foundation

/// 分享链接或二维码携带的敏感 Bearer 秘密，服务端持久化路径应仅保存摘要。
///
/// 构造器只检查字符形式，不生成随机值、证明熵或确认邀请有效；文本描述脱敏，但 rawValue 仍公开原文。
public struct V2GroupInviteSecret: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 43 字节的敏感邀请秘密原文。
    public let rawValue: String

    /// 要求恰好 43 个 ASCII 字母、数字、连字符或下划线，否则抛出 invalidSecret；不执行 Base64 解码或规范重编码检查。
    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == 43,
              rawValue.utf8.allSatisfy({ byte in
                  switch byte {
                  case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39, 0x2D, 0x5F:
                      true
                  default:
                      false
                  }
              })
        else { throw V2GroupInvitationValidationError.invalidSecret }
        self.rawValue = rawValue
    }

    /// 返回固定脱敏文本，避免普通字符串插值泄露邀请秘密。
    public var description: String { "<redacted-group-invite-secret>" }
    /// 调试描述复用脱敏文本。
    public var debugDescription: String { description }
}

/// 邀请链接的服务端生命周期状态。
public enum V2GroupInviteState: String, Codable, Equatable, Sendable {
    /// 邀请当前可用。
    case active
    /// 邀请已被撤销。
    case revoked
    /// 邀请期限已结束。
    case expired
    /// 批准使用次数已经耗尽。
    case exhausted
}

/// 入群申请的服务端处理阶段，包含可恢复的批准中间态。
public enum V2GroupJoinRequestState: String, Codable, Equatable, Sendable {
    /// 等待审核。
    case pending
    /// 正在批准，可能需要恢复已跨过成员提交的决定。
    case approving
    /// 已批准申请。
    case approved
    /// 申请人已取消。
    case cancelled
    /// 已拒绝申请。
    case rejected
}

/// 审核者提交的入群决定。
public enum V2GroupJoinDecision: String, Codable, Equatable, Sendable {
    /// 批准入群。
    case approve
    /// 拒绝申请。
    case reject
}

/// 可分享邀请的完整结果，含敏感秘密和使用次数快照。
///
/// 模型状态不自行随时钟更新，也不因次数增加自动变更，实时有效性由服务端决定。
public struct V2GroupInviteLink: Equatable, Sendable, Identifiable {
    /// 稳定邀请身份。
    public let inviteID: GroupInviteID
    /// 目标群。
    public let roomID: RoomID
    /// 裁剪后的展示群名，最多 120 个 UTF-8 字节。
    public let roomTitle: String
    /// 链接携带的敏感邀请秘密。
    public let secret: V2GroupInviteSecret
    /// 服务端邀请状态。
    public let state: V2GroupInviteState
    /// 邀请截止时间。
    public let expiresAt: Date
    /// 最大批准使用次数，必须为正。
    public let maximumApprovedUses: Int
    /// 已批准使用次数，非负且不超过上限。
    public let approvedUseCount: Int
    /// 邀请创建时间。
    public let createdAt: Date

    /// 提供邀请身份作为稳定列表标识。
    public var id: GroupInviteID { inviteID }

    /// 构造邀请业务结果。
    ///
    /// - Parameters:
    ///   - inviteID: 稳定邀请身份。
    ///   - roomID: 目标群。
    ///   - roomTitle: 裁剪后的展示群名，最多 120 个 UTF-8 字节。
    ///   - secret: 链接携带的敏感邀请秘密。
    ///   - state: 服务端邀请状态。
    ///   - expiresAt: 邀请截止时间。
    ///   - maximumApprovedUses: 最大批准使用次数，必须为正。
    ///   - approvedUseCount: 已批准使用次数，非负且不超过上限。
    ///   - createdAt: 邀请创建时间。
    ///
    /// 校验标题非空及长度、使用计数范围，并要求 expiresAt 严格晚于 createdAt，否则抛出 invalidLink；不额外验证日期有限性、当前是否过期或 state 与计数一致。
    public init(
        inviteID: GroupInviteID,
        roomID: RoomID,
        roomTitle: String,
        secret: V2GroupInviteSecret,
        state: V2GroupInviteState,
        expiresAt: Date,
        maximumApprovedUses: Int,
        approvedUseCount: Int,
        createdAt: Date
    ) throws {
        let title = roomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 120,
              maximumApprovedUses > 0,
              approvedUseCount >= 0,
              approvedUseCount <= maximumApprovedUses,
              expiresAt > createdAt
        else { throw V2GroupInvitationValidationError.invalidLink }
        self.inviteID = inviteID
        self.roomID = roomID
        self.roomTitle = title
        self.secret = secret
        self.state = state
        self.expiresAt = expiresAt
        self.maximumApprovedUses = maximumApprovedUses
        self.approvedUseCount = approvedUseCount
        self.createdAt = createdAt
    }
}

/// 用户查看邀请时的群资料及当前申请状态，不包含邀请秘密。
public struct V2GroupInvitePreview: Equatable, Sendable {
    /// 邀请身份。
    public let inviteID: GroupInviteID
    /// 目标群。
    public let roomID: RoomID
    /// 裁剪后的展示群名。
    public let roomTitle: String
    /// 邀请期限，不在此检查当前有效性。
    public let expiresAt: Date
    /// 当前用户可选申请状态。
    public let requestState: V2GroupJoinRequestState?
    /// 与申请状态同时存在或同时缺失的申请身份。
    public let requestID: GroupJoinRequestID?
    /// 当前用户是否已是成员。
    public let isAlreadyMember: Bool

    /// 构造邀请业务结果。
    ///
    /// - Parameters:
    ///   - inviteID: 邀请身份。
    ///   - roomID: 目标群。
    ///   - roomTitle: 裁剪后的展示群名。
    ///   - expiresAt: 邀请期限，不在此检查当前有效性。
    ///   - requestState: 当前用户可选申请状态。
    ///   - requestID: 与申请状态同时存在或同时缺失的申请身份。
    ///   - isAlreadyMember: 当前用户是否已是成员。
    ///
    /// 标题须非空且不超过 120 字节，申请状态与身份须同时存在或缺失，否则抛出 invalidPreview；不验证成员标记与申请状态的关系。
    public init(
        inviteID: GroupInviteID,
        roomID: RoomID,
        roomTitle: String,
        expiresAt: Date,
        requestState: V2GroupJoinRequestState?,
        requestID: GroupJoinRequestID?,
        isAlreadyMember: Bool
    ) throws {
        let title = roomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 120,
              (requestState == nil) == (requestID == nil)
        else { throw V2GroupInvitationValidationError.invalidPreview }
        self.inviteID = inviteID
        self.roomID = roomID
        self.roomTitle = title
        self.expiresAt = expiresAt
        self.requestState = requestState
        self.requestID = requestID
        self.isAlreadyMember = isAlreadyMember
    }
}

/// 入群申请及审核恢复信息，展示申请者公开身份和经过裁剪的备注。
public struct V2GroupJoinRequest: Equatable, Sendable, Identifiable {
    /// 申请身份。
    public let requestID: GroupJoinRequestID
    /// 来源邀请身份。
    public let inviteID: GroupInviteID
    /// 目标群。
    public let roomID: RoomID
    /// 申请者公开身份。
    public let applicant: V2PublicIdentity
    /// 可选申请备注，裁剪后最多 500 个 UTF-8 字节，空白转换为 nil。
    public let note: String?
    /// 当前审核阶段。
    public let state: V2GroupJoinRequestState
    /// 仅 approving 阶段可存在的恢复决定身份，由服务端限定同一审核者可使用。
    public let resumableDecisionOperationID: GroupJoinDecisionOperationID?
    /// 申请创建时间。
    public let createdAt: Date
    /// 可选决定时间，仅 approved、rejected 或 cancelled 阶段允许存在。
    public let decidedAt: Date?

    /// 提供申请身份作为稳定列表标识。
    public var id: GroupJoinRequestID { requestID }

    /// 构造邀请业务结果。
    ///
    /// - Parameters:
    ///   - requestID: 申请身份。
    ///   - inviteID: 来源邀请身份。
    ///   - roomID: 目标群。
    ///   - applicant: 申请者公开身份。
    ///   - note: 可选申请备注，裁剪后最多 500 个 UTF-8 字节，空白转换为 nil。
    ///   - state: 当前审核阶段。
    ///   - resumableDecisionOperationID: 仅 approving 阶段可存在的恢复决定身份，由服务端限定同一审核者可使用。
    ///   - createdAt: 申请创建时间。
    ///   - decidedAt: 可选决定时间，仅 approved、rejected 或 cancelled 阶段允许存在。
    ///
    /// 校验备注长度与状态字段组合，否则抛出 invalidRequest；approving 不强制有恢复身份，终态也不强制有决定时间，不校验日期先后或有限性。
    public init(
        requestID: GroupJoinRequestID,
        inviteID: GroupInviteID,
        roomID: RoomID,
        applicant: V2PublicIdentity,
        note: String?,
        state: V2GroupJoinRequestState,
        resumableDecisionOperationID: GroupJoinDecisionOperationID?,
        createdAt: Date,
        decidedAt: Date?
    ) throws {
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedNote?.utf8.count ?? 0 <= 500,
              state == .approving || resumableDecisionOperationID == nil,
              state == .approved || state == .rejected || state == .cancelled || decidedAt == nil
        else { throw V2GroupInvitationValidationError.invalidRequest }
        self.requestID = requestID
        self.inviteID = inviteID
        self.roomID = roomID
        self.applicant = applicant
        self.note = normalizedNote?.isEmpty == false ? normalizedNote : nil
        self.state = state
        self.resumableDecisionOperationID = resumableDecisionOperationID
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}

/// 入群申请列表的一页结果，游标由服务端定义。
public struct V2GroupJoinRequestPage: Equatable, Sendable {
    /// 本页申请顺序。
    public let requests: [V2GroupJoinRequest]
    /// 可选后续游标。
    public let nextCursor: String?

    /// 构造邀请业务结果。
    ///
    /// - Parameters:
    ///   - requests: 本页申请顺序。
    ///   - nextCursor: 可选后续游标。
    ///
    /// 保存列表与游标，不校验同页重复、页面大小或游标内容。
    public init(requests: [V2GroupJoinRequest], nextCursor: String?) {
        self.requests = requests
        self.nextCursor = nextCursor
    }
}

/// 邀请秘密、链接、预览或申请模型的校验错误。
public enum V2GroupInvitationValidationError: Error, Equatable, Sendable {
    /// 邀请秘密长度或字符集无效。
    case invalidSecret
    /// 邀请标题、使用计数或时间顺序不符合约束。
    case invalidLink
    /// 预览标题无效或申请状态与身份没有同时存在。
    case invalidPreview
    /// 申请备注或状态相关字段组合不符合约束。
    case invalidRequest
}
