import Foundation
import IMV2Core
import SQLKit

/// 自动低游标恢复与运维重置共用的原语。
///
/// 调用方必须在其事务内持有该设备游标行的锁；本原语假定该锁已生效，
/// 因此所有读取与写入都处于同一设备状态快照之下。
struct PostgresV2SnapshotResetStager {
    /// 暂存结果。
    struct Result: Sendable {
        /// 本次重置绑定的快照。
        let snapshotID: UUID
        /// 重置后的同步代次。
        let generation: Int64
        /// 快照基准序号。
        let baseSequence: Int64
    }

    /// 为设备暂存一次快照重置。
    ///
    /// 前置校验包括：代次为正、保留下限非负、能力生命周期为正的有限值、档位标识非空，
    /// 且存在一个处于就绪状态的投影检查点。
    /// 随后在用户与档位维度上串行创建产物：优先复用基准序号落在保留下限与检查点之间、
    /// 未过期且同档同版本的既有产物，并把其到期时间至少延长到本次分配的新截止点；
    /// 否则新建产物。最后写入设备重置记录、同步令牌并推进游标状态。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - schema: 目标 schema。
    ///   - userID: 目标用户。
    ///   - deviceID: 目标设备。
    ///   - currentGeneration: 当前同步代次，需大于零。
    ///   - retainedFloor: 可复用的最低基准序号。
    ///   - capabilityProfile: 能力档位标识。
    ///   - capabilityLifetime: 本次分配的存活时长秒数。
    ///   - now: 服务端统一授时时刻。
    ///   - makeUUID: 生成快照标识、令牌与回执的方式。
    /// - Returns: 本次暂存结果。
    /// - Throws: 分配截止点不可编码时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；检查点不可用、代次溢出、
    ///   保留下限高于检查点，或复用产物过期时抛出
    ///   ``V2SyncStoreError/snapshotCheckpointUnavailable``。
    static func stage(
        sql: any SQLDatabase,
        schema: String,
        userID: UUID,
        deviceID: UUID,
        currentGeneration: Int64,
        retainedFloor: Int64,
        capabilityProfile: String,
        capabilityLifetime: TimeInterval,
        now: Date,
        makeUUID: @Sendable () -> UUID
    ) async throws -> Result {
        guard let assignmentExpiresAt = v2PostgresFutureTimestamp(now: now, interval: capabilityLifetime) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard currentGeneration > 0,
              retainedFloor >= 0,
              capabilityLifetime.isFinite,
              capabilityLifetime > 0,
              !capabilityProfile.isEmpty,
              let checkpoint = try await sql.raw("""
                SELECT projected_sequence
                FROM \(unsafeRaw: table(schema, "user_projection_checkpoints"))
                WHERE user_id = \(bind: userID)
                  AND state = 'ready'
                """).first(decoding: SnapshotResetCheckpointRow.self)
        else { throw V2SyncStoreError.snapshotCheckpointUnavailable }
        let (generation, overflow) = currentGeneration.addingReportingOverflow(1)
        guard !overflow, generation > currentGeneration else {
            throw V2SyncStoreError.snapshotCheckpointUnavailable
        }

        let nextToken = makeUUID().uuidString
        let receipt = makeUUID().uuidString
        let checkpointBase = checkpoint.projectedSequence
        guard retainedFloor <= checkpointBase else {
            throw V2SyncStoreError.snapshotCheckpointUnavailable
        }
        // 串行化同一用户和配置的所有自动产物，不只针对精确检查点。
        // 仍有效且不低于保留下界的旧基准可服务新重连的设备；
        // 快照 ACK 后，常规增量同步会让设备追上最新状态。
        let artifactLock = "v2-snapshot-artifact:\(userID.uuidString):\(capabilityProfile)"
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: artifactLock), 0))").run()
        let artifact: SnapshotResetArtifactRow
        if let existing = try await sql.raw("""
            SELECT snapshot_id, base_user_sync_sequence, state
            FROM \(unsafeRaw: table(schema, "sync_snapshot_artifacts"))
            WHERE user_id = \(bind: userID)
              AND base_user_sync_sequence >= \(bind: retainedFloor)
              AND base_user_sync_sequence <= \(bind: checkpointBase)
              AND source_projected_sequence = base_user_sync_sequence
              AND schema_version = \(bind: Int32(V2SnapshotProjectionV3Codec.schemaVersion))
              AND capability_profile = \(bind: capabilityProfile)
              AND state IN ('building', 'published')
              AND expires_at > \(bind: now)
            ORDER BY base_user_sync_sequence DESC, created_at DESC
            LIMIT 1
            FOR UPDATE
            """).first(decoding: SnapshotResetArtifactRow.self) {
            // 迟到的设备应获得完整的能力有效期。共享不可变载荷至少要存活到
            // 最新分配到期，而不能沿用首台设备即将过期的截止时间。
            // 比较原生时间戳，避免 Date 解码隐藏延长操作，
            // 或将既有的较长截止时间向前舍入。
            try await sql.raw("""
                UPDATE \(unsafeRaw: table(schema, "sync_snapshot_artifacts"))
                SET expires_at = \(bind: assignmentExpiresAt)
                WHERE snapshot_id = \(bind: existing.snapshotID)
                  AND expires_at < \(bind: assignmentExpiresAt)
                """).run()
            artifact = existing
        } else {
            let snapshotID = makeUUID()
            let initialDigest = V2SnapshotV3Digest.initial(
                baseSequence: UInt64(checkpointBase), capabilityProfile: capabilityProfile
            )
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table(schema, "sync_snapshot_artifacts"))
                    (snapshot_id, user_id, base_user_sync_sequence,
                     source_projected_sequence, schema_version,
                     capability_profile, state, rolling_digest,
                     expires_at, created_at)
                VALUES (\(bind: snapshotID), \(bind: userID), \(bind: checkpointBase), \(bind: checkpointBase),
                        \(bind: Int32(V2SnapshotProjectionV3Codec.schemaVersion)),
                        \(bind: capabilityProfile), 'building', \(bind: initialDigest),
                        \(bind: assignmentExpiresAt), \(bind: now))
                """).run()
            artifact = .init(
                snapshotID: snapshotID,
                baseSequence: checkpointBase,
                state: "building"
            )
        }
        let resetState = artifact.state == "published" ? "ready" : "preparing"
        let cursorState = artifact.state == "published" ? "reset_pending" : "reset_preparing"
        let base = artifact.baseSequence
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: table(schema, "device_snapshot_resets"))
                (user_id, device_id, reset_generation, snapshot_id, state,
                 next_sync_token, snapshot_receipt, expires_at, created_at)
            VALUES (\(bind: userID), \(bind: deviceID), \(bind: generation),
                    \(bind: artifact.snapshotID), \(bind: resetState), \(bind: nextToken),
                    \(bind: receipt), \(bind: assignmentExpiresAt), \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: table(schema, "sync_tokens"))
                (token, user_id, device_id, reset_generation, watermark,
                 expires_at, created_at)
            VALUES (\(bind: nextToken), \(bind: userID), \(bind: deviceID),
                    \(bind: generation), \(bind: base), \(bind: assignmentExpiresAt), \(bind: now))
            """).run()
        try await sql.raw("""
            UPDATE \(unsafeRaw: table(schema, "device_sync_cursors"))
            SET state = \(bind: cursorState), reset_generation = \(bind: generation),
                pending_snapshot_id = \(bind: artifact.snapshotID),
                pending_base_sequence = \(bind: base),
                pending_snapshot_expires_at = \(bind: assignmentExpiresAt)
            WHERE user_id = \(bind: userID) AND device_id = \(bind: deviceID)
              AND state = 'ready' AND reset_generation = \(bind: currentGeneration)
            """).run()
        return .init(
            snapshotID: artifact.snapshotID, generation: generation, baseSequence: base
        )
    }

    /// 拼接 schema 限定的表名。
    ///
    /// - Parameters:
    ///   - schema: schema 名。
    ///   - name: 表名，仅允许来自代码内常量。
    /// - Returns: 形如 `schema.table` 的限定名。
    private static func table(_ schema: String, _ name: String) -> String {
        "\(schema).\(name)"
    }
}

private struct SnapshotResetArtifactRow: Decodable {
    let snapshotID: UUID
    let baseSequence: Int64
    let state: String
    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case baseSequence = "base_user_sync_sequence"
        case state
    }
}

private struct SnapshotResetCheckpointRow: Decodable {
    let projectedSequence: Int64
    enum CodingKeys: String, CodingKey {
        case projectedSequence = "projected_sequence"
    }
}
