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

/// 把已认证发送输入转换为领域命令，并交给准入或存储完成接受。
///
/// 本层执行命令构造校验，为一次调用固定时间与标识；房间权限、幂等竞争和原子提交由存储边界负责。
/// 配置批处理器时走其准入路径，否则直接调用单命令存储。
public struct V2SendMessageService: Sendable {
    /// 直接接受单命令的持久化实现。
    private let store: any V2RoomWriteStore
    /// 可选的有序准入实现。
    private let batcher: (any V2SendMessageAdmission)?
    /// 本服务采用的房间容量配置。
    private let capacityProfile: V2CapacityProfile
    /// 领域命令构造时使用的内容限制。
    private let limits: V2MessageCommandLimits
    /// 为接受请求生成稳定标识的工厂。
    private let idFactory: V2AcceptanceIDFactory
    /// 每次发送读取一次的可注入时间来源。
    private let now: @Sendable () -> Date

    /// 报告批处理器是否管理数据库工作所需的前台写入许可。
    ///
    /// 启用后 Gateway 不应为每个排队消息重复保留许可，避免尚未开始的批次耗尽前台通道。
    var managesForegroundWriteAdmission: Bool {
        batcher?.managesForegroundWriteAdmission ?? false
    }

    /// 配置发送服务及其可注入依赖。
    ///
    /// - Parameters:
    ///   - store: 单命令持久化边界。
    ///   - capacityProfile: 与房间持久化配置核对的容量策略。
    ///   - limits: 消息命令校验限制。
    ///   - idFactory: 接受标识生成器，默认使用进程共享生产生成器。
    ///   - batcher: 可选的有序准入实现；存在时发送通过它执行。
    ///   - now: 接受时间来源，每次发送读取一次。
    public init(
        store: any V2RoomWriteStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        idFactory: V2AcceptanceIDFactory = .init(),
        batcher: (any V2SendMessageAdmission)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.batcher = batcher
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
    /// 时间仅读取一次，生成的标识随请求交给批处理器；同一批次内部重试不得重新生成。
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
        if let batcher {
            return try await batcher.accept(prepared)
        }
        return try await store.accept(
            command: prepared.command,
            capacityProfile: prepared.capacityProfile,
            identifiers: prepared.identifiers,
            now: prepared.now
        )
    }
}

/// 消息持久化之前的进程内准入边界。
///
/// 实现可以使用单个批处理 actor 或按房间稳定分配的多个执行通道，必须保持同一房间的有序写入合同。
public protocol V2SendMessageAdmission: V2SendMessageBatchMetricsReading {
    /// 是否由准入实现围绕实际数据库工作管理前台写入许可，以避免等待批次的请求重复占用许可。
    var managesForegroundWriteAdmission: Bool { get }

    /// 提交不可变写入请求并等待该请求的独立结果。
    ///
    /// - Parameter request: 带固定标识与时间的接受输入。
    /// - Returns: 对应此请求的业务接受结果。
    /// - Throws: 准入、取消或存储执行错误，具体行为由实现定义。
    func accept(
        _ request: consuming V2RoomWriteRequest
    ) async throws -> V2SendMessageOutcome
}
