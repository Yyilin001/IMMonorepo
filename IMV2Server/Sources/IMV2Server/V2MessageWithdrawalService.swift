import Foundation
import IMV2Core

/// 通过认证的消息撤回请求。
public struct V2AuthenticatedMessageWithdrawal: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 发起撤回的用户。
    public let actorUserID: UserID
    /// 本次撤回的幂等操作标识。
    public let operationID: MessageWithdrawalOperationID
    /// 需要撤回的消息。
    public let messageID: MessageID
    /// 客户端观察到的消息修订，用于防止撤回他人在此期间的编辑结果。
    public let expectedMessageRevision: UInt64

    /// 保存已认证的撤回请求。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起撤回的用户。
    ///   - operationID: 幂等操作标识。
    ///   - messageID: 需要撤回的消息。
    ///   - expectedMessageRevision: 期望的消息修订。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
    }
}

/// 消息撤回的执行结果。
public enum V2MessageWithdrawalOutcome: Equatable, Sendable {
    /// 本次调用实际提交了撤回。
    case withdrawn(V2MessageWithdrawal)
    /// 同一操作标识已撤回该消息，返回其原有结果。
    case idempotent(V2MessageWithdrawal)
    /// 同一操作标识已被不同载荷的命令占用。
    case idempotencyConflict
    /// 消息修订与期望值不符，参数为当前修订。
    case revisionConflict(current: UInt64)
    /// 消息此前已被撤回。
    case alreadyWithdrawn
    /// 被限流，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 准入当前不可用，附带不可用原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
}

/// 消息撤回的持久化能力。
///
/// 行锁、授权、准入预留、消息墓碑、事件与发件箱创建以及持久化操作重放，
/// 全部由存储在同一个房间分片事务内完成，调用方不能把它们拆到多个事务。
public protocol V2MessageWithdrawalStore: Sendable {
    /// 执行一次消息撤回。
    ///
    /// - Parameters:
    ///   - command: 撤回命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 撤回结果。
    /// - Throws: 房间或消息不存在、发起者非作者、持久化失败时抛出。
    func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome
}

/// 撤回命令的事件标识生成器。
public struct V2MessageWithdrawalIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    /// 注入 UUID 来源，默认使用系统实现。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包，测试可注入确定性实现。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    /// 生成一个事件标识。
    ///
    /// - Returns: 本次命令使用的事件标识。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func make() throws -> EventID {
        try .init(makeUUID().uuidString)
    }
}

/// 消息撤回的对外服务，负责补齐标识与授时后转交存储。
public struct V2MessageWithdrawalService: Sendable {
    private let store: any V2MessageWithdrawalStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageWithdrawalIDFactory
    private let now: @Sendable () -> Date

    /// 组合撤回存储与运行参数。
    ///
    /// - Parameters:
    ///   - store: 实际执行撤回的存储实现。
    ///   - capacityProfile: 固定的容量档位。
    ///   - identifiers: 事件标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2MessageWithdrawalStore, capacityProfile: V2CapacityProfile, identifiers: V2MessageWithdrawalIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    /// 撤回一条已认证用户可见的消息。
    ///
    /// - Parameter request: 已认证的撤回请求。
    /// - Returns: 撤回结果；标识与授时由本方法补齐。
    /// - Throws: 标识生成失败，或存储判定无权限、修订冲突、持久化失败时抛出。
    public func withdraw(_ request: V2AuthenticatedMessageWithdrawal) async throws -> V2MessageWithdrawalOutcome {
        let eventID = try identifiers.make()
        return try await store.withdraw(
            command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, expectedMessageRevision: request.expectedMessageRevision),
            capacityProfile: capacityProfile,
            eventID: eventID,
            now: now()
        )
    }
}

/// 消息撤回存储错误。
public enum V2MessageWithdrawalStoreError: Error, Equatable, Sendable {
    /// 房间不存在。
    case roomNotFound
    /// 消息不存在。
    case messageNotFound
    /// 发起者不是消息作者。
    case actorNotAuthor
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
