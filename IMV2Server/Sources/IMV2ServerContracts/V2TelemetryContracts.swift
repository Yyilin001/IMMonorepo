import Foundation

/// 一个刻意保持精简的可观测性边界。
///
/// 其字段只允许是枚举值或聚合值：调用方不得把房间 ID、用户 ID、消息内容、
/// 不透明令牌、URL 或任意错误字符串作为指标标签挂载上来。
public protocol V2TelemetrySink: Sendable {
    func record(_ event: V2TelemetryEvent) async
}

/// 网关连接状态的隐私安全瞬时视图。
///
/// 它刻意只包含进程内的聚合计数：设备标识与用户标识都不得跨越该边界。
public protocol V2ConnectionMetricsSource: Sendable {
    func connectionMetricsSnapshot() async -> V2ConnectionMetricsSnapshot
}

public struct V2ConnectionMetricsSnapshot: Equatable, Sendable {
    public let activeDevices: Int
    public let activeConnections: Int

    public init(activeDevices: Int, activeConnections: Int) {
        self.activeDevices = max(0, activeDevices)
        self.activeConnections = max(0, activeConnections)
    }
}

/// 网关套接字退出服务的封闭原因集合。
///
/// 它们刻意是传输层事实而非错误字符串，因此可以作为安全的指标标签，
/// 且不会暴露命令载荷或身份数据。
public enum V2GatewayConnectionClosure: String, CaseIterable, Equatable, Sendable {
    case peerDisconnected = "peer_disconnected"
    case connectionLimit = "connection_limit"
    case authenticationTimeout = "authentication_timeout"
    case idleTimeout = "idle_timeout"
    case inboundQueueLimit = "inbound_queue_limit"
    case frameLimitViolation = "frame_limit_violation"
    case requestFailure = "request_failure"
    case requiredNotificationBackpressure = "required_notification_backpressure"
    case requiredNotificationWriteTimeout = "required_notification_write_timeout"
    case deviceRevoked = "device_revoked"
}

public struct V2GatewayTransportMetricsSnapshot: Equatable, Sendable {
    public let activeConnections: Int
    public let peakQueuedInboundBytes: Int
    public let foregroundFramesSubmitted: UInt64
    public let foregroundBytesSubmitted: UInt64
    public let foregroundRecoveryFramesQueued: UInt64
    public let foregroundRecoveryFramesReplaced: UInt64
    public let foregroundFramesWritten: UInt64
    public let foregroundBytesWritten: UInt64
    public let foregroundWriteBatches: UInt64
    public let foregroundNonWritableDeferrals: UInt64
    public let peakQueuedForegroundBytes: Int
    public let foregroundGroupEventsSubmitted: UInt64
    public let foregroundGroupEventsPublished: UInt64
    public let foregroundGroupEventBatchesPublished: UInt64
    public let foregroundGroupEventDuplicatesSuppressed: UInt64
    public let foregroundGroupEventOutOfOrderArrivals: UInt64
    public let foregroundGroupEventLateArrivals: UInt64
    public let foregroundGroupEventBatchDegradations: UInt64
    public let foregroundGroupInboundNotificationsDropped: UInt64
    public let foregroundGroupCoveredWakesSuppressed: UInt64
    public let foregroundGroupWakesDeferred: UInt64
    public let foregroundGroupDeferredWakesDelivered: UInt64
    private let closures: [V2GatewayConnectionClosure: UInt64]

    public init(
        activeConnections: Int,
        peakQueuedInboundBytes: Int,
        foregroundFramesSubmitted: UInt64 = 0,
        foregroundBytesSubmitted: UInt64 = 0,
        foregroundRecoveryFramesQueued: UInt64 = 0,
        foregroundRecoveryFramesReplaced: UInt64 = 0,
        foregroundFramesWritten: UInt64 = 0,
        foregroundBytesWritten: UInt64 = 0,
        foregroundWriteBatches: UInt64 = 0,
        foregroundNonWritableDeferrals: UInt64 = 0,
        peakQueuedForegroundBytes: Int = 0,
        foregroundGroupEventsSubmitted: UInt64 = 0,
        foregroundGroupEventsPublished: UInt64 = 0,
        foregroundGroupEventBatchesPublished: UInt64 = 0,
        foregroundGroupEventDuplicatesSuppressed: UInt64 = 0,
        foregroundGroupEventOutOfOrderArrivals: UInt64 = 0,
        foregroundGroupEventLateArrivals: UInt64 = 0,
        foregroundGroupEventBatchDegradations: UInt64 = 0,
        foregroundGroupInboundNotificationsDropped: UInt64 = 0,
        foregroundGroupCoveredWakesSuppressed: UInt64 = 0,
        foregroundGroupWakesDeferred: UInt64 = 0,
        foregroundGroupDeferredWakesDelivered: UInt64 = 0,
        closures: [V2GatewayConnectionClosure: UInt64] = [:]
    ) {
        self.activeConnections = max(0, activeConnections)
        self.peakQueuedInboundBytes = max(0, peakQueuedInboundBytes)
        self.foregroundFramesSubmitted = foregroundFramesSubmitted
        self.foregroundBytesSubmitted = foregroundBytesSubmitted
        self.foregroundRecoveryFramesQueued = foregroundRecoveryFramesQueued
        self.foregroundRecoveryFramesReplaced = foregroundRecoveryFramesReplaced
        self.foregroundFramesWritten = foregroundFramesWritten
        self.foregroundBytesWritten = foregroundBytesWritten
        self.foregroundWriteBatches = foregroundWriteBatches
        self.foregroundNonWritableDeferrals = foregroundNonWritableDeferrals
        self.peakQueuedForegroundBytes = max(0, peakQueuedForegroundBytes)
        self.foregroundGroupEventsSubmitted = foregroundGroupEventsSubmitted
        self.foregroundGroupEventsPublished = foregroundGroupEventsPublished
        self.foregroundGroupEventBatchesPublished = foregroundGroupEventBatchesPublished
        self.foregroundGroupEventDuplicatesSuppressed =
            foregroundGroupEventDuplicatesSuppressed
        self.foregroundGroupEventOutOfOrderArrivals =
            foregroundGroupEventOutOfOrderArrivals
        self.foregroundGroupEventLateArrivals = foregroundGroupEventLateArrivals
        self.foregroundGroupEventBatchDegradations =
            foregroundGroupEventBatchDegradations
        self.foregroundGroupInboundNotificationsDropped =
            foregroundGroupInboundNotificationsDropped
        self.foregroundGroupCoveredWakesSuppressed =
            foregroundGroupCoveredWakesSuppressed
        self.foregroundGroupWakesDeferred = foregroundGroupWakesDeferred
        self.foregroundGroupDeferredWakesDelivered =
            foregroundGroupDeferredWakesDelivered
        self.closures = closures
    }

    public func closureCount(for reason: V2GatewayConnectionClosure) -> UInt64 {
        closures[reason, default: 0]
    }
}

public protocol V2GatewayTransportMetricsSource: Sendable {
    func gatewayTransportMetricsSnapshot() async -> V2GatewayTransportMetricsSnapshot
}

/// 写侧的传输指标边界。
///
/// 指标监听器只接受只读来源；网关处理器额外需要这套封闭的变更词汇表。
public protocol V2GatewayTransportMetricsRecorder: V2GatewayTransportMetricsSource {
    func connectionOpened()
    func connectionClosed(reason: V2GatewayConnectionClosure)
    /// 记录一个在 channel handler 持有活跃连接计量槽之前就被拒绝的套接字。
    ///
    /// - Parameter reason: 该套接字被拒绝的封闭原因。
    func connectionRejected(reason: V2GatewayConnectionClosure)
    func observeQueuedInboundBytes(_ bytes: Int)
    func foregroundFrameSubmitted(
        bytes: Int,
        recoveryQueued: Bool,
        recoveryReplaced: Bool,
        queuedBytes: Int
    )
    func foregroundWriteBatch(frames: Int, bytes: Int)
    func foregroundWriteDeferredForWritability()
    func foregroundGroupEventSubmitted(
        duplicateSuppressed: Bool,
        outOfOrder: Bool,
        lateAfterPublication: Bool,
        degradedToWake: Bool
    )
    func foregroundGroupEventBatchPublished(eventCount: Int)
    func foregroundGroupInboundNotificationDropped()
    func foregroundGroupCoveredWakeSuppressed()
    func foregroundGroupWakeDeferred()
    func foregroundGroupDeferredWakeDelivered()
}

extension V2GatewayTransportMetricsRecorder {
    public func foregroundFrameSubmitted(
        bytes _: Int,
        recoveryQueued _: Bool,
        recoveryReplaced _: Bool,
        queuedBytes _: Int
    ) {}
    public func foregroundWriteBatch(frames _: Int, bytes _: Int) {}
    public func foregroundWriteDeferredForWritability() {}
    public func foregroundGroupEventSubmitted(
        duplicateSuppressed _: Bool,
        outOfOrder _: Bool,
        lateAfterPublication _: Bool,
        degradedToWake _: Bool
    ) {}
    public func foregroundGroupEventBatchPublished(eventCount _: Int) {}
    public func foregroundGroupInboundNotificationDropped() {}
    public func foregroundGroupCoveredWakeSuppressed() {}
    public func foregroundGroupWakeDeferred() {}
    public func foregroundGroupDeferredWakeDelivered() {}
}

public enum V2GatewayTelemetryCommand: String, CaseIterable, Hashable, Sendable {
    case messageSendOperation = "message_send_operation"
    case messageSendOperationRecover = "message_send_operation_recover"
    case sendMessage = "send_message"
    case withdrawMessage = "withdraw_message"
    case changeMessageReaction = "change_message_reaction"
    case editMessage = "edit_message"
    case recordReadReceipt = "record_read_receipt"
    case syncPull = "sync_pull"
    case syncAck = "sync_ack"
    case syncSnapshot = "sync_snapshot"
    case snapshotPagePull = "snapshot_page_pull"
    case snapshotAck = "snapshot_ack"
    case listRoomMembers = "list_room_members"
    case userRoomDirectoryList = "user_room_directory_list"
    case accountRoomChangesStart = "account_room_changes_start"
    case roomSyncStateBatch = "room_sync_state_batch"
    case roomLatestVisibleBatch = "room_latest_visible_batch"
    case getGroupRolePolicyBaseline = "get_group_role_policy_baseline"
    case groupEventPull = "group_event_pull"
    case groupEventSubscribe = "group_event_subscribe"
    case groupEventUnsubscribe = "group_event_unsubscribe"
    case unsupported = "unsupported"
}

public enum V2GatewayTelemetryOutcome: String, CaseIterable, Hashable, Sendable {
    case accepted
    case rejected
    case failed
}

/// 错误码刻意是一套封闭的、协议级词汇表。
///
/// 服务端不得把异常描述用作遥测维度。
public enum V2GatewayTelemetryRejection: String, CaseIterable, Hashable, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case forbidden = "FORBIDDEN"
    case notFound = "NOT_FOUND"
    case groupCreationFrozen = "GROUP_CREATION_FROZEN"
    case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    case revisionConflict = "REVISION_CONFLICT"
    case rateLimited = "RATE_LIMITED"
    case serverBusy = "SERVER_BUSY"
    case unavailable = "UNAVAILABLE"
    case syncTokenInvalid = "SYNC_TOKEN_INVALID"
    case syncReceiptInvalid = "SYNC_RECEIPT_INVALID"
    case resetRequired = "RESET_REQUIRED"
    case upgradeRequired = "UPGRADE_REQUIRED"

    package init?(protocolCode: String) {
        self.init(rawValue: protocolCode)
    }
}

/// Internal failure dimensions remain independent of ActorContracts and wire errors.
public enum V2MessageSendFailureCommand: String, CaseIterable, Hashable, Sendable {
    case submit = "message_send_operation"
    case recover = "message_send_operation_recover"
}
public enum V2MessageSendFailureDisposition: String, CaseIterable, Hashable, Sendable {
    case outcomeUnknown = "outcome_unknown"
    case notAccepted = "not_accepted"
    case rolledBack = "rolled_back"
}
public enum V2MessageSendFailureReason: String, CaseIterable, Hashable, Sendable {
    case none
    case staleActivation = "stale_activation"
    case notReady = "not_ready"
    case retired
    case authorityLost = "lease_lost"
    case unavailable
    case overloaded
    case deadlineExceeded = "deadline_exceeded"
    case cancelled
    case notFound = "not_found"
    case forbidden
    case invalidRequest = "invalid_request"
    case unsupportedVersion = "unsupported_version"
    case idempotencyConflict = "idempotency_conflict"
}

// Swift 6.4 的 Linux Release 构建中，异步组合接收端记录内联事件布局时会崩溃。
// 在工具链修复前保留此间接调用。
public indirect enum V2TelemetryEvent: Equatable, Sendable {
    case messageSendInternalFailure(command: V2MessageSendFailureCommand,
        disposition: V2MessageSendFailureDisposition, reason: V2MessageSendFailureReason)
    /// 跟踪 ID 用于关联单条网关命令，且不标识任何用户、设备、房间、消息、令牌或协议载荷。
    case gatewayCommand(
        traceID: UUID,
        command: V2GatewayTelemetryCommand,
        outcome: V2GatewayTelemetryOutcome,
        rejection: V2GatewayTelemetryRejection?,
        elapsedMilliseconds: UInt64
    )
}
