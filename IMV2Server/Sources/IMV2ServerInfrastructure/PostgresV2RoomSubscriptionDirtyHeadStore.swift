import Foundation
import FluentKit
import SQLKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication

/// Reuses the transactionally maintained latest-H row. Discovery follows the
/// pending index and filters the current physical host; ACK checks exact tokens.
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
    public func pending(host: V2ActorHostIdentity, after: V2RoomSubscriptionDirtyCursor?, limit: Int = 128,
                        deadline: ContinuousClock.Instant) async throws -> V2RoomSubscriptionDirtyPage {
        guard (1...128).contains(limit), after.map({ (0..<256).contains($0.partitionID) }) ?? true else { throw V2RoomSubscriptionSourceError.invalidInput }
        let rows: [HostRow] = try await transaction(deadline: deadline) { sql in
            try await sql.raw(self.pendingHostQuery(host: host, after: after, limit: limit)).all(decoding: HostRow.self)
        }
        let changes = try rows.map { row -> V2RoomSubscriptionDirtyHead in
            guard row.room_sequence >= 0, row.revision > 0, row.room_control_version >= 0 else { throw V2RoomSubscriptionSourceError.corruptPersistence }
            let token = V2RoomActivationToken(roomID: RoomID(uuid: row.room_id),
                owner: try .init(shardID: row.owner_shard_id, epoch: row.owner_epoch),
                activationEpoch: try .init(row.activation_epoch), host: host)
            return .init(activation: token, highWatermark: UInt64(row.room_sequence), revision: row.revision, roomControlVersion: row.room_control_version)
        }
        return .init(changes: changes, nextCursor: rows.last.map { .init(partitionID: $0.partition_id, roomID: $0.room_id) })
    }
    package func pendingHostQuery(host: V2ActorHostIdentity, after: V2RoomSubscriptionDirtyCursor?, limit: Int) -> SQLQueryString {
        let lower: SQLQueryString = after.map { "AND (h.partition_id,h.room_id)>(\(bind: $0.partitionID),\(bind: $0.roomID))" } ?? ""
        return """
            SELECT h.room_id,h.partition_id,h.room_sequence,h.revision,h.room_control_version,
                   l.activation_epoch,l.owner_shard_id,l.owner_epoch
            FROM \(unsafeRaw: schema).realtime_dirty_room_heads h
            JOIN LATERAL (SELECT l.* FROM \(unsafeRaw: schema).room_activation_leases l
                WHERE l.room_id=h.room_id AND l.host_id=\(bind: host.hostID.rawValue)
                  AND l.host_incarnation_id=\(bind: host.incarnationID) AND l.expires_at>clock_timestamp() OFFSET 0) l ON TRUE
            JOIN LATERAL (SELECT r.* FROM \(unsafeRaw: schema).rooms r WHERE r.room_id=h.room_id OFFSET 0) r ON TRUE
            WHERE h.pending \(lower)
              AND r.room_shard_id=l.owner_shard_id AND r.owner_epoch=l.owner_epoch
              AND h.owner_epoch=l.owner_epoch AND h.room_sequence<=r.room_sequence
            ORDER BY h.partition_id,h.room_id LIMIT \(bind: limit)
            """
    }
    private struct HostRow: Decodable, Sendable {
        let room_id: UUID; let partition_id: Int; let room_sequence: Int64; let revision: Int64; let room_control_version: Int64
        let activation_epoch: Int64; let owner_shard_id: String; let owner_epoch: Int64
    }

    public func acknowledge(_ heads: [V2RoomSubscriptionDirtyHead], deadline: ContinuousClock.Instant) async throws {
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
                    JOIN \(unsafeRaw: self.schema).room_activation_leases l ON l.room_id=c.room_id
                    WHERE h.room_id=c.room_id AND h.pending AND h.revision=c.revision AND h.room_sequence=c.room_sequence
                      AND h.owner_epoch=c.owner_epoch AND h.room_control_version=c.room_control_version
                      AND r.room_shard_id=c.owner_shard_id AND r.owner_epoch=c.owner_epoch
                      AND l.activation_epoch=c.activation_epoch AND l.owner_shard_id=c.owner_shard_id AND l.owner_epoch=c.owner_epoch
                      AND l.host_id=c.host_id AND l.host_incarnation_id=c.host_incarnation_id AND l.expires_at>clock_timestamp()
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
