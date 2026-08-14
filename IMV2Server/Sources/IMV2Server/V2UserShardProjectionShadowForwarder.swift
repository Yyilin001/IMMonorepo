import Fluent
import Foundation
import IMV2Core
import SQLKit

/// The small non-fan-out part of user sync (relationship, block and receive
/// preference) is authoritative in the control store. This boundary mirrors
/// its already-committed records to the current write owner, plus the target
/// while a migration still writes at source. The source operation ID is the
/// durable retry key, so a lost response can safely repeat the mirror without
/// allocating another target sequence.
public protocol V2UserShardProjectionShadowing: Sendable {
    /// Writes the existing control-plane record to the user's live write
    /// owner, and mirrors it to an in-flight migration target when needed.
    /// The returned sequence belongs to the live write owner and is suitable
    /// for a best-effort live sync hint. `nil` means no requested source
    /// projection existed in the control store.
    func shadowIfForwarding(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64?
}

public struct V2PostgresUserShardProjectionShadowForwarder: V2UserShardProjectionShadowing, Sendable {
    private let control: any Database
    private let router: any V2UserShardRouter
    private let migrations: any V2UserShardMigrationStoring
    private let registry: any V2UserShardStorageResolving
    private let routeFence: (any V2UserShardRouteFencing)?
    private let coLocatedControlBuckets: Set<String>

    public init(
        control: any Database, router: any V2UserShardRouter,
        migrations: any V2UserShardMigrationStoring,
        registry: any V2UserShardStorageResolving,
        routeFence: (any V2UserShardRouteFencing)? = nil,
        coLocatedControlBuckets: Set<String> = []
    ) {
        self.control = control
        self.router = router
        self.migrations = migrations
        self.registry = registry
        self.routeFence = routeFence
        self.coLocatedControlBuckets = coLocatedControlBuckets
    }

    public func shadowIfForwarding(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? {
        if let routeFence {
            return try await routeFence.withCurrentRoute(for: userID) { route, fencedDatabase in
                guard let sql = fencedDatabase as? any SQLDatabase,
                      let userUUID = UUID(uuidString: userID.rawValue)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                let migration = try await sql.raw("""
                    SELECT phase, source_bucket, target_bucket
                    FROM im_v2.user_shard_migrations
                    WHERE user_id = \(bind: userUUID)
                    """).first(decoding: ShadowMigrationRow.self)?.record
                return try await shadow(
                    userID: userID, sourceEventID: sourceEventID,
                    projectionKinds: projectionKinds, route: route,
                    controlDatabase: fencedDatabase, migration: migration
                )
            }
        }
        let routes = try await router.routes(for: [userID])
        guard routes.count == 1 else { throw V2UserShardRouterError.resultCountMismatch }
        return try await shadow(
            userID: userID, sourceEventID: sourceEventID,
            projectionKinds: projectionKinds, route: routes[0],
            controlDatabase: control,
            migration: try await migrations.load(userID: userID).map {
                .init(phase: $0.phase, sourceBucket: $0.sourceBucket, targetBucket: $0.targetBucket)
            }
        )
    }

    private func shadow(
        userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>, route: V2UserShardRoute,
        controlDatabase: any Database, migration: ShadowMigration?
    ) async throws -> UInt64? {
        guard !projectionKinds.isEmpty,
              let sql = controlDatabase as? any SQLDatabase,
              let userUUID = UUID(uuidString: userID.rawValue),
              let eventUUID = UUID(uuidString: sourceEventID.rawValue)
        else { return nil }
        var current = try registry.location(for: route.bucket)
        if coLocatedControlBuckets.contains(route.bucket) {
            current = try .init(
                bucket: current.bucket, database: controlDatabase,
                schema: current.schema
            )
        }
        var liveSequence: UInt64?
        for kind in projectionKinds.sorted() {
            guard let row = try await sql.raw("""
                SELECT user_sync_sequence, projection_kind, payload::text AS payload_json, created_at
                FROM im_v2.user_projection_effects
                WHERE user_id = \(bind: userUUID) AND source_event_id = \(bind: eventUUID)
                  AND projection_kind = \(bind: kind)
                """).first(decoding: ShadowSourceRow.self)
            else { continue }
            let currentProjector = try PostgresV2UserShardFanoutProjector(database: current.database, schema: current.schema)
            let sequence = try await currentProjector.projectAllocated(
                userID: userID, sourceEventID: sourceEventID, projectionKind: row.projectionKind,
                payloadJSON: row.payloadJSON, createdAt: row.createdAt
            )
            // A single source event can carry a profile projection plus an
            // invalidation. The wake hint must cover the last
            // mirrored sequence, otherwise a client could stop just before
            // the invalidation and retain stale profile data.
            liveSequence = max(liveSequence ?? 0, sequence)
            if let migration,
               (migration.phase == .forwarding || migration.phase == .verified),
               migration.sourceBucket == route.bucket {
                var target = try registry.location(for: migration.targetBucket)
                if coLocatedControlBuckets.contains(migration.targetBucket) {
                    target = try .init(
                        bucket: target.bucket, database: controlDatabase,
                        schema: target.schema
                    )
                }
                let targetProjector = try PostgresV2UserShardFanoutProjector(database: target.database, schema: target.schema)
                _ = try await targetProjector.mirror(.init(
                    userID: userID, sequence: sequence, sourceEventID: sourceEventID,
                    projectionKind: row.projectionKind, payloadJSON: row.payloadJSON, createdAt: row.createdAt
                ))
            }
        }
        return liveSequence
    }
}

private struct ShadowSourceRow: Decodable {
    let sequence: Int64
    let projectionKind: String
    let payloadJSON: String
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence"
        case projectionKind = "projection_kind"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}
private struct ShadowMigration: Sendable {
    let phase: V2UserShardMigrationPhase
    let sourceBucket: String
    let targetBucket: String
}
private struct ShadowMigrationRow: Decodable {
    let phase: V2UserShardMigrationPhase
    let sourceBucket: String
    let targetBucket: String
    var record: ShadowMigration { .init(phase: phase, sourceBucket: sourceBucket, targetBucket: targetBucket) }
    enum CodingKeys: String, CodingKey {
        case phase
        case sourceBucket = "source_bucket"
        case targetBucket = "target_bucket"
    }
}
