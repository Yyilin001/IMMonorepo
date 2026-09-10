import Foundation
import IMV2Core

/// 客户端转发命令的持久化发件箱条目。
public struct V2PendingForwardMessagesCommand: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let command: V2ForwardMessagesCommand; public let state: State; public let attemptCount: Int; public let nextAttemptAt: Date; public let terminalCode: String?
}

/// 本地转发发件箱存储能力。
public protocol V2LocalForwardMessagesStore: Sendable {
    /// 入队命令；等价命令复用原操作标识。
    ///
    /// - Parameter pending: 待入队条目。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReuseForwardMessages(_ pending: V2PendingForwardMessagesCommand) async throws -> V2PendingForwardMessagesCommand

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyForwardMessages(now: Date) async throws -> V2PendingForwardMessagesCommand?

    /// 标记转发命令已被确认。
    ///
    /// - Parameter operationID: 操作标识。
    /// - Throws: 持久化失败时抛出。
    func markForwardMessagesAcknowledged(operationID: MessageForwardOperationID) async throws

    /// 安排转发命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleForwardMessagesRetry(operationID: MessageForwardOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝转发命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectForwardMessages(operationID: MessageForwardOperationID, code: String) async throws
}

/// 单次转发命令刷新的结果。
public enum V2ForwardMessagesFlushResult: Equatable, Sendable { case idle, acknowledged(MessageForwardOperationID, [V2ForwardMessageResult]), retryScheduled(MessageForwardOperationID), rejected(MessageForwardOperationID, code: String) }

public actor V2ForwardMessagesOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2ForwardMessagesFlushResult>()

    private let store: any V2LocalForwardMessagesStore; private let transport: any V2ClientForwardMessagesTransport; private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    public init(store: any V2LocalForwardMessagesStore, transport: any V2ClientForwardMessagesTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) { self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay }
    public func enqueue(sources: [V2ForwardMessageReference], targetRoomIDs: [RoomID]) async throws -> V2PendingForwardMessagesCommand { let command = try V2ForwardMessagesCommand(operationID: .init(makeUUID().uuidString), sources: sources, targetRoomIDs: targetRoomIDs); return try await store.enqueueOrReuseForwardMessages(.init(command: command, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }
    public func flushOnce() async throws -> V2ForwardMessagesFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    private func flushNextReadyCommand() async throws -> V2ForwardMessagesFlushResult { guard let pending = try await store.nextReadyForwardMessages(now: now()) else { return .idle }; do { let results = try await transport.forwardMessages(command: pending.command); try Task.checkCancellation(); try await store.markForwardMessagesAcknowledged(operationID: pending.command.operationID); return .acknowledged(pending.command.operationID, results) } catch is CancellationError { throw CancellationError() } catch let error as V2RealtimeTransportError { if case .server(let code, let retryable, _, _) = error, !retryable { try await store.rejectForwardMessages(operationID: pending.command.operationID, code: code); return .rejected(pending.command.operationID, code: code) }; let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }(); try await store.scheduleForwardMessagesRetry(operationID: pending.command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(pending.command.operationID) } catch { try await store.scheduleForwardMessagesRetry(operationID: pending.command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(pending.command.operationID) } }
}

/// 批量转发计划。
///
/// 父计划允许用户转发超过单条线路命令有界载荷的内容。分片按需生成且标识确定，
/// 因此崩溃不会产生重复的服务端转发。
public struct V2ForwardMessagesPlan: Equatable, Sendable, Identifiable {
    /// 计划状态。
    public enum State: String, Equatable, Sendable { case active, completed, cancelled }

    /// 计划标识，等同于父操作标识。
    public let operationID: MessageForwardOperationID
    /// 来源消息数量。
    public let sourceMessageCount: Int
    /// 目标房间数量。
    public let targetRoomCount: Int
    /// 需要执行的转发总条数（来源与目标的笛卡尔积）。
    public let totalForwardCount: Int
    /// 已成功的条数。
    public let succeededCount: Int
    /// 已失败的条数。
    public let failedCount: Int
    /// 计划状态。
    public let state: State
    /// 终态错误码。
    public let terminalCode: String?

    /// 用于列表标识。
    public var id: MessageForwardOperationID { operationID }
}

/// 批量转发计划的持久化能力。
public protocol V2BulkForwardMessagesStore: Sendable {
    /// 入队一个转发计划并持久化来源与目标。
    ///
    /// - Parameters:
    ///   - plan: 计划。
    ///   - sources: 来源消息引用。
    ///   - targetRoomIDs: 目标房间列表。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 实际入队的计划。
    /// - Throws: 持久化失败时抛出。
    func enqueueForwardPlan(_ plan: V2ForwardMessagesPlan, sources: [V2ForwardMessageReference], targetRoomIDs: [RoomID], now: Date) async throws -> V2ForwardMessagesPlan

    /// 取出下一个已就绪的计划分片。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送分片；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyForwardPlanChunk(now: Date) async throws -> V2PendingForwardMessagesCommand?

    /// 标记分片已被确认并累计结果。
    ///
    /// - Parameters:
    ///   - operationID: 分片操作标识。
    ///   - results: 该分片的转发结果。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 计划完成时的计划标识；未完成时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func markForwardPlanChunkAcknowledged(operationID: MessageForwardOperationID, results: [V2ForwardMessageResult], now: Date) async throws -> MessageForwardOperationID?

    /// 安排分片稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 分片操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleForwardPlanChunkRetry(operationID: MessageForwardOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝分片。
    ///
    /// - Parameters:
    ///   - operationID: 分片操作标识。
    ///   - code: 服务端返回的稳定错误码。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 计划终结时的计划标识；仍需继续处理其他分片时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func rejectForwardPlanChunk(operationID: MessageForwardOperationID, code: String, now: Date) async throws -> MessageForwardOperationID?

    /// 取消整个转发计划。
    ///
    /// - Parameters:
    ///   - operationID: 计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 持久化失败时抛出。
    func cancelForwardPlan(operationID: MessageForwardOperationID, now: Date) async throws

    /// 读取指定转发计划。
    ///
    /// - Parameter operationID: 计划标识。
    /// - Returns: 计划；不存在时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func forwardPlan(operationID: MessageForwardOperationID) async throws -> V2ForwardMessagesPlan?
}

/// 单次批量转发分片刷新的结果。
public enum V2BulkForwardMessagesFlushResult: Equatable, Sendable {
    /// 当前无需推进。
    case idle
    /// 某个分片已被确认，附计划与分片标识及结果。
    case chunkAcknowledged(planID: MessageForwardOperationID, operationID: MessageForwardOperationID, results: [V2ForwardMessageResult])
    /// 某分片已安排重试。
    case retryScheduled(MessageForwardOperationID)
    /// 某分片被终态拒绝，附计划与分片标识及错误码。
    case chunkRejected(planID: MessageForwardOperationID, operationID: MessageForwardOperationID, code: String)
}

public actor V2BulkForwardMessagesOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2BulkForwardMessagesFlushResult>()

    public static let sourceMessagesPerChunk = 20

    private let store: any V2BulkForwardMessagesStore
    private let transport: any V2ClientForwardMessagesTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2BulkForwardMessagesStore, transport: any V2ClientForwardMessagesTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
        self.retryDelay = retryDelay
    }

    public func enqueue(sources: [V2ForwardMessageReference], targetRoomIDs: [RoomID]) async throws -> V2ForwardMessagesPlan {
        guard !sources.isEmpty, !targetRoomIDs.isEmpty,
              Set(sources.map(\.messageID)).count == sources.count,
              Set(targetRoomIDs).count == targetRoomIDs.count,
              sources.count <= 10_000,
              targetRoomIDs.count <= 100,
              sources.count <= Int.max / targetRoomIDs.count
        else { throw V2CoreError.invalidPositiveValue }
        let total = sources.count * targetRoomIDs.count
        let plan = V2ForwardMessagesPlan(
            operationID: try .init(makeUUID().uuidString),
            sourceMessageCount: sources.count,
            targetRoomCount: targetRoomIDs.count,
            totalForwardCount: total,
            succeededCount: 0,
            failedCount: 0,
            state: .active,
            terminalCode: nil
        )
        return try await store.enqueueForwardPlan(plan, sources: sources, targetRoomIDs: targetRoomIDs, now: now())
    }

    public func flushOnce() async throws -> V2BulkForwardMessagesFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    private func flushNextReadyCommand() async throws -> V2BulkForwardMessagesFlushResult {
        guard let pending = try await store.nextReadyForwardPlanChunk(now: now()) else { return .idle }
        do {
            let results = try await transport.forwardMessages(command: pending.command)
            try Task.checkCancellation()
            guard let planID = try await store.markForwardPlanChunkAcknowledged(operationID: pending.command.operationID, results: results, now: now()) else {
                throw V2ClientCommandError.commandConflict
            }
            return .chunkAcknowledged(planID: planID, operationID: pending.command.operationID, results: results)
        } catch is CancellationError {
            throw CancellationError()
        } catch is V2ForwardMessageResultValidationError {
            throw V2ClientCommandError.commandConflict
        } catch let error as V2ClientCommandError {
            // Local consistency failures are not network retries. In
            // particular, never reschedule an already completed chunk.
            throw error
        } catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable {
                guard let planID = try await store.rejectForwardPlanChunk(operationID: pending.command.operationID, code: code, now: now()) else {
                    throw V2ClientCommandError.commandConflict
                }
                return .chunkRejected(planID: planID, operationID: pending.command.operationID, code: code)
            }
            let delay: TimeInterval = {
                if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }
                return retryDelay
            }()
            try await store.scheduleForwardPlanChunkRetry(operationID: pending.command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay))
            return .retryScheduled(pending.command.operationID)
        } catch {
            try await store.scheduleForwardPlanChunkRetry(operationID: pending.command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
            return .retryScheduled(pending.command.operationID)
        }
    }

    public func cancel(operationID: MessageForwardOperationID) async throws {
        try await store.cancelForwardPlan(operationID: operationID, now: now())
    }

    public func plan(operationID: MessageForwardOperationID) async throws -> V2ForwardMessagesPlan? {
        try await store.forwardPlan(operationID: operationID)
    }
}

extension V2BulkForwardMessagesOutboxEngine: V2CommandFlushControlling {
    public func suspendCommandFlushing() async { await flushFlight.suspend() }
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}

extension V2ForwardMessagesOutboxEngine: V2CommandFlushControlling {
    public func suspendCommandFlushing() async { await flushFlight.suspend() }
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
