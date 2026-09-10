import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL 迁移控制记录存储，负责准备记录、带阶段检查的推进及保留期租约。
///
/// 阶段推进和失败登记在事务内锁定目标行，再核对预期阶段，避免迟到的外部结果越过阶段约束。
/// 准备操作只对已存在行加锁，新记录并发插入仍依赖数据库约束；保留期领取可批量锁定多行。
/// 本存储不执行投影复制、源端删除或路由发布。
public struct PostgresV2UserShardMigrationStore: V2UserShardMigrationStoring {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 注入迁移控制数据库和租约令牌生成器。
    ///
    /// - Parameters:
    ///   - database: 支持 SQL 的 Fluent 控制面数据库。
    ///   - makeUUID: 每批保留期领取使用的令牌生成器，默认生成随机 UUID。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    /// 在事务中按用户查询已有记录，返回匹配请求或插入准备阶段记录。
    ///
    /// 既有记录匹配迁移 ID、源桶、目标桶及源代次时直接返回，不重置其阶段。
    /// 只有实际插入时验证 `now` 可编码；本方法不执行冲突插入后的自动重读。
    ///
    /// - Parameters:
    ///   - request: 已规范化的准备请求。
    ///   - now: 新记录的创建与更新时间。
    /// - Returns: 匹配的原记录或新建的 `prepared` 记录。
    /// - Throws: 请求不匹配时抛出 `requestConflict`；SQL 能力、日期、记录转换或数据库错误向上传播。
    public func prepare(_ request: V2UserShardMigrationPreparation, now: Date) async throws -> V2UserShardMigrationRecord {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let existing = try await select(userID: request.userID, forUpdate: true, sql: sql) {
                guard existing.matches(request) else { throw V2UserShardMigrationStoreError.requestConflict }
                return try existing.record()
            }
            guard v2PostgresTimestampCanEncode(now) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_migrations
                    (migration_id, user_id, source_bucket, target_bucket, source_router_epoch, phase, created_at, updated_at)
                VALUES
                    (\(bind: request.migrationID), \(bind: try userUUID(request.userID)), \(bind: request.sourceBucket), \(bind: request.targetBucket),
                     \(bind: request.sourceRouterEpoch), 'prepared', \(bind: now), \(bind: now))
                """).run()
            guard let created = try await select(migrationID: request.migrationID, forUpdate: false, sql: sql) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return try created.record()
        }
    }

    /// 按迁移 ID读取控制记录，不加更新行锁。
    ///
    /// - Parameter migrationID: 查询标识。
    /// - Returns: 找到的记录，未命中返回 `nil`。
    /// - Throws: SQL 能力、标识转换、查询或记录解码错误。
    public func load(migrationID: UUID) async throws -> V2UserShardMigrationRecord? {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await select(migrationID: migrationID, forUpdate: false, sql: sql)?.record()
    }

    /// 按用户 ID读取控制记录，不加更新行锁。
    ///
    /// - Parameter userID: 查询标识。
    /// - Returns: 找到的记录，未命中返回 `nil`。
    /// - Throws: SQL 能力、标识转换、查询或记录解码错误。
    public func load(userID: UserID) async throws -> V2UserShardMigrationRecord? {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await select(userID: userID, forUpdate: false, sql: sql)?.record()
    }

    /// 用一次集合查询读取多个用户的迁移控制记录。
    ///
    /// - Parameter userIDs: 不重复的用户列表；空列表直接返回，调用方负责限制批次规模。
    /// - Returns: 有控制记录的用户映射，未记录用户被省略；不按迁移阶段过滤。
    /// - Throws: 重复或无效 UUID、重复结果、SQL 能力、编码或查询错误。
    ///
    /// 返回阶段仅为读取时快照，后续写入仍须保留迁移阶段与路由保护。
    public func load(userIDs: [UserID]) async throws -> [UserID: V2UserShardMigrationRecord] {
        guard !userIDs.isEmpty else { return [:] }
        let rawUserIDs = try userIDs.map(userUUID)
        guard Set(rawUserIDs).count == rawUserIDs.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let inputJSON = try migrationJSON(rawUserIDs.map(\.uuidString))
        let rows = try await sql.raw("""
            WITH input AS (
                SELECT value::uuid AS user_id
                FROM jsonb_array_elements_text(\(bind: inputJSON)::jsonb) AS values(value)
            )
            SELECT migration.migration_id, migration.user_id, migration.source_bucket,
                   migration.target_bucket, migration.source_router_epoch, migration.phase,
                   migration.source_fingerprint, migration.target_fingerprint,
                   migration.verified_at, migration.last_error_code,
                   migration.cutover_operation_id, migration.retention_until
            FROM im_v2.user_shard_migrations AS migration
            JOIN input USING (user_id)
            """).all(decoding: V2PostgresUserShardMigrationRow.self)
        var records: [UserID: V2UserShardMigrationRecord] = [:]
        for row in rows {
            let record = try row.record()
            guard records[record.userID] == nil else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            records[record.userID] = record
        }
        return records
    }

    /// 锁定记录并验证阶段，按状态机推进后清空最近失败码。
    ///
    /// 两种验证成功动作必须提供相等且格式合法的指纹，并更新验证时间；其他动作不得传指纹，
    /// 会保留已存指纹和验证时间。此方法只修改迁移记录，不执行路由切换副作用。
    ///
    /// - Parameters:
    ///   - migrationID: 目标迁移标识。
    ///   - expectedPhase: 必须与锁定行一致的预期阶段。
    ///   - action: 请求的阶段动作。
    ///   - fingerprints: 验证成功时必填的两端相等指纹，其他动作须为 `nil`。
    ///   - now: 可持久化的更新时间，验证成功时也作为验证时间。
    /// - Returns: 更新后的控制记录。
    /// - Throws: 记录缺失、阶段冲突、非法转换、指纹无效、日期无效或数据库错误。
    public func advance(
        migrationID: UUID,
        expectedPhase: V2UserShardMigrationPhase,
        action: V2UserShardMigrationAction,
        fingerprints: (source: String, target: String)?,
        now: Date
    ) async throws -> V2UserShardMigrationRecord {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let current = try await select(migrationID: migrationID, forUpdate: true, sql: sql) else {
                throw V2UserShardMigrationStoreError.recordNotFound
            }
            guard current.phase == expectedPhase else { throw V2UserShardMigrationStoreError.phaseConflict }
            let next = try V2UserShardMigrationStateMachine.transition(from: current.phase, by: action)
            let shouldPersistFingerprints = action == .verificationSucceeded || action == .forwardingVerificationSucceeded
            if shouldPersistFingerprints {
                guard let fingerprints, validFingerprint(fingerprints.source), fingerprints.source == fingerprints.target else {
                    throw V2UserShardMigrationStoreError.invalidFingerprint
                }
            } else if fingerprints != nil {
                throw V2UserShardMigrationStoreError.invalidFingerprint
            }
            let source = shouldPersistFingerprints ? fingerprints!.source : current.sourceFingerprint
            let target = shouldPersistFingerprints ? fingerprints!.target : current.targetFingerprint
            guard v2PostgresTimestampCanEncode(now) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let verifiedAt: Date? = shouldPersistFingerprints ? now : current.verifiedAt
            try await sql.raw("""
                UPDATE im_v2.user_shard_migrations
                SET phase = \(bind: next.rawValue),
                    source_fingerprint = \(bind: source),
                    target_fingerprint = \(bind: target),
                    verified_at = \(bind: verifiedAt),
                    last_error_code = NULL,
                    updated_at = \(bind: now)
                WHERE migration_id = \(bind: migrationID)
                """).run()
            return try current.record(
                phase: next, sourceFingerprint: source, targetFingerprint: target,
                verifiedAt: verifiedAt, lastErrorCodeOverride: .some(nil)
            )
        }
    }

    /// 锁定并核对阶段后标记失败，保留原指纹和其他迁移元数据。
    ///
    /// - Parameters:
    ///   - migrationID: 目标迁移标识。
    ///   - expectedPhase: 失败对应的预期阶段。
    ///   - code: 固定失败类别，不含原始错误文本。
    ///   - now: 可持久化的更新时间。
    /// - Returns: 新的失败阶段记录。
    /// - Throws: 记录缺失、阶段冲突、状态不允许失败、日期无效或数据库错误。
    public func fail(
        migrationID: UUID,
        expectedPhase: V2UserShardMigrationPhase,
        code: V2UserShardMigrationFailureCode,
        now: Date
    ) async throws -> V2UserShardMigrationRecord {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let current = try await select(migrationID: migrationID, forUpdate: true, sql: sql) else {
                throw V2UserShardMigrationStoreError.recordNotFound
            }
            guard current.phase == expectedPhase else { throw V2UserShardMigrationStoreError.phaseConflict }
            let next = try V2UserShardMigrationStateMachine.transition(from: current.phase, by: .fail)
            guard v2PostgresTimestampCanEncode(now) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                UPDATE im_v2.user_shard_migrations
                SET phase = \(bind: next.rawValue), last_error_code = \(bind: code.rawValue), updated_at = \(bind: now)
                WHERE migration_id = \(bind: migrationID)
                """).run()
            return try current.record(phase: next, lastErrorCodeOverride: .some(code))
        }
    }

    /// 按迁移 ID 读取一行；需要阶段变更保护时由调用方在事务中启用更新锁。
    private func select(migrationID: UUID, forUpdate: Bool, sql: any SQLDatabase) async throws -> V2PostgresUserShardMigrationRow? {
        try await sql.raw("""
            SELECT migration_id, user_id, source_bucket, target_bucket, source_router_epoch, phase,
                   source_fingerprint, target_fingerprint, verified_at, last_error_code,
                   cutover_operation_id, retention_until
            FROM im_v2.user_shard_migrations
            WHERE migration_id = \(bind: migrationID)
            \(unsafeRaw: forUpdate ? "FOR UPDATE" : "")
            """).first(decoding: V2PostgresUserShardMigrationRow.self)
    }

    /// 按用户读取一行，更新锁开关仅由内部调用方决定。
    private func select(userID: UserID, forUpdate: Bool, sql: any SQLDatabase) async throws -> V2PostgresUserShardMigrationRow? {
        try await sql.raw("""
            SELECT migration_id, user_id, source_bucket, target_bucket, source_router_epoch, phase,
                   source_fingerprint, target_fingerprint, verified_at, last_error_code,
                   cutover_operation_id, retention_until
            FROM im_v2.user_shard_migrations
            WHERE user_id = \(bind: try userUUID(userID))
            \(unsafeRaw: forUpdate ? "FOR UPDATE" : "")
            """).first(decoding: V2PostgresUserShardMigrationRow.self)
    }
}

/// 编码供 PostgreSQL 集合展开的 UTF-8 JSON，编码或文本转换失败时抛错。
private func migrationJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

extension PostgresV2UserShardMigrationStore: V2UserShardMigrationRetentionStoring {
    /// 批量领取已到保留期限且没有有效旧租约的迁移，使用跳过已锁定行的事务查询。
    ///
    /// 候选按保留期限和迁移 ID 排序，整批共享本次生成的令牌，并为每行设置新到期时间。
    /// 重试计数饱和递增，不在此事务中删除源端数据；返回行顺序不作保证。
    ///
    /// - Parameters:
    ///   - now: 判断保留期、旧租约及计算新租约的基准日期。
    ///   - leaseDuration: 租约秒数，须生成可编码且严格晚于基准的期限。
    ///   - limit: 最大领取行数。
    /// - Returns: 领取凭据列表；时长非正或数量非正直接返回空列表。
    /// - Throws: 时间范围无效、SQL 能力缺失、查询或行解码错误。
    public func claimExpiredRetention(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2UserShardMigrationRetentionLease] {
        guard leaseDuration > 0, limit > 0 else { return [] }
        guard let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let token = makeUUID()
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows = try await sql.raw("""
                WITH candidates AS (
                    SELECT migration_id
                    FROM im_v2.user_shard_migrations
                    WHERE phase = 'retention' AND retention_until <= \(bind: now)
                      AND (retention_claim_expires_at IS NULL OR retention_claim_expires_at <= \(bind: now))
                    ORDER BY retention_until, migration_id
                    LIMIT \(bind: limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE im_v2.user_shard_migrations AS migration
                SET retention_claim_token = \(bind: token),
                    retention_claim_expires_at = \(bind: expiry),
                    retention_retry_count = CASE WHEN migration.retention_retry_count = 9223372036854775807
                        THEN migration.retention_retry_count ELSE migration.retention_retry_count + 1 END,
                    updated_at = \(bind: now)
                FROM candidates
                WHERE migration.migration_id = candidates.migration_id
                RETURNING migration.migration_id, migration.user_id, migration.source_bucket, migration.target_bucket,
                          migration.source_router_epoch, migration.phase, migration.source_fingerprint,
                          migration.target_fingerprint, migration.verified_at, migration.last_error_code,
                          migration.cutover_operation_id, migration.retention_until
                """).all(decoding: V2PostgresUserShardMigrationRow.self)
            return try rows.map { .init(record: try $0.record(), claimToken: token) }
        }
    }

    /// 用迁移 ID、保留阶段和领取令牌匹配记录，将其标为完成并清空租约。
    ///
    /// 不再检查租约期限，也不读取源端验证实际删除结果。若清理后已经被其他工作器重新领取，
    /// 旧令牌无法完成该记录；源端清理需允许安全重试。
    ///
    /// - Parameters:
    ///   - lease: 清理依据的迁移记录与令牌。
    ///   - now: 完成更新时间，必须可编码。
    /// - Returns: 更新到一行时为 `true`，阶段或令牌不匹配时为 `false`。
    /// - Throws: 日期无效、SQL 能力缺失或数据库错误。
    public func completeRetention(_ lease: V2UserShardMigrationRetentionLease, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let completed = try V2UserShardMigrationStateMachine.transition(from: .retention, by: .complete)
        return try await sql.raw("""
            UPDATE im_v2.user_shard_migrations
            SET phase = \(bind: completed.rawValue),
                retention_claim_token = NULL, retention_claim_expires_at = NULL,
                updated_at = \(bind: now)
            WHERE migration_id = \(bind: lease.record.migrationID)
              AND phase = 'retention' AND retention_claim_token = \(bind: lease.claimToken)
            RETURNING migration_id
            """).first(decoding: V2MigrationIDRow.self) != nil
    }
}

/// 迁移表解码行，将数据库字段映射到领域记录。
private struct V2PostgresUserShardMigrationRow: Decodable {
    let migrationID: UUID
    let userID: UUID
    let sourceBucket: String
    let targetBucket: String
    let sourceRouterEpoch: Int64
    let phase: V2UserShardMigrationPhase
    let sourceFingerprint: String?
    let targetFingerprint: String?
    let verifiedAt: Date?
    let lastErrorCode: V2UserShardMigrationFailureCode?
    let cutoverOperationID: UUID?
    let retentionUntil: Date?

    enum CodingKeys: String, CodingKey {
        case migrationID = "migration_id", userID = "user_id", sourceBucket = "source_bucket", targetBucket = "target_bucket"
        case sourceRouterEpoch = "source_router_epoch", phase, sourceFingerprint = "source_fingerprint", targetFingerprint = "target_fingerprint"
        case verifiedAt = "verified_at", lastErrorCode = "last_error_code"
        case cutoverOperationID = "cutover_operation_id", retentionUntil = "retention_until"
    }

    /// 比较准备请求的迁移 ID、桶和代次；用户匹配由调用前的用户查询保证。
    func matches(_ request: V2UserShardMigrationPreparation) -> Bool {
        migrationID == request.migrationID && sourceBucket == request.sourceBucket && targetBucket == request.targetBucket && sourceRouterEpoch == request.sourceRouterEpoch
    }

    /// 构造领域记录，普通可选覆盖值为 nil 时沿用旧值；失败码双重可选允许显式清空。
    func record(
        phase: V2UserShardMigrationPhase? = nil,
        sourceFingerprint: String? = nil,
        targetFingerprint: String? = nil,
        verifiedAt: Date? = nil,
        lastErrorCodeOverride: V2UserShardMigrationFailureCode?? = nil
    ) throws -> V2UserShardMigrationRecord {
        try .init(
            migrationID: migrationID, userID: .init(userID.uuidString), sourceBucket: sourceBucket, targetBucket: targetBucket,
            sourceRouterEpoch: sourceRouterEpoch, phase: phase ?? self.phase,
            sourceFingerprint: sourceFingerprint ?? self.sourceFingerprint,
            targetFingerprint: targetFingerprint ?? self.targetFingerprint,
            verifiedAt: verifiedAt ?? self.verifiedAt,
            lastErrorCode: lastErrorCodeOverride ?? self.lastErrorCode,
            cutoverOperationID: cutoverOperationID,
            retentionUntil: retentionUntil
        )
    }
}

/// 完成更新返回的迁移标识行，用于判断是否匹配到记录。
private struct V2MigrationIDRow: Decodable {
    let migrationID: UUID
    enum CodingKeys: String, CodingKey { case migrationID = "migration_id" }
}

/// 将用户标识转换为数据库 UUID，失败按持久化状态异常报告。
private func userUUID(_ userID: UserID) throws -> UUID {
    guard let parsed = UUID(uuidString: userID.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return parsed
}

/// 验证指纹非空、UTF-8 不超过 256 字节，且不含 U+0020 以下字符或 DEL；不限制为十六进制。
private func validFingerprint(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
}
