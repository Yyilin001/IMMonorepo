import Foundation
import FluentKit
import SQLKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication

/// Reuses the transactionally maintained latest-H row. Discovery is advisory and restricted to supplied active references.
/// The composition pins native lifetimes through actual ACK SQL completion.
public struct PostgresV2RoomSubscriptionDirtyHeadStore: Sendable {
    private let database: any Database
    private let schema: String
    private let admission: V2DatabaseWorkAdmissionController?
    public init(database: any Database, schema: String = "im_v2", databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw V2RoomSubscriptionSourceError.invalidInput }
        self.database = database; self.schema = schema; self.admission = databaseWorkAdmission
    }
    /// Production discovery starts at the durable pending index, not a list of
    /// all active rooms. Caller pins each returned exact token before consuming.
    public func pending(activeTokens: [V2RoomActivationToken], after: V2RoomSubscriptionDirtyCursor?, limit: Int = 128,
                        deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionDirtyPage {
        guard activeTokens.count <= 8192, Set(activeTokens.map(\.roomID)).count == activeTokens.count,
              activeTokens.allSatisfy({ $0.roomID.uuidValue != nil }), (1...128).contains(limit), after.map({ (0..<256).contains($0.partitionID) }) ?? true else { throw V2RoomSubscriptionSourceError.invalidInput }
        let tokens = Dictionary(uniqueKeysWithValues: activeTokens.map { ($0.roomID.uuidValue!, $0) })
        let rows: [HostRow] = try await transaction(deadline: deadline) { sql in
            try await sql.raw(self.pendingHostQuery(activeTokens: activeTokens, after: after, limit: limit)).all(decoding: HostRow.self)
        }
        let changes = try rows.map { row -> V2RoomSubscriptionDirtyHead in
            guard row.room_sequence >= 0, row.revision > 0, row.room_control_version >= 0 else { throw V2RoomSubscriptionSourceError.corruptPersistence }
            guard let token = tokens[row.room_id], token.owner.shardID == row.owner_shard_id,
                  token.owner.epoch == row.owner_epoch else { throw V2RoomSubscriptionSourceError.wrongOwner }
            return .init(activation: token, highWatermark: UInt64(row.room_sequence), revision: row.revision, roomControlVersion: row.room_control_version)
        }
        return .init(changes: changes, nextCursor: rows.last.map { .init(partitionID: $0.partition_id, roomID: $0.room_id) })
    }
    package func pendingHostQuery(activeTokens: [V2RoomActivationToken], after: V2RoomSubscriptionDirtyCursor?, limit: Int) -> SQLQueryString {
        let lower: SQLQueryString = after.map { "AND (h.partition_id,h.room_id)>(\(bind: $0.partitionID),\(bind: $0.roomID))" } ?? ""
        let rooms = activeTokens.map { $0.roomID.uuidValue! }
        let shards = activeTokens.map { $0.owner.shardID }
        let epochs = activeTokens.map { $0.owner.epoch }
        return """
            WITH requested AS MATERIALIZED (
                SELECT * FROM unnest(\(bind: rooms)::uuid[], \(bind: shards)::text[], \(bind: epochs)::bigint[])
                  AS x(room_id,owner_shard_id,owner_epoch)
            )
            SELECT h.room_id,h.partition_id,h.room_sequence,h.revision,h.room_control_version,
                   r.room_shard_id AS owner_shard_id,r.owner_epoch
            FROM \(unsafeRaw: schema).realtime_dirty_room_heads h
            JOIN requested x ON x.room_id=h.room_id
            JOIN \(unsafeRaw: schema).rooms r ON r.room_id=h.room_id
            WHERE h.pending \(lower)
              AND r.room_shard_id=x.owner_shard_id AND r.owner_epoch=x.owner_epoch
              AND h.owner_epoch=x.owner_epoch AND h.room_sequence<=r.room_sequence
            ORDER BY h.partition_id,h.room_id LIMIT \(bind: limit)
            """
    }
    private struct HostRow: Decodable, Sendable {
        let room_id: UUID; let partition_id: Int; let room_sequence: Int64; let revision: Int64; let room_control_version: Int64
        let owner_shard_id: String; let owner_epoch: Int64
    }

    package func acknowledge(_ heads: [V2RoomSubscriptionDirtyHead], deadline: ContinuousClock.Instant) async throws {
        guard heads.count <= 8192, heads.allSatisfy({ $0.activation.roomID.uuidValue != nil && $0.highWatermark <= UInt64(Int64.max) && $0.revision > 0 && $0.roomControlVersion >= 0 }) else { throw V2RoomSubscriptionSourceError.invalidInput }
        for start in stride(from: 0, to: heads.count, by: 256) {
            let part = Array(heads[start..<min(start + 256, heads.count)])
            let json = String(decoding: try JSONEncoder().encode(part.enumerated().map { index, head in
                Request(ordinal: index, token: head.activation, head: head)
            }), as: UTF8.self)
            try await transaction(deadline: deadline) { sql in
                try await sql.raw("""
                    UPDATE \(unsafeRaw: self.schema).realtime_dirty_room_heads h SET pending=false
                    FROM jsonb_to_recordset(\(bind: json)::jsonb) AS c(ordinal integer,room_id uuid,activation_epoch bigint,
                        owner_shard_id text,owner_epoch bigint,host_id text,host_incarnation_id uuid,
                        room_sequence bigint,revision bigint,room_control_version bigint)
                    JOIN \(unsafeRaw: self.schema).rooms r ON r.room_id=c.room_id
                    WHERE h.room_id=c.room_id AND h.pending AND h.revision=c.revision AND h.room_sequence=c.room_sequence
                      AND h.owner_epoch=c.owner_epoch AND h.room_control_version=c.room_control_version
                      AND r.room_shard_id=c.owner_shard_id AND r.owner_epoch=c.owner_epoch
                    """).run()
            }
        }
    }
    private func transaction<T: Sendable>(deadline: ContinuousClock.Instant, body: @escaping @Sendable (any SQLDatabase) async throws -> T) async throws -> T {
        try await v2WithAdmittedRoomDatabaseWork(admission, workClass: .interactiveRead, callerDeadline: deadline) {
            try await v2WithRoomActivationTransaction(database: database, deadline: deadline) { db in
                guard let sql = db as? any SQLDatabase else { throw V2RoomSubscriptionSourceError.invalidInput }
                return try await body(sql)
            }
        }
    }
    private struct Request: Encodable {
        let ordinal: Int; let room_id: UUID; let activation_epoch: Int64; let owner_shard_id: String; let owner_epoch: Int64
        let host_id: String; let host_incarnation_id: UUID
        let room_sequence: UInt64?; let revision: Int64?; let room_control_version: Int64?
        init(ordinal: Int, token: V2RoomActivationToken, head: V2RoomSubscriptionDirtyHead?) {
            self.ordinal = ordinal; room_id = token.roomID.uuidValue!; activation_epoch = token.activationEpoch.rawValue
            owner_shard_id = token.owner.shardID; owner_epoch = token.owner.epoch; host_id = token.host.hostID.rawValue; host_incarnation_id = token.host.incarnationID
            room_sequence = head?.highWatermark; revision = head?.revision; room_control_version = head?.roomControlVersion
        }
    }
}
