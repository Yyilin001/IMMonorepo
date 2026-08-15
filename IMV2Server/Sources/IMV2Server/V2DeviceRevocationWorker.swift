import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2DeviceRevocationEvent: Equatable, Sendable {
    public let eventID: Int64
    public let userID: UserID
    public let deviceID: DeviceID
    public let revokedAt: Date

    public init(eventID: Int64, userID: UserID, deviceID: DeviceID, revokedAt: Date) {
        self.eventID = eventID
        self.userID = userID
        self.deviceID = deviceID
        self.revokedAt = revokedAt
    }
}

/// Stable durable-cursor namespace for the current device-revocation worker.
/// Any retired namespace is migrated by the numbered PostgreSQL schema before
/// the gateway process passes its readiness check.
enum V2DeviceRevocationCursorNamespace {
    static let workerName = "device-revocation"
}

enum V2RevokedDeviceProjectionCleanupCursorNamespace {
    static let workerName = "revoked-device-projection-cleanup"
    static let nodeID = "cluster"
}

public protocol V2DeviceRevocationEventStore: Sendable {
    /// A new gateway process has no live sockets before its TLS listener is
    /// bound, so historical revocations do not need replaying there. Existing
    /// node cursors must remain untouched: they represent a restarted node's
    /// durable recovery position.
    func initializeCursorIfNeeded(nodeID: String, now: Date) async throws
    /// Projection cleanup is cluster-global durable work. It replays from the
    /// beginning when first deployed so no revoked device can permanently pin
    /// state merely because every gateway was offline when it was revoked.
    func initializeCursorAtBeginningIfNeeded(nodeID: String, now: Date) async throws
    func events(afterCursorFor nodeID: String, limit: Int) async throws -> [V2DeviceRevocationEvent]
    func markProcessed(eventID: Int64, nodeID: String, now: Date) async throws
}

/// Deletes per-device state from user-projection storage after the control
/// plane has durably revoked the credential. Implementations must be
/// idempotent because event delivery is at least once.
public protocol V2RevokedDeviceProjectionCleaning: Sendable {
    func clean(userID: UserID, deviceID: DeviceID, revokedAt: Date) async throws
}

/// A cluster-global consumer owns storage reclamation separately from the
/// per-gateway live-socket consumers. Every event is acknowledged only after
/// routed cleanup succeeds, so an unavailable shard cannot silently leak a
/// cursor or capability forever.
public struct V2RevokedDeviceProjectionCleanupWorker: Sendable {
    private let store: any V2DeviceRevocationEventStore
    private let cleaner: any V2RevokedDeviceProjectionCleaning
    private let now: @Sendable () -> Date

    public init(
        store: any V2DeviceRevocationEventStore,
        cleaner: any V2RevokedDeviceProjectionCleaning,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.cleaner = cleaner
        self.now = now
    }

    public func initializeForStartup() async throws {
        try await store.initializeCursorAtBeginningIfNeeded(
            nodeID: V2RevokedDeviceProjectionCleanupCursorNamespace.nodeID,
            now: now()
        )
    }

    @discardableResult
    public func runOnce(limit: Int) async throws -> Int {
        precondition(limit > 0)
        let nodeID = V2RevokedDeviceProjectionCleanupCursorNamespace.nodeID
        let events = try await store.events(afterCursorFor: nodeID, limit: limit)
        for event in events {
            try await cleaner.clean(
                userID: event.userID,
                deviceID: event.deviceID,
                revokedAt: event.revokedAt
            )
            try await store.markProcessed(eventID: event.eventID, nodeID: nodeID, now: now())
        }
        return events.count
    }
}

/// One physical projection store. Snapshot artifacts are intentionally kept:
/// protocol V17 permits several devices to share an immutable artifact, while
/// the reset assignment, tokens, receipts and cursor are device-owned.
public struct V2PostgresRevokedDeviceProjectionStore: V2RevokedDeviceProjectionCleaning {
    private let database: any Database
    private let schema: String

    public init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    public func clean(userID: UserID, deviceID: DeviceID, revokedAt: Date) async throws {
        guard let userUUID = UUID(uuidString: userID.rawValue),
              let deviceUUID = UUID(uuidString: deviceID.rawValue)
        else { throw V2GatewayAuthenticationError.corruptPersistenceState }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GatewayAuthenticationError.corruptPersistenceState
            }
            try await sql.raw("""
                SELECT pg_advisory_xact_lock(hashtextextended(
                    CONCAT(\(bind: userUUID), ':', \(bind: deviceUUID)), 684927
                ))
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).revoked_device_projection_tombstones AS tombstone
                    (user_id, device_id, revoked_at)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: revokedAt))
                ON CONFLICT (user_id, device_id) DO UPDATE
                SET revoked_at = LEAST(tombstone.revoked_at, EXCLUDED.revoked_at)
                """).run()
            for table in ["sync_tokens", "sync_receipts", "device_snapshot_resets", "device_sync_cursors"] {
                try await sql.raw("""
                    DELETE FROM \(unsafeRaw: schema).\(unsafeRaw: table)
                    WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                    """).run()
            }
        }
    }
}

/// Route-fenced composite cleanup. The current owner and retained read
/// fallback are both cleared. Initial migration copies may race this pass,
/// but the exclusive final cutover copy is serialized against this shared
/// route lock and therefore converges from the already-cleaned source.
public struct V2RoutedRevokedDeviceProjectionCleaner: V2RevokedDeviceProjectionCleaning {
    private let routeFence: any V2UserShardRouteFencing
    private let registry: any V2UserShardStorageResolving
    private let coLocatedControlBuckets: Set<String>

    public init(
        routeFence: any V2UserShardRouteFencing,
        registry: any V2UserShardStorageResolving,
        coLocatedControlBuckets: Set<String> = []
    ) {
        self.routeFence = routeFence
        self.registry = registry
        self.coLocatedControlBuckets = coLocatedControlBuckets
    }

    public func clean(userID: UserID, deviceID: DeviceID, revokedAt: Date) async throws {
        try await routeFence.withCurrentRoute(for: userID) { route, fencedDatabase in
            var buckets = [route.bucket]
            if let fallback = route.readFallbackBucket {
                buckets.append(fallback)
            }
            for bucket in buckets {
                let configured = try registry.location(for: bucket)
                let database = coLocatedControlBuckets.contains(bucket)
                    ? fencedDatabase
                    : configured.database
                try await V2PostgresRevokedDeviceProjectionStore(
                    database: database,
                    schema: configured.schema
                ).clean(userID: userID, deviceID: deviceID, revokedAt: revokedAt)
            }
        }
    }
}

/// Every successful local close is followed by a durable cursor advance. A
/// crash before the advance replays the close, which is deliberately harmless.
public struct V2DeviceRevocationWorker: Sendable {
    private let store: any V2DeviceRevocationEventStore
    private let registry: V2DeviceConnectionRegistry
    private let nodeID: String
    private let now: @Sendable () -> Date

    public init(store: any V2DeviceRevocationEventStore, registry: V2DeviceConnectionRegistry, nodeID: String, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(!nodeID.isEmpty)
        self.store = store
        self.registry = registry
        self.nodeID = nodeID
        self.now = now
    }

    /// Must complete before this process accepts realtime connections. It
    /// prevents a newly named replica from scanning the append-only history,
    /// while preserving any existing cursor for crash recovery.
    public func initializeForStartup() async throws {
        try await store.initializeCursorIfNeeded(nodeID: nodeID, now: now())
    }

    @discardableResult
    public func runOnce(limit: Int) async throws -> Int {
        precondition(limit > 0)
        let events = try await store.events(afterCursorFor: nodeID, limit: limit)
        for event in events {
            await registry.revoke(deviceID: event.deviceID)
            try await store.markProcessed(eventID: event.eventID, nodeID: nodeID, now: now())
        }
        return events.count
    }
}

public struct V2PostgresDeviceRevocationEventStore: V2DeviceRevocationEventStore {
    private let database: any Database
    private let workerName: String

    public init(database: any Database) {
        self.database = database
        workerName = V2DeviceRevocationCursorNamespace.workerName
    }

    private init(database: any Database, workerName: String) {
        self.database = database
        self.workerName = workerName
    }

    public static func projectionCleanup(database: any Database) -> Self {
        .init(
            database: database,
            workerName: V2RevokedDeviceProjectionCleanupCursorNamespace.workerName
        )
    }

    public func initializeCursorIfNeeded(nodeID: String, now: Date) async throws {
        guard !nodeID.isEmpty, let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        // `ON CONFLICT DO NOTHING` is intentional. Replacing an existing
        // cursor here could make two accidentally duplicated node IDs skip a
        // revocation which only the older process still needs to close.
        // PostgreSQL evaluates this insert from one statement snapshot: an
        // event committed after that snapshot remains above the watermark and
        // is consumed normally once the listener is bound.
        try await sql.raw("""
            INSERT INTO im_v2.gateway_worker_cursors (worker_name, node_id, last_event_id, updated_at)
            SELECT \(bind: workerName), \(bind: nodeID), COALESCE(MAX(event_id), 0), \(bind: now)
            FROM im_v2.device_revocation_events
            ON CONFLICT (worker_name, node_id) DO NOTHING
            """).run()
    }

    public func initializeCursorAtBeginningIfNeeded(nodeID: String, now: Date) async throws {
        guard !nodeID.isEmpty, let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        try await sql.raw("""
            INSERT INTO im_v2.gateway_worker_cursors
                (worker_name, node_id, last_event_id, updated_at)
            VALUES (\(bind: workerName), \(bind: nodeID), 0, \(bind: now))
            ON CONFLICT (worker_name, node_id) DO NOTHING
            """).run()
    }

    public func events(afterCursorFor nodeID: String, limit: Int) async throws -> [V2DeviceRevocationEvent] {
        guard limit > 0, let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        let rows = try await sql.raw("""
            SELECT event.event_id, event.user_id, event.device_id, event.created_at
            FROM im_v2.device_revocation_events AS event
            WHERE event.event_id > COALESCE((
                SELECT cursor.last_event_id
                FROM im_v2.gateway_worker_cursors AS cursor
                WHERE cursor.worker_name = \(bind: workerName) AND cursor.node_id = \(bind: nodeID)
            ), 0)
            ORDER BY event.event_id
            LIMIT \(bind: limit)
            """).all(decoding: V2DeviceRevocationEventRow.self)
        return try rows.map {
            guard let userID = try? UserID($0.userID.uuidString), let deviceID = try? DeviceID($0.deviceID.uuidString) else {
                throw V2GatewayAuthenticationError.corruptPersistenceState
            }
            return .init(
                eventID: $0.eventID,
                userID: userID,
                deviceID: deviceID,
                revokedAt: $0.createdAt
            )
        }
    }

    public func markProcessed(eventID: Int64, nodeID: String, now: Date) async throws {
        guard eventID > 0, let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        try await sql.raw("""
            INSERT INTO im_v2.gateway_worker_cursors (worker_name, node_id, last_event_id, updated_at)
            VALUES (\(bind: workerName), \(bind: nodeID), \(bind: eventID), \(bind: now))
            ON CONFLICT (worker_name, node_id) DO UPDATE
            SET last_event_id = GREATEST(im_v2.gateway_worker_cursors.last_event_id, EXCLUDED.last_event_id),
                updated_at = EXCLUDED.updated_at
            """).run()
    }
}

private struct V2DeviceRevocationEventRow: Decodable {
    let eventID: Int64
    let userID: UUID
    let deviceID: UUID
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case userID = "user_id"
        case deviceID = "device_id"
        case createdAt = "created_at"
    }
}
