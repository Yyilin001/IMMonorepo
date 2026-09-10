import Foundation
import IMV2Core

/// 面向会话展示状态与消息收藏的持久化用户维度命令。
///
/// 它们刻意不参与消息投递与房间事件排序：两者都属于私有用户投影，
/// 只有在常规用户同步流应用相应投影之后才会对外可见。
public struct V2PendingConversationStateCommand: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    /// 会话状态命令。
    public let command: V2ConversationStateCommand
    /// 当前状态。
    public let state: State
    /// 已尝试次数。
    public let attemptCount: Int
    /// 下次尝试时刻。
    public let nextAttemptAt: Date
    /// 终态错误码。
    public let terminalCode: String?
}

/// 消息收藏命令的持久化发件箱条目。
public struct V2PendingMessageFavoriteCommand: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    /// 消息收藏命令。
    public let command: V2MessageFavoriteCommand
    /// 当前状态。
    public let state: State
    /// 已尝试次数。
    public let attemptCount: Int
    /// 下次尝试时刻。
    public let nextAttemptAt: Date
    /// 终态错误码。
    public let terminalCode: String?
}

/// 本地会话能力发件箱存储能力。
public protocol V2LocalConversationCapabilitiesStore: Sendable {
    /// 入队会话状态命令；等价命令复用原操作标识。
    ///
    /// - Parameter command: 待入队条目。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReuseConversationState(_ command: V2PendingConversationStateCommand) async throws -> V2PendingConversationStateCommand

    /// 取出下一条已到发送时间的会话状态命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyConversationState(now: Date) async throws -> V2PendingConversationStateCommand?

    /// 标记会话状态命令已被确认。
    ///
    /// - Parameter operationID: 操作标识。
    /// - Throws: 持久化失败时抛出。
    func markConversationStateAcknowledged(operationID: ConversationPreferenceOperationID) async throws

    /// 安排会话状态命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleConversationStateRetry(operationID: ConversationPreferenceOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝会话状态命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectConversationState(operationID: ConversationPreferenceOperationID, code: String) async throws

    /// 入队消息收藏命令；等价命令复用原操作标识。
    ///
    /// - Parameter command: 待入队条目。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReuseMessageFavorite(_ command: V2PendingMessageFavoriteCommand) async throws -> V2PendingMessageFavoriteCommand

    /// 取出下一条已到发送时间的收藏命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyMessageFavorite(now: Date) async throws -> V2PendingMessageFavoriteCommand?

    /// 标记收藏命令已被确认。
    ///
    /// - Parameter operationID: 操作标识。
    /// - Throws: 持久化失败时抛出。
    func markMessageFavoriteAcknowledged(operationID: MessageFavoriteOperationID) async throws

    /// 安排收藏命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleMessageFavoriteRetry(operationID: MessageFavoriteOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝收藏命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectMessageFavorite(operationID: MessageFavoriteOperationID, code: String) async throws
}

/// 单次会话能力命令刷新的结果。
public enum V2ConversationCapabilitiesFlushResult: Equatable, Sendable {
    /// 当前无需推进。
    case idle
    /// 会话状态命令已被确认。
    case conversationStateAcknowledged(ConversationPreferenceOperationID)
    /// 收藏命令已被确认。
    case messageFavoriteAcknowledged(MessageFavoriteOperationID)
    /// 会话状态命令已安排重试。
    case conversationStateRetryScheduled(ConversationPreferenceOperationID)
    /// 收藏命令已安排重试。
    case messageFavoriteRetryScheduled(MessageFavoriteOperationID)
    /// 会话状态命令被终态拒绝。
    case conversationStateRejected(ConversationPreferenceOperationID, code: String)
    /// 收藏命令被终态拒绝。
    case messageFavoriteRejected(MessageFavoriteOperationID, code: String)
}

/// 会话能力发件箱引擎。
///
/// 每个调度时间片最多发送一条持久化个人能力命令。状态类命令优先检查，
/// 使归档或免打扰不会排在大批收藏之后；跨功能的整体公平性由运行时统一调度器提供。
public actor V2ConversationCapabilitiesOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2ConversationCapabilitiesFlushResult>()

    private let store: any V2LocalConversationCapabilitiesStore
    private let transport: any V2ClientConversationCapabilitiesTransport
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
    public init(store: any V2LocalConversationCapabilitiesStore, transport: any V2ClientConversationCapabilitiesTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    /// 入队一次会话展示状态变更。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - isPinned: 是否置顶。
    ///   - isArchived: 是否归档。
    ///   - muteUntil: 免打扰到期时刻；为空表示未设置。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    public func enqueueConversationState(roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?) async throws -> V2PendingConversationStateCommand {
        let command = try V2ConversationStateCommand(operationID: .init(makeUUID().uuidString), roomID: roomID, isPinned: isPinned, isArchived: isArchived, muteUntil: muteUntil)
        return try await store.enqueueOrReuseConversationState(.init(command: command, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil))
    }

    /// 入队一次消息收藏变更。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - isFavorited: 目标收藏状态。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    public func enqueueMessageFavorite(roomID: RoomID, messageID: MessageID, isFavorited: Bool) async throws -> V2PendingMessageFavoriteCommand {
        let command = try V2MessageFavoriteCommand(operationID: .init(makeUUID().uuidString), roomID: roomID, messageID: messageID, isFavorited: isFavorited)
        return try await store.enqueueOrReuseMessageFavorite(.init(command: command, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil))
    }

    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2ConversationCapabilitiesFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 优先检查会话状态命令，其次才是收藏命令。
    ///
    /// 两类命令共用同一份时间基准，避免同一次刷新中出现时间偏差。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2ConversationCapabilitiesFlushResult {
        let clock = now()
        if let pending = try await store.nextReadyConversationState(now: clock) {
            return try await flush(pending)
        }
        if let pending = try await store.nextReadyMessageFavorite(now: clock) {
            return try await flush(pending)
        }
        return .idle
    }

    /// 推进一条会话状态命令。
    ///
    /// 服务端返回的房间、置顶、归档与免打扰取值必须与本次命令完全一致。
    ///
    /// - Parameter pending: 待推进条目。
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flush(_ pending: V2PendingConversationStateCommand) async throws -> V2ConversationCapabilitiesFlushResult {
        do {
            let result = try await transport.setConversationState(command: pending.command)
            try Task.checkCancellation()
            guard result.roomID == pending.command.roomID, result.isPinned == pending.command.isPinned, result.isArchived == pending.command.isArchived, result.muteUntil == pending.command.muteUntil else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markConversationStateAcknowledged(operationID: pending.command.operationID)
            return .conversationStateAcknowledged(pending.command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let code = nonRetryableCode(error) {
                try await store.rejectConversationState(operationID: pending.command.operationID, code: code)
                return .conversationStateRejected(pending.command.operationID, code: code)
            }
            try await store.scheduleConversationStateRetry(operationID: pending.command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay(for: error)))
            return .conversationStateRetryScheduled(pending.command.operationID)
        }
    }

    /// 推进一条收藏命令。
    ///
    /// 服务端返回的房间、消息与收藏状态必须与本次命令完全一致。
    ///
    /// - Parameter pending: 待推进条目。
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flush(_ pending: V2PendingMessageFavoriteCommand) async throws -> V2ConversationCapabilitiesFlushResult {
        do {
            let result = try await transport.setMessageFavorite(command: pending.command)
            try Task.checkCancellation()
            guard result.roomID == pending.command.roomID, result.messageID == pending.command.messageID, result.isFavorited == pending.command.isFavorited else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageFavoriteAcknowledged(operationID: pending.command.operationID)
            return .messageFavoriteAcknowledged(pending.command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let code = nonRetryableCode(error) {
                try await store.rejectMessageFavorite(operationID: pending.command.operationID, code: code)
                return .messageFavoriteRejected(pending.command.operationID, code: code)
            }
            try await store.scheduleMessageFavoriteRetry(operationID: pending.command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay(for: error)))
            return .messageFavoriteRetryScheduled(pending.command.operationID)
        }
    }

    /// 判断错误是否为不可重试的服务端错误码。
    ///
    /// - Parameter error: 待判断错误。
    /// - Returns: 不可重试时返回其错误码，否则返回 `nil`。
    private func nonRetryableCode(_ error: Error) -> String? {
        guard case let V2RealtimeTransportError.server(code, retryable, _, _) = error, !retryable else { return nil }
        return code
    }

    /// 计算本次失败的重试延迟。
    ///
    /// 服务端给出建议等待时间时取其与 1 秒中的较大值，否则使用配置的默认延迟。
    ///
    /// - Parameter error: 失败原因。
    /// - Returns: 重试延迟秒数。
    private func retryDelay(for error: Error) -> TimeInterval {
        if case let V2RealtimeTransportError.server(_, _, retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }
        return retryDelay
    }
}

extension V2ConversationCapabilitiesOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
