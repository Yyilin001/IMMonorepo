import Foundation
import IMV2Core

/// 持久化的建群意图。
///
/// 操作标识与初始受众一经记录便不可变，因此重连不会意外创建第二个群，
/// 也不会悄悄改变被邀请的成员。
public struct V2PendingGroupRoomCreation: Equatable, Sendable {
    /// 建群意图的状态。
    public enum State: String, Equatable, Sendable { case pending, cancelling, finalizing, cancelled, acknowledged, rejected }

    /// 建群操作标识。
    public let operationID: GroupRoomOperationID
    /// 房间标题，已去除首尾空白。
    public let title: String
    /// 房间投递模式。
    public let capacityClass: V2GroupCapacityClass
    /// 初始成员（不含群主），已排序存放。
    public let initialMemberUserIDs: [UserID]
    /// 服务端分阶段草稿已持久化确认的受众条目数量。
    ///
    /// 它只在对应的有界追加响应到达后推进，因此重连会从断点续传，
    /// 而不是重新上传十万条成员标识。
    public let uploadedMemberCount: Int
    /// 当前状态。
    public let state: State
    /// 已尝试次数。
    public let attemptCount: Int
    /// 下次尝试时刻。
    public let nextAttemptAt: Date
    /// 成功后创建的房间标识。
    public let createdRoomID: RoomID?
    /// 终态错误码。
    public let terminalCode: String?

    /// 校验并保存建群意图。
    ///
    /// 标题需非空、不超过命令上限且不含控制字符；成员标识不得重复；
    /// 已上传数量需非负且不超过成员总数。状态与字段必须匹配：仅已确认状态可带房间标识，
    /// 仅已拒绝状态可带错误码，取消中、已取消与收尾中状态都不得带这两者。
    ///
    /// - Parameters:
    ///   - operationID: 建群操作标识。
    ///   - title: 房间标题。
    ///   - capacityClass: 投递模式。
    ///   - initialMemberUserIDs: 初始成员列表。
    ///   - uploadedMemberCount: 已确认上传的成员数量，默认零。
    ///   - state: 当前状态。
    ///   - attemptCount: 已尝试次数，需非负。
    ///   - nextAttemptAt: 下次尝试时刻。
    ///   - createdRoomID: 创建成功后的房间标识。
    ///   - terminalCode: 终态错误码。
    /// - Throws: 任一字段或状态组合不合法时抛出
    ///   ``V2ClientCommandError/commandConflict``。
    public init(operationID: GroupRoomOperationID, title: String, capacityClass: V2GroupCapacityClass, initialMemberUserIDs: [UserID], uploadedMemberCount: Int = 0, state: State, attemptCount: Int, nextAttemptAt: Date, createdRoomID: RoomID?, terminalCode: String?) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              Set(initialMemberUserIDs).count == initialMemberUserIDs.count,
              uploadedMemberCount >= 0,
              uploadedMemberCount <= initialMemberUserIDs.count,
              attemptCount >= 0,
              (state == .acknowledged) == (createdRoomID != nil),
              (state == .rejected) == (terminalCode != nil),
              state != .cancelled || (createdRoomID == nil && terminalCode == nil),
              state != .cancelling || (createdRoomID == nil && terminalCode == nil),
              state != .finalizing || (createdRoomID == nil && terminalCode == nil),
              state != .rejected || createdRoomID == nil,
              state != .acknowledged || terminalCode == nil
        else { throw V2ClientCommandError.commandConflict }
        self.operationID = operationID
        self.title = normalizedTitle
        self.capacityClass = capacityClass
        self.initialMemberUserIDs = initialMemberUserIDs.sorted()
        self.uploadedMemberCount = uploadedMemberCount
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.createdRoomID = createdRoomID
        self.terminalCode = terminalCode
    }
}

/// 本地建群发件箱存储能力。
public protocol V2LocalGroupRoomCommandStore: Sendable {
    /// 直接入队一条建群意图。
    ///
    /// - Parameter command: 待入队意图。
    /// - Throws: 持久化失败时抛出。
    func enqueue(_ command: V2PendingGroupRoomCreation) async throws

    /// 原子地复用等价的待处理意图。
    ///
    /// 建群不能仅因为首次响应丢失或应用在重连前重启，就获得第二个操作标识。
    ///
    /// - Parameter command: 待入队意图。
    /// - Returns: 实际入队或复用的意图。
    /// - Throws: 持久化失败时抛出。
    func enqueueOrReusePendingGroupRoomCreation(_ command: V2PendingGroupRoomCreation) async throws -> V2PendingGroupRoomCreation

    /// 取出下一个已就绪的建群意图。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待处理意图；没有可推进项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyGroupRoomCreation(now: Date) async throws -> V2PendingGroupRoomCreation?

    /// 记录已确认上传的成员数量。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - uploadedMemberCount: 已确认的成员数量。
    /// - Throws: 持久化失败时抛出。
    func markGroupRoomCreationMembersUploaded(operationID: GroupRoomOperationID, uploadedMemberCount: Int) async throws

    /// 重置上传进度。
    ///
    /// 仅在 Begin 证明服务端已为该不可变操作重建了空的过期草稿之后使用。
    ///
    /// - Parameter operationID: 操作标识。
    /// - Throws: 持久化失败时抛出。
    func resetGroupRoomCreationUploadProgress(operationID: GroupRoomOperationID) async throws

    /// 标记建群已被确认并记录房间标识。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - roomID: 创建出的房间标识。
    /// - Throws: 持久化失败时抛出。
    func markGroupRoomCreationAcknowledged(operationID: GroupRoomOperationID, roomID: RoomID) async throws

    /// 安排建群意图稍后重试。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 持久化失败时抛出。
    func scheduleGroupRoomCreationRetry(operationID: GroupRoomOperationID, nextAttemptAt: Date) async throws

    /// 以终态错误码拒绝建群意图。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - code: 服务端返回的稳定错误码。
    /// - Throws: 持久化失败时抛出。
    func rejectGroupRoomCreation(operationID: GroupRoomOperationID, code: String) async throws

    /// 进入取消中状态。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - now: 当前时刻。
    /// - Throws: 持久化失败时抛出。
    func beginCancellingGroupRoomCreation(operationID: GroupRoomOperationID, now: Date) async throws

    /// 取出下一个待取消的建群意图。
    ///
    /// - Parameter now: 当前时刻。
    /// - Returns: 待取消意图；没有可推进项时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func nextReadyGroupRoomCreationCancellation(now: Date) async throws -> V2PendingGroupRoomCreation?

    /// 标记建群意图已取消。
    ///
    /// - Parameter operationID: 操作标识。
    /// - Throws: 持久化失败时抛出。
    func markGroupRoomCreationCancelled(operationID: GroupRoomOperationID) async throws

    /// 取消被服务端拒绝后恢复建群意图。
    ///
    /// 服务端已经冻结受众，因此取消失败时不能让持久化建群意图滞留在只能重试的取消中状态。
    ///
    /// - Parameters:
    ///   - operationID: 操作标识。
    ///   - now: 当前时刻。
    /// - Throws: 持久化失败时抛出。
    func resumeGroupRoomCreationAfterCancellationRefusal(operationID: GroupRoomOperationID, now: Date) async throws

    /// 读取有序的持久化历史，包含终态取消与拒绝记录。
    ///
    /// 界面重建时可以据此恢复离线期间执行操作的结果。
    ///
    /// - Returns: 按发生顺序排列的建群意图历史。
    /// - Throws: 持久化失败时抛出。
    func groupRoomCreations() async throws -> [V2PendingGroupRoomCreation]
}

/// 单次建群意图刷新的结果。
public enum V2GroupRoomCreationFlushResult: Equatable, Sendable {
    /// 当前无需推进。
    case idle
    /// 建群已被确认，附房间标识。
    case acknowledged(GroupRoomOperationID, roomID: RoomID)
    /// 已安排重试。
    case retryScheduled(GroupRoomOperationID)
    /// 已被终态拒绝。
    case rejected(GroupRoomOperationID, code: String)
    /// 已取消。
    case cancelled(GroupRoomOperationID)
    /// 取消被服务端拒绝。
    case cancellationRefused(GroupRoomOperationID)
}

/// 建群专用的持久化边界。
///
/// 它与成员变更刻意分离：在原子引导事务期间尚不存在可用于栅栏的房间修订，
/// 因此需要独立的语义与状态机。
public actor V2GroupRoomCommandOutboxEngine {
    private let flushFlight = V2CommandFlushFlight<V2GroupRoomCreationFlushResult>()

    private let store: any V2LocalGroupRoomCommandStore
    private let transport: any V2ClientGroupMessagingTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval
    private var preparedOperations: Set<GroupRoomOperationID> = []

    /// 组合存储、传输与重试参数。
    ///
    /// - Parameters:
    ///   - store: 本地建群发件箱存储。
    ///   - transport: 建群传输实现。
    ///   - makeUUID: 操作标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    ///   - retryDelay: 默认重试延迟秒数，默认 1 秒。
    public init(store: any V2LocalGroupRoomCommandStore, transport: any V2ClientGroupMessagingTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0)
        self.store = store; self.transport = transport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    @discardableResult
    /// 入队一次建群。
    ///
    /// - Parameters:
    ///   - title: 房间标题。
    ///   - capacityClass: 投递模式。
    ///   - initialMemberUserIDs: 初始成员列表。
    /// - Returns: 入队或复用后的意图。
    /// - Throws: 意图构造失败或持久化失败时抛出。
    public func enqueueCreation(title: String, capacityClass: V2GroupCapacityClass, initialMemberUserIDs: [UserID]) async throws -> V2PendingGroupRoomCreation {
        let command = try V2PendingGroupRoomCreation(
            operationID: .init(makeUUID().uuidString), title: title,
            capacityClass: capacityClass,
            initialMemberUserIDs: initialMemberUserIDs, state: .pending,
            attemptCount: 0, nextAttemptAt: now(), createdRoomID: nil, terminalCode: nil
        )
        return try await store.enqueueOrReusePendingGroupRoomCreation(command)
    }

    /// 请求取消指定建群操作。
    ///
    /// 本地状态迁移发生在任何网络请求之前，
    /// 因此一次重启或取消失败都无法让建群意图复活。
    ///
    /// 仅把本地意图置为取消中，是否真正取消仍由服务端裁决。
    ///
    /// - Parameter operationID: 建群操作标识。
    /// - Throws: 持久化失败时抛出。
    public func requestCancellation(operationID: GroupRoomOperationID) async throws {
        try await store.beginCancellingGroupRoomCreation(operationID: operationID, now: now())
        preparedOperations.remove(operationID)
    }

    /// 读取最近一次建群意图（含终态记录）。
    ///
    /// - Returns: 最近一条建群意图；没有记录时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    public func latestCreation() async throws -> V2PendingGroupRoomCreation? {
        try await store.groupRoomCreations().last
    }

    /// 执行一次刷新，推进至多一步建群流程。
    ///
    /// - Returns: 本次刷新结果。
    /// - Throws: 任务取消时抛出 `CancellationError`；存储失败时抛出。
    public func flushOnce() async throws -> V2GroupRoomCreationFlushResult {
        try await flushFlight.run { try await self.flushNextReadyCommand() }
    }

    private func flushNextReadyCommand() async throws -> V2GroupRoomCreationFlushResult {
        if let cancellation = try await store.nextReadyGroupRoomCreationCancellation(now: now()) {
            do {
                try await transport.cancelGroupRoomCreation(operationID: cancellation.operationID)
                try await store.markGroupRoomCreationCancelled(operationID: cancellation.operationID)
                preparedOperations.remove(cancellation.operationID)
                return .cancelled(cancellation.operationID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as V2RealtimeTransportError {
                if case .server(let code, let retryable, _, _) = error,
                   code == "GROUP_CREATION_FROZEN", !retryable {
                    // A stable protocol code distinguishes this immutable
                    // audience race from an actual idempotency conflict.
                    // Resume the original create under the same operation ID
                    // rather than endlessly retrying an impossible cancel.
                    try await store.resumeGroupRoomCreationAfterCancellationRefusal(operationID: cancellation.operationID, now: now())
                    preparedOperations.remove(cancellation.operationID)
                    return .cancellationRefused(cancellation.operationID)
                }
                try await store.scheduleGroupRoomCreationRetry(operationID: cancellation.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
                return .retryScheduled(cancellation.operationID)
            } catch {
                try await store.scheduleGroupRoomCreationRetry(operationID: cancellation.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
                return .retryScheduled(cancellation.operationID)
            }
        }
        guard let command = try await store.nextReadyGroupRoomCreation(now: now()) else { return .idle }
        do {
            if !preparedOperations.contains(command.operationID) {
                let draft = try await transport.beginGroupRoomCreation(operationID: command.operationID, title: command.title)
                guard draft.operationID == command.operationID, draft.title == command.title else { throw V2RealtimeTransportError.unexpectedResponse }
                // Server drafts have a finite lease. When a device resumes after
                // expiry, Begin recreates the empty draft under the immutable
                // operation ID and the durable client cursor is reset before any
                // page is sent. Other mismatches would risk silently changing the
                // audience and are rejected.
                if draft.stagedMemberCount == command.uploadedMemberCount {
                    preparedOperations.insert(command.operationID)
                } else if draft.stagedMemberCount == 0, command.uploadedMemberCount > 0 {
                    try await store.resetGroupRoomCreationUploadProgress(operationID: command.operationID)
                    preparedOperations.insert(command.operationID)
                } else { throw V2RealtimeTransportError.unexpectedResponse }
                return .retryScheduled(command.operationID)
            }
            let uploadedMemberCount = command.uploadedMemberCount
            if uploadedMemberCount < command.initialMemberUserIDs.count {
                let end = min(uploadedMemberCount + V2GroupAudienceImportLimits.maximumMembersPerAppend, command.initialMemberUserIDs.count)
                let appended = try await transport.appendGroupRoomCreationMembers(
                    operationID: command.operationID,
                    memberUserIDs: Array(command.initialMemberUserIDs[uploadedMemberCount ..< end])
                )
                guard appended.operationID == command.operationID, appended.stagedMemberCount == end else {
                    throw V2RealtimeTransportError.unexpectedResponse
                }
                try await store.markGroupRoomCreationMembersUploaded(operationID: command.operationID, uploadedMemberCount: end)
                return .retryScheduled(command.operationID)
            }
            let created = try await transport.finalizeGroupRoomCreation(operationID: command.operationID)
            try Task.checkCancellation()
            guard created.title == command.title,
                  created.capacityClass == command.capacityClass,
                  created.memberCount >= command.initialMemberUserIDs.count + 1,
                  created.memberUserIDs.isEmpty
            else { throw V2RealtimeTransportError.unexpectedResponse }
            try await store.markGroupRoomCreationAcknowledged(operationID: command.operationID, roomID: created.roomID)
            preparedOperations.remove(command.operationID)
            return .acknowledged(command.operationID, roomID: created.roomID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as V2RealtimeTransportError {
            preparedOperations.remove(command.operationID)
            if case .server(let code, _, _, _) = error, code == "NOT_FOUND" {
                try await store.scheduleGroupRoomCreationRetry(operationID: command.operationID, nextAttemptAt: now())
                return .retryScheduled(command.operationID)
            }
            if case .server(let code, let retryable, _, _) = error, !retryable {
                try await store.rejectGroupRoomCreation(operationID: command.operationID, code: code)
                return .rejected(command.operationID, code: code)
            }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleGroupRoomCreationRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: delay))
            return .retryScheduled(command.operationID)
        } catch {
            try await store.scheduleGroupRoomCreationRetry(operationID: command.operationID, nextAttemptAt: try v2CommandRetryDate(now: now(), delay: retryDelay))
            return .retryScheduled(command.operationID)
        }
    }
}

extension V2GroupRoomCommandOutboxEngine: V2CommandFlushControlling {
    /// 暂停命令刷新。
    public func suspendCommandFlushing() async { await flushFlight.suspend() }

    /// 恢复命令刷新。
    public func resumeCommandFlushing() async { await flushFlight.resume() }
}
