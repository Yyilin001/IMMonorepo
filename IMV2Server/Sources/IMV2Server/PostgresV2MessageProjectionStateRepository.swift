import Foundation
import IMV2Core
import SQLKit

enum V2MessageProjectionStateStorage: String, Sendable {
    case inline
    case roomEvent = "room_event"
}

struct V2StoredMessageProjectionState: Equatable, Sendable {
    let stateID: UUID
    let messageID: UUID
    let roomID: UUID
    let messageRevision: Int64
    let variantKey: Int16
    let originEventID: UUID
    let stateEventID: UUID?
    let isWithdrawn: Bool
    let payloadSchemaVersion: Int16
    let payloadJSON: String
    let createdAt: Date

    init(
        stateID: UUID,
        messageID: UUID,
        roomID: UUID,
        messageRevision: Int64,
        variantKey: Int16,
        originEventID: UUID,
        stateEventID: UUID?,
        isWithdrawn: Bool,
        payloadSchemaVersion: Int16,
        payloadJSON: String,
        createdAt: Date
    ) {
        self.stateID = stateID
        self.messageID = messageID
        self.roomID = roomID
        self.messageRevision = messageRevision
        self.variantKey = variantKey
        self.originEventID = originEventID
        self.stateEventID = stateEventID
        self.isWithdrawn = isWithdrawn
        self.payloadSchemaVersion = payloadSchemaVersion
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }

    init(
        state: V2MessageProjectionState,
        originEventID: UUID,
        stateEventID: UUID?,
        variantKey: Int16 = 0,
        createdAt: Date
    ) throws {
        guard let messageID = UUID(uuidString: state.messageID.rawValue),
              let roomID = UUID(uuidString: state.roomID.rawValue),
              state.messageRevision <= UInt64(Int64.max)
        else { throw V2MessageProjectionStatePersistenceError.corruptPersistence }
        let revision = Int64(state.messageRevision)
        self.stateID = try v2MessageProjectionStateID(
            messageID: messageID,
            messageRevision: revision,
            variantKey: variantKey
        )
        self.messageID = messageID
        self.roomID = roomID
        self.messageRevision = revision
        self.variantKey = variantKey
        self.originEventID = originEventID
        self.stateEventID = stateEventID
        self.isWithdrawn = state.isWithdrawn
        self.payloadSchemaVersion = V2MessageProjectionState.payloadSchemaVersion
        self.payloadJSON = try state.encodedPayloadJSON()
        self.createdAt = createdAt
    }

    var state: V2MessageProjectionState {
        get throws {
            let decoded = try V2MessageProjectionState(payloadJSON: payloadJSON)
            guard messageRevision > 0,
                  UUID(uuidString: decoded.messageID.rawValue) == messageID,
                  UUID(uuidString: decoded.roomID.rawValue) == roomID,
                  decoded.messageRevision == UInt64(messageRevision),
                  decoded.isWithdrawn == isWithdrawn,
                  payloadSchemaVersion == V2MessageProjectionState.payloadSchemaVersion,
                  try v2MessageProjectionStateID(
                    messageID: messageID,
                    messageRevision: messageRevision,
                    variantKey: variantKey
                  ) == stateID
            else { throw V2MessageProjectionStatePersistenceError.corruptPersistence }
            return decoded
        }
    }
}

/// 不可变消息投影状态的 SQL 边界。
///
/// 每次写入都是「幂等创建 + 等值校验」：重试可以复用已有状态，
/// 但绝不能覆盖内容不一致的规范状态。
struct PostgresV2MessageProjectionStateRepository: Sendable {
    /// 目标 schema。
    let schema: String

    /// 校验并保存 schema。
    ///
    /// - Parameter schema: 目标 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`，默认 `im_v2`。
    ///
    /// schema 名不满足格式时直接失败，避免拼接出非法 SQL 标识符。
    init(schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.schema = schema
    }

    /// 幂等持久化一个不可变状态。
    ///
    /// 写入后会以状态标识与载荷等值校验确认结果：已存在不同内容时视为持久化冲突而非覆盖。
    ///
    /// - Parameters:
    ///   - value: 待持久化的状态。
    ///   - storage: 载荷存放方式，默认内联。
    ///   - persistedCreatedAt: 已编码的创建时刻；为空时按状态自带时刻编码。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Throws: 状态标识不一致或载荷冲突时抛出
    ///   ``V2MessageProjectionStatePersistenceError/corruptPersistence``。
    func persist(
        _ value: V2StoredMessageProjectionState,
        storage: V2MessageProjectionStateStorage = .inline,
        persistedCreatedAt: V2PostgresTimestamp? = nil,
        sql: any SQLDatabase
    ) async throws {
        let createdAt = try persistedCreatedAt ?? V2PostgresTimestamp(date: value.createdAt)
        // A data-modifying CTE does not expose its inserted row through a
        // sibling scan of the base table in the same statement snapshot.
        // Keep the successful insert in `inserted`, and consult the base
        // table only for the conflict/retry branch. This preserves the strict
        // immutable equality fence while reducing persist from two database
        // round trips to one.
        let verified = try await sql.raw("""
            WITH validated AS MATERIALIZED (
                SELECT 1
                WHERE \(bind: storage.rawValue) = 'inline'
                   OR (
                       \(bind: storage.rawValue) = 'room_event'
                       AND EXISTS (
                           SELECT 1
                           FROM \(unsafeRaw: table("room_events")) AS event
                           WHERE event.event_id = \(bind: value.stateEventID)
                             AND event.room_id = \(bind: value.roomID)
                             AND event.event_type = 'message.accepted'
                             AND lower(event.payload->>'message_id') = \(bind: value.messageID.uuidString.lowercased())
                             AND lower(event.payload->>'room_id') = \(bind: value.roomID.uuidString.lowercased())
                             AND (event.payload->>'message_revision')::bigint = \(bind: value.messageRevision)
                             AND event.payload = \(bind: value.payloadJSON)::jsonb
                       )
                   )
            ), inserted AS (
                INSERT INTO \(unsafeRaw: table("message_projection_states"))
                (state_id, message_id, room_id, message_revision, variant_key,
                 origin_event_id, state_event_id, is_withdrawn,
                 payload_schema_version, payload, created_at, payload_storage)
                SELECT \(bind: value.stateID), \(bind: value.messageID), \(bind: value.roomID),
                       \(bind: value.messageRevision), \(bind: value.variantKey),
                       \(bind: value.originEventID), \(bind: value.stateEventID),
                       \(bind: value.isWithdrawn), \(bind: value.payloadSchemaVersion),
                       CASE WHEN \(bind: storage.rawValue) = 'inline'
                            THEN \(bind: value.payloadJSON)::jsonb ELSE NULL END,
                       \(bind: createdAt), \(bind: storage.rawValue)
                FROM validated
                ON CONFLICT DO NOTHING
                RETURNING 1
            )
            SELECT CASE
                WHEN EXISTS (SELECT 1 FROM inserted)
                  OR EXISTS (
                    SELECT 1
                    FROM \(unsafeRaw: table("message_projection_state_values"))
                    WHERE state_id = \(bind: value.stateID)
                      AND message_id = \(bind: value.messageID)
                      AND room_id = \(bind: value.roomID)
                      AND message_revision = \(bind: value.messageRevision)
                      AND variant_key = \(bind: value.variantKey)
                      AND origin_event_id = \(bind: value.originEventID)
                      AND state_event_id IS NOT DISTINCT FROM \(bind: value.stateEventID)
                      AND is_withdrawn = \(bind: value.isWithdrawn)
                      AND payload_schema_version = \(bind: value.payloadSchemaVersion)
                      AND payload = \(bind: value.payloadJSON)::jsonb
                  )
                THEN 1 ELSE 0
            END AS value
            """).first(decoding: MessageProjectionStateExistsRow.self)
        guard verified?.value == 1 else {
            // `INSERT .. ON CONFLICT DO NOTHING` can observe an uncommitted
            // conflicting tuple that the statement's earlier MVCC snapshot
            // cannot see through the base-table branch above. A new statement
            // gets a fresh READ COMMITTED snapshot after that conflict has
            // resolved. Keep this second read off the uncontended hot path,
            // while preserving true concurrent idempotency without issuing a
            // no-op `DO UPDATE` that would create a new heap/WAL version.
            guard let concurrentReplay = try await sql.raw("""
                SELECT 1 AS value
                FROM \(unsafeRaw: table("message_projection_state_values"))
                WHERE state_id = \(bind: value.stateID)
                  AND message_id = \(bind: value.messageID)
                  AND room_id = \(bind: value.roomID)
                  AND message_revision = \(bind: value.messageRevision)
                  AND variant_key = \(bind: value.variantKey)
                  AND origin_event_id = \(bind: value.originEventID)
                  AND state_event_id IS NOT DISTINCT FROM \(bind: value.stateEventID)
                  AND is_withdrawn = \(bind: value.isWithdrawn)
                  AND payload_schema_version = \(bind: value.payloadSchemaVersion)
                  AND payload = \(bind: value.payloadJSON)::jsonb
                """).first(decoding: MessageProjectionStateExistsRow.self),
                  concurrentReplay.value == 1
            else {
                throw V2MessageProjectionStatePersistenceError.conflictingState
            }
            return
        }
    }

    /// 按消息、修订与变体键读取状态。
    ///
    /// - Parameters:
    ///   - messageID: 目标消息。
    ///   - revision: 消息修订，需大于零。
    ///   - variantKey: 变体键，需非负，默认 0。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Returns: 对应状态；不存在时返回 `nil`。
    /// - Throws: 修订或变体键非法、或记录无法解码时抛出
    ///   ``V2MessageProjectionStatePersistenceError/corruptPersistence``。
    func load(
        messageID: UUID,
        revision: Int64,
        variantKey: Int16 = 0,
        sql: any SQLDatabase
    ) async throws -> V2StoredMessageProjectionState? {
        guard revision > 0, variantKey >= 0 else {
            throw V2MessageProjectionStatePersistenceError.corruptPersistence
        }
        return try await sql.raw("""
            SELECT state_id, message_id, room_id, message_revision, variant_key,
                   origin_event_id, state_event_id, is_withdrawn,
                   payload_schema_version, payload::text AS payload_json, created_at
            FROM \(unsafeRaw: table("message_projection_state_values"))
            WHERE message_id = \(bind: messageID)
              AND message_revision = \(bind: revision)
              AND variant_key = \(bind: variantKey)
            """).first(decoding: MessageProjectionStateRow.self)?.value
    }

    /// 按状态标识读取状态。
    ///
    /// - Parameters:
    ///   - stateID: 状态标识。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Returns: 对应状态；不存在时返回 `nil`。
    /// - Throws: 记录无法解码时抛出
    ///   ``V2MessageProjectionStatePersistenceError/corruptPersistence``。
    func load(
        stateID: UUID,
        sql: any SQLDatabase
    ) async throws -> V2StoredMessageProjectionState? {
        try await sql.raw("""
            SELECT state_id, message_id, room_id, message_revision, variant_key,
                   origin_event_id, state_event_id, is_withdrawn,
                   payload_schema_version, payload::text AS payload_json, created_at
            FROM \(unsafeRaw: table("message_projection_state_values"))
            WHERE state_id = \(bind: stateID)
            """).first(decoding: MessageProjectionStateRow.self)?.value
    }

    /// 面向「消息变更先于有界历史回填到达」的过渡期自愈路径。
    ///
    /// 它只读取控制面权威数据并持久化一个不可变的当前状态；
    /// 迁移完成后的常规写入始终命中上面的 `load` 路径。
    ///
    /// - Parameters:
    ///   - messageID: 目标消息。
    ///   - revision: 目标修订。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Returns: 已存在或刚刚物化的状态。
    /// - Throws: 控制面缺少必要记录或状态载荷非法时抛出
    ///   ``V2MessageProjectionStatePersistenceError/corruptPersistence``。
    func loadCurrentOrMaterialize(
        messageID: UUID,
        revision: Int64,
        sql: any SQLDatabase
    ) async throws -> V2StoredMessageProjectionState {
        if let existing = try await load(messageID: messageID, revision: revision, sql: sql) {
            _ = try existing.state
            return existing
        }
        guard let source = try await sql.raw("""
            SELECT message.text_body,
                   message.rich_entities::text AS entities_json,
                   message.withdrawn_at,
                   CASE
                       WHEN message.accepted_event_storage = 'message_row'
                       THEN message.accepted_event_id
                       ELSE accepted.event_id
                   END AS origin_event_id,
                   CASE
                       WHEN message.accepted_event_storage = 'message_row'
                       THEN jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', message.message_id::text,
                           'room_id', message.room_id::text,
                           'room_sequence', message.room_sequence,
                           'timeline_sequence', message.timeline_sequence,
                           'sender_user_id', message.sender_user_id::text,
                           'text', message.text_body,
                           'media_ids', '[]'::jsonb,
                           'media_presentations', '[]'::jsonb,
                           'mention_user_ids', '[]'::jsonb,
                           'mentions_everyone', FALSE,
                           'entities', message.rich_entities,
                           'reply_to_message_id',
                               message.reply_to_message_id::text,
                           'forwarded_from_message_id',
                               message.forwarded_from_message_id::text,
                           'forwarded_from_user_id',
                               message.forwarded_from_user_id::text,
                           'message_revision', 1,
                           'server_created_at_ms',
                               floor(extract(epoch FROM message.created_at)
                                     * 1000)::bigint
                       )
                       ELSE accepted.payload
                   END::text AS accepted_payload_json,
                   message.created_at
            FROM \(unsafeRaw: table("messages")) AS message
            LEFT JOIN \(unsafeRaw: table("room_events")) AS accepted
              ON message.accepted_event_storage = 'room_event'
             AND accepted.room_id = message.room_id
             AND accepted.room_sequence = message.room_sequence
             AND accepted.event_type = 'message.accepted'
            WHERE message.message_id = \(bind: messageID)
              AND message.content_revision = \(bind: revision)
              AND (
                  (
                      message.accepted_event_storage = 'message_row'
                      AND message.accepted_event_id IS NOT NULL
                      AND message.accepted_membership_revision IS NOT NULL
                  )
                  OR accepted.event_id IS NOT NULL
              )
            """).first(decoding: MessageProjectionStateMaterializationRow.self),
              source.withdrawnAt == nil,
              let entityData = source.entitiesJSON.data(using: .utf8)
        else { throw V2MessageProjectionStatePersistenceError.corruptPersistence }
        let entities: [V2MessageEntity]
        do {
            entities = try JSONDecoder().decode([V2MessageEntity].self, from: entityData)
        } catch {
            throw V2MessageProjectionStatePersistenceError.corruptPersistence
        }
        let accepted = try V2MessageProjectionState(payloadJSON: source.acceptedPayloadJSON)
        let restored: V2MessageProjectionState
        do {
            restored = try accepted.restoringActiveRevision(
                UInt64(revision),
                text: source.text,
                entities: entities
            )
        } catch {
            throw V2MessageProjectionStatePersistenceError.corruptPersistence
        }
        let value = try V2StoredMessageProjectionState(
            state: restored,
            originEventID: source.originEventID,
            stateEventID: revision == 1 ? source.originEventID : nil,
            createdAt: source.createdAt.date
        )
        try await persist(value, persistedCreatedAt: source.createdAt, sql: sql)
        return value
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

enum V2MessageProjectionStatePersistenceError: Error, Equatable, Sendable {
    case conflictingState
    case corruptPersistence
}

private struct MessageProjectionStateExistsRow: Decodable { let value: Int }

private struct MessageProjectionStateRow: Decodable {
    let stateID: UUID
    let messageID: UUID
    let roomID: UUID
    let messageRevision: Int64
    let variantKey: Int16
    let originEventID: UUID
    let stateEventID: UUID?
    let isWithdrawn: Bool
    let payloadSchemaVersion: Int16
    let payloadJSON: String
    let createdAt: Date

    var value: V2StoredMessageProjectionState {
        .init(
            stateID: stateID,
            messageID: messageID,
            roomID: roomID,
            messageRevision: messageRevision,
            variantKey: variantKey,
            originEventID: originEventID,
            stateEventID: stateEventID,
            isWithdrawn: isWithdrawn,
            payloadSchemaVersion: payloadSchemaVersion,
            payloadJSON: payloadJSON,
            createdAt: createdAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case stateID = "state_id"
        case messageID = "message_id"
        case roomID = "room_id"
        case messageRevision = "message_revision"
        case variantKey = "variant_key"
        case originEventID = "origin_event_id"
        case stateEventID = "state_event_id"
        case isWithdrawn = "is_withdrawn"
        case payloadSchemaVersion = "payload_schema_version"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}

private struct MessageProjectionStateMaterializationRow: Decodable {
    let text: String
    let entitiesJSON: String
    let withdrawnAt: Date?
    let originEventID: UUID
    let acceptedPayloadJSON: String
    let createdAt: V2PostgresTimestamp

    private enum CodingKeys: String, CodingKey {
        case text = "text_body"
        case entitiesJSON = "entities_json"
        case withdrawnAt = "withdrawn_at"
        case originEventID = "origin_event_id"
        case acceptedPayloadJSON = "accepted_payload_json"
        case createdAt = "created_at"
    }
}
