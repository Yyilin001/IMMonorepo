import Crypto
import Foundation
import IMV2Core

/// 同步适配器所依赖的已认证帧连接。
///
/// 具体连接拥有 TLS、重连与认证生命周期；此接口只负责发送一个请求并返回关联响应，便于离线测试协议映射。
public protocol V2AuthenticatedFrameTransport: Sendable {
    /// 发送完整请求帧并等待对应响应；关联管理、取消和连接错误由具体传输实现负责。
    func request(_ frame: V2Frame) async throws -> V2Frame
    func negotiatedProtocolVersion() async -> UInt8?
}

public extension V2AuthenticatedFrameTransport {
    func negotiatedProtocolVersion() async -> UInt8? { nil }
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
}

/// 会话置顶、归档、静音和消息收藏的传输边界；返回服务器结果，本地持久化由调用方负责。
public protocol V2ClientConversationCapabilitiesTransport: Sendable {
    /// 提交会话置顶、归档与静音状态。
    ///
    /// - Parameter command: 已构造的稳定业务命令，重试应保持身份与内容一致。
    /// - Returns: 服务器确认的领域结果。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    func setConversationState(command: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt
    /// 提交消息收藏状态。
    ///
    /// - Parameter command: 已构造的稳定业务命令，重试应保持身份与内容一致。
    /// - Returns: 服务器确认的领域结果。
    /// - Throws: 服务端拒绝、响应校验或传输错误。
    func setMessageFavorite(command: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt
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
public actor V2ProtobufSyncTransport: V2ClientSyncTransport, V2ClientGroupRolePolicyBaselineTransport, V2ClientMessageTransport, V2ClientConversationCapabilitiesTransport, V2ClientMembershipDirectoryTransport, V2ClientGroupEventTransport, V2ClientGroupEventSubscriptionTransport, V2ClientMessageWithdrawalTransport, V2ClientMessageEditTransport, V2ClientMessageReactionTransport, V2ClientReadReceiptTransport, V2ClientLiveActivityTransport, V2HeartbeatSender {
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



    /// 提交冻结的会话设置，并验证原操作回执的指纹、目标值及修订。
    /// 账户绑定由持有本地 intent 的服务再次核对；同步投影不能替代回执。
    public func setConversationState(command: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt {
        var request = IMV2Envelope(); request.setConversationState = .init()
        request.setConversationState.operationID = command.operationID.rawValue; request.setConversationState.roomID = command.roomID.rawValue
        request.setConversationState.isPinned = command.isPinned; request.setConversationState.isArchived = command.isArchived
        request.setConversationState.expectedRevision = command.expectedRevision.rawValue
        request.setConversationState.firstSubmissionDeadlineMs = command.firstSubmissionDeadlineMilliseconds
        if let muteUntil = command.muteUntil {
            guard let milliseconds = Int64(exactly: (muteUntil.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
                throw V2RealtimeTransportError.unexpectedResponse
            }
            request.setConversationState.muteUntilMs = milliseconds
        }
        let response = try await requestEnvelope(request)
        guard case .personalPreferenceReceipt(let value)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let receipt = try V2PersonalPreferenceReceiptCodec.decode(value)
        guard receipt.identity == (try command.identity(actorUserID: receipt.identity.accountID)),
              receipt.fingerprint == (try command.fingerprint(actorUserID: receipt.identity.accountID)) else { throw V2RealtimeTransportError.unexpectedResponse }
        if case .committed(.conversationState(let state)) = receipt.outcome {
            guard state.isPinned == command.isPinned, state.isArchived == command.isArchived, state.muteUntil == command.muteUntil,
                  state.revision.rawValue > 0, state.revision.rawValue - 1 == command.expectedRevision.rawValue else { throw V2RealtimeTransportError.unexpectedResponse }
        }
        return receipt
    }

    /// 提交冻结的收藏设置，返回成功、拒绝或关闭的不可变原回执。
    public func setMessageFavorite(command: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt {
        var request = IMV2Envelope(); request.setMessageFavorite = .init()
        request.setMessageFavorite.operationID = command.operationID.rawValue; request.setMessageFavorite.roomID = command.roomID.rawValue; request.setMessageFavorite.messageID = command.messageID.rawValue; request.setMessageFavorite.isFavorited = command.isFavorited
        request.setMessageFavorite.expectedRevision = command.expectedRevision.rawValue
        request.setMessageFavorite.firstSubmissionDeadlineMs = command.firstSubmissionDeadlineMilliseconds
        let response = try await requestEnvelope(request)
        guard case .personalPreferenceReceipt(let value)? = response.body else { try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse }
        let receipt = try V2PersonalPreferenceReceiptCodec.decode(value)
        guard receipt.identity == (try command.identity(actorUserID: receipt.identity.accountID)),
              receipt.fingerprint == (try command.fingerprint(actorUserID: receipt.identity.accountID)) else { throw V2RealtimeTransportError.unexpectedResponse }
        if case .committed(.messageFavorite(let favorite)) = receipt.outcome {
            guard favorite.isFavorited == command.isFavorited, favorite.revision.rawValue > 0,
                  favorite.revision.rawValue - 1 == command.expectedRevision.rawValue else { throw V2RealtimeTransportError.unexpectedResponse }
        }
        return receipt
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


    /// 设置账户的用户添加权限并要求服务器回显相同设置。
    ///
    /// - Parameters:
    ///   - operationID: 重试间保持稳定的偏好操作身份。
    ///   - permission: 允许或拒绝。
    /// - Returns: 服务器更新时间，由协议毫秒转换，不在此检查非负。
    /// - Throws: 未知权限枚举、响应权限与请求不符，以及服务端或传输错误。
    ///
    /// 此方法不持久化本地偏好，调用者应结合服务器结果和同步状态更新界面。


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


    /// 读取服务器当前在线及输入指示偏好，要求响应类型匹配且更新时间非负；不在此持久化缓存。
    public func setPresencePublicationMode(_ mode:V2PresencePublicationMode) async throws {
        var request=IMV2Envelope();request.presencePublicationControl = .init()
        request.presencePublicationControl.mode = mode == .suppressed ? .suppressed:.allowWhenAuthorized
        let response=try await requestEnvelope(request)
        guard case .presencePublicationControlled(let echo)?=response.body,echo.mode==request.presencePublicationControl.mode else {
            try throwServerErrorIfPresent(response);throw V2RealtimeTransportError.unexpectedResponse
        }
    }

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



    /// 分配非零请求号、写入协商版本并执行一轮帧请求。
    ///
    /// 编码与解码使用适配器默认预算，未在此传入压缩协商；响应必须匹配本次请求号和协议版本。
    /// 计数器回绕跳过零，但不在此扫描仍在途的历史编号。返回的业务错误 envelope 由各命令方法另行映射。
    func requestEnvelope(_ envelope: IMV2Envelope,
                         maximumMessageSendPayloadBytes: Int = V2MessageSendWireLimits.maximumPayloadBytes) async throws -> IMV2Envelope {
        var outbound = envelope
        let requestID = nextRequestID
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }
        outbound.requestID = requestID
        let activeVersion = await wire.negotiatedProtocolVersion() ?? protocolVersion
        outbound.protocolVersion = UInt32(activeVersion)
        let response = try await wire.request(try V2ProtobufFrameCodec.encode(outbound, frameVersion: activeVersion,
            maximumMessageSendUncompressedPayloadBytes: maximumMessageSendPayloadBytes))
        let decoded = try V2ProtobufFrameCodec.decode(response,
            maximumMessageSendUncompressedPayloadBytes: maximumMessageSendPayloadBytes)
        guard decoded.requestID == requestID, decoded.protocolVersion == UInt32(activeVersion), response.version == activeVersion else { throw V2RealtimeTransportError.unexpectedResponse }
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
