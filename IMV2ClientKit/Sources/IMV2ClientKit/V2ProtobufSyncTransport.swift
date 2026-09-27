import Crypto
import Foundation
import IMV2Core

/// 同步适配器所依赖的已认证帧连接。
///
/// 具体连接拥有 TLS、重连与认证生命周期；此接口只负责发送一个请求并返回关联响应，便于离线测试协议映射。
public protocol V2AuthenticatedFrameTransport: Sendable {
    /// 发送完整请求帧并等待对应响应；关联管理、取消和连接错误由具体传输实现负责。
    func request(_ frame: V2Frame) async throws -> V2Frame
}

/// 映射媒体展示类型与元数据；拒绝未指定或未知类型，再由领域初始化验证其余约束。
private func v2MediaPresentation(from wire: IMV2MediaPresentation) throws -> V2MediaPresentation {
    let kind: V2MediaPresentation.Kind
    switch wire.kind {
    case .image: kind = .image
    case .animatedImage: kind = .animatedImage
    case .video: kind = .video
    case .audio: kind = .audio
    case .file: kind = .file
    case .unspecified, .UNRECOGNIZED:
        throw V2RealtimeTransportError.unexpectedResponse
    }
    return try .init(
        mediaID: .init(wire.mediaID),
        kind: kind,
        contentType: wire.contentType,
        byteCount: wire.byteCount
    )
}

/// 映射富文本类型与 UTF-16 范围；拒绝未知类型，非空链接尝试转换 URL 后交给领域初始化校验。
private func v2MessageEntity(from wire: IMV2MessageEntity) throws -> V2MessageEntity {
    let kind: V2MessageEntity.Kind
    switch wire.kind {
    case .bold: kind = .bold
    case .italic: kind = .italic
    case .underline: kind = .underline
    case .strikethrough: kind = .strikethrough
    case .spoiler: kind = .spoiler
    case .code: kind = .code
    case .preformatted: kind = .preformatted
    case .link: kind = .link
    case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse
    }
    return try .init(offsetUTF16: Int(wire.offsetUtf16), lengthUTF16: Int(wire.lengthUtf16), kind: kind, linkURL: wire.linkURL.isEmpty ? nil : URL(string: wire.linkURL))
}

/// 把已验证的富文本实体编码为 protobuf；调用方需保证 UTF-16 偏移和长度可转换为 UInt32。
private func v2MessageEntityWire(_ entity: V2MessageEntity) -> IMV2MessageEntity {
    var wire = IMV2MessageEntity()
    wire.offsetUtf16 = UInt32(entity.offsetUTF16)
    wire.lengthUtf16 = UInt32(entity.lengthUTF16)
    wire.kind = switch entity.kind {
    case .bold: .bold
    case .italic: .italic
    case .underline: .underline
    case .strikethrough: .strikethrough
    case .spoiler: .spoiler
    case .code: .code
    case .preformatted: .preformatted
    case .link: .link
    }
    wire.linkURL = entity.linkURL?.absoluteString ?? ""
    return wire
}

/// 只包含正式身份、房间位置和时间的消息接受回执。
///
/// 不携带消息正文；已接受内容应从获授权的事件或投影同步获得，不能根据重试确认重新构造正文。
public struct V2ClientMessageAcceptance: Equatable, Sendable {
    /// 正式消息身份。
    public let messageID: MessageID
    /// 接受结果所属房间。
    public let roomID: RoomID
    /// 服务器确定的房间位置。
    public let roomSequence: UInt64
    /// 服务器接受时间。
    public let createdAt: Date

    /// 保存不包含正文的接受回执并验证房间序列范围。
    ///
    /// - Parameters:
    ///   - messageID: 正式消息身份。
    ///   - roomID: 所属房间。
    ///   - roomSequence: 大于零且不超过 Int64.max 的房间位置。
    ///   - createdAt: 服务器接受时间，构造本身不检查有限性或正负。
    /// - Throws: 房间序列不在范围内时抛出修订范围错误。
    public init(messageID: MessageID, roomID: RoomID, roomSequence: UInt64, createdAt: Date) throws {
        guard roomSequence > 0 && roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

/// 已认证消息发送边界，接收稳定客户端身份并返回正式接受回执；不拥有本地发件箱。
public protocol V2ClientMessageTransport: Sendable {
    /// 发送原始消息意图并返回不含正文的正式接受回执。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - clientMessageID: 跨重试保持稳定的客户端身份。
    ///   - text: 消息文本。
    ///   - media: 有序媒体引用。
    ///   - mentions: 提及目标。
    ///   - entities: 富文本实体。
    ///   - replyTo: 可选回复引用。
    /// - Returns: 服务器接受身份和位置。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    ///
    /// 调用者负责入队与回执持久化，不应根据返回回执重建消息正文。
    func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?) async throws -> V2ClientMessageAcceptance
}

/// 会话置顶、归档、静音和消息收藏的传输边界；返回服务器结果，本地持久化由调用方负责。
public protocol V2ClientConversationCapabilitiesTransport: Sendable {
    /// 提交会话置顶、归档与静音状态。
    ///
    /// - Parameter command: 已构造的稳定业务命令，重试应保持身份与内容一致。
    /// - Returns: 服务器确认的领域结果。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    func setConversationState(command: V2ConversationStateCommand) async throws -> V2ConversationState
    /// 提交消息收藏状态。
    ///
    /// - Parameter command: 已构造的稳定业务命令，重试应保持身份与内容一致。
    /// - Returns: 服务器确认的领域结果。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    func setMessageFavorite(command: V2MessageFavoriteCommand) async throws -> V2MessageFavorite
}

/// 群消息置顶、公告及角色策略变更的传输能力，权限判定和并发修订控制由服务端执行。
public protocol V2ClientGroupCapabilitiesTransport: Sendable {
    /// 提交群消息置顶或取消置顶。
    ///
    /// - Parameter command: 已构造的稳定业务命令，重试应保持身份与内容一致。
    /// - Returns: 服务器确认的领域结果。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    func setPinnedMessage(command: V2PinnedMessageCommand) async throws -> V2PinnedMessage
    /// 以预期修订更新群公告。
    ///
    /// - Parameter command: 已构造的稳定业务命令，重试应保持身份与内容一致。
    /// - Returns: 服务器确认的领域结果。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    func setGroupAnnouncement(command: V2GroupAnnouncementCommand) async throws -> V2GroupAnnouncement
    /// 以预期修订替换指定角色的权限集合。
    ///
    /// - Parameter command: 已构造的稳定业务命令，重试应保持身份与内容一致。
    /// - Returns: 服务器确认的领域结果。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    func setGroupRolePermissions(command: V2GroupRolePermissionsCommand) async throws -> V2GroupRolePermissionsChange
    /// 以预期成员修订变更成员角色。
    ///
    /// - Parameter command: 已构造的稳定业务命令，重试应保持身份与内容一致。
    /// - Returns: 服务器确认的领域结果。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    func changeGroupMemberRole(command: V2GroupMemberRoleCommand) async throws -> V2GroupMemberRoleChange
}

/// 转发命令的已认证传输边界，按来源消息与目标房间组合返回独立结果。
public protocol V2ClientForwardMessagesTransport: Sendable {
    /// 发送稳定转发命令并返回每个来源与目标组合的结果。
    ///
    /// - Parameter command: 重试时保持身份与内容不变的转发意图。
    /// - Returns: 包含逐项成功或失败的结果数组，调用方应按身份关联而非假定位置对应。
    /// - Throws: 服务端整体拒绝、响应格式或传输错误。
    func forwardMessages(command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult]
}

/// 普通成员增删完成后的动作、成员修订和房间位置回执。
public struct V2ClientMembershipChange: Equatable, Sendable {
    /// 操作所属房间。
    public let roomID: RoomID
    /// 被添加或移除的成员。
    public let targetUserID: UserID
    /// 服务器确认的增删动作。
    public let action: V2RoomMembershipAction
    /// 操作后的成员修订。
    public let membershipRevision: UInt64
    /// 操作对应的房间位置。
    public let roomSequence: UInt64
    /// 服务器操作时间。
    public let createdAt: Date

    /// 保存成员变更回执并验证修订和房间序列为正且不超过 Int64.max。
    ///
    /// - Parameters:
    ///   - roomID: 所属房间。
    ///   - targetUserID: 目标成员。
    ///   - action: 增删动作。
    ///   - membershipRevision: 新成员修订。
    ///   - roomSequence: 房间位置。
    ///   - createdAt: 操作时间，不在此检查有限性或正负。
    /// - Throws: 修订或序列范围错误。
    ///
    /// 与请求身份和旧修订的一致性由传输适配方法验证。
    public init(roomID: RoomID, targetUserID: UserID, action: V2RoomMembershipAction, membershipRevision: UInt64, roomSequence: UInt64, createdAt: Date) throws {
        guard membershipRevision > 0 && membershipRevision <= UInt64(Int64.max) && roomSequence > 0 && roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.action = action
        self.membershipRevision = membershipRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

/// 带预期成员修订的普通成员增删接口，与独立审核移除操作分离。
public protocol V2ClientMembershipTransport: Sendable {
    /// 按稳定操作身份和预期成员修订执行普通增删；返回正式回执，领域拒绝或传输失败通过错误报告。
    func changeMembership(roomID: RoomID, operationID: MembershipOperationID, targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2ClientMembershipChange
}

/// 按需读取的群成员身份及角色；资料展示须另行取得当前许可。
public struct V2ClientRoomMember: Equatable, Sendable {
    /// 成员用户身份。
    public let userID: UserID
    /// 成员在该房间的角色。
    public let role: V2RoomMembershipRole
    /// 保存目录事实，不包含可直接展示的个人资料。
    ///
    /// - Parameters:
    ///   - userID: 成员身份。
    ///   - role: 成员角色。
    public init(userID: UserID, role: V2RoomMembershipRole) {
        self.userID = userID
        self.role = role
    }
}

/// 成员目录的一页结果，包含读取时的成员修订、调用者角色和后续游标。
public struct V2ClientRoomMembersPage: Equatable, Sendable {
    /// 成员目录所属房间。
    public let roomID: RoomID
    /// 读取时的成员修订，允许为零但不能超过 Int64.max。
    public let membershipRevision: UInt64
    /// 调用者在房间中的角色。
    public let actorRole: V2RoomMembershipRole
    /// 当前页的成员资料。
    public let members: [V2ClientRoomMember]
    /// 不透明后续游标，为 nil 时没有后续页。
    public let nextCursor: String?

    /// 保存目录页并检查修订可持久化范围。
    ///
    /// - Parameters:
    ///   - roomID: 所属房间。
    ///   - membershipRevision: 不超过 Int64.max 的修订。
    ///   - actorRole: 调用者角色。
    ///   - members: 页面成员。
    ///   - nextCursor: 后续游标。
    /// - Throws: 修订超范围时抛出存储范围错误。
    ///
    /// 成员去重、分页预算和游标长度不在此检查，由传输适配器负责。
    public init(roomID: RoomID, membershipRevision: UInt64, actorRole: V2RoomMembershipRole, members: [V2ClientRoomMember], nextCursor: String?) throws {
        guard membershipRevision <= UInt64(Int64.max) else { throw V2ClientSyncError.storageRangeExceeded }
        self.roomID = roomID
        self.membershipRevision = membershipRevision
        self.actorRole = actorRole
        self.members = members
        self.nextCursor = nextCursor
    }
}

/// 按需读取获授权房间成员目录的传输边界。
public protocol V2ClientMembershipDirectoryTransport: Sendable {
    /// 按房间、不透明游标和页大小获取成员目录；返回值不自动持久化为联系人图。
    func listRoomMembers(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientRoomMembersPage
}

/// 客户端成员目录请求和响应使用的分页预算。
public enum V2ClientRoomMembersPageLimits {
    /// 单页最多请求 100 名成员。
    public static let maximumPageSize = 100
    /// 成员目录游标最多 512 个 UTF-8 字节。
    public static let maximumCursorBytes = 512
}

/// 发起私聊后返回的房间、目标用户和创建时间摘要。
public struct V2ClientDirectRoom: Equatable, Sendable {
    /// 正式私聊房间身份。
    public let roomID: RoomID
    /// 私聊目标用户。
    public let targetUserID: UserID
    /// 服务器房间创建时间。
    public let createdAt: Date

    /// 保存服务器结果字段，不执行一致性校验或持久化。
    ///
    /// - Parameters:
    ///   - roomID: 正式私聊房间身份。
    ///   - targetUserID: 私聊目标用户。
    ///   - createdAt: 服务器房间创建时间。
    public init(roomID: RoomID, targetUserID: UserID, createdAt: Date) {
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.createdAt = createdAt
    }
}

/// 发起私聊及设置账户级陌生消息、用户添加偏好的已认证传输边界。
public protocol V2ClientDirectMessagingTransport: Sendable {
    /// 按稳定操作身份发起与目标用户的私聊。
    ///
    /// 服务端或传输失败通过抛出错误报告；本地持久化由调用者负责。
    func openDirectRoom(operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2ClientDirectRoom
    /// 设置账户级陌生人消息权限，返回更新时间。
    ///
    /// 服务端或传输失败通过抛出错误报告；本地持久化由调用者负责。
    func setStrangerMessagePermission(operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> Date
    /// 设置账户级用户添加权限，返回更新时间。
    ///
    /// 服务端或传输失败通过抛出错误报告；本地持久化由调用者负责。
    func setUserAddPermission(operationID: UserAddPreferenceOperationID, permission: V2UserAddPermission) async throws -> Date
}

/// 分阶段建群完成后的房间摘要；正式成员数量不要求等于返回的成员身份数组长度。
public struct V2ClientGroupRoom: Equatable, Sendable {
    /// 正式群房间身份。
    public let roomID: RoomID
    /// 服务端返回的群名称。
    public let title: String
    /// 群的消息投递模式。
    public let capacityClass: V2GroupCapacityClass
    /// 初始化时排序的成员身份数组；建群传输当前要求为空，完整目录另行分页读取。
    public let memberUserIDs: [UserID]
    /// 服务端声明的正式成员总数。
    public let memberCount: UInt32
    /// 服务端房间创建时间。
    public let createdAt: Date

    /// 保存群摘要并按身份排序成员数组，不进行去重或字段一致性验证。
    ///
    /// - Parameters:
    ///   - roomID: 房间身份。
    ///   - title: 名称。
    ///   - capacityClass: 投递模式。
    ///   - memberUserIDs: 可选的成员身份列表。
    ///   - memberCount: 声明的总成员数，不要求等于数组长度。
    ///   - createdAt: 创建时间。
    public init(roomID: RoomID, title: String, capacityClass: V2GroupCapacityClass, memberUserIDs: [UserID], memberCount: UInt32, createdAt: Date) {
        self.roomID = roomID
        self.title = title
        self.capacityClass = capacityClass
        self.memberUserIDs = memberUserIDs.sorted()
        self.memberCount = memberCount
        self.createdAt = createdAt
    }
}

/// 服务端建群暂存进度，仅返回操作身份与数量，不返回完整名单；数量供持久化发件箱恢复处理使用。
public struct V2ClientGroupAudienceDraft: Equatable, Sendable {
    /// 贯穿建群流程的稳定操作身份。
    public let operationID: GroupRoomOperationID
    /// 暂存摘要名称；追加成员响应适配时使用 staged 占位值。
    public let title: String
    /// 服务端累计暂存的成员数量。
    public let stagedMemberCount: Int

    /// 保存建群暂存摘要，检查名称非空及数量非负。
    ///
    /// - Parameters:
    ///   - operationID: 稳定操作身份。
    ///   - title: 名称，仅用去除首尾空白后的值检查非空，保存原字符串。
    ///   - stagedMemberCount: 累计暂存人数。
    /// - Throws: 空名称或负数量时抛出异常响应错误。
    ///
    /// 人数上限不在此检查，由传输响应校验负责。
    public init(operationID: GroupRoomOperationID, title: String, stagedMemberCount: Int) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, stagedMemberCount >= 0 else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        self.operationID = operationID
        self.title = title
        self.stagedMemberCount = stagedMemberCount
    }
}

/// 分阶段建群的已认证传输边界。
///
/// 调用方持久化操作身份和建群意图，在开始、追加、完成与重试时复用同一身份。
/// 暂存成功不代表房间已经创建；完成结果才提供正式房间摘要。
public protocol V2ClientGroupMessagingTransport: Sendable {
    /// 开始或恢复建群草稿；调用者持久化操作身份，成功只代表暂存状态建立。
    func beginGroupRoomCreation(operationID: GroupRoomOperationID, title: String) async throws -> V2ClientGroupAudienceDraft
    /// 向同一操作追加有界成员批次，返回累计暂存数量；重复提交需保持相同意图。
    func appendGroupRoomCreationMembers(operationID: GroupRoomOperationID, memberUserIDs: [UserID]) async throws -> V2ClientGroupAudienceDraft
    /// 完成暂存操作并返回正式群摘要，本地终态保存由调用方负责。
    func finalizeGroupRoomCreation(operationID: GroupRoomOperationID) async throws -> V2ClientGroupRoom
    /// 取消可变草稿；应在本地取消意图已持久化后调用，不能替代本地队列状态迁移。
    func cancelGroupRoomCreation(operationID: GroupRoomOperationID) async throws
}

/// 已认证的关系与屏蔽操作边界。
///
/// 返回服务端状态，但多设备界面的持久化收敛仍通过后续同步投影完成。调用方负责稳定操作身份及重试意图。
public protocol V2ClientSocialRelationshipTransport: Sendable {
    /// 提交稳定身份的关系变更，返回服务器状态；具体响应匹配校验由适配器实现。
    ///
    /// 服务端或传输失败通过抛出错误报告；本地持久化由调用者负责。
    func changeRelationship(operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) async throws -> V2ClientRelationshipChange
    /// 提交稳定身份的屏蔽变更，返回服务器结果。
    ///
    /// 服务端或传输失败通过抛出错误报告；本地持久化由调用者负责。
    func changeUserBlock(operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) async throws -> V2ClientUserBlockChange
}

/// 服务端返回的关系操作及结果状态，构造仅保存字段，不验证操作和结果状态的组合。
public struct V2ClientRelationshipChange: Equatable, Sendable {
    /// 服务端返回的关系目标。
    public let targetUserID: UserID
    /// 服务器确认的关系动作。
    public let action: V2RelationshipAction
    /// 服务器返回的关系状态。
    public let resultingState: V2RelationshipState
    /// 服务器更新时间。
    public let updatedAt: Date
    /// 保存服务器结果字段，不执行一致性校验或持久化。
    ///
    /// - Parameters:
    ///   - targetUserID: 服务端返回的关系目标。
    ///   - action: 服务器确认的关系动作。
    ///   - resultingState: 服务器返回的关系状态。
    ///   - updatedAt: 服务器更新时间。
    public init(targetUserID: UserID, action: V2RelationshipAction, resultingState: V2RelationshipState, updatedAt: Date) { self.targetUserID = targetUserID; self.action = action; self.resultingState = resultingState; self.updatedAt = updatedAt }
}

/// 服务端屏蔽操作结果，构造仅保存字段，不验证动作与屏蔽标志是否一致。
public struct V2ClientUserBlockChange: Equatable, Sendable {
    /// 屏蔽目标用户。
    public let targetUserID: UserID
    /// 屏蔽或解除动作。
    public let action: V2UserBlockAction
    /// 结果是否处于屏蔽状态。
    public let isBlocked: Bool
    /// 服务器更新时间。
    public let updatedAt: Date
    /// 保存服务器结果字段，不执行一致性校验或持久化。
    ///
    /// - Parameters:
    ///   - targetUserID: 屏蔽目标用户。
    ///   - action: 屏蔽或解除动作。
    ///   - isBlocked: 结果是否处于屏蔽状态。
    ///   - updatedAt: 服务器更新时间。
    public init(targetUserID: UserID, action: V2UserBlockAction, isBlocked: Bool, updatedAt: Date) { self.targetUserID = targetUserID; self.action = action; self.isBlocked = isBlocked; self.updatedAt = updatedAt }
}

/// 撤回完成后的消息修订与房间位置回执。
public struct V2ClientMessageWithdrawal: Equatable, Sendable {
    /// 结果所属房间。
    public let roomID: RoomID
    /// 结果对应消息。
    public let messageID: MessageID
    /// 操作后的消息修订。
    public let messageRevision: UInt64
    /// 操作对应的房间序列。
    public let roomSequence: UInt64
    /// 服务端操作时间。
    public let createdAt: Date

    /// 保存操作回执，检查房间序列及修订为正且不超过 Int64.max。
    ///
    /// - Parameters:
    ///   - roomID: 结果所属房间。
    ///   - messageID: 结果对应消息。
    ///   - messageRevision: 操作后的消息修订。
    ///   - roomSequence: 操作对应的房间序列。
    ///   - createdAt: 服务端操作时间。
    /// - Throws: 整数范围无效时抛出修订范围错误。
    ///
    /// 初始化不检查日期有限性或正负，也不读取本地旧状态；请求与响应的一致性由传输方法检查。
    public init(roomID: RoomID, messageID: MessageID, messageRevision: UInt64, roomSequence: UInt64, createdAt: Date) throws {
        guard messageRevision > 0 && messageRevision <= UInt64(Int64.max) && roomSequence > 0 && roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

/// 发送带预期修订的撤回命令，返回正式回执。
///
/// 调用方负责持久化操作身份、重试意图及结果；此接口不直接更新本地同步投影。
public protocol V2ClientMessageWithdrawalTransport: Sendable {
    /// 发送带预期修订的撤回命令，返回正式回执。
    ///
    /// 同一意图的重试应复用操作身份与原始参数，不能在重试时悄悄改为新的业务请求。
    func withdrawMessage(roomID: RoomID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) async throws -> V2ClientMessageWithdrawal
}

/// 审核屏蔽完成后的消息修订与房间位置回执。
public struct V2ClientMessageRedaction: Equatable, Sendable {
    /// 结果所属房间。
    public let roomID: RoomID
    /// 结果对应消息。
    public let messageID: MessageID
    /// 操作后的消息修订。
    public let messageRevision: UInt64
    /// 操作对应的房间序列。
    public let roomSequence: UInt64
    /// 服务端操作时间。
    public let createdAt: Date

    /// 保存操作回执，检查房间序列及修订为正且不超过 Int64.max。
    ///
    /// - Parameters:
    ///   - roomID: 结果所属房间。
    ///   - messageID: 结果对应消息。
    ///   - messageRevision: 操作后的消息修订。
    ///   - roomSequence: 操作对应的房间序列。
    ///   - createdAt: 服务端操作时间。
    /// - Throws: 整数范围无效时抛出修订范围错误。
    ///
    /// 初始化不检查日期有限性或正负，也不读取本地旧状态；请求与响应的一致性由传输方法检查。
    public init(roomID: RoomID, messageID: MessageID, messageRevision: UInt64, roomSequence: UInt64, createdAt: Date) throws {
        guard messageRevision > 0 && messageRevision <= UInt64(Int64.max) && roomSequence > 0 && roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

/// 发送带原因的审核屏蔽命令，权限由服务端判定。
///
/// 调用方负责持久化操作身份、重试意图及结果；此接口不直接更新本地同步投影。
public protocol V2ClientMessageRedactionTransport: Sendable {
    /// 发送带原因的审核屏蔽命令，权限由服务端判定。
    ///
    /// 同一意图的重试应复用操作身份与原始参数，不能在重试时悄悄改为新的业务请求。
    func redactMessage(roomID: RoomID, operationID: ModerationOperationID, messageID: MessageID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMessageRedaction
}

/// 审核禁言回执，保留成员身份、期限与对应房间位置。
public struct V2ClientMemberMute: Equatable, Sendable {
    /// 结果所属房间。
    public let roomID: RoomID
    /// 审核目标成员。
    public let targetUserID: UserID
    /// 服务端返回的禁言期限。
    public let muteUntil: Date
    /// 操作对应的房间序列。
    public let roomSequence: UInt64
    /// 服务端操作时间。
    public let createdAt: Date

    /// 保存操作回执，检查房间序列为正且不超过 Int64.max。
    ///
    /// - Parameters:
    ///   - roomID: 结果所属房间。
    ///   - targetUserID: 审核目标成员。
    ///   - muteUntil: 服务端返回的禁言期限。
    ///   - roomSequence: 操作对应的房间序列。
    ///   - createdAt: 服务端操作时间。
    /// - Throws: 整数范围无效时抛出修订范围错误。
    ///
    /// 初始化不检查日期有限性或正负，也不读取本地旧状态；请求与响应的一致性由传输方法检查。
    public init(roomID: RoomID, targetUserID: UserID, muteUntil: Date, roomSequence: UInt64, createdAt: Date) throws {
        guard roomSequence > 0 && roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.muteUntil = muteUntil
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

/// 提交目标成员、禁言期限和审核原因，返回正式回执。
///
/// 调用方负责持久化操作身份、重试意图及结果；此接口不直接更新本地同步投影。
public protocol V2ClientMemberMuteTransport: Sendable {
    /// 提交目标成员、禁言期限和审核原因，返回正式回执。
    ///
    /// 同一意图的重试应复用操作身份与原始参数，不能在重试时悄悄改为新的业务请求。
    func muteMember(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMemberMute
}

/// 独立审核移除命令的回执；普通成员管理使用不同的操作记录和传输方法。
public struct V2ClientModeratedMemberRemoval: Equatable, Sendable {
    /// 结果所属房间。
    public let roomID: RoomID
    /// 审核目标成员。
    public let targetUserID: UserID
    /// 操作后的成员修订。
    public let membershipRevision: UInt64
    /// 操作对应的房间序列。
    public let roomSequence: UInt64
    /// 服务端操作时间。
    public let createdAt: Date

    /// 保存操作回执，检查房间序列及修订为正且不超过 Int64.max。
    ///
    /// - Parameters:
    ///   - roomID: 结果所属房间。
    ///   - targetUserID: 审核目标成员。
    ///   - membershipRevision: 操作后的成员修订。
    ///   - roomSequence: 操作对应的房间序列。
    ///   - createdAt: 服务端操作时间。
    /// - Throws: 整数范围无效时抛出修订范围错误。
    ///
    /// 初始化不检查日期有限性或正负，也不读取本地旧状态；请求与响应的一致性由传输方法检查。
    public init(roomID: RoomID, targetUserID: UserID, membershipRevision: UInt64, roomSequence: UInt64, createdAt: Date) throws {
        guard membershipRevision > 0 && membershipRevision <= UInt64(Int64.max) && roomSequence > 0 && roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.targetUserID = targetUserID
        self.membershipRevision = membershipRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

/// 提交独立审核移除操作，保持其操作身份与普通成员管理分离。
///
/// 调用方负责持久化操作身份、重试意图及结果；此接口不直接更新本地同步投影。
public protocol V2ClientModeratedMemberRemovalTransport: Sendable {
    /// 提交独立审核移除操作，保持其操作身份与普通成员管理分离。
    ///
    /// 同一意图的重试应复用操作身份与原始参数，不能在重试时悄悄改为新的业务请求。
    func removeMemberByModerator(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientModeratedMemberRemoval
}

/// 文本编辑完成后的正文、消息修订与房间位置。
public struct V2ClientMessageEdit: Equatable, Sendable {
    /// 结果所属房间。
    public let roomID: RoomID
    /// 结果对应消息。
    public let messageID: MessageID
    /// 服务器确认的编辑文本。
    public let text: String
    /// 操作后的消息修订。
    public let messageRevision: UInt64
    /// 操作对应的房间序列。
    public let roomSequence: UInt64
    /// 服务端操作时间。
    public let createdAt: Date

    /// 保存操作回执，检查房间序列及修订为正且不超过 Int64.max。
    ///
    /// - Parameters:
    ///   - roomID: 结果所属房间。
    ///   - messageID: 结果对应消息。
    ///   - text: 服务器确认的编辑文本。
    ///   - messageRevision: 操作后的消息修订。
    ///   - roomSequence: 操作对应的房间序列。
    ///   - createdAt: 服务端操作时间。
    /// - Throws: 整数范围无效时抛出修订范围错误。
    ///
    /// 初始化不检查日期有限性或正负，也不读取本地旧状态；请求与响应的一致性由传输方法检查。
    public init(roomID: RoomID, messageID: MessageID, text: String, messageRevision: UInt64, roomSequence: UInt64, createdAt: Date) throws {
        guard messageRevision > 0 && messageRevision <= UInt64(Int64.max) && roomSequence > 0 && roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.messageID = messageID
        self.text = text
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

/// 发送带预期修订的文本编辑命令，返回服务器确认结果。
///
/// 调用方负责持久化操作身份、重试意图及结果；此接口不直接更新本地同步投影。
public protocol V2ClientMessageEditTransport: Sendable {
    /// 发送带预期修订的文本编辑命令，返回服务器确认结果。
    ///
    /// 同一意图的重试应复用操作身份与原始参数，不能在重试时悄悄改为新的业务请求。
    func editMessage(roomID: RoomID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) async throws -> V2ClientMessageEdit
}

/// 服务端记录的用户房间已读水位；可能高于本次提交值，以保留已读状态的单调推进。
public struct V2ClientReadReceipt: Equatable, Sendable {
    /// 回执所属房间。
    public let roomID: RoomID
    /// 服务端报告的已读用户。
    public let userID: UserID
    /// 服务器已记录的正向连续已读水位。
    public let readThroughRoomSequence: UInt64
    /// 服务器记录时间。
    public let recordedAt: Date

    /// 保存已读回执并检查水位为正且不超过 Int64.max。
    ///
    /// - Parameters:
    ///   - roomID: 房间身份。
    ///   - userID: 已读用户。
    ///   - readThroughRoomSequence: 服务端已读水位。
    ///   - recordedAt: 记录日期，此处不检查有限性或正负。
    /// - Throws: 水位无效时抛出修订范围错误。
    public init(roomID: RoomID, userID: UserID, readThroughRoomSequence: UInt64, recordedAt: Date) throws {
        guard readThroughRoomSequence > 0 && readThroughRoomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.userID = userID
        self.readThroughRoomSequence = readThroughRoomSequence
        self.recordedAt = recordedAt
    }
}

/// 已读水位、回执偏好及授权读者目录的传输能力；本地持久化由调用方负责。
public protocol V2ClientReadReceiptTransport: Sendable {
    /// 提交带稳定操作身份的已读水位，返回服务器单调合并后的结果。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func recordReadReceipt(roomID: RoomID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) async throws -> V2ClientReadReceipt
    /// 设置账户的私聊和群聊回执偏好，返回服务器状态。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func setReadReceiptPreferences(operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2ReadReceiptPreferences
    /// 按消息与游标读取获授权的已读者目录。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func listReadReceiptReaders(roomID: RoomID, messageID: MessageID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage
}

/// 已读者分页请求的客户端预算。
public enum V2ClientReadReceiptLimits {
    /// 已读者目录单页最多请求 100 人。
    public static let maximumPageSize = 100
    public static let maximumCursorBytes = 512
}

/// 在线与输入状态的偏好、订阅和发布接口；订阅生命周期由连接或上层运行时管理。
public protocol V2ClientLiveActivityTransport: Sendable {
    /// 读取账户当前在线和输入展示偏好。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func liveActivityPreferences() async throws -> V2LiveActivityPreferences
    /// 按稳定操作身份设置在线和输入展示偏好。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func setLiveActivityPreferences(operationID: LiveActivityPreferenceOperationID, allowsOnlinePresence: Bool, allowsTypingIndicators: Bool) async throws -> V2LiveActivityPreferences
    /// 订阅指定房间的在线状态并读取初始快照。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func subscribePresence(roomID: RoomID) async throws -> V2PresenceState
    /// 取消指定房间的在线状态订阅。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func unsubscribePresence(roomID: RoomID) async throws
    /// 订阅指定房间的输入指示。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func subscribeTyping(roomID: RoomID) async throws
    /// 取消指定房间的输入指示订阅。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func unsubscribeTyping(roomID: RoomID) async throws
    /// 发布指定房间的输入状态，调用方负责节流与停止事件。
    ///
    /// 传输或服务端拒绝通过抛出错误报告；调用本身不更新本地同步投影。
    func setTyping(roomID: RoomID, isTyping: Bool) async throws
}

/// 服务器确认的消息表情变更，包含执行用户、动作与房间位置。
public struct V2ClientMessageReactionChange: Equatable, Sendable {
    /// 结果所属房间。
    public let roomID: RoomID
    /// 被添加或移除表情的消息。
    public let messageID: MessageID
    /// 服务端报告的执行用户。
    public let actorUserID: UserID
    /// 服务器确认的表情内容。
    public let reaction: String
    /// 添加或移除动作。
    public let action: V2MessageReactionAction
    /// 变更对应的房间位置。
    public let roomSequence: UInt64
    /// 服务器操作时间。
    public let createdAt: Date

    /// 保存表情回执并检查房间序列为正且不超过 Int64.max。
    ///
    /// - Parameters:
    ///   - roomID: 房间身份。
    ///   - messageID: 消息身份。
    ///   - actorUserID: 执行用户。
    ///   - reaction: 表情内容。
    ///   - action: 变更动作。
    ///   - roomSequence: 房间位置。
    ///   - createdAt: 创建日期，不在此检查有限性或正负。
    /// - Throws: 房间序列超范围时抛出修订范围错误。
    ///
    /// 构造不验证表情内容或与原始请求的一致性。
    public init(roomID: RoomID, messageID: MessageID, actorUserID: UserID, reaction: String, action: V2MessageReactionAction, roomSequence: UInt64, createdAt: Date) throws {
        guard roomSequence > 0 && roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.messageID = messageID
        self.actorUserID = actorUserID
        self.reaction = reaction
        self.action = action
        self.roomSequence = roomSequence
        self.createdAt = createdAt
    }
}

/// 消息表情添加与移除的已认证传输边界；持久化重试由调用方管理。
public protocol V2ClientMessageReactionTransport: Sendable {
    /// 使用稳定操作身份提交表情变更并返回服务器结果；请求重试需保持原意图，服务端拒绝或传输失败通过错误报告。
    func changeMessageReaction(roomID: RoomID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) async throws -> V2ClientMessageReactionChange
}

/// 运行时发送存活心跳所需的最小接口，不定义定时器或重连策略。
public protocol V2HeartbeatSender: Sendable {
    /// 发送带客户端时间的心跳并等待响应；具体编码、响应验证和错误由实现负责，调用者持有调度与取消生命周期。
    func sendHeartbeat(clientTime: Date) async throws
}

/// 业务协议适配层的响应、快照完整性及服务端错误。
public enum V2RealtimeTransportError: Error, Equatable, Sendable {
    /// 返回类型、关联号、版本或业务字段不符合当前请求的校验要求，也用于报告部分无效输入。
    case unexpectedResponse
    /// 快照清单的身份、期限、schema 或必要字段不满足要求。
    case invalidSnapshotManifest
    /// 请求的快照页号不在当前清单范围内。
    case invalidSnapshotPage
    /// 快照页面摘要或相关身份、页号、键范围和条数校验失败，不只表示散列不同。
    case snapshotDigestMismatch
    /// 服务端业务错误及重试提示；当前修订只对 REVISION_CONFLICT 保留，标量缺少存在性信息时仍可能为零。
    case server(code: String, retryable: Bool, retryAfterSeconds: UInt32, currentRevision: UInt64?)
}

/// 可注入的快照页面摘要验证边界。
public protocol V2SnapshotPageDigestVerifier: Sendable {
    /// 验证原始页面字节与声明摘要是否一致；不代替页面结构或整份快照根摘要验证。
    func matches(payload: Data, expectedDigest: String) -> Bool
}

/// 使用 SHA-256 验证快照页面字节；计算小写十六进制摘要，并忽略预期摘要的字母大小写。
public struct V2SHA256SnapshotPageDigestVerifier: V2SnapshotPageDigestVerifier {
    /// 创建无状态 SHA-256 页面摘要验证器。
    public init() {}

    /// 比较页面 SHA-256 摘要。
    ///
    /// - Parameters:
    ///   - payload: 原始页面载荷，不进行解码或规范化。
    ///   - expectedDigest: 预期十六进制摘要，比较前转为小写，不移除空白。
    /// - Returns: 摘要字符串相同时为 `true`。
    public func matches(payload: Data, expectedDigest: String) -> Bool {
        let actual = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return actual == expectedDigest.lowercased()
    }
}

/// 在已认证帧连接上构造业务请求并把 protobuf 响应转换为领域值。
///
/// 本层校验响应关联、版本和各方法声明的业务字段，不保存同步投影，也不管理持久化命令重试。
/// 请求号由 actor 在发送前分配；等待期间允许其他请求进入，实际关联与网络生命周期由底层连接负责。
public actor V2ProtobufSyncTransport: V2ClientSyncTransport, V2ClientGroupRolePolicyBaselineTransport, V2ClientMessageTransport, V2ClientConversationCapabilitiesTransport, V2ClientGroupCapabilitiesTransport, V2ClientForwardMessagesTransport, V2ClientMembershipTransport, V2ClientMembershipDirectoryTransport, V2ClientDirectMessagingTransport, V2ClientGroupMessagingTransport, V2ClientGroupEventTransport, V2ClientGroupEventSubscriptionTransport, V2ClientSocialRelationshipTransport, V2ClientMessageWithdrawalTransport, V2ClientMessageRedactionTransport, V2ClientMemberMuteTransport, V2ClientModeratedMemberRemovalTransport, V2ClientMessageEditTransport, V2ClientMessageReactionTransport, V2ClientReadReceiptTransport, V2ClientLiveActivityTransport, V2HeartbeatSender {
    /// 拥有认证连接与帧请求关联的底层传输。
    private let wire: any V2AuthenticatedFrameTransport
    /// 所有请求使用的已协商非零协议版本。
    private let protocolVersion: UInt8
    /// 用于逐页验证快照原始载荷的摘要实现。
    private let pageDigestVerifier: any V2SnapshotPageDigestVerifier
    /// 获取快照清单时检查期限的可注入当前时间；心跳默认时间来自其方法参数。
    private let now: @Sendable () -> Date
    /// 下一个帧关联号，从一开始递增并跳过回绕后的零；不在此维护在途号集合。
    private var nextRequestID: UInt64 = 1

    /// 配置已认证连接与协议映射依赖。
    ///
    /// - Parameters:
    ///   - wire: 已完成握手认证、支持关联帧请求的连接。
    ///   - protocolVersion: 已协商版本，必须大于零。
    ///   - pageDigestVerifier: 默认使用 SHA-256 的可注入页面验证器。
    ///   - now: 清单期限校验使用的当前时间来源。
    ///
    /// 零版本触发前置条件失败；初始化不发起认证或网络请求。
    public init(
        wire: any V2AuthenticatedFrameTransport,
        protocolVersion: UInt8,
        pageDigestVerifier: any V2SnapshotPageDigestVerifier = V2SHA256SnapshotPageDigestVerifier(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(protocolVersion > 0)
        self.wire = wire
        self.protocolVersion = protocolVersion
        self.pageDigestVerifier = pageDigestVerifier
        self.now = now
    }

    /// 构造同步拉取请求并映射增量或恢复响应。
    ///
    /// - Parameters:
    ///   - syncToken: 已持久化的继续令牌，无值编码为空字符串。
    ///   - maxRecords: 请求记录预算，使用 UInt32 钳制转换，不在此拒绝非正输入。
    ///   - requireSnapshot: 是否要求完整快照重建。
    /// - Returns: 检查过整数持久化范围的批次或恢复信息。
    /// - Throws: 响应格式、领域值构造、服务端或帧传输错误。
    ///
    /// 此层不验证批内连续性和能力配置匹配，后续引擎与存储必须继续检查。
    public func pull(syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool = false) async throws -> V2ClientPullResult {
        var request = IMV2Envelope()
        request.syncPull = .init()
        request.syncPull.syncToken = syncToken?.rawValue ?? ""
        request.syncPull.maxRecords = UInt32(clamping: maxRecords)
        request.syncPull.requireSnapshot = requireSnapshot
        let response = try await requestEnvelope(request)
        switch response.body {
        case .syncBatch(let batch):
            guard batch.generation > 0, batch.generation <= UInt64(Int64.max),
                  batch.records.allSatisfy({ $0.userSyncSequence > 0 && $0.userSyncSequence <= UInt64(Int64.max) })
            else { throw V2RealtimeTransportError.unexpectedResponse }
            let records = try batch.records.map {
                try V2ClientSyncRecord(sequence: $0.userSyncSequence, sourceEventID: .init($0.sourceEventID), projectionKind: $0.projectionKind, payload: $0.payload)
            }
            return .ready(try .init(generation: batch.generation, records: records, nextSyncToken: .init(batch.nextSyncToken), receipt: .init(batch.syncReceipt), hasMore: batch.hasMore_p, capabilityProfile: batch.capabilityProfile))
        case .resetRequired(let reset):
            guard reset.generation > 0, reset.generation <= UInt64(Int64.max),
                  reset.baseUserSyncSequence <= UInt64(Int64.max)
            else { throw V2RealtimeTransportError.unexpectedResponse }
            let value = try V2ClientResetRequired(snapshotID: .init(reset.snapshotID), generation: reset.generation, baseSequence: reset.baseUserSyncSequence, expiresAt: Date(timeIntervalSince1970: TimeInterval(reset.expiresAtMs) / 1_000))
            return .resetRequired(value)
        default:
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    /// 发送增量确认并要求返回 acknowledged 消息体。
    ///
    /// - Parameters:
    ///   - generation: 待确认代际。
    ///   - highestContiguousSequence: 已落盘的最高连续水位。
    ///   - receipt: 对应范围的精确回执。
    /// - Throws: 服务端拒绝、响应类型或传输错误。
    ///
    /// 此方法不读取本地存储，落盘前置条件由调用者保证。
    public func acknowledge(generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) async throws {
        var request = IMV2Envelope()
        request.syncAck = .init()
        request.syncAck.generation = generation
        request.syncAck.highestContiguousSequence = highestContiguousSequence
        request.syncAck.syncReceipt = receipt.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    /// 发送心跳并等待关联的 heartbeatAck。
    ///
    /// - Parameter clientTime: 当前客户端日期；有限负时间钳制为零，毫秒向零舍入。
    /// - Throws: 时间非有限或无法放入 UInt64，响应类型错误，以及服务端或传输错误。
    ///
    /// 只验证响应类型，不据此校准本地时钟或计算往返延迟。
    public func sendHeartbeat(clientTime: Date = Date()) async throws {
        let milliseconds = clientTime.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              let wireTime = UInt64(exactly: max(0, milliseconds).rounded(.towardZero))
        else { throw V2RealtimeTransportError.unexpectedResponse }
        var request = IMV2Envelope()
        request.heartbeat = .init()
        request.heartbeat.clientTimeMs = wireTime
        let response = try await requestEnvelope(request)
        guard case .heartbeatAck? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    /// 读取并检查恢复清单，再构造带规模约束的领域值。
    ///
    /// - Parameter reset: 当前待恢复快照的标识、代际和基准水位。
    /// - Returns: 可进入后续导入流程的清单，保留传入 reset。
    /// - Throws: 身份、代际、基准、schema、期限或必要字段错误，以及传输或模型构造错误。
    ///
    /// 当前时钟必须可转换为 Int64 毫秒；响应期限须晚于当前时间。本层只检查根摘要长度为 64，
    /// 不验证其十六进制格式，也不要求响应期限与传入 reset 的期限完全相等。
    public func fetchSnapshotManifest(for reset: V2ClientResetRequired) async throws -> V2ClientSnapshotManifest {
        guard reset.hasPersistableIntegers else { throw V2RealtimeTransportError.invalidSnapshotManifest }
        var request = IMV2Envelope()
        request.syncSnapshot = .init()
        request.syncSnapshot.snapshotID = reset.snapshotID.rawValue
        request.syncSnapshot.generation = reset.generation
        let response = try await requestEnvelope(request)
        guard case .snapshotManifest(let manifest)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard let currentMilliseconds = Int64(exactly: (now().timeIntervalSince1970 * 1_000).rounded(.towardZero)),
              manifest.snapshotID == reset.snapshotID.rawValue,
              manifest.generation == reset.generation,
              manifest.baseUserSyncSequence == reset.baseSequence,
              manifest.schemaVersion == V2SnapshotProjectionV3Codec.schemaVersion,
              manifest.expiresAtMs > currentMilliseconds,
              manifest.rootDigest.count == 64,
              !manifest.nextSyncToken.isEmpty,
              !manifest.syncReceipt.isEmpty,
              !manifest.capabilityProfile.isEmpty
        else { throw V2RealtimeTransportError.invalidSnapshotManifest }

        return try .init(reset: reset, rootDigest: manifest.rootDigest, pageCount: Int(manifest.pageCount), totalItems: manifest.totalItems, totalBytes: manifest.totalBytes, nextSyncToken: .init(manifest.nextSyncToken), receipt: .init(manifest.syncReceipt), capabilityProfile: manifest.capabilityProfile)
    }

    /// 读取指定页面，验证响应归属、键范围与载荷摘要。
    ///
    /// - Parameters:
    ///   - manifest: 当前导入清单。
    ///   - index: 从零开始且小于清单页数的下标。
    /// - Returns: 通过本层校验的页面值，内容投影仍需存储解码验证。
    /// - Throws: 请求页号无效、响应类型错误，或页面身份、根摘要、页号、条数、键范围和页面散列校验失败。
    ///
    /// 返回前不把页面写入本地存储，也不在此重新计算整份快照的根摘要。
    public func fetchSnapshotPage(for manifest: V2ClientSnapshotManifest, index: Int) async throws -> V2ClientSnapshotPage {
        guard (0 ..< manifest.pageCount).contains(index) else { throw V2RealtimeTransportError.invalidSnapshotPage }
        var request = IMV2Envelope()
        request.snapshotPagePull = .init()
        request.snapshotPagePull.snapshotID = manifest.reset.snapshotID.rawValue
        request.snapshotPagePull.generation = manifest.reset.generation
        request.snapshotPagePull.rootDigest = manifest.rootDigest
        request.snapshotPagePull.pageIndex = UInt32(index)
        let response = try await requestEnvelope(request)
        guard case .snapshotPage(let page)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard let firstKey = try? V2SnapshotProjectionKey(projectionKind: page.firstProjectionKind, entityKey: page.firstEntityKey),
              let lastKey = try? V2SnapshotProjectionKey(projectionKind: page.lastProjectionKind, entityKey: page.lastEntityKey),
              page.snapshotID == manifest.reset.snapshotID.rawValue,
              page.generation == manifest.reset.generation,
              page.rootDigest == manifest.rootDigest,
              page.pageIndex == UInt32(index),
              page.itemCount > 0,
              page.itemCount <= V2SnapshotProjectionV3Codec.maximumPageItems,
              firstKey <= lastKey,
              pageDigestVerifier.matches(payload: page.payload, expectedDigest: page.pageDigest)
        else { throw V2RealtimeTransportError.snapshotDigestMismatch }
        return try .init(index: index, digest: page.pageDigest, firstKey: firstKey, lastKey: lastKey, itemCount: Int(page.itemCount), payload: page.payload)
    }

    /// 发送快照身份、代际、基准和回执，并要求服务端返回 acknowledged。
    ///
    /// - Parameter manifest: 已完整导入并完成激活准备的清单。
    /// - Throws: 服务端拒绝、响应类型或传输错误。
    ///
    /// 此方法不检查本地准备状态，也不激活本地表；调用顺序由同步引擎保证。
    public func acknowledgeSnapshot(_ manifest: V2ClientSnapshotManifest) async throws {
        var request = IMV2Envelope()
        request.snapshotAck = .init()
        request.snapshotAck.snapshotID = manifest.reset.snapshotID.rawValue
        request.snapshotAck.generation = manifest.reset.generation
        request.snapshotAck.baseUserSyncSequence = manifest.reset.baseSequence
        request.snapshotAck.snapshotReceipt = manifest.receipt.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    /// 编码新消息或等价重试请求，并校验正式接受回执。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - clientMessageID: 跨重试稳定的客户端操作身份。
    ///   - text: 消息文本。
    ///   - media: 按顺序编码媒体身份。
    ///   - mentions: 分别编码用户提及与全体提及。
    ///   - entities: 使用 UTF-16 范围的富文本实体，调用前需完成内容校验。
    ///   - replyTo: 可选回复消息身份。
    /// - Returns: 房间匹配、房间序列可持久化且服务器时间非负的接受回执。
    /// - Throws: 响应校验、领域值构造、服务端或传输错误。
    ///
    /// 不在此生成客户端身份、入队或保存接受终态，持久化重试由发件箱负责。
    public func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) async throws -> V2ClientMessageAcceptance {
        var request = IMV2Envelope()
        request.sendMessage = .init()
        request.sendMessage.roomID = roomID.rawValue
        request.sendMessage.clientMessageID = clientMessageID.rawValue
        request.sendMessage.content = .init()
        request.sendMessage.content.text = text
        request.sendMessage.content.mediaIds = media.map { $0.mediaID.rawValue }
        request.sendMessage.content.mentionedUserIds = mentions.compactMap { if case .user(let userID) = $0 { userID.rawValue } else { nil } }
        request.sendMessage.content.mentionEveryone = mentions.contains(.everyone)
        request.sendMessage.content.entities = entities.map(v2MessageEntityWire)
        request.sendMessage.content.replyToMessageID = replyTo?.messageID.rawValue ?? ""
        let response = try await requestEnvelope(request)
        guard case .messageAccepted(let accepted)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let acceptedRoomID = try RoomID(accepted.roomID)
        guard acceptedRoomID == roomID, accepted.roomSequence > 0,
              Int64(exactly: accepted.roomSequence) != nil,
              accepted.serverCreatedAtMs >= 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(
            messageID: .init(accepted.messageID), roomID: acceptedRoomID,
            roomSequence: accepted.roomSequence,
            createdAt: Date(timeIntervalSince1970: TimeInterval(accepted.serverCreatedAtMs) / 1_000)
        )
    }

    /// 提交会话置顶、归档和静音设置，并逐项核对服务器响应。
    ///
    /// - Parameter command: 含稳定操作身份、房间和目标设置的命令。
    /// - Returns: 房间、布尔设置及静音期限与请求一致的会话状态。
    /// - Throws: 静音日期无法表示为 Int64 毫秒、响应不匹配、领域值构造或传输错误。
    ///
    /// 静音日期编码时向零舍入到毫秒，响应的零毫秒解释为 nil；响应日期随后与原始 Date 精确比较。
    /// 因此调用前的日期精度会影响结果校验。本方法不自动归一化原始日期或持久化本地会话。
    public func setConversationState(command: V2ConversationStateCommand) async throws -> V2ConversationState {
        var request = IMV2Envelope(); request.setConversationState = .init()
        request.setConversationState.operationID = command.operationID.rawValue; request.setConversationState.roomID = command.roomID.rawValue
        request.setConversationState.isPinned = command.isPinned; request.setConversationState.isArchived = command.isArchived
        if let muteUntil = command.muteUntil {
            guard let milliseconds = Int64(exactly: (muteUntil.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
                throw V2RealtimeTransportError.unexpectedResponse
            }
            request.setConversationState.muteUntilMs = milliseconds
        }
        let response = try await requestEnvelope(request)
        guard case .conversationStateSet(let value)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        guard value.roomID == command.roomID.rawValue, value.isPinned == command.isPinned, value.isArchived == command.isArchived else { throw V2RealtimeTransportError.unexpectedResponse }
        let muteUntil = value.muteUntilMs == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(value.muteUntilMs) / 1_000)
        guard muteUntil == command.muteUntil else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(value.roomID), isPinned: value.isPinned, isArchived: value.isArchived, muteUntil: muteUntil, updatedAt: Date(timeIntervalSince1970: TimeInterval(value.updatedAtMs) / 1_000))
    }

    /// 提交消息收藏状态，核对房间、消息和收藏标志。
    ///
    /// - Parameter command: 含稳定操作身份的收藏或取消收藏命令。
    /// - Returns: 对应消息的服务器收藏状态。
    /// - Throws: 响应身份或标志不匹配、领域值构造、服务端或传输错误。
    ///
    /// 更新时间从协议毫秒转换，不在此额外检查非负，也不直接修改本地收藏投影。
    public func setMessageFavorite(command: V2MessageFavoriteCommand) async throws -> V2MessageFavorite {
        var request = IMV2Envelope(); request.setMessageFavorite = .init()
        request.setMessageFavorite.operationID = command.operationID.rawValue; request.setMessageFavorite.roomID = command.roomID.rawValue; request.setMessageFavorite.messageID = command.messageID.rawValue; request.setMessageFavorite.isFavorited = command.isFavorited
        let response = try await requestEnvelope(request)
        guard case .messageFavoriteChanged(let value)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        guard value.roomID == command.roomID.rawValue, value.messageID == command.messageID.rawValue, value.isFavorited == command.isFavorited else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(value.roomID), messageID: .init(value.messageID), isFavorited: value.isFavorited, updatedAt: Date(timeIntervalSince1970: TimeInterval(value.updatedAtMs) / 1_000))
    }

    /// 提交群消息置顶状态并校验正式房间位置。
    ///
    /// - Parameter command: 指定房间、消息和目标置顶状态的稳定命令。
    /// - Returns: 身份与状态匹配、房间序列为正且可持久化的置顶结果。
    /// - Throws: 响应字段、领域值构造、服务端或传输错误。
    ///
    /// 此处不预判调用者的群权限，实际授权由服务端处理。
    public func setPinnedMessage(command: V2PinnedMessageCommand) async throws -> V2PinnedMessage {
        var request = IMV2Envelope(); request.setPinnedMessage = .init(); request.setPinnedMessage.operationID = command.operationID.rawValue; request.setPinnedMessage.roomID = command.roomID.rawValue; request.setPinnedMessage.messageID = command.messageID.rawValue; request.setPinnedMessage.isPinned = command.isPinned
        let response = try await requestEnvelope(request)
        guard case .pinnedMessageChanged(let value)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        guard value.roomID == command.roomID.rawValue, value.messageID == command.messageID.rawValue, value.isPinned == command.isPinned else { throw V2RealtimeTransportError.unexpectedResponse }
        guard value.roomSequence > 0, value.roomSequence <= UInt64(Int64.max) else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(value.roomID), messageID: .init(value.messageID), isPinned: value.isPinned, roomSequence: value.roomSequence, updatedAt: Date(timeIntervalSince1970: TimeInterval(value.updatedAtMs) / 1_000))
    }

    /// 按预期修订提交群公告，并要求服务器恰好推进一个修订。
    ///
    /// - Parameter command: 含房间、公告正文、稳定操作身份及预期修订的命令。
    /// - Returns: 房间和正文匹配、修订及房间序列有效的公告结果。
    /// - Throws: 响应身份、正文、范围或递增关系错误，以及服务端或传输错误。
    ///
    /// 校验先检查返回修订为正，再用减一与预期值比较，避免直接增加客户端预期值。
    public func setGroupAnnouncement(command: V2GroupAnnouncementCommand) async throws -> V2GroupAnnouncement {
        var request = IMV2Envelope(); request.setGroupAnnouncement = .init(); request.setGroupAnnouncement.operationID = command.operationID.rawValue; request.setGroupAnnouncement.roomID = command.roomID.rawValue; request.setGroupAnnouncement.body = command.body; request.setGroupAnnouncement.expectedRevision = command.expectedRevision
        let response = try await requestEnvelope(request)
        guard case .groupAnnouncementChanged(let value)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        guard value.roomID == command.roomID.rawValue, value.body == command.body else { throw V2RealtimeTransportError.unexpectedResponse }
        guard value.revision > 0, value.revision <= UInt64(Int64.max),
              value.roomSequence > 0, value.roomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        guard value.revision - 1 == command.expectedRevision else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(value.roomID), body: value.body, revision: value.revision, roomSequence: value.roomSequence, updatedAt: Date(timeIntervalSince1970: TimeInterval(value.updatedAtMs) / 1_000))
    }

    /// 提交指定群角色的完整权限集合并核对服务器结果。
    ///
    /// - Parameter command: 含角色、权限集合及预期策略修订的稳定命令。
    /// - Returns: 房间与角色匹配、权限集合相同且修订恰好推进一的结果。
    /// - Throws: 响应中未知或重复权限、字段不匹配、修订错误，以及服务端或传输错误。
    ///
    /// 发送前按权限原始值排序，以获得稳定编码顺序。集合大小与响应数组大小比较会拒绝未知或重复权限。
    public func setGroupRolePermissions(command: V2GroupRolePermissionsCommand) async throws -> V2GroupRolePermissionsChange {
        var request = IMV2Envelope(); request.setGroupRolePermissions = .init(); request.setGroupRolePermissions.operationID = command.operationID.rawValue; request.setGroupRolePermissions.roomID = command.roomID.rawValue; request.setGroupRolePermissions.role = command.role.rawValue; request.setGroupRolePermissions.expectedRevision = command.expectedRevision; request.setGroupRolePermissions.permissions = command.permissions.sorted { $0.rawValue < $1.rawValue }.map { var item = IMV2GroupRolePermission(); item.permission = $0.rawValue; return item }
        let response = try await requestEnvelope(request)
        guard case .groupRolePermissionsChanged(let value)? = response.body, value.roomID == command.roomID.rawValue, value.role == command.role.rawValue else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let permissions = Set(value.permissions.compactMap { V2GroupPermission(rawValue: $0.permission) })
        guard permissions.count == value.permissions.count, permissions == command.permissions else { throw V2RealtimeTransportError.unexpectedResponse }
        guard value.revision > 0, value.revision <= UInt64(Int64.max),
              value.roomSequence > 0, value.roomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        guard value.revision - 1 == command.expectedRevision else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(value.roomID), role: command.role, permissions: permissions, revision: value.revision, roomSequence: value.roomSequence)
    }

    /// 按预期成员修订变更指定成员角色，并检查响应完整匹配。
    ///
    /// - Parameter command: 含稳定操作身份、目标成员、角色及预期成员修订的命令。
    /// - Returns: 房间、成员和角色匹配，成员修订恰好推进一且房间序列有效的结果。
    /// - Throws: 响应字段或修订错误，以及服务端或传输错误。
    ///
    /// 本方法不修改本地成员目录，持久化状态通过调用方与同步流程收敛。
    public func changeGroupMemberRole(command: V2GroupMemberRoleCommand) async throws -> V2GroupMemberRoleChange {
        var request = IMV2Envelope(); request.changeGroupMemberRole = .init(); request.changeGroupMemberRole.operationID = command.operationID.rawValue; request.changeGroupMemberRole.roomID = command.roomID.rawValue; request.changeGroupMemberRole.userID = command.targetUserID.rawValue; request.changeGroupMemberRole.role = command.role.rawValue; request.changeGroupMemberRole.expectedMembershipRevision = command.expectedMembershipRevision
        let response = try await requestEnvelope(request)
        guard case .groupMemberRoleChanged(let value)? = response.body, value.roomID == command.roomID.rawValue, value.userID == command.targetUserID.rawValue, value.role == command.role.rawValue else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        guard value.membershipRevision > 0, value.membershipRevision <= UInt64(Int64.max),
              value.roomSequence > 0, value.roomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        guard value.membershipRevision - 1 == command.expectedMembershipRevision else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(value.roomID), targetUserID: .init(value.userID), role: command.role, membershipRevision: value.membershipRevision, roomSequence: value.roomSequence)
    }

    /// 提交带来源修订的转发命令，并校验结果覆盖所有来源与目标组合。
    ///
    /// - Parameter command: 稳定操作身份、有序来源引用及目标房间。
    /// - Returns: 保持服务端返回顺序的逐组合结果；顺序不保证与请求组合顺序一致。
    /// - Throws: 结果身份集合不匹配、组合遗漏或重复、成功与失败字段不一致，以及服务端或传输错误。
    ///
    /// 成功项必须有正式消息身份和正房间序列；失败项必须有错误代码、空消息身份和零序列。
    /// 逐项失败保留在返回数组中，不自动转换为整个请求失败；本方法不重试或持久化结果。
    public func forwardMessages(command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        var request = IMV2Envelope(); request.forwardMessages = .init(); request.forwardMessages.operationID = command.operationID.rawValue; request.forwardMessages.sources = command.sources.map { source in
            var wire = IMV2ForwardMessageReference()
            wire.roomID = source.roomID.rawValue
            wire.messageID = source.messageID.rawValue
            wire.revision = source.revision.rawValue
            return wire
        }; request.forwardMessages.targetRoomIds = command.targetRoomIDs.map(\.rawValue)
        let response = try await requestEnvelope(request)
        guard case .messagesForwarded(let body)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let expected = Set(command.sourceMessageIDs.flatMap { source in command.targetRoomIDs.map { source.rawValue + "|" + $0.rawValue } })
        let results = try body.results.map { value -> V2ForwardMessageResult in
            let source = try MessageID(value.sourceMessageID), target = try RoomID(value.targetRoomID)
            if value.errorCode.isEmpty { guard !value.messageID.isEmpty, value.roomSequence > 0, value.roomSequence <= UInt64(Int64.max) else { throw V2RealtimeTransportError.unexpectedResponse }; return try .init(sourceMessageID: source, targetRoomID: target, messageID: try .init(value.messageID), roomSequence: value.roomSequence, errorCode: nil) }
            guard value.messageID.isEmpty, value.roomSequence == 0 else { throw V2RealtimeTransportError.unexpectedResponse }
            return try .init(sourceMessageID: source, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: value.errorCode)
        }
        guard Set(results.map { $0.sourceMessageID.rawValue + "|" + $0.targetRoomID.rawValue }) == expected, results.count == expected.count else { throw V2RealtimeTransportError.unexpectedResponse }
        return results
    }

    /// 提交普通成员增删命令并核对修订恰好增加一。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - operationID: 稳定成员操作身份。
    ///   - targetUserID: 目标成员。
    ///   - action: 添加或移除。
    ///   - expectedMembershipRevision: 本次操作依据的成员修订。
    /// - Returns: 动作、房间和目标匹配，修订与房间序列可持久化的结果。
    /// - Throws: 响应枚举、身份、修订关系或传输错误。
    ///
    /// 服务器创建时间直接从毫秒转换，不在此另行检查非负；本地成员投影由后续流程更新。
    public func changeMembership(roomID: RoomID, operationID: MembershipOperationID, targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2ClientMembershipChange {
        var request = IMV2Envelope()
        request.changeRoomMembership = .init()
        request.changeRoomMembership.roomID = roomID.rawValue
        request.changeRoomMembership.operationID = operationID.rawValue
        request.changeRoomMembership.targetUserID = targetUserID.rawValue
        request.changeRoomMembership.action = action == .add ? .add : .remove
        request.changeRoomMembership.expectedMembershipRevision = expectedMembershipRevision
        let response = try await requestEnvelope(request)
        guard case .membershipChanged(let changed)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let returnedAction: V2RoomMembershipAction
        switch changed.action {
        case .add: returnedAction = .add
        case .remove: returnedAction = .remove
        case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse
        }
        guard returnedAction == action,
              changed.roomID == roomID.rawValue,
              changed.targetUserID == targetUserID.rawValue,
              changed.membershipRevision > 0, changed.membershipRevision <= UInt64(Int64.max),
              changed.roomSequence > 0, changed.roomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        guard changed.membershipRevision - 1 == expectedMembershipRevision else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(changed.roomID), targetUserID: .init(changed.targetUserID), action: returnedAction, membershipRevision: changed.membershipRevision, roomSequence: changed.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(changed.serverCreatedAtMs) / 1_000))
    }

    public func fetchRolePolicyBaseline(roomID: RoomID) async throws -> V2GroupRolePolicyBaseline {
        guard UUID(uuidString: roomID.rawValue) != nil else { throw V2RealtimeTransportError.unexpectedResponse }
        var request = IMV2Envelope()
        request.getGroupRolePolicyBaseline.roomID = roomID.rawValue
        let response = try await requestEnvelope(request)
        guard case .groupRolePolicyBaseline(let baseline)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        do {
            guard try RoomID(baseline.roomID) == roomID, baseline.policies.count == 2,
                  Set(baseline.policies.map(\.role)) == Set([V2RoomMembershipRole.admin.rawValue, V2RoomMembershipRole.member.rawValue])
            else { throw V2RealtimeTransportError.unexpectedResponse }
            var decoded: [String: Set<V2GroupPermission>] = [:]
            for policy in baseline.policies {
                let values = Set(policy.permissions.compactMap { V2GroupPermission(rawValue: $0.permission) })
                guard values.count == policy.permissions.count else { throw V2RealtimeTransportError.unexpectedResponse }
                decoded[policy.role] = values
            }
            guard let admin = decoded[V2RoomMembershipRole.admin.rawValue], let member = decoded[V2RoomMembershipRole.member.rawValue] else { throw V2RealtimeTransportError.unexpectedResponse }
            return try .init(roomID: roomID, permissionRevision: baseline.permissionRevision, membershipRevision: baseline.membershipRevision, roomSequence: baseline.roomSequence, adminPermissions: admin, memberPermissions: member)
        } catch { throw V2RealtimeTransportError.unexpectedResponse }
    }

    /// 按游标读取成员页并核对响应房间、数量、角色与成员身份。
    ///
    /// - Parameters:
    ///   - roomID: 待查看的房间。
    ///   - cursor: 首次为 nil；非空时必须有内容且不超过 512 个 UTF-8 字节。
    ///   - pageSize: 1 到 100 的页大小。
    /// - Returns: 单页无重复用户且角色有效的成员页；空后续游标转换为 nil。
    /// - Throws: 请求预算、响应一致性、身份构造、服务端或传输错误。
    ///
    /// 本方法不跨页去重，也不把成员结果保存为联系人关系。
    public func listRoomMembers(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientRoomMembersPage {
        guard pageSize > 0, pageSize <= V2ClientRoomMembersPageLimits.maximumPageSize,
              cursor.map({ !$0.isEmpty && $0.utf8.count <= V2ClientRoomMembersPageLimits.maximumCursorBytes }) ?? true
        else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        var request = IMV2Envelope(); request.listRoomMembers = .init()
        request.listRoomMembers.roomID = roomID.rawValue
        request.listRoomMembers.cursor = cursor ?? ""
        request.listRoomMembers.pageSize = UInt32(pageSize)
        let response = try await requestEnvelope(request)
        guard case .roomMembersPage(let page)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        guard page.roomID == roomID.rawValue,
              page.membershipRevision <= UInt64(Int64.max),
              page.members.count <= pageSize,
              page.nextCursor.utf8.count <= V2ClientRoomMembersPageLimits.maximumCursorBytes
        else { throw V2RealtimeTransportError.unexpectedResponse }
        let actorRole = try Self.membershipRole(from: page.actorRole)
        let members: [V2ClientRoomMember] = try page.members.map { member in
            let userID: UserID = try .init(member.userID)
            return .init(userID: userID, role: try Self.membershipRole(from: member.role))
        }
        guard Set(members.map(\.userID)).count == members.count else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(page.roomID), membershipRevision: page.membershipRevision, actorRole: actorRole, members: members, nextCursor: page.nextCursor.isEmpty ? nil : page.nextCursor)
    }

    /// 映射群主、管理员和普通成员角色；未指定或未知协议值作为异常响应拒绝。
    private static func membershipRole(from wireRole: IMV2RoomMembershipRole) throws -> V2RoomMembershipRole {
        switch wireRole {
        case .owner: return .owner
        case .admin: return .admin
        case .member: return .member
        case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    /// 提交稳定操作身份以打开或建立私聊房间。
    ///
    /// - Parameters:
    ///   - operationID: 本次私聊意图的稳定身份。
    ///   - targetUserID: 目标用户。
    /// - Returns: 目标身份与请求一致的房间摘要。
    /// - Throws: 响应类型、目标身份、领域身份构造、服务端或传输错误。
    ///
    /// 创建时间从协议毫秒转换，不在此额外检查非负；本地会话投影仍由后续持久化流程处理。
    public func openDirectRoom(operationID: DirectRoomOperationID, targetUserID: UserID) async throws -> V2ClientDirectRoom {
        var request = IMV2Envelope(); request.openDirectRoom = .init()
        request.openDirectRoom.operationID = operationID.rawValue
        request.openDirectRoom.targetUserID = targetUserID.rawValue
        let response = try await requestEnvelope(request)
        guard case .directRoomOpened(let opened)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        guard opened.targetUserID == targetUserID.rawValue else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(opened.roomID), targetUserID: .init(opened.targetUserID), createdAt: Date(timeIntervalSince1970: TimeInterval(opened.createdAtMs) / 1_000))
    }

    /// 请求建立或恢复指定操作的建群暂存状态。
    ///
    /// - Parameters:
    ///   - operationID: 跨阶段与重试稳定的操作身份。
    ///   - title: 提交给服务端的群名称。
    /// - Returns: 身份匹配、数量未超过上限的暂存摘要，名称采用服务端返回值。
    /// - Throws: 响应、领域值构造、服务端或传输错误。
    ///
    /// 返回名称只检查非空，不在此要求与提交名称完全相等；尚未产生可用房间。
    public func beginGroupRoomCreation(operationID: GroupRoomOperationID, title: String) async throws -> V2ClientGroupAudienceDraft {
        var request = IMV2Envelope(); request.beginGroupRoomCreation = .init()
        request.beginGroupRoomCreation.operationID = operationID.rawValue
        request.beginGroupRoomCreation.title = title
        let response = try await requestEnvelope(request)
        guard case .groupRoomCreationPrepared(let prepared)? = response.body,
              prepared.operationID == operationID.rawValue,
              prepared.stagedMemberCount <= UInt32(V2GroupCapacityPolicy.largeMaximumMembers - 1)
        else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        return try .init(operationID: .init(prepared.operationID), title: prepared.title, stagedMemberCount: Int(prepared.stagedMemberCount))
    }

    /// 向建群暂存状态追加一批成员身份。
    ///
    /// - Parameters:
    ///   - operationID: 已持久化的建群操作身份。
    ///   - memberUserIDs: 非空且不超过单次追加预算的身份数组，按原顺序编码，不在此去重。
    /// - Returns: 服务端累计暂存数量；返回对象的 title 为占位值 staged，不能用于更新群名称。
    /// - Throws: 输入数量、响应归属及上限、服务端或传输错误。
    ///
    /// 本方法不要求累计数恰好增加输入数量，去重及幂等语义由服务端负责。
    public func appendGroupRoomCreationMembers(operationID: GroupRoomOperationID, memberUserIDs: [UserID]) async throws -> V2ClientGroupAudienceDraft {
        guard !memberUserIDs.isEmpty, memberUserIDs.count <= V2GroupAudienceImportLimits.maximumMembersPerAppend else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        var request = IMV2Envelope(); request.appendGroupRoomCreationMembers = .init()
        request.appendGroupRoomCreationMembers.operationID = operationID.rawValue
        request.appendGroupRoomCreationMembers.memberUserIds = memberUserIDs.map(\.rawValue)
        let response = try await requestEnvelope(request)
        guard case .groupRoomCreationMembersAppended(let appended)? = response.body,
              appended.operationID == operationID.rawValue,
              appended.stagedMemberCount <= UInt32(V2GroupCapacityPolicy.largeMaximumMembers - 1)
        else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        return try .init(operationID: operationID, title: "staged", stagedMemberCount: Int(appended.stagedMemberCount))
    }

    /// 请求完成建群并校验正式房间摘要。
    ///
    /// - Parameter operationID: 与暂存阶段相同的稳定操作身份。
    /// - Returns: 名称非空、投递模式已识别且成员总数为正的房间；当前响应合同要求成员身份数组为空。
    /// - Throws: 响应字段、身份构造、服务端或传输错误。
    ///
    /// 完整名单按需分页读取，不依赖建群确认返回；此方法不负责本地命令终态落盘。
    public func finalizeGroupRoomCreation(operationID: GroupRoomOperationID) async throws -> V2ClientGroupRoom {
        var request = IMV2Envelope(); request.finalizeGroupRoomCreation = .init()
        request.finalizeGroupRoomCreation.operationID = operationID.rawValue
        let response = try await requestEnvelope(request)
        guard case .groupRoomCreated(let created)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        let returnedCapacityClass: V2GroupCapacityClass = switch created.capacityClass {
        case .standard: .standard
        case .large: .large
        case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse
        }
        let members = try created.memberUserIds.map { try UserID($0) }
        guard !created.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              members.count == Set(members).count,
              created.memberCount > 0,
              members.isEmpty
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(created.roomID), title: created.title, capacityClass: returnedCapacityClass, memberUserIDs: members, memberCount: created.memberCount, createdAt: Date(timeIntervalSince1970: TimeInterval(created.createdAtMs) / 1_000))
    }

    /// 取消服务端可变建群草稿，并核对确认中的操作身份。
    ///
    /// - Parameter operationID: 要取消的稳定建群操作身份。
    /// - Throws: 响应身份或类型、服务端或传输错误。
    ///
    /// 调用方需先按业务策略持久化本地取消意图，此方法不能替代本地状态迁移。
    public func cancelGroupRoomCreation(operationID: GroupRoomOperationID) async throws {
        var request = IMV2Envelope(); request.cancelGroupRoomCreation = .init()
        request.cancelGroupRoomCreation.operationID = operationID.rawValue
        let response = try await requestEnvelope(request)
        guard case .groupRoomCreationCancelled(let cancelled)? = response.body,
              cancelled.operationID == operationID.rawValue
        else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    /// 按房间水位读取群事件页，验证事件顺序与游标推进。
    ///
    /// - Parameters:
    ///   - roomID: 事件所属房间。
    ///   - afterRoomSequence: 已处理水位，返回事件必须严格晚于它。
    ///   - pageSize: 正数且不超过群事件分页上限。
    /// - Returns: 房间匹配、事件严格递增且位于请求水位与后续水位之间的页面。
    /// - Throws: 页大小、响应身份、条数、事件内容标识或水位关系错误，以及传输错误。
    ///
    /// 允许事件序列有间隔；hasMore 为真时要求后续水位严格推进，但不要求一定返回非空事件。
    /// 此方法不解码投影载荷或提交本地游标。
    public func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage {
        guard pageSize > 0, pageSize <= V2GroupEventLogLimits.maximumPageSize else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        var request = IMV2Envelope(); request.groupEventPull = .init()
        request.groupEventPull.roomID = roomID.rawValue
        request.groupEventPull.afterRoomSequence = afterRoomSequence
        request.groupEventPull.pageSize = UInt32(pageSize)
        let response = try await requestEnvelope(request)
        guard case .groupEventPage(let page)? = response.body,
              page.roomID == roomID.rawValue,
              page.events.count <= pageSize,
              page.nextRoomSequence >= afterRoomSequence,
              page.nextRoomSequence <= UInt64(Int64.max)
        else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let events: [V2ClientGroupEvent] = try page.events.map {
            guard $0.roomSequence > afterRoomSequence, $0.roomSequence <= page.nextRoomSequence,
                  !$0.projectionKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !$0.payload.isEmpty
            else { throw V2RealtimeTransportError.unexpectedResponse }
            return try .init(sourceEventID: try .init($0.sourceEventID), roomSequence: $0.roomSequence, projectionKind: $0.projectionKind, payload: $0.payload)
        }
        guard zip(events, events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
              (events.last.map(\.roomSequence) ?? afterRoomSequence) <= page.nextRoomSequence,
              !page.hasMore_p || page.nextRoomSequence > afterRoomSequence
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(
            roomID: .init(page.roomID),
            events: events,
            nextRoomSequence: page.nextRoomSequence,
            hasMore: page.hasMore_p,
            logTrimmedThroughRoomSequence: page.logTrimmedThroughRoomSequence
        )
    }

    /// 请求群事件订阅并取得服务器高水位。
    ///
    /// - Parameters:
    ///   - roomID: 待订阅房间。
    ///   - afterRoomSequence: 客户端提交的已处理水位。
    /// - Returns: 房间匹配且不超过 Int64.max 的高水位摘要。
    /// - Throws: 响应身份或水位范围错误，以及服务端或传输错误。
    ///
    /// 此处不要求返回高水位大于提交水位，也不自动执行补拉或续订。
    public func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) async throws -> V2ClientGroupEventSubscription {
        try await subscribeToGroupEvents(roomID: roomID, afterRoomSequence: afterRoomSequence, authorPresentationView: nil)
    }

    /// The view must come from this authenticated connection before subscribing.
    public func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64,
                                       authorPresentationView: V2AuthorPresentationView?) async throws -> V2ClientGroupEventSubscription {
        guard authorPresentationView.map({ $0.roomID == roomID && $0.renewBy > .now }) ?? true else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        var request = IMV2Envelope()
        request.groupEventSubscribe = .init()
        request.groupEventSubscribe.roomID = roomID.rawValue
        request.groupEventSubscribe.afterRoomSequence = afterRoomSequence
        request.groupEventSubscribe.authorPresentationViewID = authorPresentationView?.viewID.uuidString ?? ""
        let response = try await requestEnvelope(request)
        guard case .groupEventSubscribed(let subscribed)? = response.body,
              subscribed.roomID == roomID.rawValue,
              subscribed.highWatermark <= UInt64(Int64.max),
              subscribed.authorPresentationViewID == request.groupEventSubscribe.authorPresentationViewID
        else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        return try .init(roomID: roomID, highWatermark: subscribed.highWatermark)
    }

    /// Ends an exact disposable view, including one whose subscribe caller was
    /// cancelled. The server echoes all identities without touching room access.
    public func stopAuthorPresentation(_ view: V2AuthorPresentationView) async throws {
        var request = IMV2Envelope()
        request.authorPresentationEnd.streamID = view.streamID.uuidString
        request.authorPresentationEnd.roomID = view.roomID.rawValue
        request.authorPresentationEnd.viewID = view.viewID.uuidString
        let response = try await requestEnvelope(request)
        guard case .authorPresentationEnded(let ended) = response.body,
              UUID(uuidString: ended.streamID) == view.streamID,
              (try? RoomID(ended.roomID)) == view.roomID,
              UUID(uuidString: ended.viewID) == view.viewID else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    /// 取消指定房间群事件订阅并要求 acknowledged 响应；本地观察者和缓存生命周期由上层负责，传输或服务端失败继续抛出。
    public func unsubscribeFromGroupEvents(roomID: RoomID) async throws {
        var request = IMV2Envelope()
        request.groupEventUnsubscribe = .init()
        request.groupEventUnsubscribe.roomID = roomID.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
    }

    /// 设置账户的陌生人消息权限并要求服务器回显相同设置。
    ///
    /// - Parameters:
    ///   - operationID: 重试间保持稳定的偏好操作身份。
    ///   - permission: 允许或拒绝。
    /// - Returns: 服务器更新时间，由协议毫秒转换，不在此检查非负。
    /// - Throws: 未知权限枚举、响应权限与请求不符，以及服务端或传输错误。
    ///
    /// 此方法不持久化本地偏好，调用者应结合服务器结果和同步状态更新界面。
    public func setStrangerMessagePermission(operationID: StrangerMessagePreferenceOperationID, permission: V2StrangerMessagePermission) async throws -> Date {
        var request = IMV2Envelope(); request.setStrangerMessagePermission = .init()
        request.setStrangerMessagePermission.operationID = operationID.rawValue
        request.setStrangerMessagePermission.permission = permission == .allow ? .allow : .deny
        let response = try await requestEnvelope(request)
        guard case .strangerMessagePermissionSet(let result)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        let returned: V2StrangerMessagePermission
        switch result.permission { case .allow: returned = .allow; case .deny: returned = .deny; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard returned == permission else { throw V2RealtimeTransportError.unexpectedResponse }
        return Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000)
    }

    /// 设置账户的用户添加权限并要求服务器回显相同设置。
    ///
    /// - Parameters:
    ///   - operationID: 重试间保持稳定的偏好操作身份。
    ///   - permission: 允许或拒绝。
    /// - Returns: 服务器更新时间，由协议毫秒转换，不在此检查非负。
    /// - Throws: 未知权限枚举、响应权限与请求不符，以及服务端或传输错误。
    ///
    /// 此方法不持久化本地偏好，调用者应结合服务器结果和同步状态更新界面。
    public func setUserAddPermission(operationID: UserAddPreferenceOperationID, permission: V2UserAddPermission) async throws -> Date {
        var request = IMV2Envelope(); request.setUserAddPermission = .init()
        request.setUserAddPermission.operationID = operationID.rawValue
        request.setUserAddPermission.permission = permission == .allow ? .allow : .deny
        let response = try await requestEnvelope(request)
        guard case .userAddPermissionSet(let result)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        let returned: V2UserAddPermission
        switch result.permission { case .allow: returned = .allow; case .deny: returned = .deny; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard returned == permission else { throw V2RealtimeTransportError.unexpectedResponse }
        return Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000)
    }

    /// 提交关系申请、接受、拒绝或移除操作，并映射服务器结果。
    ///
    /// - Parameters:
    ///   - operationID: 重试间保持稳定的关系操作身份。
    ///   - targetUserID: 请求目标用户。
    ///   - action: 要执行的关系动作。
    /// - Returns: 动作与请求一致、状态枚举已识别的关系结果。
    /// - Throws: 未知响应枚举、动作不匹配、身份构造、服务端或传输错误。
    ///
    /// 当前实现直接采用响应中的目标用户身份，未与请求目标再次比较；也不在此校验动作与结果状态的组合。
    /// 更新时间从毫秒转换，不额外检查非负。
    public func changeRelationship(operationID: RelationshipOperationID, targetUserID: UserID, action: V2RelationshipAction) async throws -> V2ClientRelationshipChange {
        var request = IMV2Envelope(); request.changeRelationship = .init()
        request.changeRelationship.operationID = operationID.rawValue
        request.changeRelationship.targetUserID = targetUserID.rawValue
        request.changeRelationship.action = switch action { case .request: .request; case .accept: .accept; case .reject: .reject; case .remove: .remove }
        let response = try await requestEnvelope(request)
        guard case .relationshipChanged(let result)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let returnedAction: V2RelationshipAction
        switch result.action { case .request: returnedAction = .request; case .accept: returnedAction = .accept; case .reject: returnedAction = .reject; case .remove: returnedAction = .remove; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        let state: V2RelationshipState
        switch result.resultingState { case .none: state = .none; case .pending: state = .pending; case .accepted: state = .accepted; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard returnedAction == action else { throw V2RealtimeTransportError.unexpectedResponse }
        return .init(targetUserID: try .init(result.targetUserID), action: returnedAction, resultingState: state, updatedAt: Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000))
    }

    /// 提交屏蔽或解除屏蔽，并核对目标、动作与结果标志。
    ///
    /// - Parameters:
    ///   - operationID: 稳定屏蔽操作身份。
    ///   - targetUserID: 目标用户。
    ///   - action: 屏蔽或解除屏蔽。
    /// - Returns: 与请求目标、动作及预期屏蔽标志全部一致的结果。
    /// - Throws: 响应类型、枚举或字段不匹配，以及服务端或传输错误。
    ///
    /// 不自动修改本地关系图；更新时间转换后不额外检查非负。
    public func changeUserBlock(operationID: UserBlockOperationID, targetUserID: UserID, action: V2UserBlockAction) async throws -> V2ClientUserBlockChange {
        var request = IMV2Envelope(); request.changeUserBlock = .init()
        request.changeUserBlock.operationID = operationID.rawValue
        request.changeUserBlock.targetUserID = targetUserID.rawValue
        request.changeUserBlock.action = action == .block ? .block : .unblock
        let response = try await requestEnvelope(request)
        guard case .userBlockChanged(let result)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let returnedAction: V2UserBlockAction
        switch result.action { case .block: returnedAction = .block; case .unblock: returnedAction = .unblock; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard returnedAction == action, result.targetUserID == targetUserID.rawValue, result.isBlocked == (action == .block) else { throw V2RealtimeTransportError.unexpectedResponse }
        return .init(targetUserID: targetUserID, action: returnedAction, isBlocked: result.isBlocked, updatedAt: Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000))
    }

    /// 请求撤回消息并验证响应修订恰好比预期修订增加一。
    ///
    /// - Parameters:
    ///   - roomID: 消息所属房间。
    ///   - operationID: 跨重试稳定的撤回操作身份。
    ///   - messageID: 要撤回的消息。
    ///   - expectedMessageRevision: 客户端当前预期修订。
    /// - Returns: 房间和消息身份匹配、修订与房间位置可持久化的撤回回执。
    /// - Throws: 响应身份、修订、房间序列错误，或服务端与传输错误。
    ///
    /// 成功响应不自动修改本地投影。本层转换服务器时间，但不额外检查该时间非负。
    public func withdrawMessage(roomID: RoomID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) async throws -> V2ClientMessageWithdrawal {
        var request = IMV2Envelope()
        request.withdrawMessage = .init()
        request.withdrawMessage.roomID = roomID.rawValue
        request.withdrawMessage.operationID = operationID.rawValue
        request.withdrawMessage.messageID = messageID.rawValue
        request.withdrawMessage.expectedMessageRevision = expectedMessageRevision
        let response = try await requestEnvelope(request)
        guard case .messageWithdrawn(let withdrawn)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard withdrawn.roomID == roomID.rawValue, withdrawn.messageID == messageID.rawValue,
              withdrawn.messageRevision > expectedMessageRevision, withdrawn.messageRevision <= UInt64(Int64.max),
              withdrawn.roomSequence > 0, withdrawn.roomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        guard withdrawn.messageRevision - 1 == expectedMessageRevision else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(withdrawn.roomID), messageID: .init(withdrawn.messageID), messageRevision: withdrawn.messageRevision, roomSequence: withdrawn.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(withdrawn.serverCreatedAtMs) / 1_000))
    }

    /// 提交带审核原因的消息屏蔽操作并验证回执。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - operationID: 稳定审核操作身份。
    ///   - messageID: 被屏蔽消息。
    ///   - reasonCode: 审核原因代码。
    /// - Returns: 身份匹配、消息修订大于一且房间序列有效的回执。
    /// - Throws: 响应字段、服务端或传输错误。
    ///
    /// 此操作没有客户端预期修订参数，不执行恰好增加一的比较。权限与审核记录由服务端负责。
    public func redactMessage(roomID: RoomID, operationID: ModerationOperationID, messageID: MessageID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMessageRedaction {
        var request = IMV2Envelope()
        request.moderateMessage = .init()
        request.moderateMessage.roomID = roomID.rawValue
        request.moderateMessage.operationID = operationID.rawValue
        request.moderateMessage.messageID = messageID.rawValue
        request.moderateMessage.reasonCode = reasonCode.rawValue
        let response = try await requestEnvelope(request)
        guard case .messageRedacted(let redacted)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard redacted.roomID == roomID.rawValue, redacted.messageID == messageID.rawValue,
              redacted.messageRevision > 1, redacted.messageRevision <= UInt64(Int64.max),
              redacted.roomSequence > 0, redacted.roomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(redacted.roomID), messageID: .init(redacted.messageID), messageRevision: redacted.messageRevision, roomSequence: redacted.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(redacted.serverCreatedAtMs) / 1_000))
    }

    /// 把禁言期限安全转换为毫秒后提交，并核对服务端回显。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - operationID: 稳定审核操作身份。
    ///   - targetUserID: 被禁言成员。
    ///   - muteUntil: 必须可表示为正 Int64 Unix 毫秒的日期，向零舍入。
    ///   - reasonCode: 审核原因。
    /// - Returns: 房间、成员和编码后期限匹配，房间序列有效且服务器创建时间非负的回执。
    /// - Throws: 时间不可表示、响应不匹配、服务端或传输错误。
    ///
    /// 此处不读取当前时间，禁言期限是否晚于现在由服务端决定。
    public func muteMember(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2ClientMemberMute {
        guard let muteUntilMilliseconds = Int64(exactly: (muteUntil.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
              muteUntilMilliseconds > 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        var request = IMV2Envelope(); request.muteMember = .init()
        request.muteMember.roomID = roomID.rawValue
        request.muteMember.operationID = operationID.rawValue
        request.muteMember.targetUserID = targetUserID.rawValue
        request.muteMember.muteUntilMs = muteUntilMilliseconds
        request.muteMember.reasonCode = reasonCode.rawValue
        let response = try await requestEnvelope(request)
        guard case .memberMuted(let muted)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard muted.roomID == roomID.rawValue, muted.targetUserID == targetUserID.rawValue,
              muted.muteUntilMs == muteUntilMilliseconds, muted.roomSequence > 0,
              muted.roomSequence <= UInt64(Int64.max),
              muted.serverCreatedAtMs >= 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(muted.roomID), targetUserID: .init(muted.targetUserID), muteUntil: Date(timeIntervalSince1970: TimeInterval(muted.muteUntilMs) / 1_000), roomSequence: muted.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(muted.serverCreatedAtMs) / 1_000))
    }

    /// 提交独立审核移除命令并校验结果。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - operationID: 审核操作身份，与普通成员管理操作分离。
    ///   - targetUserID: 要移除的成员。
    ///   - reasonCode: 审核原因。
    /// - Returns: 身份匹配、成员修订与房间序列为正且可持久化、创建时间非负的回执。
    /// - Throws: 响应校验、服务端或传输错误。
    ///
    /// 本方法不携带预期成员修订，因此不执行与客户端旧修订的递增关系检查。
    public func removeMemberByModerator(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, reasonCode: V2ModerationReasonCode) async throws -> V2ClientModeratedMemberRemoval {
        var request = IMV2Envelope(); request.moderateMemberRemoval = .init()
        request.moderateMemberRemoval.roomID = roomID.rawValue
        request.moderateMemberRemoval.operationID = operationID.rawValue
        request.moderateMemberRemoval.targetUserID = targetUserID.rawValue
        request.moderateMemberRemoval.reasonCode = reasonCode.rawValue
        let response = try await requestEnvelope(request)
        guard case .memberRemovedByModerator(let removed)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard removed.roomID == roomID.rawValue, removed.targetUserID == targetUserID.rawValue,
              removed.membershipRevision > 0, removed.roomSequence > 0,
              removed.membershipRevision <= UInt64(Int64.max), removed.roomSequence <= UInt64(Int64.max),
              removed.serverCreatedAtMs >= 0
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(removed.roomID), targetUserID: .init(removed.targetUserID), membershipRevision: removed.membershipRevision, roomSequence: removed.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(removed.serverCreatedAtMs) / 1_000))
    }

    /// 提交文本编辑，并验证回执保留请求文本且修订恰好推进一。
    ///
    /// - Parameters:
    ///   - roomID: 消息房间。
    ///   - operationID: 稳定编辑操作身份。
    ///   - messageID: 被编辑消息。
    ///   - expectedMessageRevision: 编辑所依据的修订。
    ///   - text: 新文本，按原样发送。
    /// - Returns: 身份和文本匹配、修订与房间位置有效的编辑结果。
    /// - Throws: 响应不一致、服务端或传输错误。
    ///
    /// 此适配方法只设置文本字段，不进行本地正文校验或投影持久化；服务器时间转换后不额外检查正负。
    public func editMessage(roomID: RoomID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) async throws -> V2ClientMessageEdit {
        var request = IMV2Envelope()
        request.editMessage = .init()
        request.editMessage.roomID = roomID.rawValue
        request.editMessage.operationID = operationID.rawValue
        request.editMessage.messageID = messageID.rawValue
        request.editMessage.expectedMessageRevision = expectedMessageRevision
        request.editMessage.content = .init()
        request.editMessage.content.text = text
        let response = try await requestEnvelope(request)
        guard case .messageEdited(let edited)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard edited.roomID == roomID.rawValue, edited.messageID == messageID.rawValue,
              edited.text == text, edited.messageRevision > expectedMessageRevision,
              edited.messageRevision <= UInt64(Int64.max),
              edited.roomSequence > 0, edited.roomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        guard edited.messageRevision - 1 == expectedMessageRevision else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(edited.roomID), messageID: .init(edited.messageID), text: edited.text, messageRevision: edited.messageRevision, roomSequence: edited.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(edited.serverCreatedAtMs) / 1_000))
    }

    /// 提交已读水位并接受服务器保留的更高水位。
    ///
    /// - Parameters:
    ///   - roomID: 已读状态所属房间。
    ///   - operationID: 跨重试稳定的回执操作身份。
    ///   - readThroughRoomSequence: 本次请求记录的已读水位。
    /// - Returns: 房间匹配、为正且可持久化、并不低于提交值的服务器水位。
    /// - Throws: 响应校验、身份构造、服务端或传输错误。
    ///
    /// 响应用户身份由服务器提供并转换为领域身份，此方法不另与本地账户比较；记录时间转换后不额外检查正负。
    public func recordReadReceipt(roomID: RoomID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) async throws -> V2ClientReadReceipt {
        var request = IMV2Envelope(); request.recordReadReceipt = .init()
        request.recordReadReceipt.roomID = roomID.rawValue
        request.recordReadReceipt.operationID = operationID.rawValue
        request.recordReadReceipt.readThroughRoomSequence = readThroughRoomSequence
        let response = try await requestEnvelope(request)
        guard case .readReceiptRecorded(let recorded)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        guard recorded.roomID == roomID.rawValue, recorded.readThroughRoomSequence >= readThroughRoomSequence,
              recorded.readThroughRoomSequence > 0, recorded.readThroughRoomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(recorded.roomID), userID: .init(recorded.userID), readThroughRoomSequence: recorded.readThroughRoomSequence, recordedAt: Date(timeIntervalSince1970: TimeInterval(recorded.recordedAtMs) / 1_000))
    }

    /// 提交私聊和群聊已读回执偏好，返回服务器状态。
    ///
    /// - Parameters:
    ///   - operationID: 稳定偏好操作身份。
    ///   - allowsDirectReadReceipts: 是否允许私聊回执。
    ///   - allowsGroupReadReceipts: 是否允许群聊回执。
    /// - Returns: 服务器返回的偏好及非负更新时间。
    /// - Throws: 响应类型或时间错误，以及服务端或传输错误。
    ///
    /// 本层不要求返回的两个布尔值与请求完全相等，也不自动保存本地设置。
    public func setReadReceiptPreferences(operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2ReadReceiptPreferences {
        var request = IMV2Envelope(); request.setReadReceiptPreferences = .init()
        request.setReadReceiptPreferences.operationID = operationID.rawValue
        request.setReadReceiptPreferences.allowsDirectReadReceipts = allowsDirectReadReceipts
        request.setReadReceiptPreferences.allowsGroupReadReceipts = allowsGroupReadReceipts
        let response = try await requestEnvelope(request)
        guard case .readReceiptPreferencesSet(let result)? = response.body, result.updatedAtMs >= 0 else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        return .init(allowsDirectReadReceipts: result.allowsDirectReadReceipts, allowsGroupReadReceipts: result.allowsGroupReadReceipts, updatedAt: Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000))
    }

    /// 分页读取有权查看的消息已读者及公开资料。
    ///
    /// - Parameters:
    ///   - roomID: 消息所属房间。
    ///   - messageID: 要查看的消息。
    ///   - cursor: 不透明后续游标，nil 编码为空字符串。
    ///   - pageSize: 1 到 100 的请求数量。
    /// - Returns: 房间和消息匹配、有界且不重复的读者标识页；空后续游标转换为 nil。
    /// - Throws: 页大小、游标、响应身份、领域页构造或传输错误。
    public func listReadReceiptReaders(roomID: RoomID, messageID: MessageID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        guard (1 ... V2ClientReadReceiptLimits.maximumPageSize).contains(pageSize),
              cursor.map({ !$0.isEmpty && $0.utf8.count <= V2ClientReadReceiptLimits.maximumCursorBytes }) ?? true else { throw V2RealtimeTransportError.unexpectedResponse }
        var request = IMV2Envelope(); request.listReadReceiptReaders = .init()
        request.listReadReceiptReaders.roomID = roomID.rawValue
        request.listReadReceiptReaders.messageID = messageID.rawValue
        request.listReadReceiptReaders.cursor = cursor ?? ""
        request.listReadReceiptReaders.pageSize = UInt32(pageSize)
        let response = try await requestEnvelope(request)
        guard case .readReceiptReadersPage(let page)? = response.body,
              page.roomID == roomID.rawValue,
              page.messageID == messageID.rawValue,
              page.readers.count <= pageSize, page.nextCursor.utf8.count <= V2ClientReadReceiptLimits.maximumCursorBytes,
              page.nextCursor.isEmpty || page.nextCursor != cursor
        else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let readers = try page.readers.map { reader -> V2ReadReceiptReader in
            .init(userID: try UserID(reader.userID))
        }
        return try .init(
            roomID: roomID,
            messageID: messageID,
            readers: readers,
            nextCursor: page.nextCursor.isEmpty ? nil : page.nextCursor
        )
    }

    /// 提交在线和输入指示偏好并返回服务器确认状态。
    ///
    /// - Parameters:
    ///   - operationID: 稳定偏好操作身份。
    ///   - allowsOnlinePresence: 是否允许在线展示。
    ///   - allowsTypingIndicators: 是否允许输入指示。
    /// - Returns: 服务端偏好及非负更新时间，不在此要求返回值与请求逐项相等。
    /// - Throws: 响应类型、时间、服务端或传输错误。
    public func setLiveActivityPreferences(operationID: LiveActivityPreferenceOperationID, allowsOnlinePresence: Bool, allowsTypingIndicators: Bool) async throws -> V2LiveActivityPreferences {
        var request = IMV2Envelope(); request.setLiveActivityPreferences = .init()
        request.setLiveActivityPreferences.operationID = operationID.rawValue
        request.setLiveActivityPreferences.allowsOnlinePresence = allowsOnlinePresence
        request.setLiveActivityPreferences.allowsTypingIndicators = allowsTypingIndicators
        let response = try await requestEnvelope(request)
        guard case .liveActivityPreferencesSet(let result)? = response.body, result.updatedAtMs >= 0 else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        return .init(allowsOnlinePresence: result.allowsOnlinePresence, allowsTypingIndicators: result.allowsTypingIndicators, updatedAt: Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000))
    }

    /// 读取服务器当前在线及输入指示偏好，要求响应类型匹配且更新时间非负；不在此持久化缓存。
    public func liveActivityPreferences() async throws -> V2LiveActivityPreferences {
        var request = IMV2Envelope(); request.getLiveActivityPreferences = .init()
        let response = try await requestEnvelope(request)
        guard case .liveActivityPreferences(let result)? = response.body, result.updatedAtMs >= 0 else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        return .init(allowsOnlinePresence: result.allowsOnlinePresence, allowsTypingIndicators: result.allowsTypingIndicators, updatedAt: Date(timeIntervalSince1970: TimeInterval(result.updatedAtMs) / 1_000))
    }

    /// 订阅房间在线状态并返回初始状态。
    ///
    /// - Parameter roomID: 待订阅房间。
    /// - Returns: 房间匹配、到期毫秒非负且目标用户身份有效的状态。
    /// - Throws: 响应校验、身份构造、服务端或传输错误。
    ///
    /// 不读取当前时钟判断期限是否已到期，也不在此启动续订或自动取消任务。
    public func subscribePresence(roomID: RoomID) async throws -> V2PresenceState {
        var request = IMV2Envelope(); request.subscribePresence = .init(); request.subscribePresence.roomID = roomID.rawValue
        let response = try await requestEnvelope(request)
        guard case .presenceSubscribed(let state)? = response.body, state.roomID == roomID.rawValue, state.expiresAtMs >= 0 else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        return try .init(roomID: roomID, targetUserID: .init(state.targetUserID), isOnline: state.isOnline, expiresAt: Date(timeIntervalSince1970: TimeInterval(state.expiresAtMs) / 1_000))
    }

    /// 请求取消房间在线订阅并要求 acknowledged 响应；不在此移除本地观察者或缓存。
    public func unsubscribePresence(roomID: RoomID) async throws {
        var request = IMV2Envelope(); request.unsubscribePresence = .init(); request.unsubscribePresence.roomID = roomID.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
    }

    /// 请求订阅房间输入指示并要求 acknowledged 响应；该确认不包含初始输入状态。
    public func subscribeTyping(roomID: RoomID) async throws {
        var request = IMV2Envelope(); request.subscribeTyping = .init(); request.subscribeTyping.roomID = roomID.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
    }

    /// 请求取消房间输入指示订阅并要求 acknowledged 响应；上层仍需管理本地观察生命周期。
    public func unsubscribeTyping(roomID: RoomID) async throws {
        var request = IMV2Envelope(); request.unsubscribeTyping = .init(); request.unsubscribeTyping.roomID = roomID.rawValue
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
    }

    /// 发布房间输入状态并等待 acknowledged。
    ///
    /// - Parameters:
    ///   - roomID: 输入状态所属房间。
    ///   - isTyping: 是否正在输入。
    /// - Throws: 响应类型、服务端或传输错误。
    ///
    /// 本方法不节流、不合并请求，也不自动安排停止输入事件；调用方负责交互节奏和生命周期。
    public func setTyping(roomID: RoomID, isTyping: Bool) async throws {
        var request = IMV2Envelope(); request.setTypingState = .init(); request.setTypingState.roomID = roomID.rawValue; request.setTypingState.isTyping = isTyping
        let response = try await requestEnvelope(request)
        guard case .acknowledged? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
    }

    /// 提交表情变更并核对房间、消息、表情内容与动作。
    ///
    /// - Parameters:
    ///   - roomID: 消息所属房间。
    ///   - operationID: 重试间保持稳定的表情操作身份。
    ///   - messageID: 目标消息。
    ///   - reaction: 按原样发送的表情内容。
    ///   - action: 添加或移除。
    /// - Returns: 字段匹配且房间序列为正、可持久化的表情回执。
    /// - Throws: 未知动作、响应不匹配、身份构造、服务端或传输错误。
    ///
    /// 执行用户取自响应并构造领域身份，不在此与本地账户再次比较。创建时间从毫秒转换，不额外检查非负。
    /// 此方法不更新本地表情投影，也不自动重试。
    public func changeMessageReaction(roomID: RoomID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) async throws -> V2ClientMessageReactionChange {
        var request = IMV2Envelope(); request.changeMessageReaction = .init()
        request.changeMessageReaction.roomID = roomID.rawValue
        request.changeMessageReaction.operationID = operationID.rawValue
        request.changeMessageReaction.messageID = messageID.rawValue
        request.changeMessageReaction.reaction = reaction
        request.changeMessageReaction.action = action == .add ? .add : .remove
        let response = try await requestEnvelope(request)
        guard case .messageReactionChanged(let changed)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        let returnedAction: V2MessageReactionAction
        switch changed.action { case .add: returnedAction = .add; case .remove: returnedAction = .remove; case .unspecified, .UNRECOGNIZED: throw V2RealtimeTransportError.unexpectedResponse }
        guard changed.roomID == roomID.rawValue, changed.messageID == messageID.rawValue,
              changed.reaction == reaction, returnedAction == action,
              changed.roomSequence > 0, changed.roomSequence <= UInt64(Int64.max)
        else { throw V2RealtimeTransportError.unexpectedResponse }
        return try .init(roomID: .init(changed.roomID), messageID: .init(changed.messageID), actorUserID: .init(changed.actorUserID), reaction: changed.reaction, action: returnedAction, roomSequence: changed.roomSequence, createdAt: Date(timeIntervalSince1970: TimeInterval(changed.serverCreatedAtMs) / 1_000))
    }

    /// 分配非零请求号、写入协商版本并执行一轮帧请求。
    ///
    /// 编码与解码使用适配器默认预算，未在此传入压缩协商；响应必须匹配本次请求号和协议版本。
    /// 计数器回绕跳过零，但不在此扫描仍在途的历史编号。返回的业务错误 envelope 由各命令方法另行映射。
    func requestEnvelope(_ envelope: IMV2Envelope) async throws -> IMV2Envelope {
        var outbound = envelope
        let requestID = nextRequestID
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }
        outbound.requestID = requestID
        outbound.protocolVersion = UInt32(protocolVersion)
        let response = try await wire.request(try V2ProtobufFrameCodec.encode(outbound, frameVersion: protocolVersion))
        let decoded = try V2ProtobufFrameCodec.decode(response)
        guard decoded.requestID == requestID, decoded.protocolVersion == UInt32(protocolVersion), response.version == protocolVersion else { throw V2RealtimeTransportError.unexpectedResponse }
        return decoded
    }

    /// 把错误消息体映射为服务端错误，其他消息体不操作。
    ///
    /// 仅对 REVISION_CONFLICT 保留当前修订，并检查其可持久化整数范围；不在此自动重试或等待。
    func throwServerErrorIfPresent(_ envelope: IMV2Envelope) throws {
        if case .error(let error)? = envelope.body {
            guard error.code != "REVISION_CONFLICT" || error.currentRevision <= UInt64(Int64.max) else {
                throw V2RealtimeTransportError.unexpectedResponse
            }
            throw V2RealtimeTransportError.server(
                code: error.code,
                retryable: error.retryable,
                retryAfterSeconds: error.retryAfterSeconds,
                currentRevision: error.code == "REVISION_CONFLICT" ? error.currentRevision : nil
            )
        }
    }
}
