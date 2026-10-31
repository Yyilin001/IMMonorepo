import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import SQLKit


/// PostgreSQL 侧的持久化工作指标来源。
///
/// 快照在抓取时直接查询，而不是由工作器计数器重建：这样进程重启后依然可见，
/// 告警也能区分「工作器空闲」与「持久化积压持续增长」。
public struct PostgresV2DurableWorkMetricsSource: V2DurableWorkMetricsSource {
    private let database: any Database
    private let gatewayNodeID: String?
    private let includesUserShardMetrics: Bool

    /// 构造指标来源。
    ///
    /// - Parameters:
    ///   - database: 执行指标查询的数据库。
    ///   - gatewayNodeID: 网关节点标识，用于统计本节点待处理的吊销事件。
    ///   - includesUserShardMetrics: 是否一并统计用户分片指标。
    ///
    /// 房间来源队列由独立指标来源统计，避免与控制库重复计数。
    public init(
        database: any Database,
        gatewayNodeID: String? = nil,
        includesUserShardMetrics: Bool = true
    ) {
        self.database = database
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
        // PostgreSQL 无法为 `NULL IS NULL` 中单独绑定的 NULL 推断类型。
        // 改为绑定显式的布尔作用域标记；节点绑定仍由它与文本列的比较确定类型。
        let includesGatewayRevocationMetrics = gatewayNodeID != nil
        let scopedGatewayNodeID = gatewayNodeID ?? ""
        guard let row = try await sql.raw("""
                WITH snapshot_now AS (
                    SELECT CURRENT_TIMESTAMP AS value
                ),
                profile_metrics AS (
                    SELECT
                        COUNT(*) FILTER (
                            WHERE state = 'pending'
                               OR (state = 'claimed' AND lease_expires_at <= snapshot_now.value)
                        ) AS ready_profile_security_invalidations,
                        COUNT(*) FILTER (
                            WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value
                        ) AS leased_profile_security_invalidations
                    FROM im_v2.profile_security_invalidation_outbox, snapshot_now
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
                FROM profile_metrics, read_receipt_preference_metrics,
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
            readyProfileSecurityInvalidations: v2MetricCount(row.readyProfileSecurityInvalidations),
            leasedProfileSecurityInvalidations: v2MetricCount(row.leasedProfileSecurityInvalidations),
            readyReadReceiptPreferencePropagations: v2MetricCount(row.readyReadReceiptPreferencePropagations),
            leasedReadReceiptPreferencePropagations: v2MetricCount(row.leasedReadReceiptPreferencePropagations),
            scheduledReadReceiptPreferencePropagations: v2MetricCount(row.scheduledReadReceiptPreferencePropagations),
            pausedReadReceiptPreferencePropagations: v2MetricCount(row.pausedReadReceiptPreferencePropagations),
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
            // PostgreSQL 不可用时，/metrics 仍可被抓取；
            // 可用性测量值是明确的告警信号。错误文本不能泄漏为指标标签或响应体。
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
                    pg_total_relation_size(\(bind: "\(schema).user_sync_log")::regclass)::BIGINT
                        AS user_sync_log_relation_bytes,
                    COALESCE((SELECT n_live_tup::BIGINT FROM pg_stat_user_tables
                              WHERE schemaname = \(bind: schema)
                                AND relname = 'user_projection_effects'), 0)::BIGINT
                        AS user_projection_effects_estimated_rows,
                    pg_total_relation_size(\(bind: "\(schema).user_projection_effects")::regclass)::BIGINT
                        AS user_projection_effects_relation_bytes
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
                ), 0)::BIGINT AS projection_version_gc_backlog_estimated_rows
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
            uncompactedProjectedRecords: v2MetricCount(row.uncompactedProjectedRecords),
            pendingSyncRecordsAcrossDevices: v2MetricCount(row.pendingSyncRecordsAcrossDevices),
            resetPendingDevices: v2MetricCount(row.resetPendingDevices)
        )
    }
}


public enum V2DurableWorkMetricsError: Error, Equatable, Sendable {
    case sqlUnavailable
    case emptyResult
}


private struct DurableWorkMetricsRow: Decodable {
    let readyProfileSecurityInvalidations: Int64
    let leasedProfileSecurityInvalidations: Int64
    let readyReadReceiptPreferencePropagations: Int64
    let leasedReadReceiptPreferencePropagations: Int64
    let scheduledReadReceiptPreferencePropagations: Int64
    let pausedReadReceiptPreferencePropagations: Int64
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
        case readyProfileSecurityInvalidations = "ready_profile_security_invalidations"
        case leasedProfileSecurityInvalidations = "leased_profile_security_invalidations"
        case readyReadReceiptPreferencePropagations = "ready_read_receipt_preference_propagations"
        case leasedReadReceiptPreferencePropagations = "leased_read_receipt_preference_propagations"
        case scheduledReadReceiptPreferencePropagations = "scheduled_read_receipt_preference_propagations"
        case pausedReadReceiptPreferencePropagations = "paused_read_receipt_preference_propagations"
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
        case uncompactedProjectedRecords = "uncompacted_projected_records"
        case pendingSyncRecordsAcrossDevices = "pending_sync_records_across_devices"
        case resetPendingDevices = "reset_pending_devices"
    }
}

private func v2MetricCount(_ value: Int64) -> Int {
    guard value > 0 else { return 0 }
    return value > Int64(Int.max) ? Int.max : Int(value)
}
