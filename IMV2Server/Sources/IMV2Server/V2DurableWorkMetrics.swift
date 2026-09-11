import Fluent
import Foundation
import SQLKit
import Synchronization

/// 网关背后待处理持久化工作的私有聚合视图。
///
/// 它刻意不包含任何标识、分片标签、提供方名称或由载荷派生的字段，
/// 因此可以安全地从仅回环可达的 Prometheus 监听端点输出。
public protocol V2DurableWorkMetricsSource: Sendable {
    /// 读取当前持久化工作指标快照。
    ///
    /// - Returns: 聚合后的指标快照。
    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot
}

/// 持久化工作指标快照。
public struct V2DurableWorkMetricsSnapshot: Equatable, Sendable {
    /// 本次快照是否由数据源成功产出。
    public private(set) var isAvailable: Bool
    /// 本次快照是否来自上一次成功的完整结果。
    ///
    /// 刷新失败或超时时可以安全地暴露上一次完整的全局快照，
    /// 但绝不能把这些数据当作当前值呈现。
    public private(set) var servedFromLastKnownGood: Bool
    /// 距上次成功刷新经过的秒数。
    public private(set) var lastSuccessfulRefreshAgeSeconds: Int
    /// 处于待处理状态的房间发件箱行数。
    public let readyRoomOutboxRows: Int
    /// 已被认领的房间发件箱行数。
    public let leasedRoomOutboxRows: Int
    /// 已安排重试的房间发件箱行数。
    public let scheduledRoomOutboxRows: Int
    /// 已暂停的房间发件箱行数。
    public let pausedRoomOutboxRows: Int
    /// 仍未完成的房间发件箱行中最长的存在秒数。
    ///
    /// 瞬时失败不再进入暂停，因此"暂停行数为零"不能证明投递正在推进；持续重试但永不
    /// 成功的工作只能由该年龄发现。
    public let oldestUnfinishedRoomOutboxAgeSeconds: Int
    /// 待处理的私聊资料更新数量。
    public let readyDirectProfileUpdates: Int
    /// 已被认领的私聊资料更新数量。
    public let leasedDirectProfileUpdates: Int
    /// 待处理的已读回执偏好传播数量。
    public let readyReadReceiptPreferencePropagations: Int
    /// 已被认领的已读回执偏好传播数量。
    public let leasedReadReceiptPreferencePropagations: Int
    /// 已安排重试的已读回执偏好传播数量。
    public let scheduledReadReceiptPreferencePropagations: Int
    /// 已暂停的已读回执偏好传播数量。
    public let pausedReadReceiptPreferencePropagations: Int
    /// 仍未关闭的扇出计划数量。
    public let openFanoutPlans: Int
    /// 待处理的扇出投递数量。
    public let readyFanoutDeliveries: Int
    /// 已被认领的扇出投递数量。
    public let leasedFanoutDeliveries: Int
    /// 已安排重试的扇出投递数量。
    public let scheduledFanoutDeliveries: Int
    /// 已暂停的扇出投递数量。
    public let pausedFanoutDeliveries: Int
    /// 仍未完成的扇出投递行中最长的存在秒数。
    public let oldestUnfinishedFanoutDeliveryAgeSeconds: Int
    /// 投影阶段已完成、仍在等待独立释放工作器回收容量的扇出完成单元数量。
    public let terminalFanoutCompletionUnits: Int
    /// 上述完成单元中最长的滞留秒数。
    public let oldestTerminalFanoutCompletionAgeSeconds: Int
    /// 待处理的内容审核任务数量。
    public let readyContentReviews: Int
    /// 已被认领的内容审核任务数量。
    public let leasedContentReviews: Int
    /// 已安排重试的内容审核任务数量。
    public let scheduledContentReviews: Int
    /// 已暂停的内容审核任务数量。
    public let pausedContentReviews: Int
    /// 待处理的媒体扫描任务数量。
    public let readyMediaScans: Int
    /// 已被认领的媒体扫描任务数量。
    public let leasedMediaScans: Int
    /// 已安排重试的媒体扫描任务数量。
    public let scheduledMediaScans: Int
    /// 已暂停的媒体扫描任务数量。
    public let pausedMediaScans: Int
    /// 待处理的媒体清理任务数量。
    public let readyMediaPurges: Int
    /// 已被认领的媒体清理任务数量。
    public let leasedMediaPurges: Int
    /// 已安排重试的媒体清理任务数量。
    public let scheduledMediaPurges: Int
    /// 已暂停的媒体清理任务数量。
    public let pausedMediaPurges: Int
    /// 用户同步日志行数的 PostgreSQL 规划器估算值。
    ///
    /// 使用估算可避免在每次 Prometheus 抓取时对高写入的保留同步日志执行精确 `COUNT(*)` 扫描。
    public let userSyncLogEstimatedRows: Int
    /// 用户同步日志保留的堆、索引与 TOAST 总字节数。
    ///
    /// 与行数估算不同，这是一次精确的关系大小查询，而不是全表扫描。
    public let userSyncLogRelationBytes: Int
    /// 稳定的控制面投影幂等结果行数估算。
    ///
    /// 这些记录与可压缩的有序日志刻意分开保存，容量规划时必须与承载同一语义重试的
    /// 操作台账一并考虑。
    public let userProjectionEffectsEstimatedRows: Int
    /// 控制面投影幂等结果占用的关系字节数。
    public let userProjectionEffectsRelationBytes: Int
    /// 待处理的用户投影数量。
    public let readyUserProjections: Int
    /// 已安排重试的用户投影数量。
    public let scheduledUserProjections: Int
    /// 已暂停的用户投影数量。
    public let pausedUserProjections: Int
    /// 当前最大的用户投影滞后量。
    public let maximumUserProjectionLag: Int
    /// 正在构建的快照产物数量。
    public let buildingSnapshotArtifacts: Int
    /// 构建失败的快照产物数量。
    public let failedSnapshotArtifacts: Int
    /// 构建中快照产物的最长存在秒数。
    public let oldestBuildingSnapshotAgeSeconds: Int
    /// 投影版本回收的待处理行数估算。
    public let projectionVersionGCBacklogEstimatedRows: Int
    /// 消息投影状态行数估算；使用规划器估算可避免抓取时扫描最大的表。
    public let messageProjectionStatesEstimatedRows: Int
    /// 消息投影状态占用的关系字节数。
    public let messageProjectionStatesRelationBytes: Int
    /// 已建立状态引用的消息投影行数估算。
    public let messageProjectionReferenceEstimatedRows: Int
    /// 仍待回填状态引用的消息投影行数估算。
    public let messageProjectionBackfillEstimatedRows: Int
    /// 仍以内联方式保存载荷的消息投影行数估算。
    public let messageProjectionInlinePayloadEstimatedRows: Int
    /// 仍可被同库不可变房间事件精确引用替换的修订 1 已接受状态正文行数估算。
    public let messageProjectionStateInlineBodyEstimatedRows: Int
    /// 尚未压缩的投影记录数量。
    public let uncompactedProjectedRecords: Int
    /// 全部设备上仍未确认的同步记录数量。
    public let pendingSyncRecordsAcrossDevices: Int
    /// 处于重置待处理状态的设备数量。
    public let resetPendingDevices: Int
    /// 待发送的推送唤醒数量。
    public let readyPushWakes: Int
    /// 已被认领的推送唤醒数量。
    public let leasedPushWakes: Int
    /// 已被终态抑制的推送唤醒数量。
    public let suppressedPushWakes: Int
    /// 服务本次私有抓取的网关节点上尚未处理的账号与设备吊销事件数量。
    ///
    /// 该指标刻意不带节点、设备或用户标签，因此抓取结果不会泄漏拓扑或身份信息。
    public let pendingDeviceRevocationEvents: Int
    /// 集群级的存储清理积压。
    ///
    /// 它与套接字关闭分开统计：远端分片不可用只会延迟存储回收，不会延迟连接关闭。
    public let pendingRevokedDeviceProjectionCleanupEvents: Int

    public init(
        isAvailable: Bool,
        servedFromLastKnownGood: Bool = false,
        lastSuccessfulRefreshAgeSeconds: Int = 0,
        readyRoomOutboxRows: Int = 0,
        leasedRoomOutboxRows: Int = 0,
        scheduledRoomOutboxRows: Int = 0,
        pausedRoomOutboxRows: Int = 0,
        oldestUnfinishedRoomOutboxAgeSeconds: Int = 0,
        readyDirectProfileUpdates: Int = 0,
        leasedDirectProfileUpdates: Int = 0,
        readyReadReceiptPreferencePropagations: Int = 0,
        leasedReadReceiptPreferencePropagations: Int = 0,
        scheduledReadReceiptPreferencePropagations: Int = 0,
        pausedReadReceiptPreferencePropagations: Int = 0,
        openFanoutPlans: Int = 0,
        readyFanoutDeliveries: Int = 0,
        leasedFanoutDeliveries: Int = 0,
        scheduledFanoutDeliveries: Int = 0,
        pausedFanoutDeliveries: Int = 0,
        oldestUnfinishedFanoutDeliveryAgeSeconds: Int = 0,
        terminalFanoutCompletionUnits: Int = 0,
        oldestTerminalFanoutCompletionAgeSeconds: Int = 0,
        readyContentReviews: Int = 0,
        leasedContentReviews: Int = 0,
        scheduledContentReviews: Int = 0,
        pausedContentReviews: Int = 0,
        readyMediaScans: Int = 0,
        leasedMediaScans: Int = 0,
        scheduledMediaScans: Int = 0,
        pausedMediaScans: Int = 0,
        readyMediaPurges: Int = 0,
        leasedMediaPurges: Int = 0,
        scheduledMediaPurges: Int = 0,
        pausedMediaPurges: Int = 0,
        userSyncLogEstimatedRows: Int = 0,
        userSyncLogRelationBytes: Int = 0,
        userProjectionEffectsEstimatedRows: Int = 0,
        userProjectionEffectsRelationBytes: Int = 0,
        readyUserProjections: Int = 0,
        scheduledUserProjections: Int = 0,
        pausedUserProjections: Int = 0,
        maximumUserProjectionLag: Int = 0,
        buildingSnapshotArtifacts: Int = 0,
        failedSnapshotArtifacts: Int = 0,
        oldestBuildingSnapshotAgeSeconds: Int = 0,
        projectionVersionGCBacklogEstimatedRows: Int = 0,
        messageProjectionStatesEstimatedRows: Int = 0,
        messageProjectionStatesRelationBytes: Int = 0,
        messageProjectionReferenceEstimatedRows: Int = 0,
        messageProjectionBackfillEstimatedRows: Int = 0,
        messageProjectionInlinePayloadEstimatedRows: Int = 0,
        messageProjectionStateInlineBodyEstimatedRows: Int = 0,
        uncompactedProjectedRecords: Int = 0,
        pendingSyncRecordsAcrossDevices: Int = 0,
        resetPendingDevices: Int = 0,
        readyPushWakes: Int = 0,
        leasedPushWakes: Int = 0,
        suppressedPushWakes: Int = 0,
        pendingDeviceRevocationEvents: Int = 0,
        pendingRevokedDeviceProjectionCleanupEvents: Int = 0
    ) {
        self.isAvailable = isAvailable
        self.servedFromLastKnownGood = servedFromLastKnownGood
        self.lastSuccessfulRefreshAgeSeconds = max(0, lastSuccessfulRefreshAgeSeconds)
        self.readyRoomOutboxRows = max(0, readyRoomOutboxRows)
        self.leasedRoomOutboxRows = max(0, leasedRoomOutboxRows)
        self.scheduledRoomOutboxRows = max(0, scheduledRoomOutboxRows)
        self.pausedRoomOutboxRows = max(0, pausedRoomOutboxRows)
        self.readyDirectProfileUpdates = max(0, readyDirectProfileUpdates)
        self.leasedDirectProfileUpdates = max(0, leasedDirectProfileUpdates)
        self.readyReadReceiptPreferencePropagations = max(0, readyReadReceiptPreferencePropagations)
        self.leasedReadReceiptPreferencePropagations = max(0, leasedReadReceiptPreferencePropagations)
        self.scheduledReadReceiptPreferencePropagations = max(0, scheduledReadReceiptPreferencePropagations)
        self.pausedReadReceiptPreferencePropagations = max(0, pausedReadReceiptPreferencePropagations)
        self.openFanoutPlans = max(0, openFanoutPlans)
        self.readyFanoutDeliveries = max(0, readyFanoutDeliveries)
        self.leasedFanoutDeliveries = max(0, leasedFanoutDeliveries)
        self.scheduledFanoutDeliveries = max(0, scheduledFanoutDeliveries)
        self.pausedFanoutDeliveries = max(0, pausedFanoutDeliveries)
        self.oldestUnfinishedRoomOutboxAgeSeconds = max(
            0, oldestUnfinishedRoomOutboxAgeSeconds
        )
        self.oldestUnfinishedFanoutDeliveryAgeSeconds = max(
            0, oldestUnfinishedFanoutDeliveryAgeSeconds
        )
        self.terminalFanoutCompletionUnits = max(0, terminalFanoutCompletionUnits)
        self.oldestTerminalFanoutCompletionAgeSeconds = max(
            0, oldestTerminalFanoutCompletionAgeSeconds
        )
        self.readyContentReviews = max(0, readyContentReviews)
        self.leasedContentReviews = max(0, leasedContentReviews)
        self.scheduledContentReviews = max(0, scheduledContentReviews)
        self.pausedContentReviews = max(0, pausedContentReviews)
        self.readyMediaScans = max(0, readyMediaScans)
        self.leasedMediaScans = max(0, leasedMediaScans)
        self.scheduledMediaScans = max(0, scheduledMediaScans)
        self.pausedMediaScans = max(0, pausedMediaScans)
        self.readyMediaPurges = max(0, readyMediaPurges)
        self.leasedMediaPurges = max(0, leasedMediaPurges)
        self.scheduledMediaPurges = max(0, scheduledMediaPurges)
        self.pausedMediaPurges = max(0, pausedMediaPurges)
        self.userSyncLogEstimatedRows = max(0, userSyncLogEstimatedRows)
        self.userSyncLogRelationBytes = max(0, userSyncLogRelationBytes)
        self.userProjectionEffectsEstimatedRows = max(0, userProjectionEffectsEstimatedRows)
        self.userProjectionEffectsRelationBytes = max(0, userProjectionEffectsRelationBytes)
        self.readyUserProjections = max(0, readyUserProjections)
        self.scheduledUserProjections = max(0, scheduledUserProjections)
        self.pausedUserProjections = max(0, pausedUserProjections)
        self.maximumUserProjectionLag = max(0, maximumUserProjectionLag)
        self.buildingSnapshotArtifacts = max(0, buildingSnapshotArtifacts)
        self.failedSnapshotArtifacts = max(0, failedSnapshotArtifacts)
        self.oldestBuildingSnapshotAgeSeconds = max(0, oldestBuildingSnapshotAgeSeconds)
        self.projectionVersionGCBacklogEstimatedRows = max(0, projectionVersionGCBacklogEstimatedRows)
        self.messageProjectionStatesEstimatedRows = max(0, messageProjectionStatesEstimatedRows)
        self.messageProjectionStatesRelationBytes = max(0, messageProjectionStatesRelationBytes)
        self.messageProjectionReferenceEstimatedRows = max(0, messageProjectionReferenceEstimatedRows)
        self.messageProjectionBackfillEstimatedRows = max(0, messageProjectionBackfillEstimatedRows)
        self.messageProjectionInlinePayloadEstimatedRows = max(0, messageProjectionInlinePayloadEstimatedRows)
        self.messageProjectionStateInlineBodyEstimatedRows = max(
            0, messageProjectionStateInlineBodyEstimatedRows
        )
        self.uncompactedProjectedRecords = max(0, uncompactedProjectedRecords)
        self.pendingSyncRecordsAcrossDevices = max(0, pendingSyncRecordsAcrossDevices)
        self.resetPendingDevices = max(0, resetPendingDevices)
        self.readyPushWakes = max(0, readyPushWakes)
        self.leasedPushWakes = max(0, leasedPushWakes)
        self.suppressedPushWakes = max(0, suppressedPushWakes)
        self.pendingDeviceRevocationEvents = max(0, pendingDeviceRevocationEvents)
        self.pendingRevokedDeviceProjectionCleanupEvents = max(
            0,
            pendingRevokedDeviceProjectionCleanupEvents
        )
    }

    public static let unavailable = Self(isAvailable: false)

    func reportingUnavailable(lastSuccessfulRefreshAgeSeconds: Int?) -> Self {
        var copy = self
        copy.isAvailable = false
        copy.servedFromLastKnownGood = lastSuccessfulRefreshAgeSeconds != nil
        copy.lastSuccessfulRefreshAgeSeconds = max(0, lastSuccessfulRefreshAgeSeconds ?? 0)
        return copy
    }
}

/// 合并并发的 Prometheus 抓取，并限制昂贵精确聚合的评估频率。
///
/// 可用性失败也会在同一短窗口内被缓存，使一次故障不会因抓取端重试而演变成
/// 数据库重连风暴。
public actor V2CachedDurableWorkMetricsSource: V2DurableWorkMetricsSource {
    private let source: any V2DurableWorkMetricsSource
    private let minimumRefreshInterval: TimeInterval
    private let maximumRefreshDuration: Duration
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private var cached: (snapshot: V2DurableWorkMetricsSnapshot, loadedAt: ContinuousClock.Instant)?
    private var lastKnownGood: (snapshot: V2DurableWorkMetricsSnapshot, loadedAt: ContinuousClock.Instant)?
    private var refreshTask: Task<V2DurableWorkMetricsSnapshot, Never>?

    public init(
        source: any V2DurableWorkMetricsSource,
        minimumRefreshInterval: TimeInterval = 5,
        maximumRefreshDuration: TimeInterval = 4,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        precondition(minimumRefreshInterval.isFinite && minimumRefreshInterval > 0)
        guard maximumRefreshDuration <= 86_400,
              let refreshNanoseconds = v2TimeoutNanoseconds(maximumRefreshDuration) else {
            preconditionFailure("Refresh timeout must be finite, positive and at most one day")
        }
        self.source = source
        self.minimumRefreshInterval = minimumRefreshInterval
        self.maximumRefreshDuration = .nanoseconds(refreshNanoseconds)
        self.now = now
        self.monotonicNow = monotonicNow
    }

    public func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot {
        let requestedAt = now()
        // Preserve the server-clock availability contract without allowing
        // wall-clock corrections to change cache or fallback elapsed ages.
        guard requestedAt.timeIntervalSince1970.isFinite else { return .unavailable }
        let requestedInstant = monotonicNow()
        if let cached {
            let elapsed = cached.loadedAt.duration(to: requestedInstant)
            let components = elapsed.components
            let age = Double(components.seconds) + Double(components.attoseconds) / 1e18
            if elapsed >= .zero, age < minimumRefreshInterval {
                return cached.snapshot
            }
        }
        if let refreshTask { return await refreshTask.value }

        let source = source
        let maximumRefreshDuration = maximumRefreshDuration
        let fallback = lastKnownGood
        let now = now
        let monotonicNow = monotonicNow
        let task = Task {
            let refreshed: V2DurableWorkMetricsSnapshot
            switch await v2LoadDurableWorkMetrics(
                source: source,
                timeout: maximumRefreshDuration
            ) {
            case .snapshot(let snapshot): refreshed = snapshot
            case .timedOut: refreshed = .unavailable
            }
            guard !refreshed.isAvailable else { return refreshed }
            guard let fallback else {
                return refreshed.reportingUnavailable(lastSuccessfulRefreshAgeSeconds: nil)
            }
            let elapsed = fallback.loadedAt.duration(to: monotonicNow())
            guard now().timeIntervalSince1970.isFinite, elapsed >= .zero,
                  let age = Int(exactly: elapsed.components.seconds) else {
                // Do not advertise stale values as fresh by clamping an
                // unrepresentable age to zero or to an arbitrary maximum.
                return refreshed.reportingUnavailable(lastSuccessfulRefreshAgeSeconds: nil)
            }
            return fallback.snapshot.reportingUnavailable(
                lastSuccessfulRefreshAgeSeconds: age
            )
        }
        refreshTask = task
        let snapshot = await task.value
        if now().timeIntervalSince1970.isFinite {
            let loadedAt = monotonicNow()
            if snapshot.isAvailable { lastKnownGood = (snapshot, loadedAt) }
            cached = (snapshot, loadedAt)
        } else {
            // Recovery may land inside the old cache's interval. Force a new
            // refresh instead of presenting that older success after failure.
            cached = nil
        }
        refreshTask = nil
        return snapshot
    }
}

private enum V2DurableWorkMetricsRefreshResult: Sendable {
    case snapshot(V2DurableWorkMetricsSnapshot)
    case timedOut
}

/// 这里刻意使用非结构化竞速。
///
/// 结构化任务组在离开作用域前会等待不配合取消的数据库子任务，
/// 从而重现本边界试图避免的 `/metrics` 挂起。竞速失败的一方会被取消；
/// 若驱动未及时感知取消，PostgreSQL 的连接级语句超时仍提供独立硬停。
private func v2LoadDurableWorkMetrics(
    source: any V2DurableWorkMetricsSource,
    timeout: Duration
) async -> V2DurableWorkMetricsRefreshResult {
    await withCheckedContinuation { continuation in
        let race = V2DurableWorkMetricsRefreshRace(continuation: continuation)
        let sourceTask = Task {
            let snapshot = await source.durableWorkMetricsSnapshot()
            race.resolve(.snapshot(snapshot))
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                race.resolve(.timedOut)
            } catch {
                // The source won and cancelled this timer.
            }
        }
        race.install(tasks: [sourceTask, timeoutTask])
    }
}

private final class V2DurableWorkMetricsRefreshRace: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<V2DurableWorkMetricsRefreshResult, Never>?
        var tasks: [Task<Void, Never>] = []
        var resolved = false
    }

    private let state: Mutex<State>

    init(continuation: CheckedContinuation<V2DurableWorkMetricsRefreshResult, Never>) {
        state = Mutex(.init(continuation: continuation))
    }

    func install(tasks: [Task<Void, Never>]) {
        let cancel = state.withLock { state -> Bool in
            guard !state.resolved else { return true }
            state.tasks = tasks
            return false
        }
        if cancel { tasks.forEach { $0.cancel() } }
    }

    func resolve(_ result: V2DurableWorkMetricsRefreshResult) {
        let completion = state.withLock { state -> (
            CheckedContinuation<V2DurableWorkMetricsRefreshResult, Never>?,
            [Task<Void, Never>]
        ) in
            guard !state.resolved else { return (nil, []) }
            state.resolved = true
            let continuation = state.continuation
            state.continuation = nil
            let tasks = state.tasks
            state.tasks = []
            return (continuation, tasks)
        }
        completion.1.forEach { $0.cancel() }
        completion.0?.resume(returning: result)
    }
}

/// 把控制面快照与每个不同物理用户存储的一份快照合并起来。
///
/// 各数据源会并发查询；部分成功的结果绝不会被当作健康的全局视图呈现。
public struct V2AggregateDurableWorkMetricsSource: V2DurableWorkMetricsSource {
    private let sources: [any V2DurableWorkMetricsSource]

    /// 组合多个指标来源。
    ///
    /// - Parameter sources: 待聚合的指标来源列表。
    public init(sources: [any V2DurableWorkMetricsSource]) {
        precondition(!sources.isEmpty)
        self.sources = sources
    }

    public func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot {
        let snapshots = await withTaskGroup(
            of: V2DurableWorkMetricsSnapshot.self,
            returning: [V2DurableWorkMetricsSnapshot].self
        ) { group in
            for source in sources {
                group.addTask { await source.durableWorkMetricsSnapshot() }
            }
            var values: [V2DurableWorkMetricsSnapshot] = []
            values.reserveCapacity(sources.count)
            for await snapshot in group { values.append(snapshot) }
            return values
        }
        return v2AggregateDurableWorkMetrics(snapshots)
    }
}

/// PostgreSQL 侧的持久化工作指标来源。
///
/// 快照在抓取时直接查询，而不是由工作器计数器重建：这样进程重启后依然可见，
/// 告警也能区分「工作器空闲」与「持久化积压持续增长」。
public struct PostgresV2DurableWorkMetricsSource: V2DurableWorkMetricsSource {
    private let database: any Database
    private let deliveryBucket: String?
    private let gatewayNodeID: String?
    private let includesUserShardMetrics: Bool

    /// 构造指标来源。
    ///
    /// - Parameters:
    ///   - database: 执行指标查询的数据库。
    ///   - deliveryBucket: 投递桶过滤；为 `nil` 表示运行时视角下的全部已配置桶。
    ///   - gatewayNodeID: 网关节点标识，用于统计本节点待处理的吊销事件。
    ///   - includesUserShardMetrics: 是否一并统计用户分片指标。
    ///
    /// 桶级形式保留给针对性测试与分区部署使用。
    public init(
        database: any Database,
        deliveryBucket: String? = nil,
        gatewayNodeID: String? = nil,
        includesUserShardMetrics: Bool = true
    ) {
        self.database = database
        self.deliveryBucket = deliveryBucket
        self.gatewayNodeID = gatewayNodeID
        self.includesUserShardMetrics = includesUserShardMetrics
    }

    /// 暴露可失败的数据库边界，供针对性集成测试使用。
    ///
    /// 指标路由必须改用 `durableWorkMetricsSnapshot()`，
    /// 使抓取失败仍然可观测，而不会让整个端点随之失效。
    ///
    /// - Returns: 本次查询到的指标快照。
    /// - Throws: 连接不支持 SQL 或查询失败时抛出。
    public func loadDurableWorkMetrics() async throws -> V2DurableWorkMetricsSnapshot {
        guard let sql = database as? any SQLDatabase else {
            throw V2DurableWorkMetricsError.sqlUnavailable
        }
        // PostgreSQL cannot infer a type for a bare NULL bind in `NULL IS
        // NULL`. Bind an explicit Boolean scope flag instead, while keeping
        // the bucket bind typed by its comparison to the text column.
        let includesAllDeliveryBuckets = deliveryBucket == nil
        let scopedDeliveryBucket = deliveryBucket ?? ""
        let includesGatewayRevocationMetrics = gatewayNodeID != nil
        let scopedGatewayNodeID = gatewayNodeID ?? ""
        guard let row = try await sql.raw("""
                WITH snapshot_now AS (
                    SELECT CURRENT_TIMESTAMP AS value
                ),
                room_outbox_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE state = 'pending'
                              AND (next_attempt_at IS NULL OR next_attempt_at <= snapshot_now.value)
                              AND (lease_expires_at IS NULL OR lease_expires_at <= snapshot_now.value)
                        ) AS ready_room_outbox_rows,
                        COUNT(*) FILTER (
                            WHERE state = 'pending' AND lease_expires_at > snapshot_now.value
                        ) AS leased_room_outbox_rows,
                        COUNT(*) FILTER (
                            WHERE state = 'pending' AND next_attempt_at > snapshot_now.value
                              AND (lease_expires_at IS NULL OR lease_expires_at <= snapshot_now.value)
                        ) AS scheduled_room_outbox_rows,
                        COUNT(*) FILTER (WHERE state = 'paused') AS paused_room_outbox_rows,
                        COALESCE(
                            EXTRACT(EPOCH FROM (MAX(snapshot_now.value) - MIN(created_at)))::bigint,
                            0
                        ) AS oldest_unfinished_room_outbox_age_seconds
                    FROM im_v2.room_outbox, snapshot_now
                    WHERE state <> 'terminal'
                ),
                profile_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE state = 'pending'
                               OR (state = 'claimed' AND lease_expires_at <= snapshot_now.value)
                        ) AS ready_direct_profile_updates,
                        COUNT(*) FILTER (
                            WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value
                        ) AS leased_direct_profile_updates
                    FROM im_v2.public_profile_update_outbox, snapshot_now
                    WHERE state <> 'completed'
                ),
                read_receipt_preference_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE (state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= snapshot_now.value))
                               OR (state = 'claimed' AND lease_expires_at <= snapshot_now.value)
                        ) AS ready_read_receipt_preference_propagations,
                        COUNT(*) FILTER (
                            WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value
                        ) AS leased_read_receipt_preference_propagations,
                        COUNT(*) FILTER (
                            WHERE state = 'pending' AND next_attempt_at > snapshot_now.value
                        ) AS scheduled_read_receipt_preference_propagations,
                        COUNT(*) FILTER (WHERE state = 'paused')
                            AS paused_read_receipt_preference_propagations
                    FROM im_v2.read_receipt_preference_propagation_outbox, snapshot_now
                    WHERE state IN ('pending', 'claimed', 'paused')
                ),
                fanout_plan_metrics AS (
                    SELECT COUNT(*) AS open_fanout_plans
                    FROM im_v2.fanout_plans
                    WHERE state <> 'terminal'
                ),
                fanout_delivery_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE delivery.state = 'pending'
                              AND (delivery.next_attempt_at IS NULL OR delivery.next_attempt_at <= snapshot_now.value)
                              AND (delivery.lease_expires_at IS NULL OR delivery.lease_expires_at <= snapshot_now.value)
                        ) AS ready_fanout_deliveries,
                        COUNT(*) FILTER (
                            WHERE delivery.state = 'pending' AND delivery.lease_expires_at > snapshot_now.value
                        ) AS leased_fanout_deliveries,
                        COUNT(*) FILTER (
                            WHERE delivery.state = 'pending' AND delivery.next_attempt_at > snapshot_now.value
                              AND (delivery.lease_expires_at IS NULL OR delivery.lease_expires_at <= snapshot_now.value)
                        ) AS scheduled_fanout_deliveries,
                        COUNT(*) FILTER (WHERE delivery.state = 'paused') AS paused_fanout_deliveries,
                        -- 投递行本身没有创建时间。它承载的来源事件才是这条工作被提交的
                        -- 时刻，因此用事件创建时间衡量"这条投递等了多久"。
                        COALESCE(
                            EXTRACT(EPOCH FROM (
                                MAX(snapshot_now.value) - MIN(event.created_at)
                            ))::bigint,
                            0
                        ) AS oldest_unfinished_fanout_delivery_age_seconds
                    FROM im_v2.fanout_deliveries AS delivery
                    LEFT JOIN im_v2.room_events AS event
                      ON event.event_id = delivery.source_event_id,
                         snapshot_now
                    WHERE delivery.state <> 'terminal'
                      AND (\(bind: includesAllDeliveryBuckets) OR delivery.target_shard_bucket = \(bind: scopedDeliveryBucket))
                ),
                fanout_completion_release_metrics AS (
                    SELECT
                        COUNT(*) AS terminal_fanout_completion_units,
                        COALESCE(EXTRACT(EPOCH FROM (
                            MAX(snapshot_now.value) - MIN(event.created_at)
                        )), 0)::BIGINT
                            AS oldest_terminal_fanout_completion_age_seconds
                    FROM im_v2.fanout_completion_units AS unit
                    JOIN im_v2.room_events AS event
                      ON event.event_id = unit.source_event_id,
                         snapshot_now
                    WHERE unit.state = 'terminal'
                ),
                content_review_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE (state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= snapshot_now.value))
                               OR (state = 'claimed' AND lease_expires_at <= snapshot_now.value)
                        ) AS ready_content_reviews,
                        COUNT(*) FILTER (
                            WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value
                        ) AS leased_content_reviews,
                        COUNT(*) FILTER (
                            WHERE state = 'pending' AND next_attempt_at > snapshot_now.value
                        ) AS scheduled_content_reviews,
                        COUNT(*) FILTER (WHERE state = 'paused') AS paused_content_reviews
                    FROM im_v2.content_review_jobs, snapshot_now
                    WHERE state IN ('pending', 'claimed', 'paused')
                ),
                media_scan_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE (state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= snapshot_now.value))
                               OR (state = 'claimed' AND lease_expires_at <= snapshot_now.value)
                        ) AS ready_media_scans,
                        COUNT(*) FILTER (
                            WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value
                        ) AS leased_media_scans,
                        COUNT(*) FILTER (
                            WHERE state = 'pending' AND next_attempt_at > snapshot_now.value
                        ) AS scheduled_media_scans,
                        COUNT(*) FILTER (WHERE state = 'paused') AS paused_media_scans
                    FROM im_v2.media_scan_outbox, snapshot_now
                    WHERE state <> 'completed'
                ),
                media_purge_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE (state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= snapshot_now.value))
                               OR (state = 'claimed' AND lease_expires_at <= snapshot_now.value)
                        ) AS ready_media_purges,
                        COUNT(*) FILTER (
                            WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value
                        ) AS leased_media_purges,
                        COUNT(*) FILTER (
                            WHERE state = 'pending' AND next_attempt_at > snapshot_now.value
                        ) AS scheduled_media_purges,
                        COUNT(*) FILTER (WHERE state = 'paused') AS paused_media_purges
                    FROM im_v2.media_purge_outbox, snapshot_now
                    WHERE state <> 'completed'
                ),
                sync_metrics AS (
                    SELECT
                        COALESCE(SUM(
                            GREATEST(sequence.next_sequence - cursor.acknowledged_sequence, 0)
                        ) FILTER (WHERE cursor.state = 'ready'), 0)::BIGINT
                            AS pending_sync_records_across_devices,
                        COUNT(*) FILTER (
                            WHERE cursor.state IN ('reset_preparing', 'reset_pending')
                        )
                            AS reset_pending_devices
                    FROM im_v2.device_sync_cursors AS cursor
                    LEFT JOIN im_v2.user_sync_sequences AS sequence
                      ON sequence.user_id = cursor.user_id
                ),
                sync_log_storage_metrics AS (
                    SELECT
                        COALESCE((
                            SELECT stats.n_live_tup::BIGINT
                            FROM pg_stat_user_tables AS stats
                            WHERE stats.schemaname = 'im_v2'
                              AND stats.relname = 'user_sync_log'
                        ), 0)::BIGINT AS user_sync_log_estimated_rows,
                        pg_total_relation_size('im_v2.user_sync_log'::regclass)::BIGINT
                            AS user_sync_log_relation_bytes
                ),
                projection_effect_storage_metrics AS (
                    SELECT
                        COALESCE((
                            SELECT stats.n_live_tup::BIGINT
                            FROM pg_stat_user_tables AS stats
                            WHERE stats.schemaname = 'im_v2'
                              AND stats.relname = 'user_projection_effects'
                        ), 0)::BIGINT AS user_projection_effects_estimated_rows,
                        pg_total_relation_size(
                            'im_v2.user_projection_effects'::regclass
                        )::BIGINT AS user_projection_effects_relation_bytes
                ),
                projection_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE checkpoint.state = 'ready'
                              AND (checkpoint.next_attempt_at IS NULL
                                   OR checkpoint.next_attempt_at <= snapshot_now.value)
                              AND checkpoint.projected_sequence < sequence.next_sequence
                        ) AS ready_user_projections,
                        COUNT(*) FILTER (
                            WHERE checkpoint.state = 'ready'
                              AND checkpoint.next_attempt_at > snapshot_now.value
                        ) AS scheduled_user_projections,
                        COUNT(*) FILTER (WHERE checkpoint.state = 'paused')
                            AS paused_user_projections,
                        COALESCE(MAX(GREATEST(
                            sequence.next_sequence - checkpoint.projected_sequence, 0
                        )), 0)::BIGINT AS maximum_user_projection_lag
                    FROM im_v2.user_projection_checkpoints AS checkpoint
                    JOIN im_v2.user_sync_sequences AS sequence
                      ON sequence.user_id = checkpoint.user_id,
                         snapshot_now
                ),
                snapshot_artifact_metrics AS (
                    SELECT
                        COUNT(*) FILTER (WHERE state = 'building')
                            AS building_snapshot_artifacts,
                        COUNT(*) FILTER (WHERE state = 'failed')
                            AS failed_snapshot_artifacts,
                        COALESCE(EXTRACT(EPOCH FROM (
                            MAX(snapshot_now.value) - MIN(created_at)
                                FILTER (WHERE state = 'building')
                        )), 0)::BIGINT AS oldest_building_snapshot_age_seconds
                    FROM im_v2.sync_snapshot_artifacts, snapshot_now
                ),
                projection_gc_metrics AS (
                    SELECT COALESCE((
                        SELECT index_stats.reltuples::BIGINT
                        FROM pg_class AS index_stats
                        JOIN pg_namespace AS namespace
                          ON namespace.oid = index_stats.relnamespace
                        WHERE namespace.nspname = 'im_v2'
                          AND index_stats.relname = 'user_projection_versions_gc_idx'
                    ), 0)::BIGINT AS projection_version_gc_backlog_estimated_rows
                ),
                retention_metrics AS (
                    SELECT COALESCE(SUM(GREATEST(
                        checkpoint.projected_sequence
                          - COALESCE(retention.compacted_through_sequence, 0), 0
                    )), 0)::BIGINT AS uncompacted_projected_records
                    FROM im_v2.user_projection_checkpoints AS checkpoint
                    LEFT JOIN im_v2.user_sync_retention AS retention
                      ON retention.user_id = checkpoint.user_id
                ),
                push_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE state = 'pending'
                              AND (lease_expires_at IS NULL OR lease_expires_at <= snapshot_now.value)
                        ) AS ready_push_wakes,
                        COUNT(*) FILTER (
                            WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value
                        ) AS leased_push_wakes,
                        COUNT(*) FILTER (WHERE state = 'suppressed') AS suppressed_push_wakes
                    FROM im_v2.push_wake_outbox, snapshot_now
                ),
                revocation_metrics AS (
                    SELECT
                        CASE WHEN \(bind: includesGatewayRevocationMetrics) THEN COUNT(*) FILTER (
                            WHERE event.event_id > COALESCE((
                                SELECT cursor.last_event_id
                                FROM im_v2.gateway_worker_cursors AS cursor
                                WHERE cursor.worker_name = \(bind: V2DeviceRevocationCursorNamespace.workerName)
                                  AND cursor.node_id = \(bind: scopedGatewayNodeID)
                            ), 0)
                        ) ELSE 0 END AS pending_device_revocation_events,
                        CASE WHEN \(bind: includesGatewayRevocationMetrics) THEN COUNT(*) FILTER (
                            WHERE event.event_id > COALESCE((
                                SELECT cursor.last_event_id
                                FROM im_v2.gateway_worker_cursors AS cursor
                                WHERE cursor.worker_name = \(bind: V2RevokedDeviceProjectionCleanupCursorNamespace.workerName)
                                  AND cursor.node_id = \(bind: V2RevokedDeviceProjectionCleanupCursorNamespace.nodeID)
                            ), 0)
                        ) ELSE 0 END AS pending_revoked_device_projection_cleanup_events
                    FROM im_v2.device_revocation_events AS event
                )
                SELECT *
                FROM room_outbox_metrics, profile_metrics, read_receipt_preference_metrics, fanout_plan_metrics,
                     fanout_delivery_metrics, fanout_completion_release_metrics,
                     content_review_metrics, media_scan_metrics,
                     media_purge_metrics, sync_metrics, sync_log_storage_metrics,
                     projection_effect_storage_metrics,
                     projection_metrics, snapshot_artifact_metrics,
                     projection_gc_metrics, retention_metrics,
                     push_metrics, revocation_metrics
            """).first(decoding: DurableWorkMetricsRow.self)
        else {
            throw V2DurableWorkMetricsError.emptyResult
        }
        return .init(
            isAvailable: true,
            readyRoomOutboxRows: v2MetricCount(row.readyRoomOutboxRows),
            leasedRoomOutboxRows: v2MetricCount(row.leasedRoomOutboxRows),
            scheduledRoomOutboxRows: v2MetricCount(row.scheduledRoomOutboxRows),
            pausedRoomOutboxRows: v2MetricCount(row.pausedRoomOutboxRows),
            oldestUnfinishedRoomOutboxAgeSeconds: v2MetricCount(
                row.oldestUnfinishedRoomOutboxAgeSeconds
            ),
            readyDirectProfileUpdates: v2MetricCount(row.readyDirectProfileUpdates),
            leasedDirectProfileUpdates: v2MetricCount(row.leasedDirectProfileUpdates),
            readyReadReceiptPreferencePropagations: v2MetricCount(row.readyReadReceiptPreferencePropagations),
            leasedReadReceiptPreferencePropagations: v2MetricCount(row.leasedReadReceiptPreferencePropagations),
            scheduledReadReceiptPreferencePropagations: v2MetricCount(row.scheduledReadReceiptPreferencePropagations),
            pausedReadReceiptPreferencePropagations: v2MetricCount(row.pausedReadReceiptPreferencePropagations),
            openFanoutPlans: v2MetricCount(row.openFanoutPlans),
            readyFanoutDeliveries: v2MetricCount(row.readyFanoutDeliveries),
            leasedFanoutDeliveries: v2MetricCount(row.leasedFanoutDeliveries),
            scheduledFanoutDeliveries: v2MetricCount(row.scheduledFanoutDeliveries),
            pausedFanoutDeliveries: v2MetricCount(row.pausedFanoutDeliveries),
            oldestUnfinishedFanoutDeliveryAgeSeconds: v2MetricCount(
                row.oldestUnfinishedFanoutDeliveryAgeSeconds
            ),
            terminalFanoutCompletionUnits: v2MetricCount(row.terminalFanoutCompletionUnits),
            oldestTerminalFanoutCompletionAgeSeconds: v2MetricCount(row.oldestTerminalFanoutCompletionAgeSeconds),
            readyContentReviews: v2MetricCount(row.readyContentReviews),
            leasedContentReviews: v2MetricCount(row.leasedContentReviews),
            scheduledContentReviews: v2MetricCount(row.scheduledContentReviews),
            pausedContentReviews: v2MetricCount(row.pausedContentReviews),
            readyMediaScans: v2MetricCount(row.readyMediaScans),
            leasedMediaScans: v2MetricCount(row.leasedMediaScans),
            scheduledMediaScans: v2MetricCount(row.scheduledMediaScans),
            pausedMediaScans: v2MetricCount(row.pausedMediaScans),
            readyMediaPurges: v2MetricCount(row.readyMediaPurges),
            leasedMediaPurges: v2MetricCount(row.leasedMediaPurges),
            scheduledMediaPurges: v2MetricCount(row.scheduledMediaPurges),
            pausedMediaPurges: v2MetricCount(row.pausedMediaPurges),
            userSyncLogEstimatedRows: includesUserShardMetrics ? v2MetricCount(row.userSyncLogEstimatedRows) : 0,
            userSyncLogRelationBytes: includesUserShardMetrics ? v2MetricCount(row.userSyncLogRelationBytes) : 0,
            userProjectionEffectsEstimatedRows: includesUserShardMetrics ? v2MetricCount(row.userProjectionEffectsEstimatedRows) : 0,
            userProjectionEffectsRelationBytes: includesUserShardMetrics ? v2MetricCount(row.userProjectionEffectsRelationBytes) : 0,
            readyUserProjections: includesUserShardMetrics ? v2MetricCount(row.readyUserProjections) : 0,
            scheduledUserProjections: includesUserShardMetrics ? v2MetricCount(row.scheduledUserProjections) : 0,
            pausedUserProjections: includesUserShardMetrics ? v2MetricCount(row.pausedUserProjections) : 0,
            maximumUserProjectionLag: includesUserShardMetrics ? v2MetricCount(row.maximumUserProjectionLag) : 0,
            buildingSnapshotArtifacts: includesUserShardMetrics ? v2MetricCount(row.buildingSnapshotArtifacts) : 0,
            failedSnapshotArtifacts: includesUserShardMetrics ? v2MetricCount(row.failedSnapshotArtifacts) : 0,
            oldestBuildingSnapshotAgeSeconds: includesUserShardMetrics ? v2MetricCount(row.oldestBuildingSnapshotAgeSeconds) : 0,
            projectionVersionGCBacklogEstimatedRows: includesUserShardMetrics ? v2MetricCount(row.projectionVersionGCBacklogEstimatedRows) : 0,
            uncompactedProjectedRecords: includesUserShardMetrics ? v2MetricCount(row.uncompactedProjectedRecords) : 0,
            pendingSyncRecordsAcrossDevices: includesUserShardMetrics ? v2MetricCount(row.pendingSyncRecordsAcrossDevices) : 0,
            resetPendingDevices: includesUserShardMetrics ? v2MetricCount(row.resetPendingDevices) : 0,
            readyPushWakes: v2MetricCount(row.readyPushWakes),
            leasedPushWakes: v2MetricCount(row.leasedPushWakes),
            suppressedPushWakes: v2MetricCount(row.suppressedPushWakes),
            pendingDeviceRevocationEvents: v2MetricCount(row.pendingDeviceRevocationEvents),
            pendingRevokedDeviceProjectionCleanupEvents: v2MetricCount(
                row.pendingRevokedDeviceProjectionCleanupEvents
            )
        )
    }

    public func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot {
        do {
            return try await loadDurableWorkMetrics()
        } catch {
            // /metrics stays scrapeable when PostgreSQL is unavailable; the
            // availability gauge is the explicit alerting signal. Error text
            // must not escape as a metric label or response body.
            return .unavailable
        }
    }
}

/// 单个物理用户存储的轻量 schema 感知指标。
///
/// 它不读取控制面工作表，因此多个存储可以安全聚合，而不会把控制库重复计数。
public struct PostgresV2UserShardDurableWorkMetricsSource: V2DurableWorkMetricsSource {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String) {
        precondition(schema.range(
            of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression
        ) != nil)
        self.database = database
        self.schema = schema
    }

    public func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot {
        do { return try await load() }
        catch { return .unavailable }
    }

    private func load() async throws -> V2DurableWorkMetricsSnapshot {
        guard let sql = database as? any SQLDatabase else {
            throw V2DurableWorkMetricsError.sqlUnavailable
        }
        let table: (String) -> String = { "\(schema).\($0)" }
        guard let row = try await sql.raw("""
            WITH snapshot_now AS (SELECT CURRENT_TIMESTAMP AS value),
            sync_metrics AS (
                SELECT
                    COALESCE(SUM(GREATEST(
                        sequence.next_sequence - cursor.acknowledged_sequence, 0
                    )) FILTER (WHERE cursor.state = 'ready'), 0)::BIGINT
                        AS pending_sync_records_across_devices,
                    COUNT(*) FILTER (
                        WHERE cursor.state IN ('reset_preparing', 'reset_pending')
                    ) AS reset_pending_devices
                FROM \(unsafeRaw: table("device_sync_cursors")) AS cursor
                LEFT JOIN \(unsafeRaw: table("user_sync_sequences")) AS sequence
                  ON sequence.user_id = cursor.user_id
            ),
            storage_metrics AS (
                SELECT
                    COALESCE((SELECT n_live_tup::BIGINT FROM pg_stat_user_tables
                              WHERE schemaname = \(bind: schema)
                                AND relname = 'user_sync_log'), 0)::BIGINT
                        AS user_sync_log_estimated_rows,
                    pg_total_relation_size(
                        \(bind: "\(schema).user_sync_log")::regclass
                    )::BIGINT AS user_sync_log_relation_bytes,
                    COALESCE((SELECT n_live_tup::BIGINT FROM pg_stat_user_tables
                              WHERE schemaname = \(bind: schema)
                                AND relname = 'user_projection_effects'), 0)::BIGINT
                        AS user_projection_effects_estimated_rows,
                    pg_total_relation_size(
                        \(bind: "\(schema).user_projection_effects")::regclass
                    )::BIGINT AS user_projection_effects_relation_bytes,
                    COALESCE((SELECT n_live_tup::BIGINT FROM pg_stat_user_tables
                              WHERE schemaname = \(bind: schema)
                                AND relname = 'message_projection_states'), 0)::BIGINT
                        AS message_projection_states_estimated_rows,
                    pg_total_relation_size(
                        \(bind: "\(schema).message_projection_states")::regclass
                    )::BIGINT AS message_projection_states_relation_bytes
            ),
            projection_metrics AS (
                SELECT
                    COUNT(*) FILTER (
                        WHERE checkpoint.state = 'ready'
                          AND (checkpoint.next_attempt_at IS NULL
                               OR checkpoint.next_attempt_at <= snapshot_now.value)
                          AND checkpoint.projected_sequence < sequence.next_sequence
                    ) AS ready_user_projections,
                    COUNT(*) FILTER (
                        WHERE checkpoint.state = 'ready'
                          AND checkpoint.next_attempt_at > snapshot_now.value
                    ) AS scheduled_user_projections,
                    COUNT(*) FILTER (WHERE checkpoint.state = 'paused')
                        AS paused_user_projections,
                    COALESCE(MAX(GREATEST(
                        sequence.next_sequence - checkpoint.projected_sequence, 0
                    )), 0)::BIGINT AS maximum_user_projection_lag
                FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                JOIN \(unsafeRaw: table("user_sync_sequences")) AS sequence
                  ON sequence.user_id = checkpoint.user_id,
                     snapshot_now
            ),
            artifact_metrics AS (
                SELECT
                    COUNT(*) FILTER (WHERE state = 'building')
                        AS building_snapshot_artifacts,
                    COUNT(*) FILTER (WHERE state = 'failed')
                        AS failed_snapshot_artifacts,
                    COALESCE(EXTRACT(EPOCH FROM (
                        MAX(snapshot_now.value) - MIN(created_at)
                            FILTER (WHERE state = 'building')
                    )), 0)::BIGINT AS oldest_building_snapshot_age_seconds
                FROM \(unsafeRaw: table("sync_snapshot_artifacts")), snapshot_now
            ),
            gc_metrics AS (
                SELECT COALESCE((
                    SELECT index_stats.reltuples::BIGINT
                    FROM pg_class AS index_stats
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = index_stats.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND index_stats.relname = 'user_projection_versions_gc_idx'
                ), 0)::BIGINT AS projection_version_gc_backlog_estimated_rows,
                COALESCE((
                    SELECT index_stats.reltuples::BIGINT
                    FROM pg_class AS index_stats
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = index_stats.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND index_stats.relname = 'user_projection_versions_message_state_idx'
                ), 0)::BIGINT AS message_projection_reference_estimated_rows,
                COALESCE((
                    SELECT index_stats.reltuples::BIGINT
                    FROM pg_class AS index_stats
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = index_stats.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND index_stats.relname = 'user_projection_versions_message_backfill_idx'
                ), 0)::BIGINT AS message_projection_backfill_estimated_rows,
                COALESCE((
                    SELECT index_stats.reltuples::BIGINT
                    FROM pg_class AS index_stats
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = index_stats.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND index_stats.relname = 'user_projection_versions_message_inline_idx'
                ), 0)::BIGINT AS message_projection_inline_payload_estimated_rows,
                COALESCE((
                    SELECT index_stats.reltuples::BIGINT
                    FROM pg_class AS index_stats
                    JOIN pg_namespace AS namespace
                      ON namespace.oid = index_stats.relnamespace
                    WHERE namespace.nspname = \(bind: schema)
                      AND index_stats.relname =
                          'message_projection_states_inline_accepted_idx'
                ), 0)::BIGINT AS message_projection_state_inline_body_estimated_rows
            ),
            retention_metrics AS (
                SELECT COALESCE(SUM(GREATEST(
                    checkpoint.projected_sequence
                      - COALESCE(retention.compacted_through_sequence, 0), 0
                )), 0)::BIGINT AS uncompacted_projected_records
                FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                LEFT JOIN \(unsafeRaw: table("user_sync_retention")) AS retention
                  ON retention.user_id = checkpoint.user_id
            )
            SELECT * FROM sync_metrics, storage_metrics, projection_metrics,
                          artifact_metrics, gc_metrics, retention_metrics
            """).first(decoding: UserShardDurableWorkMetricsRow.self) else {
            throw V2DurableWorkMetricsError.emptyResult
        }
        return .init(
            isAvailable: true,
            userSyncLogEstimatedRows: v2MetricCount(row.userSyncLogEstimatedRows),
            userSyncLogRelationBytes: v2MetricCount(row.userSyncLogRelationBytes),
            userProjectionEffectsEstimatedRows: v2MetricCount(row.userProjectionEffectsEstimatedRows),
            userProjectionEffectsRelationBytes: v2MetricCount(row.userProjectionEffectsRelationBytes),
            readyUserProjections: v2MetricCount(row.readyUserProjections),
            scheduledUserProjections: v2MetricCount(row.scheduledUserProjections),
            pausedUserProjections: v2MetricCount(row.pausedUserProjections),
            maximumUserProjectionLag: v2MetricCount(row.maximumUserProjectionLag),
            buildingSnapshotArtifacts: v2MetricCount(row.buildingSnapshotArtifacts),
            failedSnapshotArtifacts: v2MetricCount(row.failedSnapshotArtifacts),
            oldestBuildingSnapshotAgeSeconds: v2MetricCount(row.oldestBuildingSnapshotAgeSeconds),
            projectionVersionGCBacklogEstimatedRows: v2MetricCount(row.projectionVersionGCBacklogEstimatedRows),
            messageProjectionStatesEstimatedRows: v2MetricCount(row.messageProjectionStatesEstimatedRows),
            messageProjectionStatesRelationBytes: v2MetricCount(row.messageProjectionStatesRelationBytes),
            messageProjectionReferenceEstimatedRows: v2MetricCount(row.messageProjectionReferenceEstimatedRows),
            messageProjectionBackfillEstimatedRows: v2MetricCount(row.messageProjectionBackfillEstimatedRows),
            messageProjectionInlinePayloadEstimatedRows: v2MetricCount(row.messageProjectionInlinePayloadEstimatedRows),
            messageProjectionStateInlineBodyEstimatedRows: v2MetricCount(
                row.messageProjectionStateInlineBodyEstimatedRows
            ),
            uncompactedProjectedRecords: v2MetricCount(row.uncompactedProjectedRecords),
            pendingSyncRecordsAcrossDevices: v2MetricCount(row.pendingSyncRecordsAcrossDevices),
            resetPendingDevices: v2MetricCount(row.resetPendingDevices)
        )
    }
}

private func v2AggregateDurableWorkMetrics(
    _ snapshots: [V2DurableWorkMetricsSnapshot]
) -> V2DurableWorkMetricsSnapshot {
    guard !snapshots.isEmpty, snapshots.allSatisfy(\.isAvailable) else {
        return .unavailable
    }
    func sum(_ keyPath: KeyPath<V2DurableWorkMetricsSnapshot, Int>) -> Int {
        snapshots.reduce(0) { partial, snapshot in
            let value = snapshot[keyPath: keyPath]
            return partial > Int.max - value ? Int.max : partial + value
        }
    }
    func maximum(_ keyPath: KeyPath<V2DurableWorkMetricsSnapshot, Int>) -> Int {
        snapshots.map { $0[keyPath: keyPath] }.max() ?? 0
    }
    return .init(
        isAvailable: true,
        readyRoomOutboxRows: sum(\.readyRoomOutboxRows),
        leasedRoomOutboxRows: sum(\.leasedRoomOutboxRows),
        scheduledRoomOutboxRows: sum(\.scheduledRoomOutboxRows),
        pausedRoomOutboxRows: sum(\.pausedRoomOutboxRows),
        oldestUnfinishedRoomOutboxAgeSeconds: maximum(\.oldestUnfinishedRoomOutboxAgeSeconds),
        readyDirectProfileUpdates: sum(\.readyDirectProfileUpdates),
        leasedDirectProfileUpdates: sum(\.leasedDirectProfileUpdates),
        readyReadReceiptPreferencePropagations: sum(\.readyReadReceiptPreferencePropagations),
        leasedReadReceiptPreferencePropagations: sum(\.leasedReadReceiptPreferencePropagations),
        scheduledReadReceiptPreferencePropagations: sum(\.scheduledReadReceiptPreferencePropagations),
        pausedReadReceiptPreferencePropagations: sum(\.pausedReadReceiptPreferencePropagations),
        openFanoutPlans: sum(\.openFanoutPlans),
        readyFanoutDeliveries: sum(\.readyFanoutDeliveries),
        leasedFanoutDeliveries: sum(\.leasedFanoutDeliveries),
        scheduledFanoutDeliveries: sum(\.scheduledFanoutDeliveries),
        pausedFanoutDeliveries: sum(\.pausedFanoutDeliveries),
        oldestUnfinishedFanoutDeliveryAgeSeconds: maximum(\.oldestUnfinishedFanoutDeliveryAgeSeconds),
        terminalFanoutCompletionUnits: sum(\.terminalFanoutCompletionUnits),
        oldestTerminalFanoutCompletionAgeSeconds: maximum(\.oldestTerminalFanoutCompletionAgeSeconds),
        readyContentReviews: sum(\.readyContentReviews),
        leasedContentReviews: sum(\.leasedContentReviews),
        scheduledContentReviews: sum(\.scheduledContentReviews),
        pausedContentReviews: sum(\.pausedContentReviews),
        readyMediaScans: sum(\.readyMediaScans),
        leasedMediaScans: sum(\.leasedMediaScans),
        scheduledMediaScans: sum(\.scheduledMediaScans),
        pausedMediaScans: sum(\.pausedMediaScans),
        readyMediaPurges: sum(\.readyMediaPurges),
        leasedMediaPurges: sum(\.leasedMediaPurges),
        scheduledMediaPurges: sum(\.scheduledMediaPurges),
        pausedMediaPurges: sum(\.pausedMediaPurges),
        userSyncLogEstimatedRows: sum(\.userSyncLogEstimatedRows),
        userSyncLogRelationBytes: sum(\.userSyncLogRelationBytes),
        userProjectionEffectsEstimatedRows: sum(\.userProjectionEffectsEstimatedRows),
        userProjectionEffectsRelationBytes: sum(\.userProjectionEffectsRelationBytes),
        readyUserProjections: sum(\.readyUserProjections),
        scheduledUserProjections: sum(\.scheduledUserProjections),
        pausedUserProjections: sum(\.pausedUserProjections),
        maximumUserProjectionLag: maximum(\.maximumUserProjectionLag),
        buildingSnapshotArtifacts: sum(\.buildingSnapshotArtifacts),
        failedSnapshotArtifacts: sum(\.failedSnapshotArtifacts),
        oldestBuildingSnapshotAgeSeconds: maximum(\.oldestBuildingSnapshotAgeSeconds),
        projectionVersionGCBacklogEstimatedRows: sum(\.projectionVersionGCBacklogEstimatedRows),
        messageProjectionStatesEstimatedRows: sum(\.messageProjectionStatesEstimatedRows),
        messageProjectionStatesRelationBytes: sum(\.messageProjectionStatesRelationBytes),
        messageProjectionReferenceEstimatedRows: sum(\.messageProjectionReferenceEstimatedRows),
        messageProjectionBackfillEstimatedRows: sum(\.messageProjectionBackfillEstimatedRows),
        messageProjectionInlinePayloadEstimatedRows: sum(\.messageProjectionInlinePayloadEstimatedRows),
        messageProjectionStateInlineBodyEstimatedRows: sum(
            \.messageProjectionStateInlineBodyEstimatedRows
        ),
        uncompactedProjectedRecords: sum(\.uncompactedProjectedRecords),
        pendingSyncRecordsAcrossDevices: sum(\.pendingSyncRecordsAcrossDevices),
        resetPendingDevices: sum(\.resetPendingDevices),
        readyPushWakes: sum(\.readyPushWakes),
        leasedPushWakes: sum(\.leasedPushWakes),
        suppressedPushWakes: sum(\.suppressedPushWakes),
        pendingDeviceRevocationEvents: sum(\.pendingDeviceRevocationEvents),
        pendingRevokedDeviceProjectionCleanupEvents: sum(
            \.pendingRevokedDeviceProjectionCleanupEvents
        )
    )
}

public enum V2DurableWorkMetricsError: Error, Equatable, Sendable {
    case sqlUnavailable
    case emptyResult
}

public func v2RenderPrometheusDurableWorkMetrics(_ snapshot: V2DurableWorkMetricsSnapshot) -> String {
    [
        "# HELP im_v2_durable_work_metrics_available Whether the durable-work scrape completed against PostgreSQL.",
        "# TYPE im_v2_durable_work_metrics_available gauge",
        "im_v2_durable_work_metrics_available \(snapshot.isAvailable ? 1 : 0)",
        "# HELP im_v2_durable_work_metrics_last_known_good Whether a failed refresh is serving the last complete snapshot.",
        "# TYPE im_v2_durable_work_metrics_last_known_good gauge",
        "im_v2_durable_work_metrics_last_known_good \(snapshot.servedFromLastKnownGood ? 1 : 0)",
        "# HELP im_v2_durable_work_metrics_last_success_age_seconds Age of the last complete durable-work refresh when serving stale data.",
        "# TYPE im_v2_durable_work_metrics_last_success_age_seconds gauge",
        "im_v2_durable_work_metrics_last_success_age_seconds \(snapshot.lastSuccessfulRefreshAgeSeconds)",
        "# HELP im_v2_room_outbox_backlog Durable room outbox rows owned by this deployment.",
        "# TYPE im_v2_room_outbox_backlog gauge",
        "im_v2_room_outbox_backlog{state=\"ready\"} \(snapshot.readyRoomOutboxRows)",
        "im_v2_room_outbox_backlog{state=\"leased\"} \(snapshot.leasedRoomOutboxRows)",
        "im_v2_room_outbox_backlog{state=\"scheduled\"} \(snapshot.scheduledRoomOutboxRows)",
        "im_v2_room_outbox_backlog{state=\"paused\"} \(snapshot.pausedRoomOutboxRows)",
        "# HELP im_v2_room_outbox_oldest_unfinished_age_seconds Age of the oldest room outbox row that has not reached a terminal state.",
        "# TYPE im_v2_room_outbox_oldest_unfinished_age_seconds gauge",
        "im_v2_room_outbox_oldest_unfinished_age_seconds \(snapshot.oldestUnfinishedRoomOutboxAgeSeconds)",
        "# HELP im_v2_direct_profile_update_backlog Durable direct-profile update sources awaiting or held by propagation.",
        "# TYPE im_v2_direct_profile_update_backlog gauge",
        "im_v2_direct_profile_update_backlog{state=\"ready\"} \(snapshot.readyDirectProfileUpdates)",
        "im_v2_direct_profile_update_backlog{state=\"leased\"} \(snapshot.leasedDirectProfileUpdates)",
        "# HELP im_v2_read_receipt_preference_propagation_backlog Durable direct-receipt preference changes awaiting or held by bounded propagation.",
        "# TYPE im_v2_read_receipt_preference_propagation_backlog gauge",
        "im_v2_read_receipt_preference_propagation_backlog{state=\"ready\"} \(snapshot.readyReadReceiptPreferencePropagations)",
        "im_v2_read_receipt_preference_propagation_backlog{state=\"leased\"} \(snapshot.leasedReadReceiptPreferencePropagations)",
        "im_v2_read_receipt_preference_propagation_backlog{state=\"scheduled\"} \(snapshot.scheduledReadReceiptPreferencePropagations)",
        "im_v2_read_receipt_preference_propagation_backlog{state=\"paused\"} \(snapshot.pausedReadReceiptPreferencePropagations)",
        "# HELP im_v2_fanout_plans_open Durable fan-out plans not yet terminal.",
        "# TYPE im_v2_fanout_plans_open gauge",
        "im_v2_fanout_plans_open \(snapshot.openFanoutPlans)",
        "# HELP im_v2_fanout_delivery_backlog Durable delivery rows for this replica's configured logical bucket.",
        "# TYPE im_v2_fanout_delivery_backlog gauge",
        "im_v2_fanout_delivery_backlog{state=\"ready\"} \(snapshot.readyFanoutDeliveries)",
        "im_v2_fanout_delivery_backlog{state=\"leased\"} \(snapshot.leasedFanoutDeliveries)",
        "im_v2_fanout_delivery_backlog{state=\"scheduled\"} \(snapshot.scheduledFanoutDeliveries)",
        "im_v2_fanout_delivery_backlog{state=\"paused\"} \(snapshot.pausedFanoutDeliveries)",
        "# HELP im_v2_fanout_delivery_oldest_unfinished_age_seconds Age of the oldest fan-out delivery row that has not reached a terminal state.",
        "# TYPE im_v2_fanout_delivery_oldest_unfinished_age_seconds gauge",
        "im_v2_fanout_delivery_oldest_unfinished_age_seconds \(snapshot.oldestUnfinishedFanoutDeliveryAgeSeconds)",
        "# HELP im_v2_fanout_completion_release_backlog Terminal completion units awaiting admission-capacity release.",
        "# TYPE im_v2_fanout_completion_release_backlog gauge",
        "im_v2_fanout_completion_release_backlog \(snapshot.terminalFanoutCompletionUnits)",
        "# HELP im_v2_fanout_completion_release_oldest_age_seconds Age since the source event of the oldest terminal unit awaiting release.",
        "# TYPE im_v2_fanout_completion_release_oldest_age_seconds gauge",
        "im_v2_fanout_completion_release_oldest_age_seconds \(snapshot.oldestTerminalFanoutCompletionAgeSeconds)",
        "# HELP im_v2_content_review_backlog Durable content-review jobs by actionable state.",
        "# TYPE im_v2_content_review_backlog gauge",
        "im_v2_content_review_backlog{state=\"ready\"} \(snapshot.readyContentReviews)",
        "im_v2_content_review_backlog{state=\"leased\"} \(snapshot.leasedContentReviews)",
        "im_v2_content_review_backlog{state=\"scheduled\"} \(snapshot.scheduledContentReviews)",
        "im_v2_content_review_backlog{state=\"paused\"} \(snapshot.pausedContentReviews)",
        "# HELP im_v2_media_scan_backlog Durable media scan jobs by actionable state.",
        "# TYPE im_v2_media_scan_backlog gauge",
        "im_v2_media_scan_backlog{state=\"ready\"} \(snapshot.readyMediaScans)",
        "im_v2_media_scan_backlog{state=\"leased\"} \(snapshot.leasedMediaScans)",
        "im_v2_media_scan_backlog{state=\"scheduled\"} \(snapshot.scheduledMediaScans)",
        "im_v2_media_scan_backlog{state=\"paused\"} \(snapshot.pausedMediaScans)",
        "# HELP im_v2_media_purge_backlog Durable provider-byte cleanup jobs by actionable state.",
        "# TYPE im_v2_media_purge_backlog gauge",
        "im_v2_media_purge_backlog{state=\"ready\"} \(snapshot.readyMediaPurges)",
        "im_v2_media_purge_backlog{state=\"leased\"} \(snapshot.leasedMediaPurges)",
        "im_v2_media_purge_backlog{state=\"scheduled\"} \(snapshot.scheduledMediaPurges)",
        "im_v2_media_purge_backlog{state=\"paused\"} \(snapshot.pausedMediaPurges)",
        "# HELP im_v2_user_sync_log_estimated_rows PostgreSQL planner-statistics estimate of retained user sync-log rows; not an exact count.",
        "# TYPE im_v2_user_sync_log_estimated_rows gauge",
        "im_v2_user_sync_log_estimated_rows \(snapshot.userSyncLogEstimatedRows)",
        "# HELP im_v2_user_sync_log_relation_bytes Heap, indexes, and TOAST bytes retained by the user sync-log relation.",
        "# TYPE im_v2_user_sync_log_relation_bytes gauge",
        "im_v2_user_sync_log_relation_bytes \(snapshot.userSyncLogRelationBytes)",
        "# HELP im_v2_user_projection_effects_estimated_rows PostgreSQL planner-statistics estimate of stable control-projection idempotency results.",
        "# TYPE im_v2_user_projection_effects_estimated_rows gauge",
        "im_v2_user_projection_effects_estimated_rows \(snapshot.userProjectionEffectsEstimatedRows)",
        "# HELP im_v2_user_projection_effects_relation_bytes Heap, indexes, and TOAST bytes retained by stable control-projection idempotency results.",
        "# TYPE im_v2_user_projection_effects_relation_bytes gauge",
        "im_v2_user_projection_effects_relation_bytes \(snapshot.userProjectionEffectsRelationBytes)",
        "# HELP im_v2_user_projection_backlog Users awaiting canonical snapshot projection by actionable state.",
        "# TYPE im_v2_user_projection_backlog gauge",
        "im_v2_user_projection_backlog{state=\"ready\"} \(snapshot.readyUserProjections)",
        "im_v2_user_projection_backlog{state=\"scheduled\"} \(snapshot.scheduledUserProjections)",
        "im_v2_user_projection_backlog{state=\"paused\"} \(snapshot.pausedUserProjections)",
        "# HELP im_v2_user_projection_maximum_lag_records Largest per-user canonical projection lag in sync records.",
        "# TYPE im_v2_user_projection_maximum_lag_records gauge",
        "im_v2_user_projection_maximum_lag_records \(snapshot.maximumUserProjectionLag)",
        "# HELP im_v2_snapshot_artifacts Durable snapshot artifacts by actionable state.",
        "# TYPE im_v2_snapshot_artifacts gauge",
        "im_v2_snapshot_artifacts{state=\"building\"} \(snapshot.buildingSnapshotArtifacts)",
        "im_v2_snapshot_artifacts{state=\"failed\"} \(snapshot.failedSnapshotArtifacts)",
        "# HELP im_v2_snapshot_oldest_building_age_seconds Age of the oldest building snapshot artifact.",
        "# TYPE im_v2_snapshot_oldest_building_age_seconds gauge",
        "im_v2_snapshot_oldest_building_age_seconds \(snapshot.oldestBuildingSnapshotAgeSeconds)",
        "# HELP im_v2_projection_version_gc_backlog_estimated_rows Planner estimate from the closed-version partial index.",
        "# TYPE im_v2_projection_version_gc_backlog_estimated_rows gauge",
        "im_v2_projection_version_gc_backlog_estimated_rows \(snapshot.projectionVersionGCBacklogEstimatedRows)",
        "# HELP im_v2_message_projection_states_estimated_rows PostgreSQL planner estimate of immutable shared message states.",
        "# TYPE im_v2_message_projection_states_estimated_rows gauge",
        "im_v2_message_projection_states_estimated_rows \(snapshot.messageProjectionStatesEstimatedRows)",
        "# HELP im_v2_message_projection_states_relation_bytes Heap, indexes, and TOAST bytes retained by immutable shared message states.",
        "# TYPE im_v2_message_projection_states_relation_bytes gauge",
        "im_v2_message_projection_states_relation_bytes \(snapshot.messageProjectionStatesRelationBytes)",
        "# HELP im_v2_message_projection_references_estimated_rows Planner estimate of user message versions linked to shared state.",
        "# TYPE im_v2_message_projection_references_estimated_rows gauge",
        "im_v2_message_projection_references_estimated_rows \(snapshot.messageProjectionReferenceEstimatedRows)",
        "# HELP im_v2_message_projection_backfill_estimated_rows Planner estimate of legacy message versions still missing a shared-state reference.",
        "# TYPE im_v2_message_projection_backfill_estimated_rows gauge",
        "im_v2_message_projection_backfill_estimated_rows \(snapshot.messageProjectionBackfillEstimatedRows)",
        "# HELP im_v2_message_projection_inline_payload_estimated_rows Planner estimate of duplicated inline message payloads remaining before contract.",
        "# TYPE im_v2_message_projection_inline_payload_estimated_rows gauge",
        "im_v2_message_projection_inline_payload_estimated_rows \(snapshot.messageProjectionInlinePayloadEstimatedRows)",
        "# HELP im_v2_message_projection_state_inline_body_estimated_rows Planner estimate of accepted state bodies still eligible for exact room-event compaction.",
        "# TYPE im_v2_message_projection_state_inline_body_estimated_rows gauge",
        "im_v2_message_projection_state_inline_body_estimated_rows \(snapshot.messageProjectionStateInlineBodyEstimatedRows)",
        "# HELP im_v2_sync_uncompacted_projected_records Aggregate canonical records above retained floors.",
        "# TYPE im_v2_sync_uncompacted_projected_records gauge",
        "im_v2_sync_uncompacted_projected_records \(snapshot.uncompactedProjectedRecords)",
        "# HELP im_v2_sync_pending_records_across_devices Aggregate unacknowledged sync records, counted once per ready device cursor.",
        "# TYPE im_v2_sync_pending_records_across_devices gauge",
        "im_v2_sync_pending_records_across_devices \(snapshot.pendingSyncRecordsAcrossDevices)",
        "# HELP im_v2_sync_reset_pending_devices Device cursors currently fenced behind a snapshot reset.",
        "# TYPE im_v2_sync_reset_pending_devices gauge",
        "im_v2_sync_reset_pending_devices \(snapshot.resetPendingDevices)",
        "# HELP im_v2_push_wake_backlog Aggregate generic Push wake work by durable state.",
        "# TYPE im_v2_push_wake_backlog gauge",
        "im_v2_push_wake_backlog{state=\"ready\"} \(snapshot.readyPushWakes)",
        "im_v2_push_wake_backlog{state=\"leased\"} \(snapshot.leasedPushWakes)",
        "im_v2_push_wake_backlog{state=\"suppressed\"} \(snapshot.suppressedPushWakes)",
        "# HELP im_v2_device_revocation_events_pending Durable device-revocation events not yet consumed by this gateway node.",
        "# TYPE im_v2_device_revocation_events_pending gauge",
        "im_v2_device_revocation_events_pending \(snapshot.pendingDeviceRevocationEvents)",
        "# HELP im_v2_revoked_device_projection_cleanup_events_pending Durable revocations awaiting user-shard capability cleanup.",
        "# TYPE im_v2_revoked_device_projection_cleanup_events_pending gauge",
        "im_v2_revoked_device_projection_cleanup_events_pending \(snapshot.pendingRevokedDeviceProjectionCleanupEvents)",
    ].joined(separator: "\n") + "\n"
}

private struct DurableWorkMetricsRow: Decodable {
    let readyRoomOutboxRows: Int64
    let leasedRoomOutboxRows: Int64
    let scheduledRoomOutboxRows: Int64
    let pausedRoomOutboxRows: Int64
    let readyDirectProfileUpdates: Int64
    let leasedDirectProfileUpdates: Int64
    let readyReadReceiptPreferencePropagations: Int64
    let leasedReadReceiptPreferencePropagations: Int64
    let scheduledReadReceiptPreferencePropagations: Int64
    let pausedReadReceiptPreferencePropagations: Int64
    let openFanoutPlans: Int64
    let readyFanoutDeliveries: Int64
    let leasedFanoutDeliveries: Int64
    let scheduledFanoutDeliveries: Int64
    let pausedFanoutDeliveries: Int64
    let oldestUnfinishedRoomOutboxAgeSeconds: Int64
    let oldestUnfinishedFanoutDeliveryAgeSeconds: Int64
    let terminalFanoutCompletionUnits: Int64
    let oldestTerminalFanoutCompletionAgeSeconds: Int64
    let readyContentReviews: Int64
    let leasedContentReviews: Int64
    let scheduledContentReviews: Int64
    let pausedContentReviews: Int64
    let readyMediaScans: Int64
    let leasedMediaScans: Int64
    let scheduledMediaScans: Int64
    let pausedMediaScans: Int64
    let readyMediaPurges: Int64
    let leasedMediaPurges: Int64
    let scheduledMediaPurges: Int64
    let pausedMediaPurges: Int64
    let userSyncLogEstimatedRows: Int64
    let userSyncLogRelationBytes: Int64
    let userProjectionEffectsEstimatedRows: Int64
    let userProjectionEffectsRelationBytes: Int64
    let readyUserProjections: Int64
    let scheduledUserProjections: Int64
    let pausedUserProjections: Int64
    let maximumUserProjectionLag: Int64
    let buildingSnapshotArtifacts: Int64
    let failedSnapshotArtifacts: Int64
    let oldestBuildingSnapshotAgeSeconds: Int64
    let projectionVersionGCBacklogEstimatedRows: Int64
    let uncompactedProjectedRecords: Int64
    let pendingSyncRecordsAcrossDevices: Int64
    let resetPendingDevices: Int64
    let readyPushWakes: Int64
    let leasedPushWakes: Int64
    let suppressedPushWakes: Int64
    let pendingDeviceRevocationEvents: Int64
    let pendingRevokedDeviceProjectionCleanupEvents: Int64

    enum CodingKeys: String, CodingKey {
        case readyRoomOutboxRows = "ready_room_outbox_rows"
        case leasedRoomOutboxRows = "leased_room_outbox_rows"
        case scheduledRoomOutboxRows = "scheduled_room_outbox_rows"
        case pausedRoomOutboxRows = "paused_room_outbox_rows"
        case readyDirectProfileUpdates = "ready_direct_profile_updates"
        case leasedDirectProfileUpdates = "leased_direct_profile_updates"
        case readyReadReceiptPreferencePropagations = "ready_read_receipt_preference_propagations"
        case leasedReadReceiptPreferencePropagations = "leased_read_receipt_preference_propagations"
        case scheduledReadReceiptPreferencePropagations = "scheduled_read_receipt_preference_propagations"
        case pausedReadReceiptPreferencePropagations = "paused_read_receipt_preference_propagations"
        case openFanoutPlans = "open_fanout_plans"
        case readyFanoutDeliveries = "ready_fanout_deliveries"
        case leasedFanoutDeliveries = "leased_fanout_deliveries"
        case scheduledFanoutDeliveries = "scheduled_fanout_deliveries"
        case pausedFanoutDeliveries = "paused_fanout_deliveries"
        case oldestUnfinishedRoomOutboxAgeSeconds = "oldest_unfinished_room_outbox_age_seconds"
        case oldestUnfinishedFanoutDeliveryAgeSeconds = "oldest_unfinished_fanout_delivery_age_seconds"
        case terminalFanoutCompletionUnits = "terminal_fanout_completion_units"
        case oldestTerminalFanoutCompletionAgeSeconds = "oldest_terminal_fanout_completion_age_seconds"
        case readyContentReviews = "ready_content_reviews"
        case leasedContentReviews = "leased_content_reviews"
        case scheduledContentReviews = "scheduled_content_reviews"
        case pausedContentReviews = "paused_content_reviews"
        case readyMediaScans = "ready_media_scans"
        case leasedMediaScans = "leased_media_scans"
        case scheduledMediaScans = "scheduled_media_scans"
        case pausedMediaScans = "paused_media_scans"
        case readyMediaPurges = "ready_media_purges"
        case leasedMediaPurges = "leased_media_purges"
        case scheduledMediaPurges = "scheduled_media_purges"
        case pausedMediaPurges = "paused_media_purges"
        case userSyncLogEstimatedRows = "user_sync_log_estimated_rows"
        case userSyncLogRelationBytes = "user_sync_log_relation_bytes"
        case userProjectionEffectsEstimatedRows = "user_projection_effects_estimated_rows"
        case userProjectionEffectsRelationBytes = "user_projection_effects_relation_bytes"
        case readyUserProjections = "ready_user_projections"
        case scheduledUserProjections = "scheduled_user_projections"
        case pausedUserProjections = "paused_user_projections"
        case maximumUserProjectionLag = "maximum_user_projection_lag"
        case buildingSnapshotArtifacts = "building_snapshot_artifacts"
        case failedSnapshotArtifacts = "failed_snapshot_artifacts"
        case oldestBuildingSnapshotAgeSeconds = "oldest_building_snapshot_age_seconds"
        case projectionVersionGCBacklogEstimatedRows = "projection_version_gc_backlog_estimated_rows"
        case uncompactedProjectedRecords = "uncompacted_projected_records"
        case pendingSyncRecordsAcrossDevices = "pending_sync_records_across_devices"
        case resetPendingDevices = "reset_pending_devices"
        case readyPushWakes = "ready_push_wakes"
        case leasedPushWakes = "leased_push_wakes"
        case suppressedPushWakes = "suppressed_push_wakes"
        case pendingDeviceRevocationEvents = "pending_device_revocation_events"
        case pendingRevokedDeviceProjectionCleanupEvents = "pending_revoked_device_projection_cleanup_events"
    }
}

private struct UserShardDurableWorkMetricsRow: Decodable {
    let userSyncLogEstimatedRows: Int64
    let userSyncLogRelationBytes: Int64
    let userProjectionEffectsEstimatedRows: Int64
    let userProjectionEffectsRelationBytes: Int64
    let readyUserProjections: Int64
    let scheduledUserProjections: Int64
    let pausedUserProjections: Int64
    let maximumUserProjectionLag: Int64
    let buildingSnapshotArtifacts: Int64
    let failedSnapshotArtifacts: Int64
    let oldestBuildingSnapshotAgeSeconds: Int64
    let projectionVersionGCBacklogEstimatedRows: Int64
    let messageProjectionStatesEstimatedRows: Int64
    let messageProjectionStatesRelationBytes: Int64
    let messageProjectionReferenceEstimatedRows: Int64
    let messageProjectionBackfillEstimatedRows: Int64
    let messageProjectionInlinePayloadEstimatedRows: Int64
    let messageProjectionStateInlineBodyEstimatedRows: Int64
    let uncompactedProjectedRecords: Int64
    let pendingSyncRecordsAcrossDevices: Int64
    let resetPendingDevices: Int64

    enum CodingKeys: String, CodingKey {
        case userSyncLogEstimatedRows = "user_sync_log_estimated_rows"
        case userSyncLogRelationBytes = "user_sync_log_relation_bytes"
        case userProjectionEffectsEstimatedRows = "user_projection_effects_estimated_rows"
        case userProjectionEffectsRelationBytes = "user_projection_effects_relation_bytes"
        case readyUserProjections = "ready_user_projections"
        case scheduledUserProjections = "scheduled_user_projections"
        case pausedUserProjections = "paused_user_projections"
        case maximumUserProjectionLag = "maximum_user_projection_lag"
        case buildingSnapshotArtifacts = "building_snapshot_artifacts"
        case failedSnapshotArtifacts = "failed_snapshot_artifacts"
        case oldestBuildingSnapshotAgeSeconds = "oldest_building_snapshot_age_seconds"
        case projectionVersionGCBacklogEstimatedRows = "projection_version_gc_backlog_estimated_rows"
        case messageProjectionStatesEstimatedRows = "message_projection_states_estimated_rows"
        case messageProjectionStatesRelationBytes = "message_projection_states_relation_bytes"
        case messageProjectionReferenceEstimatedRows = "message_projection_reference_estimated_rows"
        case messageProjectionBackfillEstimatedRows = "message_projection_backfill_estimated_rows"
        case messageProjectionInlinePayloadEstimatedRows = "message_projection_inline_payload_estimated_rows"
        case messageProjectionStateInlineBodyEstimatedRows = "message_projection_state_inline_body_estimated_rows"
        case uncompactedProjectedRecords = "uncompacted_projected_records"
        case pendingSyncRecordsAcrossDevices = "pending_sync_records_across_devices"
        case resetPendingDevices = "reset_pending_devices"
    }
}

private func v2MetricCount(_ value: Int64) -> Int {
    guard value > 0 else { return 0 }
    return value > Int64(Int.max) ? Int.max : Int(value)
}
