import Foundation

/// 消息正文的 UTF-8 字节预算，以及共享的附件／mention 数量上限。
public struct V2MessageCommandLimits: Equatable, Sendable {
    /// 正文允许的最大 UTF-8 字节数；与字符数、UTF-16 实体偏移不同。
    public let maxUTF8Bytes: Int
    /// 单条消息最多包含 10 个不重复的媒体引用。
    public static let maxMediaAttachments = 10
    /// 单条消息最多包含 20 个不重复的提及目标。
    public static let maxMentions = 20

    /// 构造正文容量限制。
    ///
    /// - Parameter maxUTF8Bytes: 正的字节上限。
    /// - Throws: 非正值抛出 invalidPositiveValue。
    public init(maxUTF8Bytes: Int) throws {
        guard maxUTF8Bytes > 0 else {
            throw V2CoreError.invalidPositiveValue
        }
        self.maxUTF8Bytes = maxUTF8Bytes
    }
}

/// 已通过内容结构检查、并携带原始意图指纹的发送命令。
///
/// 正文可为空，但必须有媒体；附件和 mentions 有数量与去重约束，富文本实体单独验证。
/// 类型不查询当前成员或媒体授权；事务存储负责最终授权和 owner 栅栏。
public struct V2SendMessageCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    /// 由可信业务层选择的受众计数规则，不允许普通客户端自行扩大投递范围。
    public let targetRule: FanoutTargetRule
    /// 服务端构造的新转发来源快照；普通发送协议不直接接受此字段。
    public let forwardedFrom: V2ForwardMessageSource?
    public let fingerprint: V2SendMessageFingerprint

    /// 验证发送内容和集合边界，并预先计算原始意图指纹。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - senderUserID: 可信认证层确定的发送者。
    ///   - clientMessageID: 重试期间不变的客户端操作 ID。
    ///   - text: 保留原始空白与 Unicode 表示的正文。
    ///   - media: 不重复的媒体引用；正文为空时必须非空。
    ///   - mentions: 不重复的提及目标，数量受共享上限约束。
    ///   - entities: 按 UTF-16 偏移描述的已定义富文本实体。
    ///   - replyTo: 可选回复消息引用，历史可见性由存储层另查。
    ///   - targetRule: 可信业务层选择的分发计数规则；精确数量不得为负。
    ///   - forwardedFrom: 新转发的可信源快照，普通发送为 nil。
    ///   - limits: 正文 UTF-8 容量预算。
    /// - Throws: 内容／集合限制、富文本验证或负的精确目标数量错误。
    ///
    /// 构造不会检查房间当前权限、媒体可用状态或数据库 owner；这些检查不能省略。
    public init(
        roomID: RoomID,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference] = [],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        targetRule: FanoutTargetRule = .eligibleMemberCount,
        forwardedFrom: V2ForwardMessageSource? = nil,
        limits: V2MessageCommandLimits
    ) throws {
        let byteCount = text.lengthOfBytes(using: .utf8)
        guard byteCount <= limits.maxUTF8Bytes,
              (byteCount > 0 || !media.isEmpty),
              media.count <= V2MessageCommandLimits.maxMediaAttachments,
              (media.count < 2 || Set(media).count == media.count),
              mentions.count <= V2MessageCommandLimits.maxMentions,
              (mentions.count < 2 || Set(mentions).count == mentions.count)
        else {
            throw V2SendMessageValidationError.invalidTextLength
        }
        try V2RichMessageContent.validate(text: text, entities: entities)
        if case .exactTargetCount(let count) = targetRule, count < 0 {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.roomID = roomID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
        self.targetRule = targetRule
        self.forwardedFrom = forwardedFrom
        self.fingerprint = V2SendMessageFingerprint(
            roomID: roomID, senderUserID: senderUserID,
            clientMessageID: clientMessageID, text: text, media: media,
            mentions: mentions, entities: entities, replyTo: replyTo,
            targetRule: targetRule, forwardedFrom: forwardedFrom
        )
    }
}

/// 历史消息的转发来源展示元数据。
///
/// 不含源 revision，不能作为新转发授权凭据；新转发必须重新验证所选版本。
public struct V2ForwardedMessageAttribution: Equatable, Sendable {
    public let messageID: MessageID
    public let senderUserID: UserID

    /// 组合历史来源展示身份；不查询或授予对源消息的访问权限。
    public init(messageID: MessageID, senderUserID: UserID) {
        self.messageID = messageID
        self.senderUserID = senderUserID
    }
}

/// 新转发所使用的服务端来源快照，包含接受时选定的精确源版本。
public struct V2ForwardMessageSource: Equatable, Sendable {
    public let messageID: MessageID
    public let senderUserID: UserID
    /// 被复制源消息的有效内容版本，参与新转发指纹，避免内容变化后仍重放为同一意图。
    public let sourceRevision: V2MessageRevision

    /// 保存可信来源读取所得的消息、原发送者与版本，供新转发接受使用。
    public init(messageID: MessageID, senderUserID: UserID, sourceRevision: V2MessageRevision) {
        self.messageID = messageID
        self.senderUserID = senderUserID
        self.sourceRevision = sourceRevision
    }
}

/// 发送命令的内容或集合基础约束不满足时的错误。
public enum V2SendMessageValidationError: Error, Equatable, Sendable {
    /// 正文超过预算、正文与媒体同时为空，或附件／mention 的数量和去重检查失败。
    case invalidTextLength
}

/// 发送操作的去重范围，由房间、发送者和客户端命令 ID 共同定义。
public struct V2CommandDeduplicationKey: Hashable, Sendable {
    public let roomID: RoomID
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID

    /// 组合稳定去重键；同一文本使用不同客户端 ID 仍表示不同操作。
    public init(roomID: RoomID, senderUserID: UserID, clientMessageID: ClientMessageID) {
        self.roomID = roomID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
    }
}

/// 纯准入 reducer 产生、尚未补齐权威媒体展示信息的接受草稿。
///
/// 与可外发的 V2AcceptedMessage 分开，避免纯规则层凭空构造附件元数据。
/// 草稿存在不代表 PostgreSQL 已提交，事务成功由存储适配器确认。
public struct V2AcceptedMessageDraft: Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    /// 由普通消息与私有活动条目共享的房间本地展示序号。
    ///
    /// 它刻意独立于 `roomSequence`：已读回执与消息变更继续使用仅含消息的序号，
    /// 不会因系统活动而出现空洞。
    public let timelineSequence: UInt64
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    /// 仅群组房间存在。
    ///
    /// 它是用于非权威前台可用性提示的准入元数据；
    /// 不会改变持久扇出或应答契约。
    public let groupDeliveryMode: V2GroupDeliveryMode?
    /// 当该已接受消息是从房间事件日志而非每用户扇出流中持久恢复时为 `true`。
    ///
    /// 提示本身是尽力而为的；房间游标仍是权威。
    public let usesRoomEventLog: Bool
    public let createdAt: Date

    public init(
        messageID: MessageID,
        roomID: RoomID,
        roomSequence: UInt64,
        timelineSequence: UInt64? = nil,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference] = [],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence ?? roomSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        precondition((try? V2RichMessageContent.validate(text: text, entities: entities)) != nil)
        self.entities = entities
        self.replyTo = replyTo
        self.groupDeliveryMode = groupDeliveryMode
        self.usesRoomEventLog = usesRoomEventLog
        self.createdAt = createdAt
    }

    /// 使用权威存储元数据补齐可序列化的接受结果。
    ///
    /// 媒体展示 ID 必须与原引用按顺序精确一致，否则目标构造器的前置条件失败。
    /// 可选参数使用本方法传入值；默认值不会自动继承草稿的 groupDeliveryMode 或 usesRoomEventLog。
    ///
    /// - Parameters:
    ///   - mediaPresentations: 与 media 数量、顺序和身份完全匹配的展示信息。
    ///   - groupDeliveryMode: 群投递模式元数据，默认 nil。
    ///   - usesRoomEventLog: 是否通过房间事件日志可靠恢复，默认 false。
    ///   - sourceEventID: 存储侧原始事件身份。
    ///   - acceptedMembershipRevision: 提交时成员资格版本栅栏。
    ///   - directRecipientUserID: 同一接受事务锁定的私聊对端。
    ///   - projectionCreatedAtUnixMilliseconds: 数据库精确保存的投影毫秒时间。
    /// - Returns: 补齐媒体与内部恢复元数据的接受结果。
    /// - Important: 仅供已验证的存储边界调用；方法不执行网络授权或数据库提交。
    public func materialized(
        mediaPresentations: [V2MediaPresentation],
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false,
        sourceEventID: EventID? = nil,
        acceptedMembershipRevision: UInt64? = nil,
        directRecipientUserID: UserID? = nil,
        projectionCreatedAtUnixMilliseconds: Int64? = nil
    ) -> V2AcceptedMessage {
        V2AcceptedMessage(
            messageID: messageID,
            roomID: roomID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            senderUserID: senderUserID,
            clientMessageID: clientMessageID,
            text: text,
            media: media,
            mediaPresentations: mediaPresentations,
            mentions: mentions,
            entities: entities,
            replyTo: replyTo,
            groupDeliveryMode: groupDeliveryMode,
            usesRoomEventLog: usesRoomEventLog,
            sourceEventID: sourceEventID,
            acceptedMembershipRevision: acceptedMembershipRevision,
            directRecipientUserID: directRecipientUserID,
            projectionCreatedAtUnixMilliseconds: projectionCreatedAtUnixMilliseconds,
            createdAt: createdAt
        )
    }
}

/// 存储边界补齐展示元数据后的完整消息接受结果。
///
/// 可供序列化和投影，但仍需按调用者权限选择响应字段。媒体身份一致与富文本有效性
/// 由前置条件断言，不宜把未经验证的外部字段直接传给该构造器。
public struct V2AcceptedMessage: Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    /// 参见 ``V2AcceptedMessageDraft/timelineSequence``。
    public let timelineSequence: UInt64
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    /// 按原媒体引用顺序排列的权威展示信息，ID 必须逐项匹配。
    public let mediaPresentations: [V2MediaPresentation]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    /// 仅群组房间存在。
    ///
    /// 它是用于非权威前台可用性提示的准入元数据；
    /// 不会改变持久扇出或应答契约。
    public let groupDeliveryMode: V2GroupDeliveryMode?
    /// 参见 ``V2AcceptedMessageDraft/usesRoomEventLog``。
    public let usesRoomEventLog: Bool
    /// canonical room-log 事件的内部持久身份。
    ///
    /// 用于服务器缓存保留原事件重放身份，不属于发送 ACK 的公开字段。
    public let sourceEventID: EventID?
    /// canonical 事件提交时的成员资格版本；缓存命中仍须对照新授权读者验证此栅栏。
    public let acceptedMembershipRevision: UInt64?
    /// 普通私聊 room-log 接受事务中锁定的对端身份。
    ///
    /// 实时加速器据此选择提交时可见目标，不从之后的订阅或成员查询猜测接收者。
    public let directRecipientUserID: UserID?
    /// 数据库保存的精确投影毫秒值，避免远 epoch 的 Date 往返精度损失。
    ///
    /// 缓存与提示应保留原整数；该字段不属于发送 receipt。
    public let projectionCreatedAtUnixMilliseconds: Int64?
    public let createdAt: Date

    public init(
        messageID: MessageID,
        roomID: RoomID,
        roomSequence: UInt64,
        timelineSequence: UInt64? = nil,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference] = [],
        mediaPresentations: [V2MediaPresentation],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false,
        sourceEventID: EventID? = nil,
        acceptedMembershipRevision: UInt64? = nil,
        directRecipientUserID: UserID? = nil,
        projectionCreatedAtUnixMilliseconds: Int64? = nil,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence ?? roomSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        precondition(mediaPresentations.map(\.mediaID) == media.map(\.mediaID))
        self.mediaPresentations = mediaPresentations
        self.mentions = mentions
        precondition((try? V2RichMessageContent.validate(text: text, entities: entities)) != nil)
        self.entities = entities
        self.replyTo = replyTo
        self.groupDeliveryMode = groupDeliveryMode
        self.usesRoomEventLog = usesRoomEventLog
        self.sourceEventID = sourceEventID
        self.acceptedMembershipRevision = acceptedMembershipRevision
        self.directRecipientUserID = directRecipientUserID
        self.projectionCreatedAtUnixMilliseconds = projectionCreatedAtUnixMilliseconds
        self.createdAt = createdAt
    }
}

/// 准入完成后的分发计划草稿，关联源事件、房间位置与已预留的容量。
public struct V2FanoutPlanDraft: Equatable, Sendable {
    public let id: FanoutPlanID
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let reservation: FanoutAdmissionReservation

    /// 保存首次接受事务准备的分发计划及容量预留。
    ///
    /// - Parameters:
    ///   - id: 同一接受重试期间固定的计划 ID。
    ///   - sourceEventID: 对应原始房间事件。
    ///   - roomID: 事件所属房间。
    ///   - roomSequence: 原消息的房间序号。
    ///   - reservation: 准入评估器返回的容量预留。
    ///
    /// 该值本身不写入队列或扣减数据库容量。
    public init(
        id: FanoutPlanID,
        sourceEventID: EventID,
        roomID: RoomID,
        roomSequence: UInt64,
        reservation: FanoutAdmissionReservation
    ) {
        self.id = id
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.reservation = reservation
    }
}

/// 纯 reducer 返回的完整房间分片接受事务值。
///
/// 存储层须在同一房间事务中按适用合同写入 canonical 消息、去重结果、事件、outbox、
/// 计划及房间／分片准入状态，不能只保存 acceptedMessage 后返回成功。
public struct V2MessageAcceptanceTransaction: Equatable, Sendable {
    public let acceptedMessage: V2AcceptedMessageDraft
    public let eventID: EventID
    public let fanoutPlan: V2FanoutPlanDraft
    /// 提交接受后应持久化的房间序号、准入和去重状态。
    public let nextRoomState: V2RoomCommandState
    /// 接受后扣减容量的分片准入状态，必须与消息一起提交。
    public let nextShardState: ShardAdmissionState

    /// 组合一项需要由存储层原子提交的接受计算结果。
    ///
    /// - Parameters:
    ///   - acceptedMessage: 尚待媒体元数据补齐的消息草稿。
    ///   - eventID: canonical 事件身份。
    ///   - fanoutPlan: 关联分发草稿和容量预留。
    ///   - nextRoomState: 提交后的房间状态。
    ///   - nextShardState: 提交后的分片容量状态。
    public init(
        acceptedMessage: V2AcceptedMessageDraft,
        eventID: EventID,
        fanoutPlan: V2FanoutPlanDraft,
        nextRoomState: V2RoomCommandState,
        nextShardState: ShardAdmissionState
    ) {
        self.acceptedMessage = acceptedMessage
        self.eventID = eventID
        self.fanoutPlan = fanoutPlan
        self.nextRoomState = nextRoomState
        self.nextShardState = nextShardState
    }
}

/// 纯消息 reducer 使用的房间状态快照；不是独立持久化存储。
public struct V2RoomCommandState: Equatable, Sendable {
    public let roomID: RoomID
    /// 下一条首次接受消息使用的房间序号；调用方需保证递增可表示。
    public let nextRoomSequence: UInt64
    public let admission: RoomAdmissionState
    /// 按完整去重键保存的原指纹和接受草稿，用于先于再次准入识别重放。
    public let acceptedCommands: [V2CommandDeduplicationKey: V2AcceptedSendCommand]

    /// 保存由调用方提供的一致房间状态快照。
    ///
    /// - Parameters:
    ///   - roomID: 状态所属房间，必须与传入 reducer 的命令一致。
    ///   - nextRoomSequence: 下一次首次接受将使用的序号，必须可安全递增。
    ///   - admission: 当前房间准入状态。
    ///   - acceptedCommands: 已提交原操作的稳定指纹与接受结果，默认为空。
    ///
    /// 构造只保存值，不读取持久化状态，也不验证序号递增边界。
    public init(
        roomID: RoomID,
        nextRoomSequence: UInt64,
        admission: RoomAdmissionState,
        acceptedCommands: [V2CommandDeduplicationKey: V2AcceptedSendCommand] = [:]
    ) {
        self.roomID = roomID
        self.nextRoomSequence = nextRoomSequence
        self.admission = admission
        self.acceptedCommands = acceptedCommands
    }
}

/// 与原接受结果一同保留的不可变输入指纹。
///
/// 消息编辑或撤回后不能替换此指纹，也不能从当前可变消息行重建它。
public struct V2AcceptedSendCommand: Equatable, Sendable {
    public let fingerprint: V2SendMessageFingerprint
    public let acceptedMessage: V2AcceptedMessageDraft

    /// 组合已经一致的原输入指纹与接受草稿；构造器不重新计算或核对二者来源。
    public init(fingerprint: V2SendMessageFingerprint, acceptedMessage: V2AcceptedMessageDraft) {
        self.fingerprint = fingerprint
        self.acceptedMessage = acceptedMessage
    }
}

/// 一次接受尝试预先生成的消息、事件与分发计划身份。
///
/// 数据库事务重试应复用该组值，避免同一操作生成第二组服务端身份。
public struct V2AcceptanceIdentifiers: Equatable, Sendable {
    public let messageID: MessageID
    public let eventID: EventID
    public let planID: FanoutPlanID

    /// 保存本次接受要使用的稳定标识，不分配数据库序号或预留容量。
    public init(messageID: MessageID, eventID: EventID, planID: FanoutPlanID) {
        self.messageID = messageID
        self.eventID = eventID
        self.planID = planID
    }
}

/// 纯接受计算的结果，区分首次事务、同意图重放、冲突与容量拒绝。
public enum V2SendMessageAcceptanceResult: Equatable, Sendable {
    /// 首次接受的完整待提交事务值，此时尚未发生数据库写入。
    case accepted(V2MessageAcceptanceTransaction)
    /// 同一去重键且指纹一致，复用原接受草稿，不再次预留容量。
    case idempotent(V2AcceptedMessageDraft)
    /// 同一操作身份对应不同输入指纹。
    case idempotencyConflict
    /// 房间准入限流，关联值给出建议等待秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 分发准入当前不可用，携带具体容量原因。
    case unavailable(FanoutAdmissionUnavailableReason)
}

/// 无 I/O 的发送接受计算，先按原指纹判重，再计算准入与后继状态。
public enum V2SendMessageReducer {
    /// 计算原操作重放结果，或一项首次消息接受事务。
    ///
    /// - Parameters:
    ///   - command: 已验证结构并具有稳定指纹的发送命令。
    ///   - roomState: 同房间的当前状态及原操作记录。
    ///   - shardState: 当前分片容量状态。
    ///   - profile: 适用的房间容量策略。
    ///   - identifiers: 同一事务重试期间保持不变的服务端身份。
    ///   - now: 准入计算与首次接受时间。
    /// - Returns: 重放、冲突、限流、不可用或包含完整后继状态的接受事务。
    /// - Throws: 房间身份不匹配，或准入计算错误。
    /// - Important: 不获取数据库锁或检查当前成员权限；调用方负责提供已授权且一致的状态。
    ///   首次接受会对 nextRoomSequence 加一，传入状态必须满足可安全递增的边界。
    public static func reduce(
        command: V2SendMessageCommand,
        roomState: V2RoomCommandState,
        shardState: ShardAdmissionState,
        profile: RoomCapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) throws -> V2SendMessageAcceptanceResult {
        guard roomState.roomID == command.roomID else {
            throw V2SendMessageReducerError.roomMismatch
        }

        let deduplicationKey = V2CommandDeduplicationKey(
            roomID: command.roomID,
            senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID
        )
        if let prior = roomState.acceptedCommands[deduplicationKey] {
            return prior.fingerprint == command.fingerprint
                ? .idempotent(prior.acceptedMessage) : .idempotencyConflict
        }

        let admission = try FanoutAdmissionEvaluator.reserve(
            request: FanoutAdmissionRequest(targetRule: command.targetRule),
            profile: profile,
            roomState: roomState.admission,
            shardState: shardState,
            now: now
        )
        switch admission {
        case .rateLimited(let retryAfterSeconds):
            return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .accepted(let reservation, let reservedRoomAdmission, let reservedShardState):
            let accepted = V2AcceptedMessageDraft(
                messageID: identifiers.messageID,
                roomID: command.roomID,
                roomSequence: roomState.nextRoomSequence,
                senderUserID: command.senderUserID,
                clientMessageID: command.clientMessageID,
                text: command.text,
                media: command.media,
                mentions: command.mentions,
                entities: command.entities,
                replyTo: command.replyTo,
                createdAt: now
            )
            var acceptedCommands = roomState.acceptedCommands
            acceptedCommands[deduplicationKey] = .init(
                fingerprint: command.fingerprint, acceptedMessage: accepted
            )
            let nextRoomState = V2RoomCommandState(
                roomID: roomState.roomID,
                nextRoomSequence: roomState.nextRoomSequence + 1,
                admission: reservedRoomAdmission,
                acceptedCommands: acceptedCommands
            )
            let plan = V2FanoutPlanDraft(
                id: identifiers.planID,
                sourceEventID: identifiers.eventID,
                roomID: command.roomID,
                roomSequence: accepted.roomSequence,
                reservation: reservation
            )
            return .accepted(
                V2MessageAcceptanceTransaction(
                    acceptedMessage: accepted,
                    eventID: identifiers.eventID,
                    fanoutPlan: plan,
                    nextRoomState: nextRoomState,
                    nextShardState: reservedShardState
                )
            )
        }
    }
}

public enum V2SendMessageReducerError: Error, Equatable, Sendable {
    case roomMismatch
}
