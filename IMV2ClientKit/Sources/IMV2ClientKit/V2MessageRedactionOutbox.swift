import Foundation
import IMV2Core

/// 持久化且需认证的审核员命令。
///
/// 原因使用有界的原因码而不是自由文本，因此可以安全地保存在本地。
public struct V2PendingMessageRedaction: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }

    /// 目标房间。
    public let roomID: RoomID
    /// 本次屏蔽的幂等操作标识。
    public let operationID: ModerationOperationID
    /// 目标消息。
    public let messageID: MessageID
    /// 审核原因码。
    public let reasonCode: V2ModerationReasonCode
    /// 当前状态。
    public let state: State
    /// 已尝试次数。
    public let attemptCount: Int
    /// 下次尝试时刻。
    public let nextAttemptAt: Date
    /// 服务端确认后的消息修订。
    public let resultingMessageRevision: UInt64?
    /// 服务端确认后的房间序号。
    public let resultingRoomSequence: UInt64?
    /// 终态错误码。
    public let terminalCode: String?
}

/// 本地消息屏蔽发件箱存储能力。
public protocol V2LocalMessageRedactionStore: Sendable {
    /// 直接入队一条屏蔽命令。
    ///
    /// - Parameter command: 待入队命令。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingMessageRedaction) async throws

    /// 入队命令；等价的待处理审核屏蔽在重试与重启之间保留同一操作标识。
    ///
    /// 这样服务端审计轨迹始终只有一条。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReusePendingMessageRedaction(_ command: V2PendingMessageRedaction) async throws -> V2PendingMessageRedaction

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyMessageRedaction(now: Date) async throws -> V2PendingMessageRedaction?

    /// 标记屏蔽命令已被确认并记录结果修订与序号。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - messageRevision: 服务端返回的消息修订。
    ///   - roomSequence: 服务端返回的房间序号。
    /// - Throws: 持久化失败时抛出。
    func markMessageRedactionAcknowledged(operationID: ModerationOperationID, messageRevision: UInt64, roomSequence: UInt64) async throws

    /// 安排屏蔽命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleMessageRedactionRetry(operationID: ModerationOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝屏蔽命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectMessageRedaction(operationID: ModerationOperationID, code: String) async throws
}

/// 单次屏蔽命令刷新的结果。
public enum V2MessageRedactionFlushResult: Equatable, Sendable {
    /// 当前无需推进。
    case idle
    /// 已被服务端确认。
    case acknowledged(ModerationOperationID)
    /// 已安排重试。
    case retryScheduled(ModerationOperationID)
    /// 已被终态拒绝，附带错误码。
    case rejected(ModerationOperationID, code: String)
}

/// 消息屏蔽发件箱引擎。
///
/// 审核屏蔽与其它所有可变客户端操作遵循同一套离线优先命令规则：
/// 重试时绝不重新生成操作标识，因此服务端审计记录始终唯一。
public actor V2MessageRedactionOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2MessageRedactionFlushResult>()

    private let store: any V2LocalMessageRedactionStore
    private let transport: any V2ClientMessageRedactionTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    /// 组合存储、传输与重试参数。
    ///
    /// - Parameters:
    ///   - store: 本地发件箱存储。
    ///   - transport: 与服务端交互的传输实现。
    ///   - makeUUID: 操作标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    ///   - retryDelay: 默认重试延迟秒数，需大于零，默认 1 秒。
    public init(store: any V2LocalMessageRedactionStore, transport: any V2ClientMessageRedactionTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
        self.retryDelay = retryDelay
    }

    /// 入队一次消息屏蔽。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - reasonCode: 审核原因码。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    @discardableResult
    public func enqueueRedaction(roomID: RoomID, messageID: MessageID, reasonCode: V2ModerationReasonCode) async throws -> V2PendingMessageRedaction {
        let command = try V2PendingMessageRedaction(
            roomID: roomID,
            operationID: .init(makeUUID().uuidString),
            messageID: messageID,
            reasonCode: reasonCode,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: now(),
            resultingMessageRevision: nil,
            resultingRoomSequence: nil,
            terminalCode: nil
        )
        return try await store.enqueueOrReusePendingMessageRedaction(command)
    }

    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2MessageRedactionFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 推进下一条已就绪命令。
    ///
    /// 服务端返回的房间与消息必须一致，且结果修订需大于 1、房间序号需为正，
    /// 以确保屏蔽确实产生了一次新的可见状态。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2MessageRedactionFlushResult {
        guard let command = try await store.nextReadyMessageRedaction(now: now()) else { return .idle }
        do {
            let result = try await transport.redactMessage(roomID: command.roomID, operationID: command.operationID, messageID: command.messageID, reasonCode: command.reasonCode)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.messageID == command.messageID,
                  result.messageRevision > 1, result.roomSequence > 0
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageRedactionAcknowledged(operationID: command.operationID, messageRevision: result.messageRevision, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            switch error {
            case .server(let code, let retryable, let retryAfter, _):
                if retryable {
                    try await store.scheduleMessageRedactionRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: TimeInterval(max(retryAfter, 1))))
                    return .retryScheduled(command.operationID)
                }
                try await store.rejectMessageRedaction(operationID: command.operationID, code: code)
                return .rejected(command.operationID, code: code)
            default:
                try await store.scheduleMessageRedactionRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
                return .retryScheduled(command.operationID)
            }
        } catch {
            try await store.scheduleMessageRedactionRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}

extension V2MessageRedactionOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
