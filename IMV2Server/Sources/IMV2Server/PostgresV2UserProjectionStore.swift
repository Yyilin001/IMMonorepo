import FluentKit
import Foundation
import IMV2Core
import SQLKit

public struct V2UserSyncProjectionMirror: Sendable {
    public let userID: UserID
    public let sequence: UInt64
    public let sourceEventID: EventID
    public let projectionKind: String
    public let payloadJSON: String
    public let createdAt: Date

    public init(userID: UserID, sequence: UInt64, sourceEventID: EventID, projectionKind: String, payloadJSON: String, createdAt: Date) {
        self.userID = userID
        self.sequence = sequence
        self.sourceEventID = sourceEventID
        self.projectionKind = projectionKind
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

/// 个人状态在用户归属库中的序号分配与精确镜像。
/// 重试使用持久化投影效果验证身份与载荷，不依赖旧扇出收件箱。
public struct PostgresV2UserProjectionStore: Sendable {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2UserShardStorageRegistryError.invalidLocation
        }
        self.database = database
        self.schema = schema
    }

    /// 镜像一条源端拥有的同步记录且不改变其序号。
    ///
    /// 它首先使用语义身份 `(user, source event, kind)`；若某序号与另一条不同记录
    /// 冲突，则视为持久化损坏，而非迁移期间可覆盖的冲突。
    ///
    /// - Parameter record: 待镜像的、已提交的用户同步记录。
    /// - Returns: 与源记录一致的持久化用户同步序号。
    /// - Throws: 标识符非法、序号超出可编码范围或持久化状态损坏时抛出。
    public func mirror(_ record: V2UserSyncProjectionMirror) async throws -> UInt64 {
        try await mirror(record, persistedCreatedAt: nil)
    }

    func mirror(
        _ record: V2UserSyncProjectionMirror,
        persistedCreatedAt: V2PostgresTimestamp?
    ) async throws -> UInt64 {
        guard let userID = UUID(uuidString: record.userID.rawValue),
              let sourceEventID = UUID(uuidString: record.sourceEventID.rawValue),
              let sequence = Int64(exactly: record.sequence), sequence > 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let existing = try await sql.raw("""
                SELECT user_sync_sequence, payload::text AS payload_json
                FROM \(unsafeRaw: table("user_projection_effects"))
                WHERE user_id = \(bind: userID) AND source_event_id = \(bind: sourceEventID)
                  AND projection_kind = \(bind: record.projectionKind)
                """).first(decoding: CrossStoreMirroredRecordRow.self) {
                guard existing.userSyncSequence == sequence, existing.payloadJSON == record.payloadJSON else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return try crossStoreUnsigned(existing.userSyncSequence)
            }
            let createdAt = try persistedCreatedAt ?? V2PostgresTimestamp(date: record.createdAt)
            if let occupying = try await sql.raw("""
                SELECT source_event_id, projection_kind
                FROM \(unsafeRaw: table("user_sync_log"))
                WHERE user_id = \(bind: userID) AND user_sync_sequence = \(bind: sequence)
                """).first(decoding: CrossStoreSequenceOccupantRow.self),
               occupying.sourceEventID != sourceEventID || occupying.projectionKind != record.projectionKind {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                VALUES (\(bind: userID), \(bind: sequence))
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = GREATEST(\(unsafeRaw: table("user_sync_sequences")).next_sequence, EXCLUDED.next_sequence)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: userID), \(bind: sequence), \(bind: sourceEventID), \(bind: record.projectionKind),
                        \(bind: record.payloadJSON)::jsonb, \(bind: createdAt))
                ON CONFLICT DO NOTHING
                """).run()
            // 排序行可能在先前镜像成功后已被压缩。无论如何，
            // 稳定的语义结果才是精确校验重试的持久来源。
            guard let mirrored = try await sql.raw("""
                SELECT user_sync_sequence, payload::text AS payload_json
                FROM \(unsafeRaw: table("user_projection_effects"))
                WHERE user_id = \(bind: userID) AND source_event_id = \(bind: sourceEventID)
                  AND projection_kind = \(bind: record.projectionKind)
                """).first(decoding: CrossStoreMirroredRecordRow.self),
                  mirrored.userSyncSequence == sequence, mirrored.payloadJSON == record.payloadJSON
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return try crossStoreUnsigned(mirrored.userSyncSequence)
        }
    }

    /// 把控制面拥有的投影追加到当前权威的用户分片。
    ///
    /// 其源事件/类型身份使重试具备幂等性，而序号由该分片分配。
    /// 切换后这是必需的：控制数据库的历史计数器不再是目标用户的实时序号计数器。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - sourceEventID: 源事件标识。
    ///   - projectionKind: 投影类型。
    ///   - payloadJSON: 投影载荷 JSON。
    ///   - createdAt: 投影创建时间。
    /// - Returns: 由目标用户分片新分配的用户同步序号。
    /// - Throws: 标识符非法、时间戳无法编码或持久化状态损坏时抛出。
    public func projectAllocated(
        userID: UserID,
        sourceEventID: EventID,
        projectionKind: String,
        payloadJSON: String,
        createdAt: Date
    ) async throws -> UInt64 {
        try await projectAllocated(userID: userID, sourceEventID: sourceEventID,
            projectionKind: projectionKind, payloadJSON: payloadJSON, createdAt: createdAt, persistedCreatedAt: nil)
    }

    func projectAllocated(
        userID: UserID,
        sourceEventID: EventID,
        projectionKind: String,
        payloadJSON: String,
        createdAt: Date,
        persistedCreatedAt: V2PostgresTimestamp?
    ) async throws -> UInt64 {
        guard let userUUID = UUID(uuidString: userID.rawValue),
              let eventUUID = UUID(uuidString: sourceEventID.rawValue)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let existing = try await sql.raw("""
                SELECT user_sync_sequence, payload::text AS payload_json
                FROM \(unsafeRaw: table("user_projection_effects"))
                WHERE user_id = \(bind: userUUID) AND source_event_id = \(bind: eventUUID)
                  AND projection_kind = \(bind: projectionKind)
                """).first(decoding: CrossStoreMirroredRecordRow.self) {
                guard existing.payloadJSON == payloadJSON else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return try crossStoreUnsigned(existing.userSyncSequence)
            }
            let timestamp = try persistedCreatedAt ?? V2PostgresTimestamp(date: createdAt)
            guard let sequence = try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_sequences")) (user_id, next_sequence)
                VALUES (\(bind: userUUID), 1)
                ON CONFLICT (user_id)
                DO UPDATE SET next_sequence = \(unsafeRaw: table("user_sync_sequences")).next_sequence + 1
                WHERE \(unsafeRaw: table("user_sync_sequences")).next_sequence < \(bind: Int64.max)
                RETURNING next_sequence AS user_sync_sequence
                """).first(decoding: CrossStoreSequenceRow.self)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: table("user_sync_log"))
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                VALUES (\(bind: userUUID), \(bind: sequence.userSyncSequence), \(bind: eventUUID), \(bind: projectionKind),
                        \(bind: payloadJSON)::jsonb, \(bind: timestamp))
                """).run()
            return try crossStoreUnsigned(sequence.userSyncSequence)
        }
    }

    private func table(_ name: String) -> String { "\(schema).\(name)" }
}

private struct CrossStoreSequenceRow: Decodable { let userSyncSequence: Int64; enum CodingKeys: String, CodingKey { case userSyncSequence = "user_sync_sequence" } }
private struct CrossStoreMirroredRecordRow: Decodable { let userSyncSequence: Int64; let payloadJSON: String; enum CodingKeys: String, CodingKey { case userSyncSequence = "user_sync_sequence", payloadJSON = "payload_json" } }
private struct CrossStoreSequenceOccupantRow: Decodable { let sourceEventID: UUID; let projectionKind: String; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", projectionKind = "projection_kind" } }
private func crossStoreUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
