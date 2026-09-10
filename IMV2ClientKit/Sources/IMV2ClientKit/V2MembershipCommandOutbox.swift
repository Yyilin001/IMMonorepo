import Foundation
import IMV2Core

/// 持久化的非消息类命令。
///
/// 其操作标识在记录意图时生成一次，此后一直复用，直到服务端给出终态结果。
public struct V2PendingMembershipCommand: Equatable, Sendable {
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }

    /// 目标房间。
    public let roomID: RoomID
    /// 本次变更的幂等操作标识。
    public let operationID: MembershipOperationID
    /// 变更目标用户。
    public let targetUserID: UserID
    /// 需要执行的动作。
    public let action: V2RoomMembershipAction
    /// 期望的成员修订。
    public let expectedMembershipRevision: UInt64
    /// 当前状态。
    public let state: State
    /// 已尝试次数。
    public let attemptCount: Int
    /// 下次尝试时刻。
    public let nextAttemptAt: Date
    /// 服务端确认后的成员修订。
    public let resultingMembershipRevision: UInt64?
    /// 服务端确认后的房间序号。
    public let resultingRoomSequence: UInt64?
    /// 终态错误码。
    public let terminalCode: String?
    /// 终态时服务端给出的当前成员修订。
    public let terminalCurrentRevision: UInt64?

    /// 保存待处理成员命令。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - operationID: 幂等操作标识。
    ///   - targetUserID: 变更目标用户。
    ///   - action: 需要执行的动作。
    ///   - expectedMembershipRevision: 期望的成员修订。
    ///   - state: 当前状态。
    ///   - attemptCount: 已尝试次数。
    ///   - nextAttemptAt: 下次尝试时刻。
    ///   - resultingMembershipRevision: 确认后的成员修订。
    ///   - resultingRoomSequence: 确认后的房间序号。
    ///   - terminalCode: 终态错误码。
    ///   - terminalCurrentRevision: 终态时的当前成员修订。
    public init(
        roomID: RoomID,
        operationID: MembershipOperationID,
        targetUserID: UserID,
        action: V2RoomMembershipAction,
        expectedMembershipRevision: UInt64,
        state: State,
        attemptCount: Int,
        nextAttemptAt: Date,
        resultingMembershipRevision: UInt64?,
        resultingRoomSequence: UInt64?,
        terminalCode: String?,
        terminalCurrentRevision: UInt64?
    ) {
        self.roomID = roomID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
        self.expectedMembershipRevision = expectedMembershipRevision
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.resultingMembershipRevision = resultingMembershipRevision
        self.resultingRoomSequence = resultingRoomSequence
        self.terminalCode = terminalCode
        self.terminalCurrentRevision = terminalCurrentRevision
    }
}

/// 本地成员命令发件箱存储能力。
public protocol V2LocalMembershipCommandStore: Sendable {
    /// 直接入队一条成员命令。
    ///
    /// - Parameter command: 待入队命令。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingMembershipCommand) async throws

    /// 入队命令；同一目标、动作与修订的重试必须保留原操作标识。
    ///
    /// 本地存储会让这一复用跨应用重启保持原子。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReusePendingMembershipCommand(_ command: V2PendingMembershipCommand) async throws -> V2PendingMembershipCommand

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyMembershipCommand(now: Date) async throws -> V2PendingMembershipCommand?

    /// 标记成员命令已被确认并记录结果修订与序号。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - membershipRevision: 服务端返回的成员修订。
    ///   - roomSequence: 服务端返回的房间序号。
    /// - Throws: 持久化失败时抛出。
    func markMembershipAcknowledged(operationID: MembershipOperationID, membershipRevision: UInt64, roomSequence: UInt64) async throws

    /// 安排成员命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleMembershipRetry(operationID: MembershipOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝成员命令，并记录服务端给出的当前修订。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    ///   - currentRevision: 服务端给出的当前成员修订。
    /// - Throws: 持久化失败时抛出。
    func rejectMembership(operationID: MembershipOperationID, code: String, currentRevision: UInt64?) async throws
}

/// 单次成员命令刷新的结果。
public enum V2MembershipCommandFlushResult: Equatable, Sendable {
    /// 当前无需推进。
    case idle
    /// 已被服务端确认。
    case acknowledged(MembershipOperationID)
    /// 已安排重试。
    case retryScheduled(MembershipOperationID)
    /// 已被终态拒绝，附带错误码。
    case rejected(MembershipOperationID, code: String)
}

/// 成员变更发件箱引擎。
///
/// 成员变更与消息发送相互独立地串行化。修订冲突被判定为终态：
/// 重放同一个陈旧意图不可能变得合法，调用方必须刷新成员状态并显式创建新的操作。
public actor V2MembershipCommandOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2MembershipCommandFlushResult>()

    private let store: any V2LocalMembershipCommandStore
    private let transport: any V2ClientMembershipTransport
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
    public init(
        store: any V2LocalMembershipCommandStore,
        transport: any V2ClientMembershipTransport,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init,
        retryDelay: TimeInterval = 1
    ) {
        precondition(retryDelay > 0)
        self.store = store
        self.transport = transport
        self.makeUUID = makeUUID
        self.now = now
        self.retryDelay = retryDelay
    }

    /// 入队一次成员变更。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - targetUserID: 变更目标用户。
    ///   - action: 需要执行的动作。
    ///   - expectedMembershipRevision: 期望的成员修订。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 命令构造失败或持久化失败时抛出。
    @discardableResult
    public func enqueueMembershipChange(
        roomID: RoomID,
        targetUserID: UserID,
        action: V2RoomMembershipAction,
        expectedMembershipRevision: UInt64
    ) async throws -> V2PendingMembershipCommand {
        let command = try V2PendingMembershipCommand(
            roomID: roomID,
            operationID: .init(makeUUID().uuidString),
            targetUserID: targetUserID,
            action: action,
            expectedMembershipRevision: expectedMembershipRevision,
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: now(),
            resultingMembershipRevision: nil,
            resultingRoomSequence: nil,
            terminalCode: nil,
            terminalCurrentRevision: nil
        )
        return try await store.enqueueOrReusePendingMembershipCommand(command)
    }

    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2MembershipCommandFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 推进下一条已就绪命令。
    ///
    /// 服务端返回的房间、目标用户与动作必须与本次命令一致；不可重试的错误（含修订冲突）
    /// 会连同当前修订一起落库并终结该命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2MembershipCommandFlushResult {
        guard let command = try await store.nextReadyMembershipCommand(now: now()) else { return .idle }
        do {
            let changed = try await transport.changeMembership(
                roomID: command.roomID,
                operationID: command.operationID,
                targetUserID: command.targetUserID,
                action: command.action,
                expectedMembershipRevision: command.expectedMembershipRevision
            )
            try Task.checkCancellation()
            guard changed.roomID == command.roomID,
                  changed.targetUserID == command.targetUserID,
                  changed.action == command.action
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markMembershipAcknowledged(
                operationID: command.operationID,
                membershipRevision: changed.membershipRevision,
                roomSequence: changed.roomSequence
            )
            return .acknowledged(command.operationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            switch error {
            case .server(let code, let retryable, let retryAfter, let currentRevision):
                if retryable {
                    try await store.scheduleMembershipRetry(
                        operationID: command.operationID,
                        nextAttemptAt: try v2CommandRetryDate(now: now(), delay: TimeInterval(max(retryAfter, 1)))
                    )
                    return .retryScheduled(command.operationID)
                }
                try await store.rejectMembership(operationID: command.operationID, code: code, currentRevision: currentRevision)
                return .rejected(command.operationID, code: code)
            default:
                try await store.scheduleMembershipRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
                return .retryScheduled(command.operationID)
            }
        } catch {
            try await store.scheduleMembershipRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}

extension V2MembershipCommandOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
