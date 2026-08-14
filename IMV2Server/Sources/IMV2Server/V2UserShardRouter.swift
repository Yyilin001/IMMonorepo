import Foundation
import Fluent
import IMV2Core
import SQLKit

/// A logical destination, never a physical database address. The epoch fences
/// a delivery against the version of routing configuration that created it.
public struct V2UserShardRoute: Equatable, Sendable {
    public let bucket: String
    public let observedRouterEpoch: Int64
    /// During a controlled move reads may fall back to the previous logical
    /// owner. Delivery records deliberately persist only the write identity;
    /// a fallback must never cause a second fan-out write.
    public let readFallbackBucket: String?

    public init(bucket: String, observedRouterEpoch: Int64, readFallbackBucket: String? = nil) throws {
        let normalizedBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFallback = readFallbackBucket?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBucket.isEmpty,
              observedRouterEpoch >= 0,
              normalizedFallback.map({ !$0.isEmpty && $0 != normalizedBucket }) ?? true
        else {
            throw V2UserShardRouterError.invalidRoute
        }
        self.bucket = normalizedBucket
        self.observedRouterEpoch = observedRouterEpoch
        self.readFallbackBucket = normalizedFallback
    }

    /// The persisted fan-out route contains exactly these two fields. A
    /// read fallback is not an alternate delivery target.
    public var writeIdentity: V2UserShardWriteIdentity {
        .init(bucket: bucket, observedRouterEpoch: observedRouterEpoch)
    }
}

public struct V2UserShardWriteIdentity: Equatable, Sendable {
    public let bucket: String
    public let observedRouterEpoch: Int64
}

/// The router is deliberately an injected, versioned control-plane boundary.
/// Fan-out planning must not derive a bucket by hashing an identifier locally.
public protocol V2UserShardRouter: Sendable {
    /// Returns exactly one route for each requested user, in the input order.
    /// Bounded planners and delivery workers use this ordering to retain a
    /// route epoch fence without issuing one control-plane query per user.
    func routes(for users: [UserID]) async throws -> [V2UserShardRoute]
}

/// Serializes a routed user-store operation with cutover/rollback. The body
/// runs while a shared lock is held on the control-plane route generation;
/// route mutations take the corresponding exclusive lock. Cross-store I/O is
/// intentionally permitted here: this is the bounded per-user cutover fence,
/// not a general database transaction abstraction.
public protocol V2UserShardRouteFencing: Sendable {
    func withCurrentRoute<Result: Sendable>(
        for userID: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result
    ) async throws -> Result
}

public enum V2UserShardRouterError: Error, Equatable, Sendable {
    case invalidRoute
    case resultCountMismatch
}

/// First-deployment router. It is explicit configuration rather than an
/// inferred hash; a future control-plane router can replace it without
/// changing planner or delivery contracts.
public struct V2SingleUserShardRouter: V2UserShardRouter {
    private let route: V2UserShardRoute

    public init(route: V2UserShardRoute) {
        self.route = route
    }

    public func routes(for users: [UserID]) async throws -> [V2UserShardRoute] {
        Array(repeating: route, count: users.count)
    }
}

/// PostgreSQL-backed logical router. It stores user overrides rather than
/// physical hosts, so an application process can reload routing decisions on
/// every bounded planner/delivery batch without making a database address part
/// of a fan-out row.
public struct V2PostgresUserShardRouter: V2UserShardRouter {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    /// First deployment seeds a single explicit route. Once the row exists it
    /// is authoritative; changing a process environment cannot silently
    /// replace a controlled routing decision.
    public func bootstrap(defaultRoute: V2UserShardRoute, now: Date = Date()) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            INSERT INTO im_v2.user_shard_router_configuration
                (configuration_key, router_epoch, default_write_bucket, default_read_fallback_bucket, updated_at)
            VALUES (TRUE, \(bind: defaultRoute.observedRouterEpoch), \(bind: defaultRoute.bucket),
                    \(bind: defaultRoute.readFallbackBucket), \(bind: now))
            ON CONFLICT (configuration_key) DO NOTHING
            """).run()
    }

    public func routes(for users: [UserID]) async throws -> [V2UserShardRoute] {
        guard !users.isEmpty else { return [] }
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let requestedJSON = try String(data: JSONEncoder().encode(users.map(\.rawValue)), encoding: .utf8)
        guard let requestedJSON else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let rows = try await sql.raw("""
            SELECT requested.ordinal, COALESCE(override.write_bucket, config.default_write_bucket) AS write_bucket,
                   COALESCE(override.router_epoch, config.router_epoch) AS router_epoch,
                   COALESCE(override.read_fallback_bucket, config.default_read_fallback_bucket) AS read_fallback_bucket
            FROM jsonb_array_elements_text(\(bind: requestedJSON)::jsonb) WITH ORDINALITY AS requested(user_id, ordinal)
            CROSS JOIN im_v2.user_shard_router_configuration AS config
            LEFT JOIN im_v2.user_shard_route_overrides AS override
              ON override.user_id = requested.user_id::uuid
            WHERE config.configuration_key = TRUE
            ORDER BY requested.ordinal
            """).all(decoding: V2PostgresUserShardRouteRow.self)
        guard rows.count == users.count else { throw V2UserShardRouterError.resultCountMismatch }
        return try rows.map {
            try .init(bucket: $0.writeBucket, observedRouterEpoch: $0.routerEpoch, readFallbackBucket: $0.readFallbackBucket)
        }
    }
}

extension V2PostgresUserShardRouter: V2UserShardRouteFencing {
    public func withCurrentRoute<Result: Sendable>(
        for userID: UserID,
        _ operation: @escaping @Sendable (V2UserShardRoute, any Database) async throws -> Result
    ) async throws -> Result {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let userUUID = UUID(uuidString: userID.rawValue)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: userID.rawValue), 0))").run()
            guard let configuration = try await sql.raw("""
                SELECT router_epoch, default_write_bucket, default_read_fallback_bucket
                FROM im_v2.user_shard_router_configuration
                WHERE configuration_key = TRUE
                """).first(decoding: V2PostgresFencedRouterConfigurationRow.self)
            else { throw V2UserShardRouteControlError.missingRouterConfiguration }
            let override = try await sql.raw("""
                SELECT write_bucket, read_fallback_bucket, router_epoch
                FROM im_v2.user_shard_route_overrides
                WHERE user_id = \(bind: userUUID)
                """).first(decoding: V2UserShardRouteOverrideRow.self)
            let route = try V2UserShardRoute(
                bucket: override?.writeBucket ?? configuration.defaultWriteBucket,
                observedRouterEpoch: override?.routerEpoch ?? configuration.routerEpoch,
                readFallbackBucket: override?.readFallbackBucket ?? configuration.defaultReadFallbackBucket
            )
            return try await operation(route, transaction)
        }
    }
}

/// Serialized, idempotent control-plane operation for one user's logical
/// write owner. Data copy/verification is deliberately outside this API: the
/// caller must complete that evidence before it invokes a cutover.
public struct V2UserShardRouteCutover: Sendable {
    public let operationID: UUID
    public let userID: UserID
    public let expectedRouterEpoch: Int64
    public let newWriteBucket: String
    public let readFallbackBucket: String?

    public init(operationID: UUID, userID: UserID, expectedRouterEpoch: Int64, newWriteBucket: String, readFallbackBucket: String?) throws {
        _ = try V2UserShardRoute(bucket: newWriteBucket, observedRouterEpoch: expectedRouterEpoch, readFallbackBucket: readFallbackBucket)
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
        self.newWriteBucket = newWriteBucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.readFallbackBucket = readFallbackBucket?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum V2UserShardRouteControlError: Error, Equatable, Sendable {
    case staleRouterEpoch
    case operationConflict
    case missingRouterConfiguration
    case migrationNotVerified
    case migrationConflict
    case finalVerificationFailed
}

public struct V2UserShardRouteCutoverResult: Equatable, Sendable {
    public let route: V2UserShardRoute
    public let wasIdempotent: Bool

    public init(route: V2UserShardRoute, wasIdempotent: Bool) {
        self.route = route
        self.wasIdempotent = wasIdempotent
    }
}

/// Returns a still-retained user to the source write owner. The command never
/// accepts a bucket from its caller: source/target are the durable migration
/// facts recorded by the successful cutover.
public struct V2UserShardRouteRollback: Sendable {
    public let operationID: UUID
    public let userID: UserID
    public let expectedRouterEpoch: Int64

    public init(operationID: UUID, userID: UserID, expectedRouterEpoch: Int64) throws {
        guard expectedRouterEpoch >= 0 else { throw V2UserShardRouterError.invalidRoute }
        self.operationID = operationID
        self.userID = userID
        self.expectedRouterEpoch = expectedRouterEpoch
    }
}

public protocol V2UserShardRouteCutoverHandling: Sendable {
    func cutOver(_ command: V2UserShardRouteCutover) async throws -> V2UserShardRouteCutoverResult
}

public protocol V2UserShardRouteRollbackHandling: Sendable {
    func rollBack(_ command: V2UserShardRouteRollback) async throws -> V2UserShardRouteCutoverResult
}

public struct V2PostgresUserShardRouteControl: Sendable {
    private let database: any Database
    private let operatorPrincipal: String
    private let retentionWindow: TimeInterval
    private let finalizer: (any V2UserShardCutoverFinalizing)?

    public init(
        database: any Database, operatorPrincipal: String,
        retentionWindow: TimeInterval = 86_400,
        finalizer: (any V2UserShardCutoverFinalizing)? = nil
    ) {
        precondition(V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal))
        precondition(retentionWindow > 0)
        self.database = database
        self.operatorPrincipal = operatorPrincipal
        self.retentionWindow = retentionWindow
        self.finalizer = finalizer
    }

    public func cutOver(_ command: V2UserShardRouteCutover, now: Date = Date()) async throws -> V2UserShardRouteCutoverResult {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            if let replay = try await sql.raw("""
                SELECT operator_principal, user_id, write_bucket, read_fallback_bucket, resulting_router_epoch
                FROM im_v2.user_shard_route_operations WHERE operation_id = \(bind: command.operationID)
                """).first(decoding: V2UserShardRouteOperationRow.self) {
                guard replay.userID == (try v2UUID(command.userID)),
                      replay.operatorPrincipal == operatorPrincipal,
                      replay.writeBucket == command.newWriteBucket,
                      replay.readFallbackBucket == command.readFallbackBucket
                else { throw V2UserShardRouteControlError.operationConflict }
                return .init(route: try .init(bucket: replay.writeBucket, observedRouterEpoch: replay.resultingRouterEpoch, readFallbackBucket: replay.readFallbackBucket), wasIdempotent: true)
            }
            guard let configuration = try await sql.raw("""
                SELECT router_epoch FROM im_v2.user_shard_router_configuration
                WHERE configuration_key = TRUE FOR UPDATE
                """).first(decoding: V2PostgresRouterConfigurationRow.self)
            else { throw V2UserShardRouteControlError.missingRouterConfiguration }
            guard configuration.routerEpoch == command.expectedRouterEpoch else { throw V2UserShardRouteControlError.staleRouterEpoch }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: command.userID.rawValue), 0))").run()
            guard let migration = try await sql.raw("""
                SELECT migration_id, source_bucket, target_bucket, source_router_epoch, phase, cutover_operation_id
                FROM im_v2.user_shard_migrations
                WHERE user_id = \(bind: try v2UUID(command.userID))
                FOR UPDATE
                """).first(decoding: V2UserShardCutoverMigrationRow.self)
            else { throw V2UserShardRouteControlError.migrationNotVerified }
            guard migration.sourceBucket == command.readFallbackBucket,
                  migration.targetBucket == command.newWriteBucket,
                  migration.sourceRouterEpoch == command.expectedRouterEpoch
            else { throw V2UserShardRouteControlError.migrationConflict }
            guard migration.phase == .verified else { throw V2UserShardRouteControlError.migrationNotVerified }
            guard migration.cutoverOperationID == nil || migration.cutoverOperationID == command.operationID else {
                throw V2UserShardRouteControlError.operationConflict
            }
            guard let finalizer else { throw V2UserShardRouteControlError.finalVerificationFailed }
            do {
                try await finalizer.finalizeForCutover(
                    migrationID: migration.migrationID, userID: command.userID,
                    sourceBucket: migration.sourceBucket, targetBucket: migration.targetBucket,
                    sourceRouterEpoch: migration.sourceRouterEpoch,
                    controlTransaction: transaction
                )
            } catch {
                throw V2UserShardRouteControlError.finalVerificationFailed
            }
            let cutoverPhase = try V2UserShardMigrationStateMachine.transition(from: migration.phase, by: .cutOver)
            let migrationPhase = try V2UserShardMigrationStateMachine.transition(from: cutoverPhase, by: .beginRetention)
            let retentionUntil = now.addingTimeInterval(retentionWindow)
            let resultingEpoch = configuration.routerEpoch + 1
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_route_overrides
                    (user_id, write_bucket, read_fallback_bucket, router_epoch, updated_at)
                VALUES (\(bind: try v2UUID(command.userID)), \(bind: command.newWriteBucket), \(bind: command.readFallbackBucket), \(bind: resultingEpoch), \(bind: now))
                ON CONFLICT (user_id) DO UPDATE
                SET write_bucket = EXCLUDED.write_bucket,
                    read_fallback_bucket = EXCLUDED.read_fallback_bucket,
                    router_epoch = EXCLUDED.router_epoch,
                    updated_at = EXCLUDED.updated_at
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_shard_router_configuration
                SET router_epoch = \(bind: resultingEpoch), updated_at = \(bind: now)
                WHERE configuration_key = TRUE
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_route_operations
                    (operation_id, operator_principal, user_id, write_bucket, read_fallback_bucket, resulting_router_epoch, created_at)
                VALUES (\(bind: command.operationID), \(bind: operatorPrincipal), \(bind: try v2UUID(command.userID)), \(bind: command.newWriteBucket), \(bind: command.readFallbackBucket), \(bind: resultingEpoch), \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_shard_migrations
                SET phase = \(bind: migrationPhase.rawValue),
                    cutover_operation_id = \(bind: command.operationID),
                    retention_until = \(bind: retentionUntil),
                    retention_claim_token = NULL, retention_claim_expires_at = NULL,
                    updated_at = \(bind: now)
                WHERE migration_id = \(bind: migration.migrationID) AND phase = 'verified' AND cutover_operation_id IS NULL
                """).run()
            return .init(route: try .init(bucket: command.newWriteBucket, observedRouterEpoch: resultingEpoch, readFallbackBucket: command.readFallbackBucket), wasIdempotent: false)
        }
    }

    /// Reverses a cutover only while the original migration's rollback window
    /// remains open. It is the same epoch-CAS and durable-operation boundary
    /// as cutover, so a late operator cannot silently overwrite a newer move.
    public func rollBack(_ command: V2UserShardRouteRollback, now: Date = Date()) async throws -> V2UserShardRouteCutoverResult {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let migration = try await sql.raw("""
                SELECT migration_id, source_bucket, target_bucket, source_router_epoch, phase,
                       cutover_operation_id, retention_until
                FROM im_v2.user_shard_migrations
                WHERE user_id = \(bind: try v2UUID(command.userID)) FOR UPDATE
                """).first(decoding: V2UserShardCutoverMigrationRow.self)
            else { throw V2UserShardRouteControlError.migrationNotVerified }
            if let replay = try await sql.raw("""
                SELECT operator_principal, user_id, write_bucket, read_fallback_bucket, resulting_router_epoch
                FROM im_v2.user_shard_route_operations WHERE operation_id = \(bind: command.operationID)
                """).first(decoding: V2UserShardRouteOperationRow.self) {
                guard replay.userID == (try v2UUID(command.userID)),
                      replay.operatorPrincipal == operatorPrincipal,
                      replay.writeBucket == migration.sourceBucket,
                      replay.readFallbackBucket == migration.targetBucket
                else { throw V2UserShardRouteControlError.operationConflict }
                return .init(route: try .init(bucket: replay.writeBucket, observedRouterEpoch: replay.resultingRouterEpoch, readFallbackBucket: replay.readFallbackBucket), wasIdempotent: true)
            }
            guard migration.phase == .retention,
                  let retentionUntil = migration.retentionUntil, retentionUntil > now
            else { throw V2UserShardRouteControlError.migrationNotVerified }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: command.userID.rawValue), 0))").run()
            guard let finalizer else { throw V2UserShardRouteControlError.finalVerificationFailed }
            do {
                try await finalizer.finalizeForRollback(
                    migrationID: migration.migrationID, userID: command.userID,
                    sourceBucket: migration.sourceBucket, targetBucket: migration.targetBucket,
                    sourceRouterEpoch: migration.sourceRouterEpoch,
                    controlTransaction: transaction
                )
            } catch {
                throw V2UserShardRouteControlError.finalVerificationFailed
            }
            guard let configuration = try await sql.raw("""
                SELECT router_epoch FROM im_v2.user_shard_router_configuration
                WHERE configuration_key = TRUE FOR UPDATE
                """).first(decoding: V2PostgresRouterConfigurationRow.self),
                configuration.routerEpoch == command.expectedRouterEpoch
            else { throw V2UserShardRouteControlError.staleRouterEpoch }
            guard let current = try await sql.raw("""
                SELECT write_bucket, read_fallback_bucket, router_epoch
                FROM im_v2.user_shard_route_overrides
                WHERE user_id = \(bind: try v2UUID(command.userID)) FOR UPDATE
                """).first(decoding: V2UserShardRouteOverrideRow.self),
                current.writeBucket == migration.targetBucket,
                current.readFallbackBucket == migration.sourceBucket,
                current.routerEpoch == command.expectedRouterEpoch
            else { throw V2UserShardRouteControlError.migrationConflict }
            let rolledBack = try V2UserShardMigrationStateMachine.transition(from: .retention, by: .rollback)
            let resultingEpoch = configuration.routerEpoch + 1
            try await sql.raw("""
                UPDATE im_v2.user_shard_route_overrides
                SET write_bucket = \(bind: migration.sourceBucket),
                    read_fallback_bucket = \(bind: migration.targetBucket),
                    router_epoch = \(bind: resultingEpoch), updated_at = \(bind: now)
                WHERE user_id = \(bind: try v2UUID(command.userID))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_shard_router_configuration
                SET router_epoch = \(bind: resultingEpoch), updated_at = \(bind: now)
                WHERE configuration_key = TRUE
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_shard_route_operations
                    (operation_id, operator_principal, user_id, write_bucket, read_fallback_bucket, resulting_router_epoch, created_at)
                VALUES (\(bind: command.operationID), \(bind: operatorPrincipal), \(bind: try v2UUID(command.userID)),
                        \(bind: migration.sourceBucket), \(bind: migration.targetBucket), \(bind: resultingEpoch), \(bind: now))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.user_shard_migrations
                SET phase = \(bind: rolledBack.rawValue), retention_until = NULL,
                    retention_claim_token = NULL, retention_claim_expires_at = NULL, updated_at = \(bind: now)
                WHERE migration_id = \(bind: migration.migrationID) AND phase = 'retention'
                """).run()
            return .init(route: try .init(
                bucket: migration.sourceBucket, observedRouterEpoch: resultingEpoch,
                readFallbackBucket: migration.targetBucket
            ), wasIdempotent: false)
        }
    }
}

extension V2PostgresUserShardRouteControl: V2UserShardRouteCutoverHandling {
    public func cutOver(_ command: V2UserShardRouteCutover) async throws -> V2UserShardRouteCutoverResult {
        try await cutOver(command, now: Date())
    }
}

extension V2PostgresUserShardRouteControl: V2UserShardRouteRollbackHandling {
    public func rollBack(_ command: V2UserShardRouteRollback) async throws -> V2UserShardRouteCutoverResult {
        try await rollBack(command, now: Date())
    }
}

private struct V2PostgresUserShardRouteRow: Decodable {
    let ordinal: Int64
    let writeBucket: String
    let routerEpoch: Int64
    let readFallbackBucket: String?
    enum CodingKeys: String, CodingKey {
        case ordinal
        case writeBucket = "write_bucket"
        case routerEpoch = "router_epoch"
        case readFallbackBucket = "read_fallback_bucket"
    }
}

private struct V2PostgresRouterConfigurationRow: Decodable {
    let routerEpoch: Int64
    enum CodingKeys: String, CodingKey { case routerEpoch = "router_epoch" }
}

private struct V2PostgresFencedRouterConfigurationRow: Decodable {
    let routerEpoch: Int64
    let defaultWriteBucket: String
    let defaultReadFallbackBucket: String?
    enum CodingKeys: String, CodingKey {
        case routerEpoch = "router_epoch"
        case defaultWriteBucket = "default_write_bucket"
        case defaultReadFallbackBucket = "default_read_fallback_bucket"
    }
}

private struct V2UserShardRouteOperationRow: Decodable {
    let operatorPrincipal: String
    let userID: UUID
    let writeBucket: String
    let readFallbackBucket: String?
    let resultingRouterEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case operatorPrincipal = "operator_principal"
        case userID = "user_id"
        case writeBucket = "write_bucket"
        case readFallbackBucket = "read_fallback_bucket"
        case resultingRouterEpoch = "resulting_router_epoch"
    }
}

private struct V2UserShardCutoverMigrationRow: Decodable {
    let migrationID: UUID
    let sourceBucket: String
    let targetBucket: String
    let sourceRouterEpoch: Int64
    let phase: V2UserShardMigrationPhase
    let cutoverOperationID: UUID?
    let retentionUntil: Date?

    enum CodingKeys: String, CodingKey {
        case migrationID = "migration_id", sourceBucket = "source_bucket", targetBucket = "target_bucket"
        case sourceRouterEpoch = "source_router_epoch", phase, cutoverOperationID = "cutover_operation_id", retentionUntil = "retention_until"
    }
}

private struct V2UserShardRouteOverrideRow: Decodable {
    let writeBucket: String
    let readFallbackBucket: String?
    let routerEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case writeBucket = "write_bucket", readFallbackBucket = "read_fallback_bucket", routerEpoch = "router_epoch"
    }
}

private func v2UUID(_ userID: UserID) throws -> UUID {
    guard let value = UUID(uuidString: userID.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}
