import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
import IMV2ServerInfrastructure

// Direct-store regression harnesses; public runtime writes use durable Actor operations.

/// 把两条既有的幂等写入路径（打开私聊房间与接受消息）与特殊账号注册表和审计边界协调起来。
///
/// 瞬时失败后的重试可能留下一个空的私聊房间，但绝不会创建第二条客户可见消息：
/// 两条底层操作使用同一个由调用方提供的操作标识。
public struct V2TrustedSpecialAccountMessagingService: Sendable {
    private let store: any V2SpecialAccountMessagingStore
    private let directMessaging: PostgresV2DirectRoomOperationStore
    private let messages: V2SendMessageService
    private let now: @Sendable () -> Date

    /// 组合注册表存储、私聊服务与消息发送服务。
    ///
    /// - Parameters:
    ///   - store: 特殊账号注册表与审计存储。
    ///   - directMessaging: 负责打开私聊房间的服务。
    ///   - messages: 负责接受消息的服务。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        store: any V2SpecialAccountMessagingStore,
        directMessaging: PostgresV2DirectRoomOperationStore,
        messages: V2SendMessageService,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.directMessaging = directMessaging
        self.messages = messages
        self.now = now
    }

    /// 发送一条特殊账号消息。
    ///
    /// 流程为：解析可用账号、以同一操作标识打开或复用私聊房间、校验会话资格、
    /// 接受消息，最后在成功或幂等时记录审计。底层返回的限流、不可用与拒绝结果
    /// 会映射为对应的领域错误，不会留下未审计的成功发送。
    ///
    /// - Parameter request: 已校验的特殊账号消息请求。
    /// - Returns: 底层消息发送结果。
    /// - Throws: 账号不可用时抛出 ``V2SpecialAccountMessagingError/accountUnavailable``；
    ///   操作标识冲突时抛出 ``V2SpecialAccountMessagingError/idempotencyConflict``；
    ///   准入或存储不可用时抛出 ``V2SpecialAccountMessagingError/unavailable``；
    ///   会话资格不通过时抛出 ``V2SpecialAccountMessagingError/deliveryDenied``。
    public func send(_ request: V2TrustedSpecialAccountMessage) async throws -> V2SendMessageOutcome {
        guard let account = try await store.resolveActiveAccount(stableKey: request.stableAccountKey) else {
            throw V2SpecialAccountMessagingError.accountUnavailable
        }
        let command = try V2DirectRoomOperationCommand(actorUserID:account.userID,
            operationID:.init(request.operationID.rawValue),targetUserID:request.customerUserID,
            firstSubmissionDeadlineMilliseconds:request.firstSubmissionDeadlineMilliseconds)
        let opened = try await directMessaging.submit(command,now:now(),deadline:ContinuousClock.now.advanced(by:.seconds(10)))
        let roomID:RoomID
        switch opened {
        case .receipt(let receipt):
            guard receipt.validates(command:command) else { throw V2SpecialAccountMessagingError.unavailable }
            guard case .opened(let room,_) = receipt.outcome else { throw V2SpecialAccountMessagingError.deliveryDenied }
            roomID=room
        case .fingerprintConflict: throw V2SpecialAccountMessagingError.idempotencyConflict
        case .processing,.unresolved,.deferred: throw V2SpecialAccountMessagingError.unavailable
        }
        try await store.authorizeOutbound(account: account, roomID: roomID, customerUserID: request.customerUserID)
        let outcome = try await messages.send(.init(
            roomID: roomID,
            actorUserID: account.userID,
            clientMessageID: request.operationID,
            text: request.text,
            media: request.media,
            mentions: request.mentions,
            entities: request.entities,
            replyTo: request.replyTo
        ))
        switch outcome {
        case .accepted, .idempotent:
            try await store.record(request: request, account: account, roomID: roomID, outcome: outcome, now: now())
        case .idempotencyConflict: throw V2SpecialAccountMessagingError.idempotencyConflict
        case .rateLimited, .unavailable: throw V2SpecialAccountMessagingError.unavailable
        case .denied: throw V2SpecialAccountMessagingError.deliveryDenied
        }
        return outcome
    }
}

import IMV2ServerContracts
import Foundation
import IMV2Core

/// 测试中把已认证发送输入转换为领域命令，并交给单命令存储。
///
/// 本层执行命令构造校验，为一次调用固定时间与标识；房间权限、幂等竞争和原子提交由存储边界负责。
public struct V2SendMessageService: Sendable {
    /// 直接接受单命令的持久化实现。
    private let store: any V2RoomWriteStore
    /// 本服务采用的房间容量配置。
    private let capacityProfile: V2CapacityProfile
    /// 领域命令构造时使用的内容限制。
    private let limits: V2MessageCommandLimits
    /// 为接受请求生成稳定标识的工厂。
    private let idFactory: V2AcceptanceIDFactory
    /// 每次发送读取一次的可注入时间来源。
    private let now: @Sendable () -> Date

    /// 配置发送服务及其可注入依赖。
    ///
    /// - Parameters:
    ///   - store: 单命令持久化边界。
    ///   - capacityProfile: 与房间持久化配置核对的容量策略。
    ///   - limits: 消息命令校验限制。
    ///   - idFactory: 接受标识生成器，默认使用进程共享生产生成器。
    ///   - now: 接受时间来源，每次发送读取一次。
    public init(
        store: any V2RoomWriteStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        idFactory: V2AcceptanceIDFactory = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.limits = limits
        self.idFactory = idFactory
        self.now = now
    }

    /// 校验发送内容，准备不可变写入请求并等待接受结果。
    ///
    /// - Parameter request: 已由传输边缘绑定可信用户身份的发送输入；本方法不验证认证凭证。
    /// - Returns: 新接受、原回执重放、冲突、限流、不可用或私聊策略拒绝结果。
    /// - Throws: 命令校验、标识生成、准入或持久化执行的错误。
    ///
    /// 时间仅读取一次，生成的标识随请求交给存储。
    public func send(_ request: V2AuthenticatedSendMessage) async throws -> V2SendMessageOutcome {
        let command = try V2SendMessageCommand(
            roomID: request.roomID,
            senderUserID: request.actorUserID,
            clientMessageID: request.clientMessageID,
            text: request.text,
            media: request.media,
            mentions: request.mentions,
            entities: request.entities,
            replyTo: request.replyTo,
            limits: limits
        )
        let acceptedAt = now()
        let prepared = V2RoomWriteRequest(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: try idFactory.make(at: acceptedAt),
            now: acceptedAt
        )
        return try await store.accept(
            command: prepared.command,
            capacityProfile: prepared.capacityProfile,
            identifiers: prepared.identifiers,
            now: prepared.now
        )
    }
}

/// 由传输边缘确认 actor 身份后的发送输入。
///
/// 公开协议解码不得直接提供可信 sender。该类型可被进程内代码构造，
/// 因此调用方必须先完成认证，类型名称本身不构成授权证明。
public struct V2AuthenticatedSendMessage: Sendable {
    /// 目标房间标识。
    public let roomID: RoomID
    /// 传输边缘认证所得的发送者身份，不能直接信任客户端载荷。
    public let actorUserID: UserID
    /// 客户端生成并在重试间保持不变的消息操作标识。
    public let clientMessageID: ClientMessageID
    /// 待发送文本，实际限制由领域命令构造检查。
    public let text: String
    /// 有序媒体引用，默认无附件。
    public let media: [V2MediaReference]
    /// 消息提及目标，默认无提及。
    public let mentions: [V2MentionTarget]
    /// 文本实体及其范围，默认无实体。
    public let entities: [V2MessageEntity]
    /// 可选回复目标，由存储进一步检查有效性。
    public let replyTo: V2MessageReplyReference?

    /// 保存已认证发送输入，不在此处执行领域校验或认证。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 边缘认证所得用户。
    ///   - clientMessageID: 重试间稳定的客户端操作标识。
    ///   - text: 消息文本。
    ///   - media: 有序媒体引用。
    ///   - mentions: 提及目标。
    ///   - entities: 文本实体。
    ///   - replyTo: 可选回复目标。
    public init(roomID: RoomID, actorUserID: UserID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
    }
}
