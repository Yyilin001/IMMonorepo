import Foundation
import IMV2Core

/// 客户端群控制命令的持久化发件箱条目。
///
/// 所有有序群控制变更共用这一条持久化通道。每一行永久持有自己的操作标识，
/// 因此重连后重试的是同一次服务端意图，而不会产生第二个置顶、公告修订或角色变更。
public struct V2PendingGroupCapabilityCommand: Equatable, Sendable {
    /// 命令种类。
    public enum Kind: String, Equatable, Sendable { case pin, announcement, rolePermissions, memberRole }
    /// 命令状态。
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let kind: Kind; public let operationID: String; public let roomID: RoomID
    public let messageID: MessageID?; public let isPinned: Bool?; public let body: String?
    public let role: V2RoomMembershipRole?; public let permissions: Set<V2GroupPermission>; public let targetUserID: UserID?
    public let expectedRevision: UInt64; public let state: State; public let attemptCount: Int; public let nextAttemptAt: Date; public let terminalCode: String?
}

/// 本地群控制发件箱存储能力。
public protocol V2LocalGroupCapabilitiesStore: Sendable {
    /// 入队命令；同一操作标识已存在时复用原条目。
    ///
    /// - Parameter command: 待入队命令。
    /// - Returns: 实际入队或复用的条目。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReuseGroupCapability(_ command: V2PendingGroupCapabilityCommand) async throws -> V2PendingGroupCapabilityCommand

    /// 取出下一条已到发送时间的命令。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待发送命令；没有可发送项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyGroupCapability(now: Date) async throws -> V2PendingGroupCapabilityCommand?

    /// 标记命令已被服务端确认。
    ///
    /// - Parameter operationID: 操作标识。
    /// - Throws: 持久化失败时抛出。
    func markGroupCapabilityAcknowledged(operationID: String) async throws

    /// 安排命令稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleGroupCapabilityRetry(operationID: String, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝命令。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectGroupCapability(operationID: String, code: String) async throws
}

/// 单次群控制命令刷新的结果。
public enum V2GroupCapabilitiesFlushResult: Equatable, Sendable { case idle, acknowledged(String), retryScheduled(String), rejected(String, code: String) }

/// 群控制发件箱的刷新引擎。
///
/// 每次只推进一条命令；可重试的服务端错误与传输错误会安排退避重试，
/// 不可重试的服务端错误码则直接终结该命令。
public actor V2GroupCapabilitiesOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2GroupCapabilitiesFlushResult>()

    private let store: any V2LocalGroupCapabilitiesStore; private let transport: any V2ClientGroupCapabilitiesTransport
    private let makeUUID: @Sendable () -> UUID; private let now: @Sendable () -> Date; private let retryDelay: TimeInterval
    /// 组合存储、传输与重试参数。
    ///
    /// - Parameters:
    ///   - store: 本地发件箱存储。
    ///   - transport: 与服务端交互的传输实现。
    ///   - makeUUID: 操作标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    ///   - retryDelay: 默认重试延迟秒数，默认 1 秒。
    public init(store: any V2LocalGroupCapabilitiesStore, transport: any V2ClientGroupCapabilitiesTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) { self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay }

    /// 入队一次置顶变更。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - isPinned: 目标置顶状态。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 持久化失败时抛出。
    public func enqueuePin(roomID: RoomID, messageID: MessageID, isPinned: Bool) async throws -> V2PendingGroupCapabilityCommand { try await enqueue(.init(kind: .pin, operationID: makeUUID().uuidString, roomID: roomID, messageID: messageID, isPinned: isPinned, body: nil, role: nil, permissions: [], targetUserID: nil, expectedRevision: 0, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }

    /// 入队一次公告变更。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - body: 公告正文。
    ///   - expectedRevision: 期望的当前修订。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 公告命令校验失败或持久化失败时抛出。
    public func enqueueAnnouncement(roomID: RoomID, body: String, expectedRevision: UInt64) async throws -> V2PendingGroupCapabilityCommand { let operationID = makeUUID().uuidString; _ = try V2GroupAnnouncementCommand(operationID: .init(operationID), roomID: roomID, body: body, expectedRevision: expectedRevision); return try await enqueue(.init(kind: .announcement, operationID: operationID, roomID: roomID, messageID: nil, isPinned: nil, body: body, role: nil, permissions: [], targetUserID: nil, expectedRevision: expectedRevision, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }

    /// 入队一次角色权限变更。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - role: 目标角色，不能是群主。
    ///   - permissions: 目标权限集合。
    ///   - expectedRevision: 期望的当前修订。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 角色为群主时抛出
    ///   ``V2GroupPermissionValidationError/ownerPolicyIsImmutable``；其余失败来自持久化。
    public func enqueueRolePermissions(roomID: RoomID, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, expectedRevision: UInt64) async throws -> V2PendingGroupCapabilityCommand { guard role != .owner else { throw V2GroupPermissionValidationError.ownerPolicyIsImmutable }; return try await enqueue(.init(kind: .rolePermissions, operationID: makeUUID().uuidString, roomID: roomID, messageID: nil, isPinned: nil, body: nil, role: role, permissions: permissions, targetUserID: nil, expectedRevision: expectedRevision, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }

    /// 入队一次成员角色变更。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - targetUserID: 目标成员。
    ///   - role: 目标角色，不能是群主。
    ///   - expectedMembershipRevision: 期望的成员修订。
    /// - Returns: 入队或复用后的条目。
    /// - Throws: 角色为群主时抛出
    ///   ``V2GroupPermissionValidationError/memberRoleCannotBeOwner``；其余失败来自持久化。
    public func enqueueMemberRole(roomID: RoomID, targetUserID: UserID, role: V2RoomMembershipRole, expectedMembershipRevision: UInt64) async throws -> V2PendingGroupCapabilityCommand { guard role != .owner else { throw V2GroupPermissionValidationError.memberRoleCannotBeOwner }; return try await enqueue(.init(kind: .memberRole, operationID: makeUUID().uuidString, roomID: roomID, messageID: nil, isPinned: nil, body: nil, role: role, permissions: [], targetUserID: targetUserID, expectedRevision: expectedMembershipRevision, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)) }
    private func enqueue(_ command: V2PendingGroupCapabilityCommand) async throws -> V2PendingGroupCapabilityCommand { try await store.enqueueOrReuseGroupCapability(command) }
    /// 执行一次刷新，推进至多一条命令。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2GroupCapabilitiesFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    /// 推进下一条已就绪命令并按其结果更新本地状态。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；重试时刻不可用或存储失败时抛出。
    private func flushNextReadyCommand() async throws -> V2GroupCapabilitiesFlushResult {
        guard let pending = try await store.nextReadyGroupCapability(now: now()) else { return .idle }
        do {
            switch pending.kind {
            case .pin: _ = try await transport.setPinnedMessage(command: .init(operationID: try .init(pending.operationID), roomID: pending.roomID, messageID: pending.messageID!, isPinned: pending.isPinned!))
            case .announcement: _ = try await transport.setGroupAnnouncement(command: .init(operationID: try .init(pending.operationID), roomID: pending.roomID, body: pending.body!, expectedRevision: pending.expectedRevision))
            case .rolePermissions: _ = try await transport.setGroupRolePermissions(command: .init(operationID: try .init(pending.operationID), roomID: pending.roomID, role: pending.role!, permissions: pending.permissions, expectedRevision: pending.expectedRevision))
            case .memberRole: _ = try await transport.changeGroupMemberRole(command: .init(operationID: try .init(pending.operationID), roomID: pending.roomID, targetUserID: pending.targetUserID!, role: pending.role!, expectedMembershipRevision: pending.expectedRevision))
            }
            try Task.checkCancellation(); try await store.markGroupCapabilityAcknowledged(operationID: pending.operationID); return .acknowledged(pending.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError { if case .server(let code, let retryable, _, _) = error, !retryable { try await store.rejectGroupCapability(operationID: pending.operationID, code: code); return .rejected(pending.operationID, code: code) }; let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }(); try await store.scheduleGroupCapabilityRetry(operationID: pending.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay)); return .retryScheduled(pending.operationID) }
        catch { try await store.scheduleGroupCapabilityRetry(operationID: pending.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay)); return .retryScheduled(pending.operationID) }
    }
}

extension V2GroupCapabilitiesOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
