import Fluent
import Foundation
import SQLKit

/// Installs the durable owner marker. This fences v2RequireRoomOwner callers;
/// it is not yet a certificate that every background writer has drained.
public struct PostgresV2RoomMigrationWriteFence: Sendable {
    private let database: any Database
    private let schema: String
    public init(database: any Database) { self.init(database: database, schema: "im_v2") }
    init(database: any Database, schema: String) {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database; self.schema = schema
    }

    /// Called with the durable control record after beginFreezing succeeds.
    /// The room row lock drains earlier users of the shared owner fence.
    /// Keep FOR UPDATE: independent admission reservations use FOR KEY SHARE
    /// so they can coexist with the sending transaction's NO KEY UPDATE lock.
    public func install(for record: V2RoomOwnerMigrationRecord) async throws {
        guard record.phase == .freezing else { throw V2RoomOwnerMigrationError.invalidPhase }
        let request = record.request
        guard let room = request.roomID.uuidValue else { throw V2RoomOwnerMigrationError.invalidRequest }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomOwnerMigrationError.corruptPersistenceState }
            guard let row = try await sql.raw("""
                SELECT room_shard_id AS shard, owner_epoch AS epoch, migration_fence_id AS migration
                FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: room) FOR UPDATE
                """).first(decoding: MigrationOwnerRow.self), row.shard == request.source.shardID,
                row.epoch == request.source.epoch else { throw V2RoomOwnerMigrationError.sourceChanged }
            if let installed = row.migration {
                guard installed == request.migrationID else { throw V2RoomOwnerMigrationError.requestConflict }
                return
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET migration_fence_id = \(bind: request.migrationID) WHERE room_id = \(bind: room)").run()
        }
    }
}
private struct MigrationOwnerRow: Decodable {
    let shard: String
    let epoch: Int64
    let migration: UUID?
}
