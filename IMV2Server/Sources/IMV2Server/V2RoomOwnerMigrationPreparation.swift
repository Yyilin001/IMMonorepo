import Fluent
import Foundation
import IMV2Core
import SQLKit

public enum V2RoomOwnerMigrationError: Error, Equatable, Sendable {
    case invalidRequest, unknownShard, requestConflict, migrationInProgress, sourceChanged, corruptPersistenceState, migrationNotFound, invalidPhase
}

/// Immutable identity for a room move. Preparation never publishes a route.
public struct V2RoomOwnerMigrationPreparation: Equatable, Sendable {
    public let migrationID: UUID
    public let roomID: RoomID
    public let source: V2RoomShardRoute
    public let target: V2RoomShardRoute

    public init(migrationID: UUID, roomID: RoomID, source: V2RoomShardRoute, targetShardID: String) throws {
        guard roomID.uuidValue != nil, source.epoch < Int64.max else { throw V2RoomOwnerMigrationError.invalidRequest }
        let target = try V2RoomShardRoute(shardID: targetShardID, epoch: source.epoch + 1)
        guard target.shardID != source.shardID else { throw V2RoomOwnerMigrationError.invalidRequest }
        self.migrationID = migrationID; self.roomID = roomID; self.source = source; self.target = target
    }
}

public enum V2RoomOwnerMigrationPhase: String, Codable, Sendable {
    case prepared, freezing, frozen, copying, copied, verified, published, retaining, completed, aborted
}

public struct V2RoomOwnerMigrationRecord: Equatable, Sendable {
    public let request: V2RoomOwnerMigrationPreparation
    public let phase: V2RoomOwnerMigrationPhase
    public let createdAt: Date
    public let updatedAt: Date
}

/// Durable control intent only. This store never freezes owner writes, copies
/// data or publishes routes; a phase record is not proof of those effects.
public struct PostgresV2RoomOwnerMigrationPreparationStore: Sendable {
    private let database: any Database
    private let registeredShardIDs: Set<String>
    private let schema: String

    public init(database: any Database, registeredShardIDs: Set<String>) {
        self.init(database: database, registeredShardIDs: registeredShardIDs, schema: "im_v2")
    }

    init(database: any Database, registeredShardIDs: Set<String>, schema: String) {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database; self.registeredShardIDs = registeredShardIDs; self.schema = schema
    }

    /// Read durable progress without requiring the original shard registry.
    /// This is a snapshot, not authorization to perform the next stage.
    public func record(migrationID: UUID) async throws -> V2RoomOwnerMigrationRecord? {
        guard let sql = database as? any SQLDatabase else { throw V2RoomOwnerMigrationError.corruptPersistenceState }
        return try await sql.raw("SELECT * FROM \(unsafeRaw: schema).room_owner_migrations WHERE migration_id = \(bind: migrationID)")
            .first(decoding: RoomMigrationPreparationRow.self)?.record()
    }

    /// Only preparation may be abandoned without coordinating source/target
    /// recovery. Future freezing must first leave prepared under this row lock.
    public func abortPreparation(_ request: V2RoomOwnerMigrationPreparation, now: Date) async throws -> V2RoomOwnerMigrationRecord {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomOwnerMigrationError.corruptPersistenceState }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "room-migration:" + request.migrationID.uuidString), 0))").run()
            guard let row = try await sql.raw("SELECT * FROM \(unsafeRaw: schema).room_owner_migrations WHERE migration_id = \(bind: request.migrationID) FOR UPDATE")
                .first(decoding: RoomMigrationPreparationRow.self) else { throw V2RoomOwnerMigrationError.migrationNotFound }
            let record = try row.record()
            guard record.request == request else { throw V2RoomOwnerMigrationError.requestConflict }
            if record.phase == .aborted { return record }
            guard record.phase == .prepared else { throw V2RoomOwnerMigrationError.invalidPhase }
            guard v2PostgresTimestampCanEncode(now), now >= record.updatedAt else { throw V2RoomOwnerMigrationError.invalidRequest }
            guard let updated = try await sql.raw("""
                UPDATE \(unsafeRaw: schema).room_owner_migrations SET phase = 'aborted', updated_at = \(bind: now)
                WHERE migration_id = \(bind: request.migrationID) AND phase = 'prepared' RETURNING *
                """).first(decoding: RoomMigrationPreparationRow.self) else { throw V2RoomOwnerMigrationError.corruptPersistenceState }
            return try updated.record()
        }
    }

    /// Claims the control-plane intent before any source-side freezing effect.
    /// Freezing is resumable and cannot use the preparation cancellation path.
    public func beginFreezing(_ request: V2RoomOwnerMigrationPreparation, now: Date) async throws -> V2RoomOwnerMigrationRecord {
        guard registeredShardIDs.contains(request.source.shardID), registeredShardIDs.contains(request.target.shardID) else {
            throw V2RoomOwnerMigrationError.unknownShard
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase, let room = request.roomID.uuidValue else {
                throw V2RoomOwnerMigrationError.corruptPersistenceState
            }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "room-migration:" + request.migrationID.uuidString), 0))").run()
            guard let row = try await sql.raw("SELECT * FROM \(unsafeRaw: schema).room_owner_migrations WHERE migration_id = \(bind: request.migrationID) FOR UPDATE")
                .first(decoding: RoomMigrationPreparationRow.self) else { throw V2RoomOwnerMigrationError.migrationNotFound }
            let record = try row.record()
            guard record.request == request else { throw V2RoomOwnerMigrationError.requestConflict }
            guard record.phase == .prepared || record.phase == .freezing else { throw V2RoomOwnerMigrationError.invalidPhase }
            guard let route = try await sql.raw("""
                SELECT room_shard_id AS shard, route_epoch AS epoch FROM \(unsafeRaw: schema).room_owner_routes
                WHERE room_id = \(bind: room) FOR UPDATE
                """).first(decoding: RoomMigrationSourceRow.self), route.shard == request.source.shardID,
                route.epoch == request.source.epoch else { throw V2RoomOwnerMigrationError.sourceChanged }
            if record.phase == .freezing { return record }
            guard v2PostgresTimestampCanEncode(now), now >= record.updatedAt else { throw V2RoomOwnerMigrationError.invalidRequest }
            guard let updated = try await sql.raw("""
                UPDATE \(unsafeRaw: schema).room_owner_migrations SET phase = 'freezing', updated_at = \(bind: now)
                WHERE migration_id = \(bind: request.migrationID) AND phase = 'prepared' RETURNING *
                """).first(decoding: RoomMigrationPreparationRow.self) else { throw V2RoomOwnerMigrationError.corruptPersistenceState }
            return try updated.record()
        }
    }

    public func prepare(_ request: V2RoomOwnerMigrationPreparation, now: Date) async throws -> V2RoomOwnerMigrationRecord {
        guard registeredShardIDs.contains(request.source.shardID), registeredShardIDs.contains(request.target.shardID) else {
            throw V2RoomOwnerMigrationError.unknownShard
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase, let room = request.roomID.uuidValue else {
                throw V2RoomOwnerMigrationError.corruptPersistenceState
            }
            // Serialize identical IDs even when conflicting requests name
            // different rooms. Room row locking then serializes distinct IDs.
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "room-migration:" + request.migrationID.uuidString), 0))").run()
            if let row = try await sql.raw("SELECT * FROM \(unsafeRaw: schema).room_owner_migrations WHERE migration_id = \(bind: request.migrationID) FOR UPDATE").first(decoding: RoomMigrationPreparationRow.self) {
                let record = try row.record()
                guard record.request == request else { throw V2RoomOwnerMigrationError.requestConflict }
                return record
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomOwnerMigrationError.invalidRequest }
            guard let route = try await sql.raw("""
                SELECT room_shard_id AS shard, route_epoch AS epoch FROM \(unsafeRaw: schema).room_owner_routes
                WHERE room_id = \(bind: room) FOR UPDATE
                """).first(decoding: RoomMigrationSourceRow.self), route.shard == request.source.shardID,
                route.epoch == request.source.epoch else { throw V2RoomOwnerMigrationError.sourceChanged }
            if try await sql.raw("""
                SELECT migration_id FROM \(unsafeRaw: schema).room_owner_migrations
                WHERE room_id = \(bind: room) AND phase NOT IN ('completed', 'aborted')
                """).first() != nil { throw V2RoomOwnerMigrationError.migrationInProgress }
            guard let row = try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_owner_migrations
                    (migration_id, room_id, source_shard_id, target_shard_id, source_epoch, target_epoch, phase, created_at, updated_at)
                VALUES (\(bind: request.migrationID), \(bind: room), \(bind: request.source.shardID),
                    \(bind: request.target.shardID), \(bind: request.source.epoch), \(bind: request.target.epoch), 'prepared', \(bind: now), \(bind: now))
                RETURNING *
                """).first(decoding: RoomMigrationPreparationRow.self) else { throw V2RoomOwnerMigrationError.corruptPersistenceState }
            return try row.record()
        }
    }
}

private struct RoomMigrationSourceRow: Decodable { let shard: String; let epoch: Int64 }
private struct RoomMigrationPreparationRow: Decodable {
    let migrationID: UUID, roomID: UUID
    let sourceShardID: String, targetShardID: String
    let sourceEpoch: Int64, targetEpoch: Int64
    let phase: V2RoomOwnerMigrationPhase
    let createdAt: Date, updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case migrationID = "migration_id", roomID = "room_id", sourceShardID = "source_shard_id", targetShardID = "target_shard_id"
        case sourceEpoch = "source_epoch", targetEpoch = "target_epoch", phase, createdAt = "created_at", updatedAt = "updated_at"
    }
    func record() throws -> V2RoomOwnerMigrationRecord {
        let request = try V2RoomOwnerMigrationPreparation(migrationID: migrationID, roomID: .init(uuid: roomID),
            source: .init(shardID: sourceShardID, epoch: sourceEpoch), targetShardID: targetShardID)
        guard request.target.epoch == targetEpoch, v2PostgresTimestampCanEncode(createdAt),
            v2PostgresTimestampCanEncode(updatedAt), updatedAt >= createdAt else { throw V2RoomOwnerMigrationError.corruptPersistenceState }
        return .init(request: request, phase: phase, createdAt: createdAt, updatedAt: updatedAt)
    }
}
