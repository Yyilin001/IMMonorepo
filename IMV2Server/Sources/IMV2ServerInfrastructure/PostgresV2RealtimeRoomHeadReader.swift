import Foundation
import FluentKit
import SQLKit
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts

/// Internal committed watermarks for already authorized Gateway interests.
/// Content/member authorization stays at the connection's registration/read
/// barrier. This service never discovers a realtime recipient.
public struct PostgresV2RealtimeRoomHeadReader: Sendable {
    private let database: any Database
    private let schema: String
    public init(database: any Database, schema: String = "im_v2") throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RealtimeDirectoryError.invalidInput
        }
        self.database = database; self.schema = schema
    }
    /// Exactly one query for valid topics, with missing/changed authority
    /// isolated to those topics. SQL/decoding failures remain group failures.
    public func heads(topics: [V2RealtimeTopic]) async throws -> [V2RealtimeTopic: V2RealtimeRecoveryHeadOutcome] {
        guard topics.count <= 128, let sql = database as? any SQLDatabase else { throw V2RealtimeDirectoryError.invalidInput }
        var result: [V2RealtimeTopic: V2RealtimeRecoveryHeadOutcome] = [:]
        var valid: [V2RealtimeTopic] = []
        for topic in Set(topics) {
            guard topic.kind == .roomEvents, UUID(uuidString: topic.id) != nil else {
                result[topic] = .unavailable(.invalid); continue
            }
            valid.append(topic)
        }
        guard !valid.isEmpty else { return result }
        let ids = Array(Set(valid.compactMap { UUID(uuidString: $0.id) }))
        let rows = try await sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch, room_sequence
            FROM \(unsafeRaw: schema).rooms WHERE room_id = ANY(\(bind: ids)::uuid[])
            """).all(decoding: Row.self)
        var values: [UUID: Row] = [:]
        for row in rows {
            guard ids.contains(row.roomID), values[row.roomID] == nil else { throw V2RealtimeDirectoryError.corruptPersistenceState }
            values[row.roomID] = row
        }
        for topic in valid {
            guard let id = UUID(uuidString: topic.id), let row = values[id],
                  row.shardID == topic.owner.shardID, row.ownerEpoch == topic.owner.epoch else {
                result[topic] = .unavailable(.wrongOwner); continue
            }
            guard row.sequence >= 0 else { result[topic] = .unavailable(.dependency); continue }
            result[topic] = .available(UInt64(row.sequence))
        }
        return result
    }
    private struct Row: Decodable {
        let roomID: UUID
        let shardID: String
        let ownerEpoch: Int64
        let sequence: Int64
        enum CodingKeys: String, CodingKey {
            case roomID = "room_id", shardID = "room_shard_id", ownerEpoch = "owner_epoch", sequence = "room_sequence"
        }
    }
}
