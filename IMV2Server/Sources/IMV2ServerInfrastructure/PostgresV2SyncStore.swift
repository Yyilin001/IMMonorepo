import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL 游标与重置栅栏。
///
/// 拉取与确认绝不信任客户端提供的序号超出设备游标的代次范围或持久化日志水位。
public struct PostgresV2SyncStore: V2SyncStore {
    private let database: any Database
    private let schema: String
    private let makeUUID: @Sendable () -> UUID
    private let capabilityLifetime: TimeInterval
    private let capabilityProfile: String
    /// 单个同步批次内编码后 `records` 重复字段的字节预算。
    ///
    /// 网关会把帧内其余字节留给信封、令牌、回执、代次与能力元数据。
    private let maximumEncodedRecordsBytes: Int

    /// 校验并保存数据库、schema 与批次预算。
    ///
    /// - Parameters:
    ///   - database: 存放设备游标与用户同步日志的数据库。
    ///   - schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///   - capabilityProfile: 能力档位标识，需非空。
    ///   - maximumEncodedRecordsBytes: 单批编码记录字节上限，需大于零。
    ///   - makeUUID: 令牌与回执标识生成方式。
    ///   - capabilityLifetime: 快照与令牌能力存活秒数，需大于零。
    ///
    /// 参数越界时直接失败，避免出现越界分页或非法 schema 拼接。
    public init(
        database: any Database,
        schema: String = "im_v2",
        capabilityProfile: String = "base",
        maximumEncodedRecordsBytes: Int = 48 * 1_024,
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        capabilityLifetime: TimeInterval = 86_400
    ) {
        precondition(
            capabilityLifetime > 0 &&
            !capabilityProfile.isEmpty &&
            maximumEncodedRecordsBytes > 0
        )
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
        self.makeUUID = makeUUID
        self.capabilityLifetime = capabilityLifetime
        self.capabilityProfile = capabilityProfile
        self.maximumEncodedRecordsBytes = maximumEncodedRecordsBytes
    }

    /// 拉取同步记录或要求设备重置。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - syncToken: 上次同步令牌。
    ///   - maxRecords: 本次最多返回的记录数。
    ///   - requireSnapshot: 是否要求以快照方式同步。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 拉取结果。
    /// - Throws: 设备已吊销、令牌非法或持久化失败时抛出。
    public func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool = false, now: Date) async throws -> V2SyncPullResult {
        guard maxRecords > 0, maxRecords < Int.max else { throw V2SyncStoreError.invalidRecordLimit }
        guard v2PostgresTimestampCanEncode(now) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let metadata = try await preparePullCursor(sql: sql, userID: userUUID, deviceID: deviceUUID)
            let cursor = metadata.cursor
            if cursor.state == "reset_preparing" {
                guard let snapshotID = cursor.pendingSnapshotID else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return .resetPreparing(
                    snapshotID: try SnapshotID(snapshotID.uuidString),
                    generation: try unsigned(cursor.resetGeneration),
                    retryAfter: 1
                )
            }
            if cursor.state == "reset_pending" {
                guard let snapshotID = cursor.pendingSnapshotID,
                      let base = cursor.pendingBaseSequence,
                      let snapshot = try await sql.raw("""
                    SELECT LEAST(artifact.expires_at, reset.expires_at) AS expires_at
                    FROM \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                    JOIN \(unsafeRaw: table("device_snapshot_resets")) AS reset
                      ON reset.snapshot_id = artifact.snapshot_id
                    WHERE artifact.snapshot_id = \(bind: snapshotID) AND artifact.user_id = \(bind: userUUID)
                      AND reset.user_id = \(bind: userUUID) AND reset.device_id = \(bind: deviceUUID)
                      AND reset.reset_generation = \(bind: cursor.resetGeneration)
                      AND artifact.state = 'published' AND reset.state = 'ready'
                    """).first(decoding: SnapshotMetadataRow.self)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                guard v2PostgresTimestampCanEncode(snapshot.expiresAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return .resetRequired(
                    snapshotID: try SnapshotID(snapshotID.uuidString),
                    generation: try unsigned(cursor.resetGeneration),
                    baseSequence: try unsigned(base),
                    expiresAt: snapshot.expiresAt
                )
            }
            guard cursor.state == "ready" else { throw V2RoomWriteStoreError.corruptPersistenceState }
            // 待处理的重置只报告其既有分配。
            // 签发能力或暂存重置时须设置新的截止时间。
            guard let expiresAt = v2PostgresFutureTimestamp(now: now, interval: capabilityLifetime) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let generation = try unsigned(cursor.resetGeneration)
            let startSequence: Int64
            if let syncToken, !requireSnapshot {
                guard let issued = try await sql.raw("""
                    SELECT watermark FROM \(unsafeRaw: table("sync_tokens"))
                    WHERE token = \(bind: syncToken.rawValue) AND user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                      AND reset_generation = \(bind: cursor.resetGeneration) AND expires_at > \(bind: now)
                    """).first(decoding: SyncTokenRow.self)
                else { throw V2SyncStoreError.invalidOrExpiredSyncToken }
                startSequence = issued.watermark
            } else {
                startSequence = cursor.acknowledgedSequence
            }
            let retainedFloor = metadata.retainedFloor
            if requireSnapshot {
                // 空账号没有同步日志触发器来初始化检查点。
                // 首个事件前基准值为零有效；已确认的非零游标
                // 由下方的压缩下界保护。
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: table("user_projection_checkpoints")) (user_id, projected_sequence, updated_at)
                    SELECT \(bind: userUUID), 0, \(bind: now)
                    WHERE NOT EXISTS (SELECT 1 FROM \(unsafeRaw: table("user_sync_sequences")) WHERE user_id = \(bind: userUUID) AND next_sequence > 0)
                    ON CONFLICT (user_id) DO NOTHING
                    """).run()
            }
            if requireSnapshot || startSequence < retainedFloor {
                let reset = try await PostgresV2SnapshotResetStager.stage(
                    sql: sql, schema: schema,
                    userID: userUUID, deviceID: deviceUUID,
                    currentGeneration: cursor.resetGeneration,
                    retainedFloor: requireSnapshot ? max(retainedFloor, cursor.acknowledgedSequence) : retainedFloor,
                    capabilityProfile: capabilityProfile,
                    capabilityLifetime: capabilityLifetime,
                    now: now, makeUUID: makeUUID
                )
                return .resetPreparing(
                    snapshotID: try SnapshotID(reset.snapshotID.uuidString),
                    generation: try unsigned(reset.generation), retryAfter: 1
                )
            }
            let rows = try await sql.raw("""
                SELECT log.user_sync_sequence, log.source_event_id, log.projection_kind,
                       log.payload::text AS payload_json
                FROM \(unsafeRaw: table("user_sync_log")) AS log
                WHERE log.user_id = \(bind: userUUID) AND log.user_sync_sequence > \(bind: startSequence)
                ORDER BY log.user_sync_sequence LIMIT \(bind: maxRecords + 1)
                """).all(decoding: SyncLogRow.self)
            let candidates = try rows.prefix(maxRecords).map {
                try V2SyncRecord(sequence: try unsigned($0.sequence), sourceEventID: try EventID($0.sourceEventID.uuidString), projectionKind: $0.projectionKind, payloadJSON: $0.payloadJSON)
            }
            var records: [V2SyncRecord] = []
            records.reserveCapacity(candidates.count)
            var encodedRecordsBytes = 0
            var previousSequence = startSequence
            for candidate in candidates {
                let candidateBytes = v2EncodedSyncBatchRecordFieldBytes(candidate)
                guard candidateBytes <= maximumEncodedRecordsBytes else {
                    // 保留可发送的前缀。超大的记录留在下一页开头，不能跳过。
                    guard !records.isEmpty else { throw V2SyncStoreError.syncRecordTooLarge }
                    break
                }
                guard encodedRecordsBytes <= maximumEncodedRecordsBytes - candidateBytes else {
                    break
                }
                // 签发能力前校验返回的整个前缀。
                // 尚未发送的预读记录属于后续拉取。
                let (expectedSequence, overflow) = previousSequence.addingReportingOverflow(1)
                guard !overflow, expectedSequence > 0,
                      candidate.sequence == UInt64(expectedSequence) else {
                    throw V2SyncStoreError.syncLogSequenceGap
                }
                records.append(candidate)
                encodedRecordsBytes += candidateBytes
                previousSequence = expectedSequence
            }
            let hasMore = rows.count > records.count
            let lastSequence = try records.last.map { try signed($0.sequence) } ?? startSequence
            let firstSequence = try records.first.map { try signed($0.sequence) } ?? startSequence
            let nextToken = try V2SyncToken(makeUUID().uuidString)
            let receipt = try V2SyncReceipt(makeUUID().uuidString)
            try await sql.raw("""
                WITH issued_token AS (
                    INSERT INTO \(unsafeRaw: table("sync_tokens"))
                        (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
                    VALUES (\(bind: nextToken.rawValue), \(bind: userUUID), \(bind: deviceUUID),
                            \(bind: cursor.resetGeneration), \(bind: lastSequence), \(bind: expiresAt), \(bind: now))
                    RETURNING 1
                )
                INSERT INTO \(unsafeRaw: table("sync_receipts"))
                    (receipt, user_id, device_id, reset_generation, first_sequence,
                     last_sequence, expires_at, created_at)
                SELECT \(bind: receipt.rawValue), \(bind: userUUID), \(bind: deviceUUID),
                       \(bind: cursor.resetGeneration), \(bind: firstSequence),
                       \(bind: lastSequence), \(bind: expiresAt), \(bind: now)
                FROM issued_token
                """).run()
            return .ready(generation: generation, records: records, nextSyncToken: nextToken, receipt: receipt, hasMore: hasMore)
        }
    }

    /// 确认已连续处理的最高序号。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - generation: 同步代次。
    ///   - highestContiguousSequence: 已连续处理的最高序号。
    ///   - receipt: 本次确认回执。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 序号超出水印、设备已吊销或持久化失败时抛出。
    public func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let generation = try signed(generation)
        let sequence = try signed(highestContiguousSequence)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await prepareActiveCursor(sql: sql, userID: userUUID, deviceID: deviceUUID)
            guard let cursorAndReceipt = try await sql.raw("""
                SELECT cursor.state, cursor.reset_generation, cursor.acknowledged_sequence,
                       cursor.pending_snapshot_id, cursor.pending_base_sequence,
                       cursor.completed_snapshot_id, cursor.completed_snapshot_ack_receipt,
                       cursor.completed_snapshot_generation,
                       cursor.completed_snapshot_base_sequence,
                       receipt.first_sequence, receipt.last_sequence
                FROM \(unsafeRaw: table("device_sync_cursors")) AS cursor
                LEFT JOIN \(unsafeRaw: table("sync_receipts")) AS receipt
                  ON receipt.receipt = \(bind: receipt.rawValue)
                 AND receipt.user_id = cursor.user_id
                 AND receipt.device_id = cursor.device_id
                 AND receipt.reset_generation = \(bind: generation)
                 AND receipt.expires_at > \(bind: now)
                WHERE cursor.user_id = \(bind: userUUID)
                  AND cursor.device_id = \(bind: deviceUUID)
                FOR UPDATE OF cursor
                """).first(decoding: DeviceCursorAndReceiptRow.self)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let cursor = cursorAndReceipt.cursor
            guard let firstSequence = cursorAndReceipt.firstSequence,
                let lastSequence = cursorAndReceipt.lastSequence,
                sequence >= firstSequence, sequence <= lastSequence,
                sequence >= cursor.acknowledgedSequence
            else { throw V2SyncStoreError.invalidOrExpiredSyncReceipt }
            let nextGeneration = generation.addingReportingOverflow(1)
            let matchesReadyGeneration = cursor.state == "ready" && cursor.resetGeneration == generation
            let matchesImmediatelyPreResetGeneration =
                cursor.state != "ready" &&
                !nextGeneration.overflow &&
                cursor.resetGeneration == nextGeneration.partialValue &&
                (cursor.pendingBaseSequence ?? -1) >= sequence
            guard matchesReadyGeneration || matchesImmediatelyPreResetGeneration else {
                if cursor.state == "ready" { throw V2SyncStoreError.generationMismatch }
                throw V2SyncStoreError.resetRequired
            }
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_sync_cursors"))
                SET acknowledged_sequence = GREATEST(acknowledged_sequence, \(bind: sequence))
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).run()
        }
    }

    /// 读取快照清单。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 快照清单。
    /// - Throws: 快照不存在、代次不符或持久化失败时抛出。
    public func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest {
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let snapshotUUID = try uuid(snapshotID)
        let generation = try signed(generation)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await lockActiveDevice(sql: sql, userID: userUUID, deviceID: deviceUUID)
            guard let cursor = try await fetchCursor(sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true),
                  cursor.state == "reset_pending", cursor.resetGeneration == generation, cursor.pendingSnapshotID == snapshotUUID,
                  let manifest = try await sql.raw("""
                    SELECT artifact.base_user_sync_sequence, artifact.root_digest, artifact.schema_version,
                           artifact.capability_profile, artifact.page_count, artifact.item_count,
                           artifact.total_bytes, reset.next_sync_token, reset.snapshot_receipt,
                           LEAST(artifact.expires_at, reset.expires_at) AS expires_at
                    FROM \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                    JOIN \(unsafeRaw: table("device_snapshot_resets")) AS reset
                      ON reset.snapshot_id = artifact.snapshot_id
                    WHERE artifact.snapshot_id = \(bind: snapshotUUID) AND artifact.user_id = \(bind: userUUID)
                      AND reset.user_id = \(bind: userUUID) AND reset.device_id = \(bind: deviceUUID)
                      AND reset.reset_generation = \(bind: generation)
                      AND artifact.state = 'published' AND reset.state = 'ready'
                      AND artifact.expires_at > \(bind: now) AND reset.expires_at > \(bind: now)
                    """).first(decoding: SnapshotManifestRow.self)
            else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
            guard v2PostgresTimestampCanEncode(manifest.expiresAt) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return try .init(
                snapshotID: snapshotID,
                generation: unsigned(generation),
                baseSequence: unsigned(manifest.baseSequence),
                rootDigest: manifest.rootDigest,
                schemaVersion: UInt32(manifest.schemaVersion),
                capabilityProfile: manifest.capabilityProfile,
                pageCount: UInt32(manifest.pageCount),
                totalItems: unsigned(manifest.itemCount),
                totalBytes: unsigned(manifest.totalBytes),
                nextSyncToken: .init(manifest.nextSyncToken),
                receipt: .init(manifest.receipt),
                expiresAt: manifest.expiresAt
            )
        }
    }

    /// 读取快照分页。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - rootDigest: 期望的根摘要。
    ///   - index: 页序号。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 快照分页。
    /// - Throws: 页面不存在、摘要不符或持久化失败时抛出。
    public func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage {
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let snapshotUUID = try uuid(snapshotID)
        let generation = try signed(generation)
        guard let index = Int(exactly: index) else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await lockActiveDevice(sql: sql, userID: userUUID, deviceID: deviceUUID)
            guard let cursor = try await fetchCursor(sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true),
                  cursor.state == "reset_pending", cursor.resetGeneration == generation, cursor.pendingSnapshotID == snapshotUUID,
                  let page = try await sql.raw("""
                    SELECT page.first_projection_kind, page.first_entity_key,
                           page.last_projection_kind, page.last_entity_key,
                           page.item_count, page.page_digest, page.payload
                    FROM \(unsafeRaw: table("sync_snapshot_pages")) AS page
                    JOIN \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                      ON artifact.snapshot_id = page.snapshot_id
                    JOIN \(unsafeRaw: table("device_snapshot_resets")) AS reset
                      ON reset.snapshot_id = artifact.snapshot_id
                    WHERE page.snapshot_id = \(bind: snapshotUUID) AND page.page_index = \(bind: index)
                      AND artifact.user_id = \(bind: userUUID) AND artifact.root_digest = \(bind: rootDigest)
                      AND artifact.state = 'published' AND artifact.expires_at > \(bind: now)
                      AND reset.user_id = \(bind: userUUID) AND reset.device_id = \(bind: deviceUUID)
                      AND reset.reset_generation = \(bind: generation) AND reset.state = 'ready'
                      AND reset.expires_at > \(bind: now)
                    """).first(decoding: SnapshotPageRow.self)
            else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
            return try .init(
                snapshotID: snapshotID, generation: unsigned(generation), rootDigest: rootDigest,
                index: UInt32(index),
                firstKey: .init(projectionKind: page.firstProjectionKind, entityKey: page.firstEntityKey),
                lastKey: .init(projectionKind: page.lastProjectionKind, entityKey: page.lastEntityKey),
                itemCount: UInt32(page.itemCount), digest: page.digest, payload: page.payload
            )
        }
    }

    /// 确认快照已接收完成。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - baseSequence: 快照基准序号。
    ///   - receipt: 本次确认回执。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 代次或基准序号不符、设备已吊销或持久化失败时抛出。
    public func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let userUUID = try uuid(userID)
        let deviceUUID = try uuid(deviceID)
        let snapshotUUID = try uuid(snapshotID)
        let generation = try signed(generation)
        let base = try signed(baseSequence)
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await lockActiveDevice(sql: sql, userID: userUUID, deviceID: deviceUUID)
            guard let cursor = try await fetchCursor(
                sql: sql, userID: userUUID, deviceID: deviceUUID, lock: true
            ) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if cursor.completedSnapshotID == snapshotUUID,
               cursor.completedSnapshotAckReceipt == receipt.rawValue,
               cursor.completedSnapshotGeneration == generation,
               cursor.completedSnapshotBaseSequence == base
            {
                // 首次 ACK 已提交代次围栏。精确重放已认证的 ACK
                // 可直接视为成功，无须再次移动游标。即使运维操作已暂存下一代次，
                // 这一规则仍成立：客户端可能在服务端首次提交后、
                // 本地影子状态激活前崩溃。
                return
            }
            guard cursor.state == "reset_pending" else { throw V2SyncStoreError.noResetPending }
            guard cursor.resetGeneration == generation,
                  cursor.pendingSnapshotID == snapshotUUID,
                  cursor.pendingBaseSequence == base
            else { throw V2SyncStoreError.snapshotFenceMismatch }
            guard let snapshot = try await sql.raw("""
                SELECT artifact.snapshot_id
                FROM \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                JOIN \(unsafeRaw: table("device_snapshot_resets")) AS reset
                  ON reset.snapshot_id = artifact.snapshot_id
                WHERE artifact.snapshot_id = \(bind: snapshotUUID) AND artifact.user_id = \(bind: userUUID)
                  AND artifact.base_user_sync_sequence = \(bind: base) AND artifact.state = 'published'
                  AND reset.user_id = \(bind: userUUID) AND reset.device_id = \(bind: deviceUUID)
                  AND reset.reset_generation = \(bind: generation)
                  AND reset.snapshot_receipt = \(bind: receipt.rawValue) AND reset.state = 'ready'
                  AND artifact.expires_at > \(bind: now) AND reset.expires_at > \(bind: now)
                FOR UPDATE OF reset
                """).first(decoding: SnapshotIDRow.self)
            else { throw V2SyncStoreError.snapshotExpiredOrInvalid }
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_snapshot_resets"))
                SET state = 'acknowledged', acknowledged_at = \(bind: now)
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                  AND reset_generation = \(bind: generation) AND snapshot_id = \(bind: snapshot.snapshotID)
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_sync_cursors"))
                SET state = 'ready', acknowledged_sequence = \(bind: base),
                    pending_snapshot_id = NULL, pending_base_sequence = NULL, pending_snapshot_expires_at = NULL,
                    completed_snapshot_id = \(bind: snapshotUUID), completed_snapshot_ack_receipt = \(bind: receipt.rawValue),
                    completed_snapshot_generation = \(bind: generation), completed_snapshot_base_sequence = \(bind: base)
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).run()
        }
    }

    /// Advisory waiting must end before establishing the authority snapshot. A CTE
    /// dependency orders execution, but cannot refresh a statement's MVCC snapshot.
    private func lockDevice(sql: any SQLDatabase, userID: UUID, deviceID: UUID) async throws {
        try await sql.raw("""
            SELECT pg_advisory_xact_lock(hashtextextended(
                CONCAT(\(bind: userID), ':', \(bind: deviceID)), 684927
            ))
            """).run()
    }

    private func preparePullCursor(
        sql: any SQLDatabase, userID: UUID, deviceID: UUID
    ) async throws -> (cursor: DeviceCursorRow, retainedFloor: Int64) {
        try await lockDevice(sql: sql, userID: userID, deviceID: deviceID)
        // Existing rows are actually locked. Newly inserted rows are returned by
        // the modifying CTE, never read back from its older statement snapshot.
        // The device advisory lock serializes every supported cursor creator.
        guard let row = try await sql.raw("""
            WITH active AS MATERIALIZED (
                SELECT NOT EXISTS (
                    SELECT 1 FROM \(unsafeRaw: table("revoked_device_projection_tombstones"))
                    WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)
                ) AS is_active
            ), existing AS MATERIALIZED (
                SELECT cursor.* FROM \(unsafeRaw: table("device_sync_cursors")) AS cursor
                CROSS JOIN active
                WHERE cursor.user_id = \(bind: userID) AND cursor.device_id = \(bind: deviceID)
                  AND active.is_active
                FOR UPDATE OF cursor
            ), inserted AS (
                INSERT INTO \(unsafeRaw: table("device_sync_cursors"))
                    (user_id, device_id, state, reset_generation)
                SELECT \(bind: userID), \(bind: deviceID), 'ready', 1 FROM active
                WHERE is_active AND NOT EXISTS (SELECT 1 FROM existing)
                ON CONFLICT (user_id, device_id) DO NOTHING
                RETURNING *
            ), selected AS MATERIALIZED (
                SELECT * FROM existing UNION ALL SELECT * FROM inserted
            ), cursor_barrier AS MATERIALIZED (
                SELECT count(*) AS cursor_count, bool_and(state = 'ready') AS is_ready FROM selected
            ), retention AS MATERIALIZED (
                SELECT retained.compacted_through_sequence
                FROM \(unsafeRaw: table("user_sync_retention")) AS retained
                CROSS JOIN cursor_barrier
                WHERE retained.user_id = \(bind: userID) AND cursor_barrier.cursor_count = 1
                  AND cursor_barrier.is_ready
                FOR SHARE OF retained
            )
            SELECT active.is_active, cursor_barrier.cursor_count, selected.*,
                   COALESCE(retention.compacted_through_sequence, 0) AS retained_floor
            FROM active CROSS JOIN cursor_barrier
            LEFT JOIN selected ON TRUE LEFT JOIN retention ON TRUE
            """).first()
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard try row.decode(column: "is_active", as: Bool.self) else {
            throw V2SyncStoreError.deviceRevoked
        }
        guard try row.decode(column: "cursor_count", as: Int64.self) == 1 else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return (try row.decode(model: DeviceCursorRow.self),
                try row.decode(column: "retained_floor", as: Int64.self))
    }

    private func prepareActiveCursor(
        sql: any SQLDatabase,
        userID: UUID,
        deviceID: UUID
    ) async throws {
        try await lockDevice(sql: sql, userID: userID, deviceID: deviceID)
        guard let active = try await sql.raw("""
            WITH active AS MATERIALIZED (
                SELECT NOT EXISTS (
                    SELECT 1
                    FROM \(unsafeRaw: table("revoked_device_projection_tombstones"))
                    WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)
                ) AS is_active
            ), inserted AS (
                INSERT INTO \(unsafeRaw: table("device_sync_cursors"))
                    (user_id, device_id, state, reset_generation)
                SELECT \(bind: userID), \(bind: deviceID), 'ready', 1
                FROM active WHERE is_active
                ON CONFLICT (user_id, device_id) DO NOTHING
                RETURNING 1
            )
            SELECT is_active FROM active
            """).first(decoding: ActiveDeviceRow.self)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard active.isActive else { throw V2SyncStoreError.deviceRevoked }
    }

    /// 使游标创建与变更同异步吊销清理串行化。
    ///
    /// 一旦单调墓碑提交，任何在途或重试的同步请求都无法重新创建该设备的私有状态。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - userID: 目标用户。
    ///   - deviceID: 目标设备。
    /// - Throws: 设备已吊销时抛出 ``V2SyncStoreError/deviceRevoked``；
    ///   记录异常时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
    private func lockActiveDevice(
        sql: any SQLDatabase,
        userID: UUID,
        deviceID: UUID
    ) async throws {
        try await lockDevice(sql: sql, userID: userID, deviceID: deviceID)
        guard let active = try await sql.raw("""
            SELECT NOT EXISTS (
                SELECT 1
                FROM \(unsafeRaw: table("revoked_device_projection_tombstones"))
                WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)
            ) AS is_active
            """).first(decoding: ActiveDeviceRow.self)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard active.isActive else { throw V2SyncStoreError.deviceRevoked }
    }

    private func fetchCursor(sql: any SQLDatabase, userID: UUID, deviceID: UUID, lock: Bool) async throws -> DeviceCursorRow? {
        let suffix = lock ? " FOR UPDATE" : ""
        return try await sql.raw("""
            SELECT state, reset_generation, acknowledged_sequence, pending_snapshot_id, pending_base_sequence,
                   completed_snapshot_id, completed_snapshot_ack_receipt,
                   completed_snapshot_generation, completed_snapshot_base_sequence
            FROM \(unsafeRaw: table("device_sync_cursors"))
            WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)\(unsafeRaw: suffix)
            """).first(decoding: DeviceCursorRow.self)
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}


/// 计算单个 `IMV2SyncBatch.records` 重复字段的精确 protobuf 线路字节数。
///
/// 把该估算与游标推进放在一起，可避免已签发的令牌跳过后被传输边界裁剪掉的记录。
///
/// - Parameter record: 待估算的同步记录。
/// - Returns: 该记录编码后的字节数。
func v2EncodedSyncBatchRecordFieldBytes(_ record: V2SyncRecord) -> Int {
    let sequenceBytes = 1 + v2ProtobufVarintBytes(record.sequence)
    let sourceEventBytes = v2ProtobufLengthDelimitedBytes(record.sourceEventID.rawValue.utf8.count)
    let projectionKindBytes = v2ProtobufLengthDelimitedBytes(record.projectionKind.utf8.count)
    let payloadBytes = v2ProtobufLengthDelimitedBytes(record.payloadJSON.utf8.count)
    let recordBytes = sequenceBytes + sourceEventBytes + projectionKindBytes + payloadBytes
    return 1 + v2ProtobufVarintBytes(UInt64(recordBytes)) + recordBytes
}

private func v2ProtobufLengthDelimitedBytes(_ payloadBytes: Int) -> Int {
    1 + v2ProtobufVarintBytes(UInt64(payloadBytes)) + payloadBytes
}

private func v2ProtobufVarintBytes(_ value: UInt64) -> Int {
    var remaining = value
    var count = 1
    while remaining >= 0x80 {
        remaining >>= 7
        count += 1
    }
    return count
}

private struct DeviceCursorRow: Decodable {
    let state: String; let resetGeneration: Int64; let acknowledgedSequence: Int64; let pendingSnapshotID: UUID?; let pendingBaseSequence: Int64?; let completedSnapshotID: UUID?; let completedSnapshotAckReceipt: String?; let completedSnapshotGeneration: Int64?; let completedSnapshotBaseSequence: Int64?
    enum CodingKeys: String, CodingKey {
        case state, resetGeneration = "reset_generation", acknowledgedSequence = "acknowledged_sequence"
        case pendingSnapshotID = "pending_snapshot_id", pendingBaseSequence = "pending_base_sequence"
        case completedSnapshotID = "completed_snapshot_id", completedSnapshotAckReceipt = "completed_snapshot_ack_receipt"
        case completedSnapshotGeneration = "completed_snapshot_generation", completedSnapshotBaseSequence = "completed_snapshot_base_sequence"
    }
}
private struct DeviceCursorAndReceiptRow: Decodable {
    let state: String
    let resetGeneration: Int64
    let acknowledgedSequence: Int64
    let pendingSnapshotID: UUID?
    let pendingBaseSequence: Int64?
    let completedSnapshotID: UUID?
    let completedSnapshotAckReceipt: String?
    let completedSnapshotGeneration: Int64?
    let completedSnapshotBaseSequence: Int64?
    let firstSequence: Int64?
    let lastSequence: Int64?

    var cursor: DeviceCursorRow {
        .init(
            state: state,
            resetGeneration: resetGeneration,
            acknowledgedSequence: acknowledgedSequence,
            pendingSnapshotID: pendingSnapshotID,
            pendingBaseSequence: pendingBaseSequence,
            completedSnapshotID: completedSnapshotID,
            completedSnapshotAckReceipt: completedSnapshotAckReceipt,
            completedSnapshotGeneration: completedSnapshotGeneration,
            completedSnapshotBaseSequence: completedSnapshotBaseSequence
        )
    }

    enum CodingKeys: String, CodingKey {
        case state
        case resetGeneration = "reset_generation"
        case acknowledgedSequence = "acknowledged_sequence"
        case pendingSnapshotID = "pending_snapshot_id"
        case pendingBaseSequence = "pending_base_sequence"
        case completedSnapshotID = "completed_snapshot_id"
        case completedSnapshotAckReceipt = "completed_snapshot_ack_receipt"
        case completedSnapshotGeneration = "completed_snapshot_generation"
        case completedSnapshotBaseSequence = "completed_snapshot_base_sequence"
        case firstSequence = "first_sequence"
        case lastSequence = "last_sequence"
    }
}
private struct ActiveDeviceRow: Decodable {
    let isActive: Bool
    enum CodingKeys: String, CodingKey { case isActive = "is_active" }
}
private struct SyncLogRow: Decodable {
    let sequence: Int64; let sourceEventID: UUID; let projectionKind: String; let payloadJSON: String
    enum CodingKeys: String, CodingKey { case sequence = "user_sync_sequence", sourceEventID = "source_event_id", projectionKind = "projection_kind", payloadJSON = "payload_json" }
}
private struct SyncTokenRow: Decodable { let watermark: Int64 }
private struct SnapshotMetadataRow: Decodable {
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
}
private struct SnapshotManifestRow: Decodable {
    let baseSequence: Int64
    let rootDigest: String
    let schemaVersion: Int32
    let capabilityProfile: String
    let pageCount: Int32
    let itemCount: Int64
    let totalBytes: Int64
    let nextSyncToken: String
    let receipt: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case baseSequence = "base_user_sync_sequence"
        case rootDigest = "root_digest"
        case schemaVersion = "schema_version"
        case capabilityProfile = "capability_profile"
        case pageCount = "page_count"
        case itemCount = "item_count"
        case totalBytes = "total_bytes"
        case nextSyncToken = "next_sync_token"
        case receipt = "snapshot_receipt"
        case expiresAt = "expires_at"
    }
}
private struct SnapshotPageRow: Decodable {
    let firstProjectionKind: String
    let firstEntityKey: String
    let lastProjectionKind: String
    let lastEntityKey: String
    let itemCount: Int32
    let digest: String
    let payload: Data
    enum CodingKeys: String, CodingKey {
        case firstProjectionKind = "first_projection_kind"
        case firstEntityKey = "first_entity_key"
        case lastProjectionKind = "last_projection_kind"
        case lastEntityKey = "last_entity_key"
        case itemCount = "item_count"
        case digest = "page_digest"
        case payload
    }
}
private struct SnapshotIDRow: Decodable { let snapshotID: UUID; enum CodingKeys: String, CodingKey { case snapshotID = "snapshot_id" } }

private func uuid<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}
private func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}
private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
