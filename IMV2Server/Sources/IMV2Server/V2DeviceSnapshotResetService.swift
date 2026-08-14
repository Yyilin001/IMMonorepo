import Fluent
import Foundation
import IMV2Core
import SQLKit

/// One operator-authorized reset request. The operation UUID is the immutable
/// artifact ID, making request retries converge on the same durable build.
public struct V2DeviceSnapshotResetCommand: Sendable {
    public let operationID: UUID
    public let userID: UserID
    public let deviceID: DeviceID

    public init(operationID: UUID, userID: UserID, deviceID: DeviceID) {
        self.operationID = operationID
        self.userID = userID
        self.deviceID = deviceID
    }
}

public enum V2DeviceSnapshotResetBuildState: String, Codable, Equatable, Sendable {
    case preparing
    case ready
}

public struct V2DeviceSnapshotResetResult: Equatable, Sendable {
    public let generation: UInt64
    public let state: V2DeviceSnapshotResetBuildState
    public let wasIdempotent: Bool
    public init(generation: UInt64, state: V2DeviceSnapshotResetBuildState, wasIdempotent: Bool) {
        self.generation = generation; self.state = state; self.wasIdempotent = wasIdempotent
    }
}

public enum V2DeviceSnapshotResetError: Error, Equatable, Sendable {
    case deviceUnavailable
    case resetAlreadyPending
    case malformedPersistence
    case unavailable
}

public protocol V2DeviceSnapshotResetting: Sendable {
    func stage(_ command: V2DeviceSnapshotResetCommand) async throws -> V2DeviceSnapshotResetResult
}

/// Creates only durable build/assignment state. Page materialization belongs
/// to `PostgresV2SnapshotArtifactBuilder`, so this operator request never holds
/// a user's full current projection in its task or HTTP response lifecycle.
public struct V2PostgresDeviceSnapshotResetService: V2DeviceSnapshotResetting, Sendable {
    private let router: any V2UserShardRouter
    private let registry: any V2UserShardStorageResolving
    private let routeFence: (any V2UserShardRouteFencing)?
    private let coLocatedControlBuckets: Set<String>
    private let capabilityProfile: String
    private let capabilityLifetime: TimeInterval
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        router: any V2UserShardRouter,
        registry: any V2UserShardStorageResolving,
        routeFence: (any V2UserShardRouteFencing)? = nil,
        coLocatedControlBuckets: Set<String> = [],
        capabilityProfile: String,
        capabilityLifetime: TimeInterval = 86_400,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let normalized = capabilityProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, capabilityLifetime > 0 else { throw V2DeviceSnapshotResetError.unavailable }
        self.router = router; self.registry = registry; self.routeFence = routeFence
        self.coLocatedControlBuckets = coLocatedControlBuckets; self.capabilityProfile = normalized
        self.capabilityLifetime = capabilityLifetime; self.makeUUID = makeUUID; self.now = now
    }

    public func stage(_ command: V2DeviceSnapshotResetCommand) async throws -> V2DeviceSnapshotResetResult {
        if let routeFence {
            return try await routeFence.withCurrentRoute(for: command.userID) { route, fencedDatabase in
                var location = try registry.location(for: route.bucket)
                if coLocatedControlBuckets.contains(route.bucket) {
                    location = try .init(bucket: location.bucket, database: fencedDatabase, schema: location.schema)
                }
                return try await stage(command, at: location)
            }
        }
        return try await stage(command, at: location(for: command.userID))
    }

    private func stage(_ command: V2DeviceSnapshotResetCommand, at location: V2UserShardStorageLocation) async throws -> V2DeviceSnapshotResetResult {
        let userUUID = try snapshotResetUUID(command.userID)
        let deviceUUID = try snapshotResetUUID(command.deviceID)
        guard let sql = location.database as? any SQLDatabase else { throw V2DeviceSnapshotResetError.unavailable }
        guard try await sql.raw("SELECT 1 FROM \(unsafeRaw: location.schema).auth_devices WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID) AND revoked_at IS NULL").first() != nil else {
            throw V2DeviceSnapshotResetError.deviceUnavailable
        }
        if let existing = try await existing(operationID: command.operationID, userID: userUUID, deviceID: deviceUUID, schema: location.schema, sql: sql) {
            switch existing.state {
            case "preparing":
                return .init(generation: try unsigned(existing.generation), state: .preparing, wasIdempotent: true)
            case "ready", "acknowledged":
                return .init(generation: try unsigned(existing.generation), state: .ready, wasIdempotent: true)
            default:
                throw V2DeviceSnapshotResetError.unavailable
            }
        }
        let currentTime = now()
        let expiresAt = currentTime.addingTimeInterval(capabilityLifetime)
        return try await location.database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DeviceSnapshotResetError.unavailable }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).device_sync_cursors
                    (user_id, device_id, state, reset_generation)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), 'ready', 1)
                ON CONFLICT (user_id, device_id) DO NOTHING
                """).run()
            guard let cursor = try await sql.raw("""
                SELECT state, reset_generation
                FROM \(unsafeRaw: location.schema).device_sync_cursors
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                FOR UPDATE
                """).first(decoding: ResetCursorRow.self) else {
                throw V2DeviceSnapshotResetError.malformedPersistence
            }
            // The optimistic lookup above is only a fast path. Recheck after
            // serializing on the device cursor so concurrent retries for the
            // same operation ID are idempotent rather than reported pending.
            if let existing = try await existing(
                operationID: command.operationID, userID: userUUID,
                deviceID: deviceUUID, schema: location.schema, sql: sql
            ) {
                switch existing.state {
                case "preparing":
                    return .init(generation: try unsigned(existing.generation), state: .preparing, wasIdempotent: true)
                case "ready", "acknowledged":
                    return .init(generation: try unsigned(existing.generation), state: .ready, wasIdempotent: true)
                default:
                    throw V2DeviceSnapshotResetError.unavailable
                }
            }
            // Failed/expired builds deliberately have no live assignment, but
            // the immutable artifact still reserves the operation ID.
            if try await artifactExists(
                operationID: command.operationID, schema: location.schema, sql: sql
            ) {
                throw V2DeviceSnapshotResetError.unavailable
            }
            guard cursor.state == "ready" else {
                throw V2DeviceSnapshotResetError.resetAlreadyPending
            }
            let watermark = try await sql.raw("""
                SELECT COALESCE(next_sequence, 0) AS value
                FROM \(unsafeRaw: location.schema).user_sync_sequences
                WHERE user_id = \(bind: userUUID)
                """).first(decoding: ResetWatermarkRow.self)?.value ?? 0
            guard watermark >= 0 else { throw V2DeviceSnapshotResetError.malformedPersistence }
            let (generation, overflow) = cursor.generation.addingReportingOverflow(1)
            guard !overflow, generation > 1 else {
                throw V2DeviceSnapshotResetError.malformedPersistence
            }
            // A user with no sync events still needs a checkpoint row; the
            // builder intentionally uses that row as its bounded claim/fence.
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).user_projection_checkpoints
                    (user_id, projected_sequence, updated_at)
                VALUES (\(bind: userUUID), 0, \(bind: currentTime))
                ON CONFLICT (user_id) DO NOTHING
                """).run()
            let projectedSequence = try await sql.raw("""
                SELECT projected_sequence AS value
                FROM \(unsafeRaw: location.schema).user_projection_checkpoints
                WHERE user_id = \(bind: userUUID)
                FOR UPDATE
                """).first(decoding: ResetWatermarkRow.self)?.value ?? 0
            guard projectedSequence >= watermark else {
                // The background projector will catch up; a later retry with
                // the same operation ID remains safe because nothing has
                // been staged yet.
                throw V2DeviceSnapshotResetError.unavailable
            }
            let initialDigest = V2SnapshotV3Digest.initial(baseSequence: UInt64(watermark), capabilityProfile: capabilityProfile)
            let nextToken = makeUUID().uuidString
            let receipt = makeUUID().uuidString
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).sync_snapshot_artifacts
                    (snapshot_id, user_id, base_user_sync_sequence, source_projected_sequence, schema_version,
                     capability_profile, state, rolling_digest, expires_at, created_at)
                VALUES (\(bind: command.operationID), \(bind: userUUID), \(bind: watermark), \(bind: projectedSequence),
                        \(bind: Int32(V2SnapshotProjectionV3Codec.schemaVersion)),
                        \(bind: capabilityProfile), 'building', \(bind: initialDigest),
                        \(bind: expiresAt), \(bind: currentTime))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).device_snapshot_resets
                    (user_id, device_id, reset_generation, snapshot_id, state,
                     next_sync_token, snapshot_receipt, expires_at, created_at)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: generation),
                        \(bind: command.operationID), 'preparing', \(bind: nextToken),
                        \(bind: receipt), \(bind: expiresAt), \(bind: currentTime))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: location.schema).sync_tokens
                    (token, user_id, device_id, reset_generation, watermark, expires_at, created_at)
                VALUES (\(bind: nextToken), \(bind: userUUID), \(bind: deviceUUID),
                        \(bind: generation), \(bind: watermark), \(bind: expiresAt), \(bind: currentTime))
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: location.schema).device_sync_cursors
                SET state = 'reset_preparing', reset_generation = \(bind: generation),
                    pending_snapshot_id = \(bind: command.operationID),
                    pending_base_sequence = \(bind: watermark),
                    pending_snapshot_expires_at = \(bind: expiresAt)
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).run()
            return .init(generation: try unsigned(generation), state: .preparing, wasIdempotent: false)
        }
    }

    private func location(for userID: UserID) async throws -> V2UserShardStorageLocation {
        let routes = try await router.routes(for: [userID])
        guard routes.count == 1 else { throw V2DeviceSnapshotResetError.unavailable }
        return try registry.location(for: routes[0].bucket)
    }

    private func existing(operationID: UUID, userID: UUID, deviceID: UUID, schema: String, sql: any SQLDatabase) async throws -> ExistingResetRow? {
        try await sql.raw("""
            SELECT reset.reset_generation, reset.state
            FROM \(unsafeRaw: schema).device_snapshot_resets AS reset
            WHERE reset.snapshot_id = \(bind: operationID) AND reset.user_id = \(bind: userID)
              AND reset.device_id = \(bind: deviceID)
            """).first(decoding: ExistingResetRow.self)
    }

    private func artifactExists(operationID: UUID, schema: String, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 FROM \(unsafeRaw: schema).sync_snapshot_artifacts
            WHERE snapshot_id = \(bind: operationID)
            """).first() != nil
    }
}

private struct ExistingResetRow: Decodable {
    let generation: Int64; let state: String
    enum CodingKeys: String, CodingKey { case generation = "reset_generation", state }
}
private struct ResetCursorRow: Decodable {
    let state: String; let generation: Int64
    enum CodingKeys: String, CodingKey { case state, generation = "reset_generation" }
}
private struct ResetWatermarkRow: Decodable { let value: Int64 }
private func snapshotResetUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2DeviceSnapshotResetError.malformedPersistence }
    return value
}
private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2DeviceSnapshotResetError.malformedPersistence }
    return UInt64(value)
}
