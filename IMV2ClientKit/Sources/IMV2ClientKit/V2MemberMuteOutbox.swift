import Foundation
import IMV2Core

/// 客户端成员禁言的持久化发件箱条目。
public struct V2PendingMemberMute: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let targetUserID: UserID
    public let muteUntil: Date
    public let reasonCode: V2ModerationReasonCode
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
}

/// 本地成员禁言发件箱存储能力。
public protocol V2LocalMemberMuteStore: Sendable {
    /// 直接入队一条禁言命令。
    ///
    /// - Parameter command: 待入队命令。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingMemberMute) async throws

    /// 入队命令；等价的待处理禁言在应用重启之间保留同一操作标识。
    ///
    /// 到期时间或原因码发生变化时视为不同的动作。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReusePendingMemberMute(_ command: V2PendingMemberMute) async throws -> V2PendingMemberMute

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyMemberMute(now: Date) async throws -> V2PendingMemberMute?

    /// 标记禁言命令已被确认并记录结果序号。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - roomSequence: 服务端返回的房间序号。
    /// - Throws: 持久化失败时抛出。
    func markMemberMuteAcknowledged(operationID: ModerationOperationID, roomSequence: UInt64) async throws

    /// 安排禁言命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleMemberMuteRetry(operationID: ModerationOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝禁言命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectMemberMute(operationID: ModerationOperationID, code: String) async throws
}

/// 单次成员禁言命令刷新的结果。
public enum V2MemberMuteFlushResult: Equatable, Sendable { case idle, acknowledged(ModerationOperationID), retryScheduled(ModerationOperationID), rejected(ModerationOperationID, code: String) }

/// 成员禁言发件箱的刷新引擎。
public actor V2MemberMuteOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2MemberMuteFlushResult>()

    private let store: any V2LocalMemberMuteStore
    private let transport: any V2ClientMemberMuteTransport
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
    public init(store: any V2LocalMemberMuteStore, transport: any V2ClientMemberMuteTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0); self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    /// 入队一次成员禁言。
    ///
    /// 线路协议以毫秒承载到期时间，因此这里也持久化规范化到毫秒的取值；
    /// 否则亚毫秒精度的 `Date` 永远无法与服务端确认结果精确相等。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - targetUserID: 被禁言的成员。
    ///   - muteUntil: 禁言到期时刻，需晚于当前时刻且可规范化为毫秒。
    ///   - reasonCode: 审核原因码。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 到期时间不可表示或不晚于当前时刻时抛出
    ///   ``V2ModerationValidationError/invalidMuteExpiry``；其余失败来自持久化。
    public func enqueueMute(roomID: RoomID, targetUserID: UserID, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2PendingMemberMute {
        // The wire protocol carries milliseconds. Persist the canonical value
        // too, otherwise a sub-millisecond Date can never exactly match the
        // acknowledgement returned by the server.
        guard let milliseconds = Int64(exactly: (muteUntil.timeIntervalSince1970 * 1_000).rounded(.towardZero)) else {
            throw V2ModerationValidationError.invalidMuteExpiry
        }
        let normalizedMuteUntil = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        let commandTime = now()
        guard normalizedMuteUntil > commandTime else { throw V2ModerationValidationError.invalidMuteExpiry }
        let command = try V2PendingMemberMute(roomID: roomID, operationID: .init(makeUUID().uuidString), targetUserID: targetUserID, muteUntil: normalizedMuteUntil, reasonCode: reasonCode, state: .pending, attemptCount: 0, nextAttemptAt: commandTime, resultingRoomSequence: nil, terminalCode: nil)
        return try await store.enqueueOrReusePendingMemberMute(command)
    }

    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2MemberMuteFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 推进下一条已就绪命令。
    ///
    /// 已过期的禁言会直接以 `MUTE_EXPIRED` 终结而不发送；服务端返回的房间、目标成员与
    /// 到期时刻都必须与本次命令完全一致。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2MemberMuteFlushResult {
        guard let command = try await store.nextReadyMemberMute(now: now()) else { return .idle }
        guard command.muteUntil > now() else {
            try await store.rejectMemberMute(operationID: command.operationID, code: "MUTE_EXPIRED")
            return .rejected(command.operationID, code: "MUTE_EXPIRED")
        }
        do {
            let result = try await transport.muteMember(roomID: command.roomID, operationID: command.operationID, targetUserID: command.targetUserID, muteUntil: command.muteUntil, reasonCode: command.reasonCode)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.targetUserID == command.targetUserID, result.muteUntil == command.muteUntil, result.roomSequence > 0 else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMemberMuteAcknowledged(operationID: command.operationID, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, let retryAfter, _) = error {
                if retryable { try await store.scheduleMemberMuteRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: TimeInterval(max(retryAfter, 1)))); return .retryScheduled(command.operationID) }
                try await store.rejectMemberMute(operationID: command.operationID, code: code); return .rejected(command.operationID, code: code)
            }
            try await store.scheduleMemberMuteRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(command.operationID)
        } catch {
            try await store.scheduleMemberMuteRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(command.operationID)
        }
    }
}

extension V2MemberMuteOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
