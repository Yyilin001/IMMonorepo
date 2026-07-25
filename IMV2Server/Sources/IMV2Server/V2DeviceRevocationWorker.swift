import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct V2DeviceRevocationEvent: Equatable, Sendable {
    public let eventID: Int64
    public let userID: UserID
    public let deviceID: DeviceID

    public init(eventID: Int64, userID: UserID, deviceID: DeviceID) {
        self.eventID = eventID
        self.userID = userID
        self.deviceID = deviceID
    }
}

public protocol V2DeviceRevocationEventStore: Sendable {
    /// A new gateway process has no live sockets before its TLS listener is
    /// bound, so historical revocations do not need replaying there. Existing
    /// node cursors must remain untouched: they represent a restarted node's
    /// durable recovery position.
    func initializeCursorIfNeeded(nodeID: String, now: Date) async throws
    func events(afterCursorFor nodeID: String, limit: Int) async throws -> [V2DeviceRevocationEvent]
    func markProcessed(eventID: Int64, nodeID: String, now: Date) async throws
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
    private let workerName = "device-revocation-v1"

    public init(database: any Database) { self.database = database }

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

    public func events(afterCursorFor nodeID: String, limit: Int) async throws -> [V2DeviceRevocationEvent] {
        guard limit > 0, let sql = database as? any SQLDatabase else {
            throw V2GatewayAuthenticationError.corruptPersistenceState
        }
        let rows = try await sql.raw("""
            SELECT event.event_id, event.user_id, event.device_id
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
            return .init(eventID: $0.eventID, userID: userID, deviceID: deviceID)
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
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case userID = "user_id"
        case deviceID = "device_id"
    }
}
