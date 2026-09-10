import Foundation
import IMV2Core

/// 客户端消息编辑的持久化发件箱条目。
public struct V2PendingMessageEdit: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID; public let operationID: MessageEditOperationID; public let messageID: MessageID
    public let expectedMessageRevision: UInt64; public let text: String; public let state: State
    public let attemptCount: Int; public let nextAttemptAt: Date; public let resultingMessageRevision: UInt64?
    public let resultingRoomSequence: UInt64?; public let terminalCode: String?; public let terminalCurrentRevision: UInt64?
}

/// 本地消息编辑发件箱存储能力。
public protocol V2LocalMessageEditStore: Sendable {
    /// 直接入队一条编辑命令。
    ///
    /// - Parameter command: 待入队命令。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingMessageEdit) async throws

    /// 入队命令；同一修订栅栏下的编辑重试保留原操作标识。
    ///
    /// 即使应用重启，同一次编辑的重试仍沿用最初的操作标识。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReusePendingMessageEdit(_ command: V2PendingMessageEdit) async throws -> V2PendingMessageEdit

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyMessageEdit(now: Date) async throws -> V2PendingMessageEdit?

    /// 标记编辑命令已被确认并记录结果修订与序号。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - messageRevision: 服务端返回的消息修订。
    ///   - roomSequence: 服务端返回的房间序号。
    /// - Throws: 持久化失败时抛出。
    func markMessageEditAcknowledged(operationID: MessageEditOperationID, messageRevision: UInt64, roomSequence: UInt64) async throws

    /// 安排编辑命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleMessageEditRetry(operationID: MessageEditOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝编辑命令，并记录服务端给出的当前修订。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    ///   - currentRevision: 服务端给出的当前消息修订。
    /// - Throws: 持久化失败时抛出。
    func rejectMessageEdit(operationID: MessageEditOperationID, code: String, currentRevision: UInt64?) async throws
}

/// 单次编辑命令刷新的结果。
public enum V2MessageEditFlushResult: Equatable, Sendable { case idle, acknowledged(MessageEditOperationID), retryScheduled(MessageEditOperationID), rejected(MessageEditOperationID, code: String) }

/// 消息编辑发件箱的刷新引擎。
public actor V2MessageEditOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2MessageEditFlushResult>()

    private let store: any V2LocalMessageEditStore; private let transport: any V2ClientMessageEditTransport
    private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    /// 组合存储、传输与重试参数。
    ///
    /// - Parameters:
    ///   - store: 本地发件箱存储。
    ///   - transport: 与服务端交互的传输实现。
    ///   - makeUUID: 操作标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    ///   - retryDelay: 默认重试延迟秒数，需大于零，默认 1 秒。
    public init(store: any V2LocalMessageEditStore, transport: any V2ClientMessageEditTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0); self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }
    /// 入队一次消息编辑。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - expectedMessageRevision: 期望的消息修订。
    ///   - text: 编辑后的正文。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 标识构造失败或持久化失败时抛出。
    public func enqueueEdit(roomID: RoomID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) async throws -> V2PendingMessageEdit {
        let command = V2PendingMessageEdit(roomID: roomID, operationID: try .init(makeUUID().uuidString), messageID: messageID, expectedMessageRevision: expectedMessageRevision, text: text, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingMessageRevision: nil, resultingRoomSequence: nil, terminalCode: nil, terminalCurrentRevision: nil)
        return try await store.enqueueOrReusePendingMessageEdit(command)
    }
    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2MessageEditFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 推进下一条已就绪命令。
    ///
    /// 服务端返回的房间、消息与正文必须与本次命令一致，否则视为意外响应；
    /// 不可重试的服务端错误码会连同其当前修订一起落库并终结该命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2MessageEditFlushResult {
        guard let command = try await store.nextReadyMessageEdit(now: now()) else { return .idle }
        do {
            let result = try await transport.editMessage(roomID: command.roomID, operationID: command.operationID, messageID: command.messageID, expectedMessageRevision: command.expectedMessageRevision, text: command.text)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.messageID == command.messageID, result.text == command.text else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMessageEditAcknowledged(operationID: command.operationID, messageRevision: result.messageRevision, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, let currentRevision) = error, !retryable {
                try await store.rejectMessageEdit(operationID: command.operationID, code: code, currentRevision: currentRevision)
                return .rejected(command.operationID, code: code)
            }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleMessageEditRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(command.operationID)
        } catch { try await store.scheduleMessageEditRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(command.operationID) }
    }
}

extension V2MessageEditOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
