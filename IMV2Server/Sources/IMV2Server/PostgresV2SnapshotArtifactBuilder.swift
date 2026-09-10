import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 单轮快照产物构建报告。
public struct V2SnapshotArtifactBuildReport: Equatable, Sendable {
    /// 本轮是否成功认领到一个构建任务。
    public let claimed: Bool
    /// 本轮是否发布了完整产物。
    public let published: Bool
    /// 产物包含的页数。
    public let pageCount: UInt32
    /// 产物包含的条目数。
    public let itemCount: UInt64
}

/// 可续传的快照 V3 构建器。
///
/// 每次迭代最多在内存中保留一份有界查询结果与一个已编码页面，
/// 并在写入页面字节的同一事务内提交其键集游标，因此进程中断后可以从游标处继续。
public struct PostgresV2SnapshotArtifactBuilder: Sendable {
    private let database: any Database
    private let schema: String
    private let pageItemLimit: Int
    private let maximumCandidateItems: Int
    private let leaseDuration: TimeInterval
    private let messageReadMode: V2MessageProjectionReadMode
    private let makeUUID: @Sendable () -> UUID

    /// 校验并保存数据库、schema 与分页参数。
    ///
    /// - Parameters:
    ///   - database: 存放投影状态与快照产物的数据库。
    ///   - schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///   - pageItemLimit: 单页条目上限，需落在编解码器允许范围内。
    ///   - maximumCandidateItems: 单次候选读取上限，需不小于单页上限。
    ///   - leaseDuration: 认领租约秒数，需大于零。
    ///   - messageReadMode: 消息投影读取模式，默认优先共享状态。
    ///   - makeUUID: 页面或产物标识生成方式。
    ///
    /// 参数越界时直接失败，避免出现越界分页或非法 schema 拼接。
    public init(
        database: any Database,
        schema: String = "im_v2",
        pageItemLimit: Int = V2SnapshotProjectionV3Codec.maximumPageItems,
        maximumCandidateItems: Int = 500,
        leaseDuration: TimeInterval = 30,
        messageReadMode: V2MessageProjectionReadMode = .preferShared,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        precondition((1 ... V2SnapshotProjectionV3Codec.maximumPageItems).contains(pageItemLimit))
        precondition(maximumCandidateItems >= pageItemLimit && leaseDuration > 0)
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
        self.pageItemLimit = pageItemLimit
        self.maximumCandidateItems = maximumCandidateItems
        self.leaseDuration = leaseDuration
        self.messageReadMode = messageReadMode
        self.makeUUID = makeUUID
    }

    /// 执行一轮有界快照构建。
    ///
    /// 无可认领任务时返回未认领的报告；成功认领后逐页读取、编码并提交，
    /// 全部页面完成后发布产物。
    ///
    /// - Parameter now: 本次构建时刻。
    /// - Returns: 本轮构建报告。
    /// - Throws: 任务取消时抛出 `CancellationError`；持久化异常、条目过大、
    ///   产物过大或租约丢失时抛出 ``V2SnapshotArtifactBuilderError``。
    public func runOnce(now: Date = Date()) async throws -> V2SnapshotArtifactBuildReport {
        try Task.checkCancellation()
        guard let claim = try await claim(now: now) else {
            return .init(claimed: false, published: false, pageCount: 0, itemCount: 0)
        }
        do {
            let candidates = try await readCandidates(for: claim)
            try Task.checkCancellation()
            guard !candidates.isEmpty else {
                guard isWithinArtifactLimits(
                    pageCount: claim.nextPageIndex,
                    itemCount: claim.itemCount,
                    totalBytes: claim.totalBytes
                ) else {
                    try await fail(claim: claim, code: "snapshot_too_large")
                    return .init(
                        claimed: true, published: false,
                        pageCount: UInt32(claim.nextPageIndex), itemCount: UInt64(claim.itemCount)
                    )
                }
                try await publish(claim: claim, now: now)
                return .init(
                    claimed: true, published: true,
                    pageCount: UInt32(claim.nextPageIndex), itemCount: UInt64(claim.itemCount)
                )
            }
            let encoded: EncodedPage
            do {
                encoded = try makePage(from: candidates)
            } catch is V2SnapshotProjectionV3Error {
                try await fail(claim: claim, code: "invalid_projection")
                return .init(
                    claimed: true, published: false,
                    pageCount: UInt32(claim.nextPageIndex), itemCount: UInt64(claim.itemCount)
                )
            } catch V2SnapshotArtifactBuilderError.itemTooLarge {
                try await fail(claim: claim, code: "projection_too_large")
                return .init(
                    claimed: true, published: false,
                    pageCount: UInt32(claim.nextPageIndex), itemCount: UInt64(claim.itemCount)
                )
            }
            guard isWithinArtifactLimits(
                pageCount: claim.nextPageIndex + 1,
                itemCount: claim.itemCount + Int64(encoded.page.items.count),
                totalBytes: claim.totalBytes + Int64(encoded.payload.count)
            ) else {
                try await fail(claim: claim, code: "snapshot_too_large")
                return .init(
                    claimed: true, published: false,
                    pageCount: UInt32(claim.nextPageIndex), itemCount: UInt64(claim.itemCount)
                )
            }
            try await append(encoded, claim: claim)
            return .init(
                claimed: true, published: false,
                pageCount: UInt32(claim.nextPageIndex + 1),
                itemCount: UInt64(claim.itemCount + Int64(encoded.page.items.count))
            )
        } catch is CancellationError {
            try? await release(claim: claim)
            throw CancellationError()
        } catch {
            try? await release(claim: claim)
            throw error
        }
    }

    private func claim(now: Date) async throws -> BuildClaim? {
        guard let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2SnapshotArtifactBuilderError.corruptPersistence
        }
        let token = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2SnapshotArtifactBuilderError.corruptPersistence
            }
            guard let row = try await sql.raw("""
                SELECT artifact.snapshot_id, artifact.user_id,
                       artifact.base_user_sync_sequence, artifact.capability_profile,
                       artifact.after_projection_kind, artifact.after_entity_key,
                       artifact.next_page_index, artifact.rolling_digest,
                       artifact.item_count, artifact.total_bytes
                FROM \(unsafeRaw: table("sync_snapshot_artifacts")) AS artifact
                JOIN \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                  ON checkpoint.user_id = artifact.user_id
                WHERE artifact.state = 'building'
                  AND (checkpoint.migration_fence_expires_at IS NULL
                       OR checkpoint.migration_fence_expires_at <= \(bind: now))
                  AND (artifact.lease_expires_at IS NULL OR artifact.lease_expires_at <= \(bind: now))
                  AND artifact.expires_at > \(bind: now)
                ORDER BY artifact.created_at, artifact.snapshot_id
                FOR UPDATE SKIP LOCKED
                LIMIT 1
                """).first(decoding: BuildRow.self) else { return nil }
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("sync_snapshot_artifacts"))
                SET lease_token = \(bind: token), lease_expires_at = \(bind: expiry)
                WHERE snapshot_id = \(bind: row.snapshotID)
                """).run()
            return try .init(row: row, leaseToken: token)
        }
    }

    private func readCandidates(for claim: BuildClaim) async throws -> [ProjectionVersionRow] {
        guard let sql = database as? any SQLDatabase else {
            throw V2SnapshotArtifactBuilderError.corruptPersistence
        }
        if let after = claim.afterKey {
            return try await sql.raw("""
                SELECT version.projection_kind, version.entity_key, version.valid_from_sequence,
                       version.source_event_id,
                       CASE
                           WHEN version.projection_kind <> 'message' THEN version.payload
                           WHEN \(bind: messageReadMode.rawValue) = 'inline' THEN
                               COALESCE(version.payload, state.payload)
                           WHEN \(bind: messageReadMode.rawValue) = 'prefer_shared' THEN
                               COALESCE(state.payload, version.payload)
                           ELSE state.payload
                       END::text AS payload_json
                FROM \(unsafeRaw: table("user_projection_versions")) AS version
                LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
                  ON state.state_id = version.message_state_id
                WHERE version.user_id = \(bind: claim.userID)
                  AND version.valid_from_sequence <= \(bind: claim.baseSequence)
                  AND (version.valid_to_sequence IS NULL OR version.valid_to_sequence > \(bind: claim.baseSequence))
                  AND (version.projection_kind, version.entity_key) > (\(bind: after.projectionKind), \(bind: after.entityKey))
                ORDER BY version.projection_kind, version.entity_key
                LIMIT \(bind: maximumCandidateItems)
                """).all(decoding: ProjectionVersionRow.self)
        }
        return try await sql.raw("""
            SELECT version.projection_kind, version.entity_key, version.valid_from_sequence,
                   version.source_event_id,
                   CASE
                       WHEN version.projection_kind <> 'message' THEN version.payload
                       WHEN \(bind: messageReadMode.rawValue) = 'inline' THEN
                           COALESCE(version.payload, state.payload)
                       WHEN \(bind: messageReadMode.rawValue) = 'prefer_shared' THEN
                           COALESCE(state.payload, version.payload)
                       ELSE state.payload
                   END::text AS payload_json
            FROM \(unsafeRaw: table("user_projection_versions")) AS version
            LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
              ON state.state_id = version.message_state_id
            WHERE version.user_id = \(bind: claim.userID)
              AND version.valid_from_sequence <= \(bind: claim.baseSequence)
              AND (version.valid_to_sequence IS NULL OR version.valid_to_sequence > \(bind: claim.baseSequence))
            ORDER BY version.projection_kind, version.entity_key
            LIMIT \(bind: maximumCandidateItems)
            """).all(decoding: ProjectionVersionRow.self)
    }

    private func makePage(from candidates: [ProjectionVersionRow]) throws -> EncodedPage {
        let items = try candidates.prefix(pageItemLimit).map { row in
            guard row.sequence > 0, let payload = row.payloadJSON.data(using: .utf8) else {
                throw V2SnapshotArtifactBuilderError.corruptPersistence
            }
            return try V2SnapshotProjectionItem(
                key: .init(projectionKind: row.projectionKind, entityKey: row.entityKey),
                sourceEventID: .init(row.sourceEventID.uuidString),
                sequence: UInt64(row.sequence), payload: payload
            )
        }
        guard !items.isEmpty else { throw V2SnapshotArtifactBuilderError.itemTooLarge }

        // Encoded size is monotonic in the item prefix. Binary search reduces
        // page construction from O(n²) repeated encodes to O(n log n) bytes.
        var low = 1
        var high = items.count
        var acceptedCount = 0
        var acceptedPayload: Data?
        while low <= high {
            let middle = low + (high - low) / 2
            do {
                let payload = try V2SnapshotProjectionV3Codec.encode(
                    .init(items: Array(items.prefix(middle)))
                )
                acceptedCount = middle
                acceptedPayload = payload
                low = middle + 1
            } catch V2SnapshotProjectionV3Error.pageTooLarge {
                high = middle - 1
            }
        }
        guard let payload = acceptedPayload, acceptedCount > 0 else {
            throw V2SnapshotArtifactBuilderError.itemTooLarge
        }
        let page = try V2SnapshotProjectionV3Page(items: Array(items.prefix(acceptedCount)))
        return .init(page: page, payload: payload, digest: V2SnapshotV3Digest.page(payload))
    }

    private func isWithinArtifactLimits(
        pageCount: Int,
        itemCount: Int64,
        totalBytes: Int64
    ) -> Bool {
        pageCount >= 0
            && pageCount <= V2SnapshotProjectionV3Codec.maximumPageCount
            && itemCount >= 0
            && UInt64(itemCount) <= V2SnapshotProjectionV3Codec.maximumTotalItems
            && totalBytes >= 0
            && UInt64(totalBytes) <= V2SnapshotProjectionV3Codec.maximumTotalBytes
    }

    private func append(_ encoded: EncodedPage, claim: BuildClaim) async throws {
        let nextRolling = V2SnapshotV3Digest.next(
            previous: claim.rollingDigest, pageIndex: UInt32(claim.nextPageIndex),
            pageDigest: encoded.digest, firstKey: encoded.page.firstKey,
            lastKey: encoded.page.lastKey, itemCount: UInt32(encoded.page.items.count)
        )
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2SnapshotArtifactBuilderError.corruptPersistence
            }
            guard let locked = try await lockedBuild(snapshotID: claim.snapshotID, sql: sql),
                  locked.state == "building", locked.leaseToken == claim.leaseToken,
                  locked.nextPageIndex == claim.nextPageIndex,
                  locked.afterProjectionKind == claim.afterKey?.projectionKind,
                  locked.afterEntityKey == claim.afterKey?.entityKey,
                  locked.rollingDigest == claim.rollingDigest
            else { throw V2SnapshotArtifactBuilderError.lostLease }
            guard isWithinArtifactLimits(
                pageCount: locked.nextPageIndex + 1,
                itemCount: locked.itemCount + Int64(encoded.page.items.count),
                totalBytes: locked.totalBytes + Int64(encoded.payload.count)
            ) else { throw V2SnapshotArtifactBuilderError.artifactTooLarge }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("sync_snapshot_pages"))
                    (snapshot_id, page_index, first_projection_kind, first_entity_key,
                     last_projection_kind, last_entity_key, item_count,
                     page_digest, payload, byte_count)
                VALUES (\(bind: claim.snapshotID), \(bind: claim.nextPageIndex),
                        \(bind: encoded.page.firstKey.projectionKind), \(bind: encoded.page.firstKey.entityKey),
                        \(bind: encoded.page.lastKey.projectionKind), \(bind: encoded.page.lastKey.entityKey),
                        \(bind: encoded.page.items.count), \(bind: encoded.digest),
                        \(bind: encoded.payload), \(bind: encoded.payload.count))
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("sync_snapshot_artifacts"))
                SET after_projection_kind = \(bind: encoded.page.lastKey.projectionKind),
                    after_entity_key = \(bind: encoded.page.lastKey.entityKey),
                    next_page_index = next_page_index + 1,
                    rolling_digest = \(bind: nextRolling),
                    item_count = item_count + \(bind: encoded.page.items.count),
                    total_bytes = total_bytes + \(bind: encoded.payload.count),
                    lease_token = NULL, lease_expires_at = NULL
                WHERE snapshot_id = \(bind: claim.snapshotID) AND lease_token = \(bind: claim.leaseToken)
                """).run()
        }
    }

    private func publish(claim: BuildClaim, now: Date) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2SnapshotArtifactBuilderError.corruptPersistence
            }
            guard let locked = try await lockedBuild(snapshotID: claim.snapshotID, sql: sql),
                  locked.state == "building", locked.leaseToken == claim.leaseToken,
                  locked.nextPageIndex == claim.nextPageIndex,
                  locked.afterProjectionKind == claim.afterKey?.projectionKind,
                  locked.afterEntityKey == claim.afterKey?.entityKey,
                  locked.rollingDigest == claim.rollingDigest
            else { throw V2SnapshotArtifactBuilderError.lostLease }
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("sync_snapshot_artifacts"))
                SET state = 'published', root_digest = rolling_digest,
                    page_count = next_page_index, published_at = \(bind: now),
                    lease_token = NULL, lease_expires_at = NULL
                WHERE snapshot_id = \(bind: claim.snapshotID)
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_snapshot_resets"))
                SET state = 'ready'
                WHERE snapshot_id = \(bind: claim.snapshotID) AND state = 'preparing'
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_sync_cursors")) AS cursor
                SET state = 'reset_pending'
                FROM \(unsafeRaw: table("device_snapshot_resets")) AS reset
                WHERE reset.snapshot_id = \(bind: claim.snapshotID) AND reset.state = 'ready'
                  AND cursor.user_id = reset.user_id AND cursor.device_id = reset.device_id
                  AND cursor.reset_generation = reset.reset_generation
                  AND cursor.pending_snapshot_id = reset.snapshot_id
                  AND cursor.state = 'reset_preparing'
                """).run()
        }
    }

    private func release(claim: BuildClaim) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            UPDATE \(unsafeRaw: table("sync_snapshot_artifacts"))
            SET lease_token = NULL, lease_expires_at = NULL
            WHERE snapshot_id = \(bind: claim.snapshotID) AND state = 'building'
              AND lease_token = \(bind: claim.leaseToken)
            """).run()
    }

    private func fail(claim: BuildClaim, code: String) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let locked = try await lockedBuild(snapshotID: claim.snapshotID, sql: sql),
                  locked.state == "building", locked.leaseToken == claim.leaseToken,
                  locked.nextPageIndex == claim.nextPageIndex,
                  locked.afterProjectionKind == claim.afterKey?.projectionKind,
                  locked.afterEntityKey == claim.afterKey?.entityKey,
                  locked.rollingDigest == claim.rollingDigest
            else { throw V2SnapshotArtifactBuilderError.lostLease }
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("sync_snapshot_artifacts"))
                SET state = 'failed', failure_code = \(bind: code),
                    lease_token = NULL, lease_expires_at = NULL
                WHERE snapshot_id = \(bind: claim.snapshotID)
                """).run()
            try await sql.raw("""
                DELETE FROM \(unsafeRaw: table("sync_tokens")) AS token
                USING \(unsafeRaw: table("device_snapshot_resets")) AS reset
                WHERE reset.snapshot_id = \(bind: claim.snapshotID)
                  AND reset.state = 'preparing'
                  AND token.token = reset.next_sync_token
                  AND token.user_id = reset.user_id AND token.device_id = reset.device_id
                  AND token.reset_generation = reset.reset_generation
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: table("device_sync_cursors")) AS cursor
                SET state = 'ready', reset_generation = cursor.reset_generation - 1,
                    pending_snapshot_id = NULL,
                    pending_base_sequence = NULL, pending_snapshot_expires_at = NULL
                FROM \(unsafeRaw: table("device_snapshot_resets")) AS reset
                WHERE reset.snapshot_id = \(bind: claim.snapshotID)
                  AND reset.state = 'preparing'
                  AND cursor.user_id = reset.user_id AND cursor.device_id = reset.device_id
                  AND cursor.reset_generation = reset.reset_generation
                  AND cursor.pending_snapshot_id = reset.snapshot_id
                  AND cursor.state = 'reset_preparing'
                """).run()
            // Keep the failed artifact as the operation-id idempotency record,
            // but discard the unpublished assignment so a later operation can
            // safely reuse the next reset generation.
            try await sql.raw("""
                DELETE FROM \(unsafeRaw: table("device_snapshot_resets"))
                WHERE snapshot_id = \(bind: claim.snapshotID) AND state = 'preparing'
                """).run()
        }
    }

    private func lockedBuild(snapshotID: UUID, sql: any SQLDatabase) async throws -> LockedBuildRow? {
        try await sql.raw("""
            SELECT state, lease_token, next_page_index, after_projection_kind,
                   after_entity_key, rolling_digest, item_count, total_bytes
            FROM \(unsafeRaw: table("sync_snapshot_artifacts"))
            WHERE snapshot_id = \(bind: snapshotID)
            FOR UPDATE
            """).first(decoding: LockedBuildRow.self)
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

/// 快照产物构建错误。
public enum V2SnapshotArtifactBuilderError: Error, Equatable, Sendable {
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistence
    /// 单个条目超出允许的页内大小。
    case itemTooLarge
    /// 产物总量超出允许上限。
    case artifactTooLarge
    /// 构建期间租约已被他人接管。
    case lostLease
}

private struct BuildClaim: Sendable {
    let snapshotID: UUID
    let userID: UUID
    let baseSequence: Int64
    let capabilityProfile: String
    let afterKey: V2SnapshotProjectionKey?
    let nextPageIndex: Int
    let rollingDigest: String
    let itemCount: Int64
    let totalBytes: Int64
    let leaseToken: UUID

    init(row: BuildRow, leaseToken: UUID) throws {
        snapshotID = row.snapshotID; userID = row.userID; baseSequence = row.baseSequence
        capabilityProfile = row.capabilityProfile
        switch (row.afterProjectionKind, row.afterEntityKey) {
        case (nil, nil): afterKey = nil
        case let (.some(kind), .some(key)): afterKey = try .init(projectionKind: kind, entityKey: key)
        default: throw V2SnapshotArtifactBuilderError.corruptPersistence
        }
        nextPageIndex = row.nextPageIndex; rollingDigest = row.rollingDigest
        itemCount = row.itemCount; totalBytes = row.totalBytes; self.leaseToken = leaseToken
    }
}

private struct EncodedPage { let page: V2SnapshotProjectionV3Page; let payload: Data; let digest: String }
private struct BuildRow: Decodable {
    let snapshotID: UUID; let userID: UUID; let baseSequence: Int64; let capabilityProfile: String
    let afterProjectionKind: String?; let afterEntityKey: String?; let nextPageIndex: Int
    let rollingDigest: String; let itemCount: Int64; let totalBytes: Int64
    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id", userID = "user_id", baseSequence = "base_user_sync_sequence"
        case capabilityProfile = "capability_profile", afterProjectionKind = "after_projection_kind"
        case afterEntityKey = "after_entity_key", nextPageIndex = "next_page_index"
        case rollingDigest = "rolling_digest", itemCount = "item_count", totalBytes = "total_bytes"
    }
}
private struct ProjectionVersionRow: Decodable {
    let projectionKind: String; let entityKey: String; let sequence: Int64
    let sourceEventID: UUID; let payloadJSON: String
    enum CodingKeys: String, CodingKey {
        case projectionKind = "projection_kind", entityKey = "entity_key"
        case sequence = "valid_from_sequence", sourceEventID = "source_event_id"
        case payloadJSON = "payload_json"
    }
}
private struct LockedBuildRow: Decodable {
    let state: String; let leaseToken: UUID?; let nextPageIndex: Int
    let afterProjectionKind: String?; let afterEntityKey: String?; let rollingDigest: String
    let itemCount: Int64; let totalBytes: Int64
    enum CodingKeys: String, CodingKey {
        case state, leaseToken = "lease_token", nextPageIndex = "next_page_index"
        case afterProjectionKind = "after_projection_kind", afterEntityKey = "after_entity_key"
        case rollingDigest = "rolling_digest", itemCount = "item_count", totalBytes = "total_bytes"
    }
}
