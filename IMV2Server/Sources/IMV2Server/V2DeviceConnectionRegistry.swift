import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Process-local index of authenticated live connections. A durable revocation
/// consumer invokes this registry on every gateway replica.
public actor V2DeviceConnectionRegistry {
    private var streamsByDevice: [DeviceID: [UUID: V2GatewayByteStream]] = [:]
    private var streamsByUser: [UserID: [UUID: V2GatewayByteStream]] = [:]
    private var identityByConnection: [UUID: V2AuthenticatedConnection] = [:]

    public init() {}

    public func register(_ stream: V2GatewayByteStream, connectionID: UUID, identity: V2AuthenticatedConnection) {
        identityByConnection[connectionID] = identity
        streamsByDevice[identity.deviceID, default: [:]][connectionID] = stream
        streamsByUser[identity.userID, default: [:]][connectionID] = stream
    }

    public func unregister(connectionID: UUID) {
        guard let identity = identityByConnection.removeValue(forKey: connectionID) else { return }
        streamsByDevice[identity.deviceID]?.removeValue(forKey: connectionID)
        if streamsByDevice[identity.deviceID]?.isEmpty == true { streamsByDevice.removeValue(forKey: identity.deviceID) }
        streamsByUser[identity.userID]?.removeValue(forKey: connectionID)
        if streamsByUser[identity.userID]?.isEmpty == true { streamsByUser.removeValue(forKey: identity.userID) }
    }

    public func revoke(deviceID: DeviceID) async {
        let connectionIDs = streamsByDevice[deviceID].map { Array($0.keys) } ?? []
        let streams = connectionIDs.compactMap { connectionID -> V2GatewayByteStream? in
            defer { unregister(connectionID: connectionID) }
            return streamsByDevice[deviceID]?[connectionID]
        }
        for stream in streams { await stream.revokeDevice() }
    }

    public func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) async {
        let streams = streamsByUser[userID].map { Array($0.values) } ?? []
        for stream in streams { await stream.sendSyncAvailable(eventID: eventID, highWatermark: highWatermark) }
    }

    public func connectionCount(for deviceID: DeviceID) -> Int { streamsByDevice[deviceID]?.count ?? 0 }

    public func connectionMetricsSnapshot() -> V2ConnectionMetricsSnapshot {
        .init(activeDevices: streamsByDevice.count, activeConnections: identityByConnection.count)
    }
}

extension V2DeviceConnectionRegistry: V2LiveSyncNotifier {}
extension V2DeviceConnectionRegistry: V2ConnectionMetricsSource {}

/// The write-side counterpart to authentication. It persists the revocation
/// event atomically with credential invalidation, then closes local sockets.
public struct V2PostgresDeviceRevocationService: Sendable {
    private let database: any Database
    private let registry: V2DeviceConnectionRegistry
    private let now: @Sendable () -> Date

    public init(database: any Database, registry: V2DeviceConnectionRegistry, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.registry = registry
        self.now = now
    }

    public func revoke(userID: UserID, deviceID: DeviceID) async throws {
        guard database is any SQLDatabase,
              let userUUID = UUID(uuidString: userID.rawValue),
              let deviceUUID = UUID(uuidString: deviceID.rawValue)
        else { throw V2GatewayAuthenticationError.corruptPersistenceState }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GatewayAuthenticationError.corruptPersistenceState }
            guard let _: V2RevokedDeviceRow = try await sql.raw("""
                UPDATE im_v2.auth_devices SET revoked_at = COALESCE(revoked_at, \(bind: now()))
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                RETURNING device_id
                """).first(decoding: V2RevokedDeviceRow.self) else {
                throw V2GatewayAuthenticationError.unauthenticated
            }
            try await sql.raw("""
                UPDATE im_v2.device_access_tokens SET revoked_at = COALESCE(revoked_at, \(bind: now()))
                WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now()))
                ON CONFLICT (device_id) DO NOTHING
                """).run()
        }
        await registry.revoke(deviceID: deviceID)
    }
}

private struct V2RevokedDeviceRow: Decodable {
    let deviceID: UUID
}
