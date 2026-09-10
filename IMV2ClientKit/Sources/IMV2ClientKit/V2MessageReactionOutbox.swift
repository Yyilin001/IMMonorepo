import Foundation
import IMV2Core

/// 客户端表情变更的持久化发件箱条目。
public struct V2PendingMessageReaction: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID; public let operationID: MessageReactionOperationID; public let messageID: MessageID
    public let reaction: String; public let action: V2MessageReactionAction; public let state: State
    public let attemptCount: Int; public let nextAttemptAt: Date; public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
}

/// 本地表情发件箱存储能力。
public protocol V2LocalMessageReactionStore: Sendable {
    /// 直接入队一条表情命令。
    ///
    /// - Parameter command: 待入队命令。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingMessageReaction) async throws

    /// 入队命令；相同待处理变更复用原有操作标识。
    ///
    /// 完全相同的待处理表情变更会在重试与重启之间保留其操作标识；
    /// 动作不同则视为新的意图。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReusePendingMessageReaction(_ command: V2PendingMessageReaction) async throws -> V2PendingMessageReaction

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyMessageReaction(now: Date) async throws -> V2PendingMessageReaction?

    /// 标记表情命令已被确认并记录结果序号。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - roomSequence: 服务端返回的房间序号。
    /// - Throws: 持久化失败时抛出。
    func markMessageReactionAcknowledged(operationID: MessageReactionOperationID, roomSequence: UInt64) async throws

    /// 安排表情命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleMessageReactionRetry(operationID: MessageReactionOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝表情命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectMessageReaction(operationID: MessageReactionOperationID, code: String) async throws
}

/// 单次表情命令刷新的结果。
public enum V2MessageReactionFlushResult: Equatable, Sendable { case idle, acknowledged(MessageReactionOperationID), retryScheduled(MessageReactionOperationID), rejected(MessageReactionOperationID, code: String) }

/// 表情发件箱的刷新引擎。
public actor V2MessageReactionOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2MessageReactionFlushResult>()

    private let store: any V2LocalMessageReactionStore; private let transport: any V2ClientMessageReactionTransport
    private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    /// 组合存储、传输与重试参数。
    ///
    /// - Parameters:
    ///   - store: 本地发件箱存储。
    ///   - transport: 与服务端交互的传输实现。
    ///   - makeUUID: 操作标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    ///   - retryDelay: 默认重试延迟秒数，默认 1 秒。
    public init(store: any V2LocalMessageReactionStore, transport: any V2ClientMessageReactionTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) { self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay }

    /// 入队一次表情变更。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - reaction: 表情内容。
    ///   - action: 新增或移除。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    public func enqueueReaction(roomID: RoomID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) async throws -> V2PendingMessageReaction {
        let command = try V2PendingMessageReaction(roomID: roomID, operationID: .init(makeUUID().uuidString), messageID: messageID, reaction: reaction, action: action, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingRoomSequence: nil, terminalCode: nil)
        return try await store.enqueueOrReusePendingMessageReaction(command)
    }
    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2MessageReactionFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 推进下一条已就绪命令。
    ///
    /// 服务端返回的房间、消息、表情与动作必须与本次命令完全一致，否则视为意外响应；
    /// 不可重试的服务端错误码会直接终结该命令，其余错误安排退避重试。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2MessageReactionFlushResult {
        guard let command = try await store.nextReadyMessageReaction(now: now()) else { return .idle }
        do {
            let result = try await transport.changeMessageReaction(roomID: command.roomID, operationID: command.operationID, messageID: command.messageID, reaction: command.reaction, action: command.action)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.messageID == command.messageID, result.reaction == command.reaction, result.action == command.action else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageReactionAcknowledged(operationID: command.operationID, roomSequence: result.roomSequence); return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable { try await store.rejectMessageReaction(operationID: command.operationID, code: code); return .rejected(command.operationID, code: code) }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleMessageReactionRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(command.operationID)
        } catch { try await store.scheduleMessageReactionRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(command.operationID) }
    }
}

extension V2MessageReactionOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
