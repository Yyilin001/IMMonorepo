import Fluent
import Foundation
import SQLKit

/// 消息投影回填报告。
public struct V2MessageProjectionBackfillReport: Equatable, Sendable {
    /// 本次新建立状态引用的行数。
    public let linkedRowCount: Int
    /// 本次压缩掉内联载荷的行数。
    public let compactedRowCount: Int

    /// 本轮是否产生了实际变更。
    public var didWork: Bool { linkedRowCount > 0 || compactedRowCount > 0 }
}

/// 把历史按用户存储的消息载荷增量转换为对不可变分片内消息状态的引用。
///
/// 扩展开启的迁移过程中，行始终可读：双写模式保留内联载荷，共享模式只会在同一事务内
/// 确认状态已写入之后才移除内联副本。
public struct PostgresV2MessageProjectionBackfillWorker: Sendable {
    private let database: any Database
    private let schema: String
    private let compactInlinePayloads: Bool

    /// 组合数据库、schema 与压缩开关。
    ///
    /// - Parameters:
    ///   - database: 存放用户投影版本与消息状态的数据库。
    ///   - schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///   - compactInlinePayloads: 是否在建立引用后清空内联载荷，默认保留。
    ///
    /// schema 名不满足格式时直接失败，避免拼接出非法 SQL 标识符。
    public init(
        database: any Database,
        schema: String = "im_v2",
        compactInlinePayloads: Bool = false
    ) {
        precondition(
            schema.range(
                of: "^[A-Za-z_][A-Za-z0-9_]*$",
                options: .regularExpression
            ) != nil
        )
        self.database = database
        self.schema = schema
        self.compactInlinePayloads = compactInlinePayloads
    }

    /// 执行一轮有界回填。
    ///
    /// 迁移栅栏仍在生效的行会被跳过；候选行使用 `FOR UPDATE SKIP LOCKED` 选取，
    /// 因此多个实例可安全并行。已存在状态引用时，只有在压缩模式且载荷完全一致时才接受，
    /// 否则判定为状态冲突。历史载荷必须能解码为与实体键、房间匹配且修订可写入 `Int64` 的状态。
    ///
    /// - Parameters:
    ///   - now: 本次判定的服务端时刻。
    ///   - limit: 本轮最多处理的行数。
    /// - Returns: 本轮链接与压缩的计数。
    /// - Throws: 上限非正时抛出 ``V2MessageProjectionBackfillError/invalidLimit``；
    ///   任务取消时抛出 `CancellationError`；时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2MessageProjectionBackfillError/corruptPersistence``；历史载荷无法解析或与实体不符时抛出
    ///   ``V2MessageProjectionBackfillError/invalidLegacyPayload``；已有状态与新载荷不一致时抛出
    ///   ``V2MessageProjectionBackfillError/conflictingState``。
    public func runOnce(
        now: Date = Date(),
        limit: Int = 100
    ) async throws -> V2MessageProjectionBackfillReport {
        guard limit > 0 else { throw V2MessageProjectionBackfillError.invalidLimit }
        try Task.checkCancellation()
        guard v2PostgresTimestampCanEncode(now) else { throw V2MessageProjectionBackfillError.corruptPersistence }
        return try await database.transaction { database in
            guard let sql = database as? any SQLDatabase else {
                throw V2MessageProjectionBackfillError.corruptPersistence
            }
            let rows = try await sql.raw("""
                SELECT version.user_id, version.entity_key,
                       version.valid_from_sequence, version.source_event_id,
                       version.scope_room_id, version.message_state_id,
                       version.payload::text AS payload_json, version.created_at,
                       state.payload::text AS state_payload_json
                FROM \(unsafeRaw: table("user_projection_versions")) AS version
                LEFT JOIN \(unsafeRaw: table("message_projection_state_values")) AS state
                  ON state.state_id = version.message_state_id
                WHERE version.projection_kind = 'message'
                  AND version.payload IS NOT NULL
                  AND (
                      version.message_state_id IS NULL
                      OR \(bind: compactInlinePayloads)
                  )
                  AND NOT EXISTS (
                      SELECT 1
                      FROM \(unsafeRaw: table("user_projection_checkpoints")) AS checkpoint
                      WHERE checkpoint.user_id = version.user_id
                        AND checkpoint.migration_fence_expires_at > \(bind: now)
                  )
                ORDER BY version.user_id, version.entity_key,
                         version.valid_from_sequence
                LIMIT \(bind: limit)
                FOR UPDATE OF version SKIP LOCKED
                """).all(decoding: MessageProjectionBackfillRow.self)
            guard !rows.isEmpty else {
                return .init(linkedRowCount: 0, compactedRowCount: 0)
            }

            let repository = PostgresV2MessageProjectionStateRepository(schema: schema)
            var linked = 0
            var compacted = 0
            for row in rows {
                try Task.checkCancellation()
                let stateID: UUID
                if let existingStateID = row.messageStateID {
                    guard compactInlinePayloads,
                          row.statePayloadJSON == row.payloadJSON
                    else { throw V2MessageProjectionBackfillError.conflictingState }
                    stateID = existingStateID
                } else {
                    guard let payloadJSON = row.payloadJSON,
                          let messageID = UUID(uuidString: row.entityKey),
                          let roomID = row.roomID
                    else { throw V2MessageProjectionBackfillError.invalidLegacyPayload }
                    let state: V2MessageProjectionState
                    do {
                        state = try .init(payloadJSON: payloadJSON)
                    } catch {
                        throw V2MessageProjectionBackfillError.invalidLegacyPayload
                    }
                    guard UUID(uuidString: state.messageID.rawValue) == messageID,
                          UUID(uuidString: state.roomID.rawValue) == roomID,
                          state.messageRevision <= UInt64(Int64.max)
                    else { throw V2MessageProjectionBackfillError.invalidLegacyPayload }
                    let stateEventID = state.messageRevision == 1 ? row.sourceEventID : nil
                    let stored = try V2StoredMessageProjectionState(
                        state: state,
                        originEventID: row.sourceEventID,
                        stateEventID: stateEventID,
                        createdAt: row.createdAt.date
                    )
                    try await repository.persist(stored, persistedCreatedAt: row.createdAt, sql: sql)
                    stateID = stored.stateID
                    linked += 1
                }

                try await sql.raw("""
                    UPDATE \(unsafeRaw: table("user_projection_versions"))
                    SET message_state_id = \(bind: stateID),
                        payload = CASE
                            WHEN \(bind: compactInlinePayloads) THEN NULL
                            ELSE payload
                        END
                    WHERE user_id = \(bind: row.userID)
                      AND projection_kind = 'message'
                      AND entity_key = \(bind: row.entityKey)
                      AND valid_from_sequence = \(bind: row.validFromSequence)
                    """).run()
                if compactInlinePayloads { compacted += 1 }
            }
            return .init(linkedRowCount: linked, compactedRowCount: compacted)
        }
    }

    /// 拼接 schema 限定的表名。
    ///
    /// - Parameter name: 表名，仅允许来自代码内常量。
    /// - Returns: 形如 `schema.table` 的限定名。
    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

/// 消息投影回填错误。
public enum V2MessageProjectionBackfillError: Error, Equatable, Sendable {
    /// 单轮处理上限为非正值。
    case invalidLimit
    /// 持久化状态损坏或数据库适配器不受支持。
    case corruptPersistence
    /// 历史载荷无法解码为合法的消息投影状态。
    case invalidLegacyPayload
    /// 已有状态引用携带的载荷与新载荷不一致。
    case conflictingState
}

private struct MessageProjectionBackfillRow: Decodable {
    let userID: UUID
    let entityKey: String
    let validFromSequence: Int64
    let sourceEventID: UUID
    let roomID: UUID?
    let messageStateID: UUID?
    let payloadJSON: String?
    let createdAt: V2PostgresTimestamp
    let statePayloadJSON: String?
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", entityKey = "entity_key"
        case validFromSequence = "valid_from_sequence"
        case sourceEventID = "source_event_id", roomID = "scope_room_id"
        case messageStateID = "message_state_id", payloadJSON = "payload_json"
        case createdAt = "created_at", statePayloadJSON = "state_payload_json"
    }
}
