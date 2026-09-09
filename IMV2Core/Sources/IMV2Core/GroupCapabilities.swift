import Foundation

/// 房间内置顶或取消置顶的幂等命令。
///
/// 权威处理为变更分配房间序号并按该顺序投递，命令本身不验证成员权限或消息可见性。
public struct V2PinnedMessageCommand: Equatable, Sendable {
    /// 本值的不可变业务字段；各字段含义见初始化参数说明。
    public let operationID: PinnedMessageOperationID; public let roomID: RoomID; public let messageID: MessageID; public let isPinned: Bool
    /// 构造业务命令。
    ///
    /// - Parameters:
    ///   - operationID: 稳定置顶操作身份。
    ///   - roomID: 目标房间。
    ///   - messageID: 待改变置顶状态的消息。
    ///   - isPinned: 期望的置顶状态。
    ///
    /// 仅保存字段，不读取旧置顶状态或验证权限。
    public init(operationID: PinnedMessageOperationID, roomID: RoomID, messageID: MessageID, isPinned: Bool) { self.operationID = operationID; self.roomID = roomID; self.messageID = messageID; self.isPinned = isPinned }
}

/// 消息置顶状态变更结果，携带对应房间顺序及更新时间。
public struct V2PinnedMessage: Equatable, Sendable {
    /// 本值的不可变业务字段；各字段含义见初始化参数说明。
    public let roomID: RoomID; public let messageID: MessageID; public let isPinned: Bool; public let roomSequence: UInt64; public let updatedAt: Date
    /// 构造业务结果。
    ///
    /// - Parameters:
    ///   - roomID: 变更所属房间。
    ///   - messageID: 目标消息。
    ///   - isPinned: 最终置顶状态。
    ///   - roomSequence: 变更房间序号，1 到 Int64.max。
    ///   - updatedAt: 更新时间，未在构造器校验。
    ///
    /// 房间序号越界时抛出 outOfRange；不检查日期、消息存在性或事务提交状态。
    public init(roomID: RoomID, messageID: MessageID, isPinned: Bool, roomSequence: UInt64, updatedAt: Date) throws {
        guard roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID; self.messageID = messageID; self.isPinned = isPinned; self.roomSequence = roomSequence; self.updatedAt = updatedAt }
}

/// 带预期公告版本的群公告更新命令，保留原始正文。
public struct V2GroupAnnouncementCommand: Equatable, Sendable {
    /// 公告原始正文的 UTF-8 字节上限：4096。
    public static let maximumUTF8Bytes = 4_096
    /// 本值的不可变业务字段；各字段含义见初始化参数说明。
    public let operationID: GroupAnnouncementOperationID; public let roomID: RoomID; public let body: String; public let expectedRevision: UInt64
    /// 构造业务命令。
    ///
    /// - Parameters:
    ///   - operationID: 本次公告修改的稳定身份。
    ///   - roomID: 目标群。
    ///   - body: 非纯空白且最多 4096 个 UTF-8 字节的原始正文。
    ///   - expectedRevision: 预期公告版本，允许零且不超过 Int64.max。
    ///
    /// 正文裁剪后为空时抛出 emptyAnnouncement，原始字节数超限时抛出 announcementTooLarge，版本越界时抛出 outOfRange；保存正文原样，不裁剪或过滤内部控制字符。
    public init(operationID: GroupAnnouncementOperationID, roomID: RoomID, body: String, expectedRevision: UInt64) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2GroupPermissionValidationError.emptyAnnouncement }
        guard body.lengthOfBytes(using: .utf8) <= Self.maximumUTF8Bytes else { throw V2GroupPermissionValidationError.announcementTooLarge }
        guard expectedRevision <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.operationID = operationID; self.roomID = roomID; self.body = body; self.expectedRevision = expectedRevision
    }
}

/// 群公告变更结果，携带公告版本与房间事件顺序。
public struct V2GroupAnnouncement: Equatable, Sendable {
    /// 本值的不可变业务字段；各字段含义见初始化参数说明。
    public let roomID: RoomID; public let body: String; public let revision: UInt64; public let roomSequence: UInt64; public let updatedAt: Date
    /// 构造业务结果。
    ///
    /// - Parameters:
    ///   - roomID: 公告所属群。
    ///   - body: 公告正文，结果构造器不重复校验长度或非空。
    ///   - revision: 变更后的正公告版本。
    ///   - roomSequence: 正房间事件序号。
    ///   - updatedAt: 更新时间，构造器不校验日期。
    ///
    /// 公告版本及房间序号必须位于 1 到 Int64.max，否则抛出 outOfRange；不验证相对旧公告的版本递增关系。
    public init(roomID: RoomID, body: String, revision: UInt64, roomSequence: UInt64, updatedAt: Date) throws {
        guard revision > 0, revision <= UInt64(Int64.max), roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID; self.body = body; self.revision = revision; self.roomSequence = roomSequence; self.updatedAt = updatedAt }
}

/// 修改非群主角色完整权限集合的命令，使用权限修订号并发控制。
public struct V2GroupRolePermissionsCommand: Equatable, Sendable {
    /// 本值的不可变业务字段；各字段含义见初始化参数说明。
    public let operationID: GroupPermissionOperationID; public let roomID: RoomID; public let role: V2RoomMembershipRole; public let permissions: Set<V2GroupPermission>; public let expectedRevision: UInt64
    /// 构造业务命令。
    ///
    /// - Parameters:
    ///   - operationID: 稳定策略修改操作身份。
    ///   - roomID: 目标群。
    ///   - role: 目标角色，只允许 admin 或 member。
    ///   - permissions: 新的完整权限集合，空集合表示不授予权限。
    ///   - expectedRevision: 预期权限版本，1 到 Int64.max。
    ///
    /// 目标为 owner 时抛出 ownerPolicyIsImmutable，版本为零时抛出 invalidPositiveValue，超过 Int64.max 时抛出 outOfRange；不校验操作者权限，调用边界负责。
    public init(operationID: GroupPermissionOperationID, roomID: RoomID, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, expectedRevision: UInt64) throws {
        guard role != .owner else { throw V2GroupPermissionValidationError.ownerPolicyIsImmutable }
        guard expectedRevision > 0 else { throw V2CoreError.invalidPositiveValue }
        guard expectedRevision <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.operationID = operationID; self.roomID = roomID; self.role = role; self.permissions = permissions; self.expectedRevision = expectedRevision
    }
}

/// 角色权限变更结果，仅描述指定角色的新集合及对应版本。
public struct V2GroupRolePermissionsChange: Equatable, Sendable {
    /// 本值的不可变业务字段；各字段含义见初始化参数说明。
    public let roomID: RoomID; public let role: V2RoomMembershipRole; public let permissions: Set<V2GroupPermission>; public let revision: UInt64; public let roomSequence: UInt64
    /// 构造业务结果。
    ///
    /// - Parameters:
    ///   - roomID: 目标群。
    ///   - role: 变更角色，结果构造器不拒绝 owner。
    ///   - permissions: 完整结果权限集合。
    ///   - revision: 正权限版本。
    ///   - roomSequence: 正房间事件序号。
    ///
    /// 版本与序号必须位于 1 到 Int64.max，否则抛出 outOfRange；不补充默认权限或验证角色可修改性。
    public init(roomID: RoomID, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, revision: UInt64, roomSequence: UInt64) throws {
        guard revision > 0, revision <= UInt64(Int64.max), roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID; self.role = role; self.permissions = permissions; self.revision = revision; self.roomSequence = roomSequence }
}

/// 修改单个成员角色的命令，以预期成员版本进行并发控制，不用于转让群主。
public struct V2GroupMemberRoleCommand: Equatable, Sendable {
    /// 本值的不可变业务字段；各字段含义见初始化参数说明。
    public let operationID: GroupRoleOperationID; public let roomID: RoomID; public let targetUserID: UserID; public let role: V2RoomMembershipRole; public let expectedMembershipRevision: UInt64
    /// 构造业务命令。
    ///
    /// - Parameters:
    ///   - operationID: 稳定成员角色操作身份。
    ///   - roomID: 目标群。
    ///   - targetUserID: 待修改角色的成员。
    ///   - role: 目标角色，只允许 admin 或 member。
    ///   - expectedMembershipRevision: 预期成员修订号，1 到 Int64.max。
    ///
    /// 目标角色为 owner 时抛出 memberRoleCannotBeOwner，版本为零时抛出 invalidPositiveValue，超范围时抛出 outOfRange；不读取目标当前角色或成员资格。
    public init(operationID: GroupRoleOperationID, roomID: RoomID, targetUserID: UserID, role: V2RoomMembershipRole, expectedMembershipRevision: UInt64) throws {
        guard role != .owner else { throw V2GroupPermissionValidationError.memberRoleCannotBeOwner }
        guard expectedMembershipRevision > 0 else { throw V2CoreError.invalidPositiveValue }
        guard expectedMembershipRevision <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.operationID = operationID; self.roomID = roomID; self.targetUserID = targetUserID; self.role = role; self.expectedMembershipRevision = expectedMembershipRevision
    }
}

/// 成员角色变更结果，包含新的成员版本与房间序号。
public struct V2GroupMemberRoleChange: Equatable, Sendable {
    /// 本值的不可变业务字段；各字段含义见初始化参数说明。
    public let roomID: RoomID; public let targetUserID: UserID; public let role: V2RoomMembershipRole; public let membershipRevision: UInt64; public let roomSequence: UInt64
    /// 构造业务结果。
    ///
    /// - Parameters:
    ///   - roomID: 目标群。
    ///   - targetUserID: 被修改的成员。
    ///   - role: 结果角色，构造器不额外限制 owner。
    ///   - membershipRevision: 变更后的正成员版本。
    ///   - roomSequence: 正房间事件序号。
    ///
    /// 成员版本与序号必须位于 1 到 Int64.max，否则抛出 outOfRange；不判断目标当前权限或版本是否连续。
    public init(roomID: RoomID, targetUserID: UserID, role: V2RoomMembershipRole, membershipRevision: UInt64, roomSequence: UInt64) throws {
        guard membershipRevision > 0, membershipRevision <= UInt64(Int64.max), roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID; self.targetUserID = targetUserID; self.role = role; self.membershipRevision = membershipRevision; self.roomSequence = roomSequence }
}
