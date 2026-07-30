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
    /// Foreground group viewers are intentionally process-local soft state.
    /// The durable room event log and normal per-user sync remain recovery
    /// sources after a process or connection failure.
    private var streamsByForegroundGroup: [RoomID: [UUID: V2GatewayByteStream]] = [:]
    private var foregroundGroupByConnection: [UUID: RoomID] = [:]
    private var foregroundGroupInterestManager: (any V2GroupEventWakeInterestManaging)?

    public init() {}

    public func register(_ stream: V2GatewayByteStream, connectionID: UUID, identity: V2AuthenticatedConnection) {
        identityByConnection[connectionID] = identity
        streamsByDevice[identity.deviceID, default: [:]][connectionID] = stream
        streamsByUser[identity.userID, default: [:]][connectionID] = stream
    }

    public func unregister(connectionID: UUID) async {
        guard let identity = identityByConnection.removeValue(forKey: connectionID) else { return }
        streamsByDevice[identity.deviceID]?.removeValue(forKey: connectionID)
        if streamsByDevice[identity.deviceID]?.isEmpty == true { streamsByDevice.removeValue(forKey: identity.deviceID) }
        streamsByUser[identity.userID]?.removeValue(forKey: connectionID)
        if streamsByUser[identity.userID]?.isEmpty == true { streamsByUser.removeValue(forKey: identity.userID) }
        await removeForegroundGroupSubscription(connectionID: connectionID)
    }

    public func revoke(deviceID: DeviceID) async {
        let connectionIDs = streamsByDevice[deviceID].map { Array($0.keys) } ?? []
        let streams = connectionIDs.compactMap { streamsByDevice[deviceID]?[$0] }
        for connectionID in connectionIDs { await unregister(connectionID: connectionID) }
        for stream in streams { await stream.revokeDevice() }
    }

    public func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) async {
        let streams = streamsByUser[userID].map { Array($0.values) } ?? []
        for stream in streams { await stream.sendSyncAvailable(eventID: eventID, highWatermark: highWatermark) }
    }

    /// The domain handler has already verified group membership before this
    /// is called. One foreground connection may watch one detail room;
    /// moving it tears down its previous local interest atomically.
    public func configureForegroundGroupInterestManager(_ manager: any V2GroupEventWakeInterestManaging) async {
        foregroundGroupInterestManager = manager
        for roomID in streamsByForegroundGroup.keys {
            try? await manager.activate(roomID: roomID)
        }
    }

    public func subscribeForegroundGroup(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID) async {
        guard identityByConnection[connectionID] != nil else { return }
        if foregroundGroupByConnection[connectionID] == roomID {
            streamsByForegroundGroup[roomID, default: [:]][connectionID] = stream
            return
        }
        await removeForegroundGroupSubscription(connectionID: connectionID)
        foregroundGroupByConnection[connectionID] = roomID
        let wasInactive = streamsByForegroundGroup[roomID] == nil
        streamsByForegroundGroup[roomID, default: [:]][connectionID] = stream
        if wasInactive, let foregroundGroupInterestManager {
            try? await foregroundGroupInterestManager.activate(roomID: roomID)
        }
    }

    public func unsubscribeForegroundGroup(connectionID: UUID, roomID: RoomID) async {
        guard foregroundGroupByConnection[connectionID] == roomID else { return }
        await removeForegroundGroupSubscription(connectionID: connectionID)
    }

    /// Core routing is allowed to duplicate or lose this hint. Each stream
    /// receives only a room waterline and must cursor-pull durable events.
    public func notifyForegroundGroupAvailable(roomID: RoomID, highWatermark: UInt64) async {
        let streams = streamsByForegroundGroup[roomID].map { Array($0.values) } ?? []
        for stream in streams {
            await stream.sendGroupEventAvailable(roomID: roomID, highWatermark: highWatermark)
        }
    }

    public func connectionCount(for deviceID: DeviceID) -> Int { streamsByDevice[deviceID]?.count ?? 0 }

    public func connectionMetricsSnapshot() -> V2ConnectionMetricsSnapshot {
        .init(activeDevices: streamsByDevice.count, activeConnections: identityByConnection.count)
    }

    public func activeForegroundGroupMetrics() -> (rooms: Int, viewers: Int) {
        (streamsByForegroundGroup.count, foregroundGroupByConnection.count)
    }

    private func removeForegroundGroupSubscription(connectionID: UUID) async {
        guard let roomID = foregroundGroupByConnection.removeValue(forKey: connectionID) else { return }
        streamsByForegroundGroup[roomID]?.removeValue(forKey: connectionID)
        if streamsByForegroundGroup[roomID]?.isEmpty == true {
            streamsByForegroundGroup.removeValue(forKey: roomID)
            if let foregroundGroupInterestManager {
                await foregroundGroupInterestManager.deactivate(roomID: roomID)
            }
        }
    }

    // Compatibility entry points retained for existing integrations. Their
    // behavior is now mode-agnostic because authorization occurs before a
    // connection is registered as a foreground viewer.
    public func configureHybridGroupInterestManager(_ manager: any V2GroupEventWakeInterestManaging) async {
        await configureForegroundGroupInterestManager(manager)
    }

    public func subscribeHybridGroup(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID) async {
        await subscribeForegroundGroup(stream, connectionID: connectionID, roomID: roomID)
    }

    public func unsubscribeHybridGroup(connectionID: UUID, roomID: RoomID) async {
        await unsubscribeForegroundGroup(connectionID: connectionID, roomID: roomID)
    }

    public func notifyHybridGroupAvailable(roomID: RoomID, highWatermark: UInt64) async {
        await notifyForegroundGroupAvailable(roomID: roomID, highWatermark: highWatermark)
    }

    public func activeHybridGroupMetrics() -> (rooms: Int, viewers: Int) {
        activeForegroundGroupMetrics()
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
