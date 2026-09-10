import Foundation
import IMV2Core

/// 客户端已读回执的持久化发件箱条目。
public struct V2PendingReadReceipt: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID; public let operationID: ReadReceiptOperationID; public let readThroughRoomSequence: UInt64
    public let state: State; public let attemptCount: Int; public let nextAttemptAt: Date
    public let resultingRoomSequence: UInt64?; public let terminalCode: String?
}
/// 本地已读回执存储能力。
public protocol V2LocalReadReceiptStore: Sendable {
    /// 直接入队一条回执命令。
    ///
    /// - Parameter command: 待入队命令。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingReadReceipt) async throws

    /// 仅当该回执推进房间的本地持久化水位时才原子入队。
    ///
    /// 处于重试中的回执同样计入水位，因此离线尝试或重启之后重新打开房间
    /// 不会产生重复的查看操作。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队时为 `true`；已存在不旧于它的记录时返回 `false`。
    /// - Throws: 持久化失败时抛出。
    func enqueueIfReadReceiptAdvances(_ command: V2PendingReadReceipt) async throws -> Bool

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyReadReceipt(now: Date) async throws -> V2PendingReadReceipt?

    /// 标记回执已被确认并记录结果序号。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - roomSequence: 服务端返回的房间序号。
    /// - Throws: 持久化失败时抛出。
    func markReadReceiptAcknowledged(operationID: ReadReceiptOperationID, roomSequence: UInt64) async throws

    /// 安排回执稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleReadReceiptRetry(operationID: ReadReceiptOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝回执。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectReadReceipt(operationID: ReadReceiptOperationID, code: String) async throws
}

/// 单次已读回执刷新的结果。
public enum V2ReadReceiptFlushResult: Equatable, Sendable { case idle, acknowledged(ReadReceiptOperationID), retryScheduled(ReadReceiptOperationID), rejected(ReadReceiptOperationID, code: String) }

/// 已读回执发件箱的刷新引擎。
public actor V2ReadReceiptOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2ReadReceiptFlushResult>()

    private let store: any V2LocalReadReceiptStore; private let transport: any V2ClientReadReceiptTransport
    private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    /// 组合存储、传输与重试参数。
    ///
    /// - Parameters:
    ///   - store: 本地发件箱存储。
    ///   - transport: 与服务端交互的传输实现。
    ///   - makeUUID: 操作标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    ///   - retryDelay: 默认重试延迟秒数，需大于零，默认 1 秒。
    public init(store: any V2LocalReadReceiptStore, transport: any V2ClientReadReceiptTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) { precondition(retryDelay > 0); self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay }

    /// 入队一次已读回执。
    ///
    /// 权威库与本地 SQLite 的列都是有符号 `BIGINT`，而 protobuf 允许 `uint64`，
    /// 因此这里在客户端边界直接拒绝无法持久化的取值，避免转换 `Int64` 时崩溃。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - readThroughRoomSequence: 已读到的房间序号，需为正且不超过 `Int64` 上限。
    /// - Returns: 入队后的条目。
    /// - Throws: 序号越界时抛出 ``V2ClientCommandError/commandConflict``；
    ///   其余失败来自存储。
    public func enqueueReceipt(roomID: RoomID, readThroughRoomSequence: UInt64) async throws -> V2PendingReadReceipt {
        // The authoritative PostgreSQL and local SQLite columns are signed
        // BIGINT. Protobuf permits uint64, so reject an unpersistable value at
        // the client boundary instead of trapping during Int64 conversion.
        guard readThroughRoomSequence > 0, readThroughRoomSequence <= UInt64(Int64.max) else {
            throw V2ClientCommandError.commandConflict
        }
        let command = try V2PendingReadReceipt(roomID: roomID, operationID: .init(makeUUID().uuidString), readThroughRoomSequence: readThroughRoomSequence, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(command); return command
    }

    /// 仅在推进水位时入队已读回执。
    ///
    /// 若该房间已持久化排队或确认了相同或更新的回执，则返回 `nil`。
    /// 比较与插入共享同一次本地 SQLite 写事务，使并发的界面刷新不会产生重复的查看操作。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - readThroughRoomSequence: 已读到的房间序号，需为正且不超过 `Int64` 上限。
    /// - Returns: 实际入队的条目；无需推进时返回 `nil`。
    /// - Throws: 序号越界时抛出 ``V2ClientCommandError/commandConflict``；
    ///   其余失败来自存储。
    public func enqueueReceiptIfAdvancing(roomID: RoomID, readThroughRoomSequence: UInt64) async throws -> V2PendingReadReceipt? {
        guard readThroughRoomSequence > 0, readThroughRoomSequence <= UInt64(Int64.max) else {
            throw V2ClientCommandError.commandConflict
        }
        let command = try V2PendingReadReceipt(
            roomID: roomID,
            operationID: .init(makeUUID().uuidString),
            readThroughRoomSequence: readThroughRoomSequence,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: now(),
            resultingRoomSequence: nil,
            terminalCode: nil
        )
        return try await store.enqueueIfReadReceiptAdvances(command) ? command : nil
    }
    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2ReadReceiptFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 推进下一条已就绪命令。
    ///
    /// 服务端返回的房间必须一致，且已读序号不得小于本次提交值、也不得超出 `Int64` 上限。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2ReadReceiptFlushResult {
        guard let command = try await store.nextReadyReadReceipt(now: now()) else { return .idle }
        do {
            let result = try await transport.recordReadReceipt(roomID: command.roomID, operationID: command.operationID, readThroughRoomSequence: command.readThroughRoomSequence)
            try Task.checkCancellation()
            guard result.roomID == command.roomID,
                  result.readThroughRoomSequence >= command.readThroughRoomSequence,
                  result.readThroughRoomSequence <= UInt64(Int64.max)
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markReadReceiptAcknowledged(operationID: command.operationID, roomSequence: result.readThroughRoomSequence); return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable { try await store.rejectReadReceipt(operationID: command.operationID, code: code); return .rejected(command.operationID, code: code) }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleReadReceiptRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(command.operationID)
        } catch { try await store.scheduleReadReceiptRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(command.operationID) }
    }
}

extension V2ReadReceiptOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
