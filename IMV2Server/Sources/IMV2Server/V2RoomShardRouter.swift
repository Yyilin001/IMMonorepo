import Fluent
import Foundation
import IMV2Core
import SQLKit

/// A durable logical room owner. It intentionally carries no hostname or
/// connection information; deployment configuration resolves that separately.
public struct V2RoomShardRoute: Equatable, Sendable {
    public let shardID: String
    public let epoch: Int64

    public init(shardID: String, epoch: Int64) throws {
        let normalized = shardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, epoch >= 0 else {
            throw V2RoomShardRouteError.invalidRoute
        }
        self.shardID = normalized
        self.epoch = epoch
    }
}

public enum V2RoomShardRouteError: Error, Equatable, Sendable {
    case invalidRoute
    case roomNotFound
    case routeConflict
    case corruptPersistenceState
}

/// Resolves the persisted owner of an existing room. The route database is a
/// control-plane directory, not a second source of message truth.
public protocol V2RoomShardRouting: Sendable {
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute
    /// Resolves a bounded batch from the same durable owner directory. The
    /// default preserves compatibility for routers which cannot provide a
    /// set-based lookup; PostgreSQL implementations override it so routing
    /// does not add one round trip per command to an append micro-batch.
    func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute]
}

public extension V2RoomShardRouting {
    func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        var routes: [RoomID: V2RoomShardRoute] = [:]
        routes.reserveCapacity(roomIDs.count)
        for roomID in roomIDs {
            if routes[roomID] == nil {
                routes[roomID] = try await route(for: roomID)
            }
        }
        return routes
    }
}

/// Creation needs a stable pair fence because a direct-room request has no
/// room ID yet. The operation executes under a control-plane advisory lock;
/// the callback may perform the one bounded owner-store transaction needed to
/// create or replay the direct room.
public protocol V2DirectRoomShardRouting: V2RoomShardRouting {
    func withDirectPairRoute<Result: Sendable>(
        actorUserID: UserID,
        targetUserID: UserID,
        proposedShardID: String,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (result: Result, roomID: RoomID?)
    ) async throws -> Result
}

/// PostgreSQL control-plane directory for physical room owners. Legacy rooms
/// fall back to their existing `rooms.room_shard_id` while every newly routed
/// direct room receives an explicit route record. This lets a deployment add
/// the registry before migrating historical rooms and never re-hashes an
/// existing room on command handling.
public struct V2PostgresRoomShardRouter: V2DirectRoomShardRouting {
    private let database: any Database
    private let now: @Sendable () -> Date

    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    public func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue)
        else { throw V2RoomShardRouteError.corruptPersistenceState }
        if let row = try await sql.raw("""
            SELECT room_shard_id, route_epoch
            FROM im_v2.room_owner_routes
            WHERE room_id = \(bind: roomUUID)
            """).first(decoding: RouteRow.self) {
            return try .init(shardID: row.roomShardID, epoch: row.routeEpoch)
        }
        // Before physical routing is enabled, `rooms` itself is the only
        // durable owner directory. Keep that fallback read-only so a legacy
        // route cannot be accidentally rewritten by a new hash configuration.
        guard let legacy = try await sql.raw("""
            SELECT room_shard_id FROM im_v2.rooms WHERE room_id = \(bind: roomUUID)
            """).first(decoding: LegacyRouteRow.self) else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return try .init(shardID: legacy.roomShardID, epoch: 0)
    }

    public func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        guard !roomIDs.isEmpty else { return [:] }
        let uniqueRoomIDs = Array(Set(roomIDs))
        let requestedRoomIDs: [(roomID: RoomID, uuid: UUID)] = try uniqueRoomIDs.map { roomID in
            guard let uuid = UUID(uuidString: roomID.rawValue) else {
                throw V2RoomShardRouteError.corruptPersistenceState
            }
            return (roomID, uuid)
        }
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomShardRouteError.corruptPersistenceState
        }
        let requestedJSON = try roomRouteUUIDJSON(requestedRoomIDs.map(\.uuid))
        let explicitRows = try await sql.raw("""
            SELECT route.room_id, route.room_shard_id, route.route_epoch
            FROM im_v2.room_owner_routes AS route
            INNER JOIN jsonb_array_elements_text(\(bind: requestedJSON)::jsonb) AS requested(room_id)
              ON route.room_id = requested.room_id::uuid
            """).all(decoding: RoutedRoomRow.self)
        var routes: [RoomID: V2RoomShardRoute] = [:]
        routes.reserveCapacity(requestedRoomIDs.count)
        for row in explicitRows {
            routes[try RoomID(row.roomID.uuidString)] = try .init(
                shardID: row.roomShardID, epoch: row.routeEpoch
            )
        }
        let legacyRoomIDs = requestedRoomIDs.compactMap { routes[$0.roomID] == nil ? $0.uuid : nil }
        if !legacyRoomIDs.isEmpty {
            let legacyJSON = try roomRouteUUIDJSON(legacyRoomIDs)
            let legacyRows = try await sql.raw("""
                SELECT room.room_id, room.room_shard_id
                FROM im_v2.rooms AS room
                INNER JOIN jsonb_array_elements_text(\(bind: legacyJSON)::jsonb) AS requested(room_id)
                  ON room.room_id = requested.room_id::uuid
                """).all(decoding: RoutedLegacyRoomRow.self)
            for row in legacyRows {
                routes[try RoomID(row.roomID.uuidString)] = try .init(
                    shardID: row.roomShardID, epoch: 0
                )
            }
        }
        guard routes.count == requestedRoomIDs.count else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return routes
    }

    public func withDirectPairRoute<Result: Sendable>(
        actorUserID: UserID,
        targetUserID: UserID,
        proposedShardID: String,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (result: Result, roomID: RoomID?)
    ) async throws -> Result {
        guard let actor = UUID(uuidString: actorUserID.rawValue),
              let target = UUID(uuidString: targetUserID.rawValue)
        else { throw V2RoomShardRouteError.corruptPersistenceState }
        let pair = canonicalPair(actor, target)
        let lockKey = roomOwnerDirectRouteLockKey(pair)
        // This is intentionally a short control-plane fence around direct
        // room creation only. Existing-room sends use `route(for:)` and never
        // hold a control transaction while their owner transaction runs.
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomShardRouteError.corruptPersistenceState
            }
            try await sql.raw(
                "SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))"
            ).run()
            let route: V2RoomShardRoute
            if let existing = try await sql.raw("""
                SELECT room_shard_id, route_epoch
                FROM im_v2.direct_room_owner_routes
                WHERE lower_user_id = \(bind: pair.lower)
                  AND higher_user_id = \(bind: pair.higher)
                """).first(decoding: RouteRow.self) {
                route = try .init(shardID: existing.roomShardID, epoch: existing.routeEpoch)
            } else {
                route = try .init(shardID: proposedShardID, epoch: 0)
            }
            let completion = try await operation(route)
            guard let roomID = completion.roomID,
                  let roomUUID = UUID(uuidString: roomID.rawValue)
            else { return completion.result }
            try await record(
                roomID: roomUUID, pair: pair, route: route, sql: sql, now: now()
            )
            return completion.result
        }
    }

    private func record(
        roomID: UUID, pair: CanonicalDirectPair, route: V2RoomShardRoute,
        sql: any SQLDatabase, now: Date
    ) async throws {
        if let existing = try await sql.raw("""
            SELECT room_shard_id, route_epoch
            FROM im_v2.room_owner_routes WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: RouteRow.self) {
            guard existing.roomShardID == route.shardID, existing.routeEpoch == route.epoch else {
                throw V2RoomShardRouteError.routeConflict
            }
        } else {
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomShardRouteError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO im_v2.room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: roomID), \(bind: route.shardID), \(bind: route.epoch), \(bind: now), \(bind: now))
                """).run()
        }
        if let existing = try await sql.raw("""
            SELECT room_id, room_shard_id, route_epoch
            FROM im_v2.direct_room_owner_routes
            WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)
            FOR UPDATE
            """).first(decoding: DirectRouteRow.self) {
            guard existing.roomID == roomID,
                  existing.roomShardID == route.shardID,
                  existing.routeEpoch == route.epoch
            else { throw V2RoomShardRouteError.routeConflict }
        } else {
            guard v2PostgresTimestampCanEncode(now) else { throw V2RoomShardRouteError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_owner_routes
                    (lower_user_id, higher_user_id, room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: pair.lower), \(bind: pair.higher), \(bind: roomID),
                        \(bind: route.shardID), \(bind: route.epoch), \(bind: now), \(bind: now))
                """).run()
        }
    }
}

private struct RouteRow: Decodable {
    let roomShardID: String
    let routeEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
    }
}

private struct RoutedRoomRow: Decodable {
    let roomID: UUID
    let roomShardID: String
    let routeEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
    }
}

private struct RoutedLegacyRoomRow: Decodable {
    let roomID: UUID
    let roomShardID: String
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomShardID = "room_shard_id"
    }
}

private struct LegacyRouteRow: Decodable {
    let roomShardID: String
    enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id" }
}

private struct DirectRouteRow: Decodable {
    let roomID: UUID
    let roomShardID: String
    let routeEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
    }
}

struct CanonicalDirectPair: Sendable {
    let lower: UUID
    let higher: UUID
    // This is a control-directory fence. Keep its advisory-lock namespace
    // distinct from PostgresV2DirectMessagingStore's owner-store pair lock;
    // otherwise a co-located deployment would wait on its own open transaction.
}

private func canonicalPair(_ first: UUID, _ second: UUID) -> CanonicalDirectPair {
    first.uuidString.lowercased() < second.uuidString.lowercased()
        ? .init(lower: first, higher: second)
        : .init(lower: second, higher: first)
}

private func roomRouteUUIDJSON(_ values: [UUID]) throws -> String {
    String(decoding: try JSONEncoder().encode(values.map(\.uuidString)), as: UTF8.self)
}

/// Stable control-plane advisory-lock namespace for a direct pair. It is
/// internal so a regression test can prove it remains valid PostgreSQL text.
func roomOwnerDirectRouteLockKey(_ pair: CanonicalDirectPair) -> String {
    // PostgreSQL text parameters cannot contain a NUL byte. UUIDs have a fixed
    // textual form, so colon delimiters are unambiguous here and keep this
    // namespace separate from the owner-store direct-pair lock.
    "room-route:" + pair.lower.uuidString.lowercased() + ":" + pair.higher.uuidString.lowercased()
}
