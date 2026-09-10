import Fluent
import Foundation
import SQLKit

/// 从唯一一个已注册的当前归属读取不可变创建绑定的导入实现。
///
/// 读取归属期间不持有控制面事务或连接；发布与其不可变审计是原子的，
/// 任一绑定冲突都会回滚整页。
public struct PostgresV2GroupInviteDirectoryImporter: V2GroupInviteDirectoryImporting {
    private let control: any Database
    private let owners: any V2RoomShardStorageResolving
    private let principal: String
    private let now: @Sendable () -> Date

    /// 校验运维主体并保存控制库与归属解析器。
    ///
    /// - Parameters:
    ///   - controlDatabase: 存放邀请目录与导入审计的控制库。
    ///   - owners: 房间归属到存储位置的解析器。
    ///   - operatorPrincipal: 运维主体标识，需符合通用运维主体格式。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 运维主体格式非法时抛出
    ///   ``V2GroupInviteDirectoryImportError/invalidRequest``。
    public init(controlDatabase: any Database, owners: any V2RoomShardStorageResolving,
                operatorPrincipal: String, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal)
        else { throw V2GroupInviteDirectoryImportError.invalidRequest }
        self.control = controlDatabase; self.owners = owners; self.principal = operatorPrincipal; self.now = now
    }

    /// 导入一页房间邀请绑定。
    ///
    /// 先尝试完全一致的幂等重放（路由或注册表变化后仍然可用），再以共享锁校验路由与归属一致，
    /// 随后在归属事务内读取一页绑定。发布阶段在控制库事务中重新加锁校验归属，
    /// 并用保存点隔离绑定写入，使任一冲突都能整页回滚。
    ///
    /// - Parameter command: 已校验的导入命令。
    /// - Returns: 本页导入统计。
    /// - Throws: 运维主体非法或时刻不可编码时抛出
    ///   ``V2GroupInviteDirectoryImportError/invalidRequest``；分片未配置或 schema 不符时抛出
    ///   ``V2GroupInviteDirectoryImportError/unknownShard``；归属不符时抛出
    ///   ``V2GroupInviteDirectoryImportError/ownerChanged``；其余失败抛出
    ///   ``V2GroupInviteDirectoryImportError/corruptPersistenceState``。
    public func importPage(_ command: V2GroupInviteDirectoryImportCommand) async throws -> V2GroupInviteDirectoryImportResult {
        let sql = try importSQL(control)
        // Exact replay remains available after routes or registry entries change.
        if let result = try await replay(command, on: sql) { return result }
        try await verifyRoute(command, shared: false, on: sql)
        let location: V2RoomShardStorageLocation
        do { location = try owners.location(for: command.shardID) }
        catch { throw V2GroupInviteDirectoryImportError.unknownShard }
        guard location.schema == "im_v2" else { throw V2GroupInviteDirectoryImportError.unknownShard }
        let source = try await location.database.transaction { transaction in
            let ownerSQL = try importSQL(transaction)
            guard let owner = try await ownerSQL.raw("""
                SELECT room_shard_id AS shard_id, owner_epoch AS epoch
                FROM im_v2.rooms WHERE room_id = \(bind: command.roomID) FOR SHARE
                """).first(decoding: ImportOwnerRow.self),
                  owner.shardID == command.shardID, owner.epoch == command.ownerEpoch
            else { throw V2GroupInviteDirectoryImportError.ownerChanged }
            let after: SQLQueryString = if let cursor = command.afterInviteID { "AND invite_id > \(bind: cursor)" } else { "" }
            return try await ownerSQL.raw("""
                SELECT created_by_user_id AS actor_user_id, creation_operation_id AS operation_id,
                       invite_id, room_id, token_digest, requested_lifetime_seconds,
                       maximum_approved_uses, created_at, expires_at
                FROM im_v2.group_invite_links WHERE room_id = \(bind: command.roomID)
                \(after) ORDER BY invite_id LIMIT \(bind: command.limit + 1)
                """).all(decoding: ImportBinding.self)
        }
        let page = Array(source.prefix(command.limit))
        let nextCursor = source.count > command.limit ? page.last?.inviteID : nil
        let snapshot = String(decoding: try JSONEncoder().encode(page.map(ImportBindingSnapshot.init)), as: UTF8.self)
        let attemptedAt = now()
        guard v2PostgresTimestampCanEncode(attemptedAt) else { throw V2GroupInviteDirectoryImportError.invalidRequest }
        return try await control.transaction { transaction in
            let sql = try importSQL(transaction)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "group-invite-import:\(command.operationID)"), 0))").run()
            if let result = try await replay(command, on: sql) { return result }
            // Hold the explicit durable route row through publication and audit.
            // A legacy local-room fallback is deliberately not an import scope.
            try await verifyRoute(command, shared: true, on: sql)
            try await sql.raw("SAVEPOINT invite_bindings").run()
            var inserted = 0, published = 0, unchanged = 0
            var conflicts: [UUID] = []
            for binding in page {
                let added = try await sql.raw("""
                    INSERT INTO im_v2.group_invite_directory
                        (actor_user_id, operation_id, invite_id, room_id, token_digest,
                         requested_lifetime_seconds, maximum_approved_uses, created_at, expires_at, state, ready_at)
                    VALUES (\(bind: binding.actorUserID), \(bind: binding.operationID), \(bind: binding.inviteID),
                            \(bind: binding.roomID), \(bind: binding.tokenDigest), \(bind: binding.requestedLifetimeSeconds),
                            \(bind: binding.maximumApprovedUses), \(bind: binding.createdAt), \(bind: binding.expiresAt), 'ready', \(bind: attemptedAt))
                    ON CONFLICT DO NOTHING RETURNING invite_id
                    """).first() != nil
                if added { inserted += 1; continue }
                guard let existing = try await sql.raw("""
                    SELECT * FROM im_v2.group_invite_directory
                    WHERE actor_user_id = \(bind: binding.actorUserID) AND operation_id = \(bind: binding.operationID) FOR UPDATE
                    """).first(decoding: ImportDirectoryRow.self), existing.binding == binding
                else { conflicts.append(binding.inviteID); continue }
                switch existing.state {
                case "ready": unchanged += 1
                case "prepared":
                    try await sql.raw("""
                        UPDATE im_v2.group_invite_directory SET state = 'ready', ready_at = \(bind: attemptedAt)
                        WHERE actor_user_id = \(bind: binding.actorUserID) AND operation_id = \(bind: binding.operationID)
                        """).run()
                    published += 1
                default: throw V2GroupInviteDirectoryImportError.corruptPersistenceState
                }
                // A prepared binding may have a pending, leased or paused job.
                // The exact committed owner binding is the completion proof.
                try await sql.raw("""
                    UPDATE im_v2.group_invite_creation_recovery
                    SET state = 'completed', claim_token = NULL, lease_expires_at = NULL,
                        last_error_code = NULL, completed_at = \(bind: attemptedAt), updated_at = \(bind: attemptedAt)
                    WHERE actor_user_id = \(bind: binding.actorUserID) AND operation_id = \(bind: binding.operationID) AND state <> 'completed'
                    """).run()
            }
            let outcome: V2GroupInviteDirectoryImportOutcome = conflicts.isEmpty ? .applied : .conflict
            if !conflicts.isEmpty {
                try await sql.raw("ROLLBACK TO SAVEPOINT invite_bindings").run()
                inserted = 0; published = 0; unchanged = 0
            }
            try await sql.raw("RELEASE SAVEPOINT invite_bindings").run()
            try await sql.raw("""
                INSERT INTO im_v2.group_invite_directory_import_audit
                    (operation_id, operator_principal, shard_id, owner_epoch, room_id, after_invite_id,
                     page_size, reason_code, requested_at, outcome, source_snapshot, source_digest,
                     source_count, inserted_count, published_count, unchanged_count, next_cursor, conflicting_invite_ids)
                VALUES (\(bind: command.operationID), \(bind: principal), \(bind: command.shardID), \(bind: command.ownerEpoch),
                        \(bind: command.roomID), \(bind: command.afterInviteID), \(bind: command.limit), \(bind: command.reason.rawValue),
                        \(bind: attemptedAt), \(bind: outcome.rawValue), \(bind: snapshot)::jsonb,
                        sha256(convert_to((\(bind: snapshot)::jsonb)::text, 'UTF8')), \(bind: page.count),
                        \(bind: inserted), \(bind: published), \(bind: unchanged), \(bind: nextCursor), \(bind: conflicts)::uuid[])
                """).run()
            return .init(operationID: command.operationID, outcome: outcome, sourceCount: page.count,
                insertedCount: inserted, publishedCount: published, unchangedCount: unchanged,
                nextCursor: nextCursor, conflictingInviteIDs: conflicts, wasIdempotent: false)
        }
    }

    private func verifyRoute(_ command: V2GroupInviteDirectoryImportCommand, shared: Bool, on sql: any SQLDatabase) async throws {
        guard let route = try await sql.raw("""
            SELECT room_shard_id AS shard_id, route_epoch AS epoch
            FROM im_v2.room_owner_routes WHERE room_id = \(bind: command.roomID) \(unsafeRaw: shared ? "FOR SHARE" : "")
            """).first(decoding: ImportOwnerRow.self), route.shardID == command.shardID, route.epoch == command.ownerEpoch
        else { throw V2GroupInviteDirectoryImportError.ownerChanged }
    }

    private func replay(_ command: V2GroupInviteDirectoryImportCommand, on sql: any SQLDatabase) async throws -> V2GroupInviteDirectoryImportResult? {
        guard let row = try await sql.raw("SELECT * FROM im_v2.group_invite_directory_import_audit WHERE operation_id = \(bind: command.operationID)").first(decoding: ImportAuditRow.self) else { return nil }
        guard row.operatorPrincipal == principal, row.shardID == command.shardID, row.ownerEpoch == command.ownerEpoch,
              row.roomID == command.roomID, row.afterInviteID == command.afterInviteID,
              row.pageSize == command.limit, row.reasonCode == command.reason.rawValue
        else { throw V2GroupInviteDirectoryImportError.idempotencyConflict }
        guard let outcome = V2GroupInviteDirectoryImportOutcome(rawValue: row.outcome)
        else { throw V2GroupInviteDirectoryImportError.corruptPersistenceState }
        return .init(operationID: command.operationID, outcome: outcome, sourceCount: row.sourceCount,
            insertedCount: row.insertedCount, publishedCount: row.publishedCount, unchangedCount: row.unchangedCount,
            nextCursor: row.nextCursor, conflictingInviteIDs: row.conflictingInviteIDs, wasIdempotent: true)
    }
}

private func importSQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw V2GroupInviteDirectoryImportError.corruptPersistenceState }
    return sql
}
private struct ImportOwnerRow: Decodable {
    let shardID: String, epoch: Int64
    enum CodingKeys: String, CodingKey { case shardID = "shard_id", epoch }
}
private struct ImportBinding: Decodable, Equatable, Sendable {
    let actorUserID: UUID, operationID: UUID, inviteID: UUID, roomID: UUID
    let tokenDigest: Data
    let requestedLifetimeSeconds: Int, maximumApprovedUses: Int
    let createdAt: V2PostgresTimestamp, expiresAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case actorUserID = "actor_user_id", operationID = "operation_id", inviteID = "invite_id", roomID = "room_id"
        case tokenDigest = "token_digest", requestedLifetimeSeconds = "requested_lifetime_seconds", maximumApprovedUses = "maximum_approved_uses"
        case createdAt = "created_at", expiresAt = "expires_at"
    }
}

/// 保持审计使用的 Unix 秒整数格式编码。
///
/// 编码过程不把原生微秒经过 `Double` 转换，使数据库绑定在复制与冲突检测两种用途下
/// 都保持精确，包括 `Date` 会折叠掉精度的时间戳。
private struct ImportBindingSnapshot: Encodable {
    let binding: ImportBinding

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: ImportBinding.CodingKeys.self)
        try values.encode(binding.actorUserID, forKey: .actorUserID)
        try values.encode(binding.operationID, forKey: .operationID)
        try values.encode(binding.inviteID, forKey: .inviteID)
        try values.encode(binding.roomID, forKey: .roomID)
        try values.encode(binding.tokenDigest, forKey: .tokenDigest)
        try values.encode(binding.requestedLifetimeSeconds, forKey: .requestedLifetimeSeconds)
        try values.encode(binding.maximumApprovedUses, forKey: .maximumApprovedUses)
        try values.encode(unixSeconds(binding.createdAt), forKey: .createdAt)
        try values.encode(unixSeconds(binding.expiresAt), forKey: .expiresAt)
    }

    private func unixSeconds(_ timestamp: V2PostgresTimestamp) -> Decimal {
        Decimal(timestamp.microseconds) / Decimal(1_000_000) + Decimal(946_684_800)
    }
}

private struct ImportDirectoryRow: Decodable {
    let binding: ImportBinding, state: String
    enum CodingKeys: String, CodingKey { case state }
    init(from decoder: any Decoder) throws {
        binding = try ImportBinding(from: decoder)
        state = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .state)
    }
}
private struct ImportAuditRow: Decodable {
    let operatorPrincipal: String, shardID: String, ownerEpoch: Int64, roomID: UUID
    let afterInviteID: UUID?, pageSize: Int, reasonCode: String, outcome: String
    let sourceCount: Int, insertedCount: Int, publishedCount: Int, unchangedCount: Int
    let nextCursor: UUID?, conflictingInviteIDs: [UUID]
    enum CodingKeys: String, CodingKey {
        case operatorPrincipal = "operator_principal", shardID = "shard_id", ownerEpoch = "owner_epoch", roomID = "room_id"
        case afterInviteID = "after_invite_id", pageSize = "page_size", reasonCode = "reason_code", outcome
        case sourceCount = "source_count", insertedCount = "inserted_count", publishedCount = "published_count", unchangedCount = "unchanged_count"
        case nextCursor = "next_cursor", conflictingInviteIDs = "conflicting_invite_ids"
    }
}
