import Foundation
import IMV2Core

/// 审计级成员移除协议的持久化客户端意图。
///
/// 它与普通成员发件箱分开维护：原因码属于服务端不可变审计记录的一部分，
/// 因此需要独立的语义与存储接口。
public struct V2PendingModeratedMemberRemoval: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let targetUserID: UserID
    public let reasonCode: V2ModerationReasonCode
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let resultingMembershipRevision: UInt64?
    public let resultingRoomSequence: UInt64?
    public let terminalCode: String?
}

/// 本地审计级移除发件箱存储能力。
public protocol V2LocalModeratedMemberRemovalStore: Sendable {
    /// 直接入队一条审计级移除命令。
    ///
    /// - Parameter command: 待入队命令。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingModeratedMemberRemoval) async throws

    /// 入队命令；等价的待处理审计移除在重试与重启之间保留原操作标识。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReusePendingModeratedMemberRemoval(_ command: V2PendingModeratedMemberRemoval) async throws -> V2PendingModeratedMemberRemoval

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyModeratedMemberRemoval(now: Date) async throws -> V2PendingModeratedMemberRemoval?

    /// 标记移除命令已被确认并记录结果修订与序号。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - membershipRevision: 服务端返回的成员修订。
    ///   - roomSequence: 服务端返回的房间序号。
    /// - Throws: 持久化失败时抛出。
    func markModeratedMemberRemovalAcknowledged(operationID: ModerationOperationID, membershipRevision: UInt64, roomSequence: UInt64) async throws

    /// 安排移除命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleModeratedMemberRemovalRetry(operationID: ModerationOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝移除命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectModeratedMemberRemoval(operationID: ModerationOperationID, code: String) async throws
}

/// 单次审计级移除命令刷新的结果。
public enum V2ModeratedMemberRemovalFlushResult: Equatable, Sendable { case idle, acknowledged(ModerationOperationID), retryScheduled(ModerationOperationID), rejected(ModerationOperationID, code: String) }

/// 审计级移除发件箱的刷新引擎。
public actor V2ModeratedMemberRemovalOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2ModeratedMemberRemovalFlushResult>()

    private let store: any V2LocalModeratedMemberRemovalStore
    private let transport: any V2ClientModeratedMemberRemovalTransport
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
    public init(store: any V2LocalModeratedMemberRemovalStore, transport: any V2ClientModeratedMemberRemovalTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    /// 入队一次审计级成员移除。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - targetUserID: 被移除的成员。
    ///   - reasonCode: 审计原因码。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    public func enqueueRemoval(roomID: RoomID, targetUserID: UserID, reasonCode: V2ModerationReasonCode) async throws -> V2PendingModeratedMemberRemoval {
        let command = try V2PendingModeratedMemberRemoval(roomID: roomID, operationID: .init(makeUUID().uuidString), targetUserID: targetUserID, reasonCode: reasonCode, state: .pending, attemptCount: 0, nextAttemptAt: now(), resultingMembershipRevision: nil, resultingRoomSequence: nil, terminalCode: nil)
        return try await store.enqueueOrReusePendingModeratedMemberRemoval(command)
    }

    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2ModeratedMemberRemovalFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 推进下一条已就绪命令。
    ///
    /// 服务端返回的房间与目标用户必须一致，且成员修订与房间序号都必须为正。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2ModeratedMemberRemovalFlushResult {
        guard let command = try await store.nextReadyModeratedMemberRemoval(now: now()) else { return .idle }
        do {
            let result = try await transport.removeMemberByModerator(roomID: command.roomID, operationID: command.operationID, targetUserID: command.targetUserID, reasonCode: command.reasonCode)
            try Task.checkCancellation()
            guard result.roomID == command.roomID, result.targetUserID == command.targetUserID, result.membershipRevision > 0, result.roomSequence > 0 else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markModeratedMemberRemovalAcknowledged(operationID: command.operationID, membershipRevision: result.membershipRevision, roomSequence: result.roomSequence)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, let retryAfter, _) = error {
                if retryable {
                    try await store.scheduleModeratedMemberRemovalRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: TimeInterval(max(retryAfter, 1))))
                    return .retryScheduled(command.operationID)
                }
                try await store.rejectModeratedMemberRemoval(operationID: command.operationID, code: code)
                return .rejected(command.operationID, code: code)
            }
            try await store.scheduleModeratedMemberRemovalRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
            return .retryScheduled(command.operationID)
        } catch {
            try await store.scheduleModeratedMemberRemovalRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}

extension V2ModeratedMemberRemovalOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
