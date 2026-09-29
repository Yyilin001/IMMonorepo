import IMV2ServerContracts
import Foundation
import Synchronization

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
        // 保持服务端时钟的可用性契约，同时不让墙上时钟校正
        // 改变缓存或回退数据的已流逝时长。
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
                // 不能把无法表示的数据年龄钳制到零或任意最大值，
                // 从而将过期数据伪装为新鲜数据。
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
            // 恢复可能落在旧缓存的有效间隔内。此时强制重新刷新，
            // 不在故障后继续展示较早的成功值。
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
                try await v2Sleep(for: timeout)
                race.resolve(.timedOut)
            } catch {
                // 数据源先完成，并取消了此计时器。
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
        readyUserStateEventRows: sum(\.readyUserStateEventRows),
        leasedUserStateEventRows: sum(\.leasedUserStateEventRows),
        scheduledUserStateEventRows: sum(\.scheduledUserStateEventRows),
        pausedUserStateEventRows: sum(\.pausedUserStateEventRows),
        oldestUnfinishedUserStateEventAgeSeconds: maximum(\.oldestUnfinishedUserStateEventAgeSeconds),
        readyDirectProfileUpdates: sum(\.readyDirectProfileUpdates),
        leasedDirectProfileUpdates: sum(\.leasedDirectProfileUpdates),
        readyReadReceiptPreferencePropagations: sum(\.readyReadReceiptPreferencePropagations),
        leasedReadReceiptPreferencePropagations: sum(\.leasedReadReceiptPreferencePropagations),
        scheduledReadReceiptPreferencePropagations: sum(\.scheduledReadReceiptPreferencePropagations),
        pausedReadReceiptPreferencePropagations: sum(\.pausedReadReceiptPreferencePropagations),
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
        "# HELP im_v2_user_state_event_backlog Durable personal event rows across configured source databases.",
        "# TYPE im_v2_user_state_event_backlog gauge",
        "im_v2_user_state_event_backlog{state=\"ready\"} \(snapshot.readyUserStateEventRows)",
        "im_v2_user_state_event_backlog{state=\"leased\"} \(snapshot.leasedUserStateEventRows)",
        "im_v2_user_state_event_backlog{state=\"scheduled\"} \(snapshot.scheduledUserStateEventRows)",
        "im_v2_user_state_event_backlog{state=\"paused\"} \(snapshot.pausedUserStateEventRows)",
        "# HELP im_v2_user_state_event_oldest_unfinished_age_seconds Age of the oldest personal event awaiting completion.",
        "# TYPE im_v2_user_state_event_oldest_unfinished_age_seconds gauge",
        "im_v2_user_state_event_oldest_unfinished_age_seconds \(snapshot.oldestUnfinishedUserStateEventAgeSeconds)",
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
        "# HELP im_v2_message_projection_states_estimated_rows PostgreSQL planner estimate of immutable room message states.",
        "# TYPE im_v2_message_projection_states_estimated_rows gauge",
        "im_v2_message_projection_states_estimated_rows \(snapshot.messageProjectionStatesEstimatedRows)",
        "# HELP im_v2_message_projection_states_relation_bytes Heap, indexes, and TOAST bytes retained by immutable room message states.",
        "# TYPE im_v2_message_projection_states_relation_bytes gauge",
        "im_v2_message_projection_states_relation_bytes \(snapshot.messageProjectionStatesRelationBytes)",
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
