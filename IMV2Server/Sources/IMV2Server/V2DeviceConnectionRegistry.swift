import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Process-local index of authenticated live connections. A durable revocation
/// consumer invokes this registry on every gateway replica.
public actor V2DeviceConnectionRegistry {
    private let connectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy
    private var streamsByDevice: [DeviceID: [UUID: V2GatewayByteStream]] = [:]
    private var streamsByUser: [UserID: [UUID: V2GatewayByteStream]] = [:]
    private var identityByConnection: [UUID: V2AuthenticatedConnection] = [:]
    /// Every registration gets a fresh token. Actor methods revalidate it
    /// after external awaits so an older continuation cannot resurrect state
    /// after unregister or a later registration of the same connection ID.
    private var lifecycleByConnection: [UUID: UUID] = [:]
    /// Foreground group viewers are intentionally process-local soft state.
    /// The durable room event log and normal per-user sync remain recovery
    /// sources after a process or connection failure.
    private var streamsByForegroundGroup: [RoomID: [UUID: V2GatewayByteStream]] = [:]
    private var foregroundGroupByConnection: [UUID: RoomID] = [:]
    private var foregroundMutationByConnection: [UUID: UUID] = [:]
    private var foregroundGroupInterestManager: (any V2GroupEventWakeInterestManaging)?
    private var livePresenceLeases: (any V2LivePresenceLeaseManaging)?
    private var liveActivityObservationAuthorizer: (any V2LiveActivityObservationAuthorizing)?
    private var liveActivityBroker: (any V2LiveActivityInterestManaging & V2LiveActivityPublishing)?
    private var presenceByConnection: [UUID: (roomID: RoomID, targetUserID: UserID)] = [:]
    private var presenceMutationByConnection: [UUID: UUID] = [:]
    private var presenceWatchersByTarget: [UserID: [UUID: V2GatewayByteStream]] = [:]
    private var typingRoomByConnection: [UUID: RoomID] = [:]
    private var typingMutationByConnection: [UUID: UUID] = [:]
    private var typingWatchersByRoom: [RoomID: [UUID: V2GatewayByteStream]] = [:]

    public init(
        connectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy = .init(
            maximumConnectionsPerDevice: 2,
            maximumConnectionsPerUser: 8
        )
    ) {
        self.connectionAdmissionPolicy = connectionAdmissionPolicy
    }

    @discardableResult
    public func register(_ stream: V2GatewayByteStream, connectionID: UUID, identity: V2AuthenticatedConnection) async -> Bool {
        // A connection ID is one lifecycle token, not an idempotency key.
        // Accepting a duplicate while the first registration is suspended
        // would let a different stream inherit its identity and lease.
        if identityByConnection[connectionID] != nil { return false }
        guard (streamsByDevice[identity.deviceID]?.count ?? 0) < connectionAdmissionPolicy.maximumConnectionsPerDevice,
              (streamsByUser[identity.userID]?.count ?? 0) < connectionAdmissionPolicy.maximumConnectionsPerUser
        else { return false }
        let lifecycle = UUID()
        lifecycleByConnection[connectionID] = lifecycle
        identityByConnection[connectionID] = identity
        streamsByDevice[identity.deviceID, default: [:]][connectionID] = stream
        streamsByUser[identity.userID, default: [:]][connectionID] = stream
        guard let livePresenceLeases else { return true }
        let lease: V2AuthenticatedConnectionLeaseOutcome
        do {
            lease = try await livePresenceLeases.admitConnection(
                identity: identity,
                connectionID: connectionID,
                policy: connectionAdmissionPolicy,
                now: Date()
            )
        } catch {
            rollbackRegistration(connectionID: connectionID, identity: identity, lifecycle: lifecycle)
            return false
        }
        guard lifecycleByConnection[connectionID] == lifecycle else {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        guard case .accepted(let expiresAt) = lease else {
            rollbackRegistration(connectionID: connectionID, identity: identity, lifecycle: lifecycle)
            return false
        }
        let allowsOnlinePresence = (
            try? await livePresenceLeases.allowsOnlinePresence(userID: identity.userID)
        ) == true
        guard lifecycleByConnection[connectionID] == lifecycle else {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        guard allowsOnlinePresence else {
            // The durable row is also the cross-replica authenticated
            // connection-admission lease.  Presence privacy controls whether
            // that lease is observable, not whether it exists.  Dropping it
            // here would let users who hide presence bypass global per-user
            // and per-device connection limits.
            return true
        }
        await routePresence(targetUserID: identity.userID, isOnline: true, expiresAt: expiresAt)
        if lifecycleByConnection[connectionID] != lifecycle {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        return true
    }

    public func unregister(connectionID: UUID) async {
        guard let identity = identityByConnection.removeValue(forKey: connectionID) else { return }
        lifecycleByConnection.removeValue(forKey: connectionID)
        streamsByDevice[identity.deviceID]?.removeValue(forKey: connectionID)
        if streamsByDevice[identity.deviceID]?.isEmpty == true { streamsByDevice.removeValue(forKey: identity.deviceID) }
        streamsByUser[identity.userID]?.removeValue(forKey: connectionID)
        if streamsByUser[identity.userID]?.isEmpty == true { streamsByUser.removeValue(forKey: identity.userID) }
        do {
            let mutation = UUID()
            foregroundMutationByConnection[connectionID] = mutation
            defer {
                if foregroundMutationByConnection[connectionID] == mutation {
                    foregroundMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removeForegroundGroupSubscription(connectionID: connectionID)
        }
        guard lifecycleByConnection[connectionID] == nil else { return }
        do {
            let mutation = UUID()
            presenceMutationByConnection[connectionID] = mutation
            defer {
                if presenceMutationByConnection[connectionID] == mutation {
                    presenceMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removePresenceSubscription(connectionID: connectionID)
        }
        guard lifecycleByConnection[connectionID] == nil else { return }
        do {
            let mutation = UUID()
            typingMutationByConnection[connectionID] = mutation
            defer {
                if typingMutationByConnection[connectionID] == mutation {
                    typingMutationByConnection.removeValue(forKey: connectionID)
                }
            }
            await removeTypingSubscription(connectionID: connectionID)
        }
        // A later registration may have reused the ID while the broker
        // teardown awaited. Its new lease must not be deleted by this older
        // continuation.
        guard lifecycleByConnection[connectionID] == nil else { return }
        guard let remainsOnline = await removePresenceLease(
            identity: identity,
            connectionID: connectionID
        ) else {
            // A failed cross-replica query cannot prove the user offline.
            // The short database lease will converge without emitting a
            // misleading global transition during the outage.
            return
        }
        if !remainsOnline, lifecycleByConnection[connectionID] == nil {
            await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
        }
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
        for roomID in Array(streamsByForegroundGroup.keys) {
            try? await manager.activate(roomID: roomID)
            if streamsByForegroundGroup[roomID] == nil {
                await manager.deactivate(roomID: roomID)
            }
        }
    }

    public func detachForegroundGroupInterestManager() {
        foregroundGroupInterestManager = nil
    }

    public func subscribeForegroundGroup(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID) async {
        guard identityByConnection[connectionID] != nil,
              let lifecycle = lifecycleByConnection[connectionID]
        else { return }
        let mutation = UUID()
        foregroundMutationByConnection[connectionID] = mutation
        defer {
            if foregroundMutationByConnection[connectionID] == mutation {
                foregroundMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        if foregroundGroupByConnection[connectionID] == roomID {
            streamsByForegroundGroup[roomID, default: [:]][connectionID] = stream
            return
        }
        await removeForegroundGroupSubscription(connectionID: connectionID)
        guard lifecycleByConnection[connectionID] == lifecycle,
              foregroundMutationByConnection[connectionID] == mutation
        else { return }
        foregroundGroupByConnection[connectionID] = roomID
        let wasInactive = streamsByForegroundGroup[roomID] == nil
        streamsByForegroundGroup[roomID, default: [:]][connectionID] = stream
        if wasInactive, let foregroundGroupInterestManager {
            try? await foregroundGroupInterestManager.activate(roomID: roomID)
            if streamsByForegroundGroup[roomID] == nil {
                await foregroundGroupInterestManager.deactivate(roomID: roomID)
            }
        }
    }

    public func unsubscribeForegroundGroup(connectionID: UUID, roomID: RoomID) async {
        guard foregroundGroupByConnection[connectionID] == roomID else { return }
        let mutation = UUID()
        foregroundMutationByConnection[connectionID] = mutation
        defer {
            if foregroundMutationByConnection[connectionID] == mutation {
                foregroundMutationByConnection.removeValue(forKey: connectionID)
            }
        }
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

    public func configureLivePresenceLeases(_ leases: any V2LivePresenceLeaseManaging) {
        livePresenceLeases = leases
    }

    public func configureLiveActivityObservationAuthorizer(_ authorizer: any V2LiveActivityObservationAuthorizing) {
        liveActivityObservationAuthorizer = authorizer
    }

    public func configureLiveActivityBroker(_ broker: any V2LiveActivityInterestManaging & V2LiveActivityPublishing) async {
        liveActivityBroker = broker
        for userID in Array(presenceWatchersByTarget.keys) {
            try? await broker.activatePresence(targetUserID: userID)
            if presenceWatchersByTarget[userID] == nil { await broker.deactivatePresence(targetUserID: userID) }
        }
        for roomID in Array(typingWatchersByRoom.keys) {
            try? await broker.activateTyping(roomID: roomID)
            if typingWatchersByRoom[roomID] == nil { await broker.deactivateTyping(roomID: roomID) }
        }
    }

    public func detachLiveActivityBroker() {
        liveActivityBroker = nil
    }

    @discardableResult
    public func refreshLivePresence(connectionID: UUID) async -> Bool {
        guard let identity = identityByConnection[connectionID],
              let lifecycle = lifecycleByConnection[connectionID]
        else { return false }
        guard let livePresenceLeases else { return true }
        let lease: V2AuthenticatedConnectionLeaseOutcome
        do {
            lease = try await livePresenceLeases.renewConnection(
                identity: identity,
                connectionID: connectionID,
                now: Date()
            )
        } catch {
            await unregister(connectionID: connectionID)
            return false
        }
        guard lifecycleByConnection[connectionID] == lifecycle else {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        guard case .accepted(let expiresAt) = lease else {
            await unregister(connectionID: connectionID)
            return false
        }
        if (try? await livePresenceLeases.allowsOnlinePresence(userID: identity.userID)) == true,
           lifecycleByConnection[connectionID] == lifecycle {
            await routePresence(targetUserID: identity.userID, isOnline: true, expiresAt: expiresAt)
        }
        if lifecycleByConnection[connectionID] != lifecycle {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        return true
    }

    public func subscribePresence(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID, targetUserID: UserID) async {
        guard identityByConnection[connectionID] != nil,
              let lifecycle = lifecycleByConnection[connectionID]
        else { return }
        let mutation = UUID()
        presenceMutationByConnection[connectionID] = mutation
        defer {
            if presenceMutationByConnection[connectionID] == mutation {
                presenceMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removePresenceSubscription(connectionID: connectionID)
        guard lifecycleByConnection[connectionID] == lifecycle,
              presenceMutationByConnection[connectionID] == mutation
        else { return }
        presenceByConnection[connectionID] = (roomID, targetUserID)
        presenceWatchersByTarget[targetUserID, default: [:]][connectionID] = stream
        if presenceWatchersByTarget[targetUserID]?.count == 1, let liveActivityBroker {
            try? await liveActivityBroker.activatePresence(targetUserID: targetUserID)
            if presenceWatchersByTarget[targetUserID] == nil {
                await liveActivityBroker.deactivatePresence(targetUserID: targetUserID)
            }
        }
    }

    public func unsubscribePresence(connectionID: UUID, roomID: RoomID) async {
        guard presenceByConnection[connectionID]?.roomID == roomID else { return }
        let mutation = UUID()
        presenceMutationByConnection[connectionID] = mutation
        defer {
            if presenceMutationByConnection[connectionID] == mutation {
                presenceMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removePresenceSubscription(connectionID: connectionID)
    }

    public func subscribeTyping(_ stream: V2GatewayByteStream, connectionID: UUID, roomID: RoomID) async {
        guard identityByConnection[connectionID] != nil,
              let lifecycle = lifecycleByConnection[connectionID]
        else { return }
        let mutation = UUID()
        typingMutationByConnection[connectionID] = mutation
        defer {
            if typingMutationByConnection[connectionID] == mutation {
                typingMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removeTypingSubscription(connectionID: connectionID)
        guard lifecycleByConnection[connectionID] == lifecycle,
              typingMutationByConnection[connectionID] == mutation
        else { return }
        typingRoomByConnection[connectionID] = roomID
        typingWatchersByRoom[roomID, default: [:]][connectionID] = stream
        if typingWatchersByRoom[roomID]?.count == 1, let liveActivityBroker {
            try? await liveActivityBroker.activateTyping(roomID: roomID)
            if typingWatchersByRoom[roomID] == nil {
                await liveActivityBroker.deactivateTyping(roomID: roomID)
            }
        }
    }

    public func unsubscribeTyping(connectionID: UUID, roomID: RoomID) async {
        guard typingRoomByConnection[connectionID] == roomID else { return }
        let mutation = UUID()
        typingMutationByConnection[connectionID] = mutation
        defer {
            if typingMutationByConnection[connectionID] == mutation {
                typingMutationByConnection.removeValue(forKey: connectionID)
            }
        }
        await removeTypingSubscription(connectionID: connectionID)
    }

    public func notifyTyping(roomID: RoomID, actorUserID: UserID, isTyping: Bool, expiresAt: Date) async {
        let state = V2TypingState(roomID: roomID, userID: actorUserID, isTyping: isTyping, expiresAt: expiresAt)
        await notifyTypingWatchers(state)
        await liveActivityBroker?.publishTyping(state)
    }

    public func receivePresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        await notifyPresenceWatchers(targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt)
    }

    public func receiveTyping(_ state: V2TypingState) async {
        await notifyTypingWatchers(state)
    }

    @discardableResult
    public func applyLiveActivityPreferences(connectionID: UUID, allowsOnlinePresence: Bool) async -> Bool {
        guard let identity = identityByConnection[connectionID],
              let lifecycle = lifecycleByConnection[connectionID]
        else { return false }
        if allowsOnlinePresence {
            return await refreshLivePresence(connectionID: connectionID)
        } else {
            // Keep every connection-admission lease alive.  Database reads
            // and refresh broadcasts both apply the privacy preference, so
            // the lease remains invisible while still enforcing caps across
            // gateway replicas.
            guard lifecycleByConnection[connectionID] == lifecycle else { return false }
            await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
            return lifecycleByConnection[connectionID] == lifecycle
        }
    }

    private func notifyTypingWatchers(_ state: V2TypingState) async {
        let streams = typingWatchersByRoom[state.roomID].map { Array($0) } ?? []
        let candidates = streams.compactMap { connectionID, stream -> (V2LiveObservationKey, V2GatewayByteStream)? in
            guard let observer = identityByConnection[connectionID]?.userID, observer != state.userID else { return nil }
            return (.init(roomID: state.roomID, observerUserID: observer, subjectUserID: state.userID), stream)
        }
        let authorized = await authorizedObservationKeys(Set(candidates.map(\.0)))
        for (key, stream) in candidates where authorized.contains(key) {
            guard typingWatchersByRoom[state.roomID]?.values.contains(where: { $0 === stream }) == true else { continue }
            await stream.sendTypingState(state)
        }
    }

    private func routePresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        await notifyPresenceWatchers(targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt)
        await liveActivityBroker?.publishPresence(targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt)
    }

    private func compensateStalePresence(connectionID: UUID, identity: V2AuthenticatedConnection) async {
        // A newer lifecycle may have deliberately reused this UUID and now
        // owns the database row. The stale continuation must not delete it.
        guard lifecycleByConnection[connectionID] == nil else { return }
        guard let remainsOnline = await removePresenceLease(
            identity: identity,
            connectionID: connectionID
        ) else { return }
        guard !remainsOnline,
              identityByConnection[connectionID] == nil
        else { return }
        await routePresence(targetUserID: identity.userID, isOnline: false, expiresAt: Date())
    }

    private func removePresenceLease(
        identity: V2AuthenticatedConnection,
        connectionID: UUID
    ) async -> Bool? {
        guard let livePresenceLeases else {
            return streamsByUser[identity.userID] != nil
        }
        return try? await livePresenceLeases.removePresence(
            identity: identity,
            connectionID: connectionID,
            now: Date()
        )
    }

    private func notifyPresenceWatchers(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        let streams = presenceWatchersByTarget[targetUserID].map { Array($0) } ?? []
        let candidates = streams.compactMap { connectionID, stream -> (V2LiveObservationKey, V2GatewayByteStream)? in
            guard let watch = presenceByConnection[connectionID],
                  let observer = identityByConnection[connectionID]?.userID,
                  watch.targetUserID == targetUserID
            else { return nil }
            return (.init(roomID: watch.roomID, observerUserID: observer, subjectUserID: targetUserID), stream)
        }
        let authorized = await authorizedObservationKeys(Set(candidates.map(\.0)))
        for (key, stream) in candidates where authorized.contains(key) {
            guard presenceWatchersByTarget[targetUserID]?.values.contains(where: { $0 === stream }) == true else { continue }
            await stream.sendPresenceState(.init(roomID: key.roomID, targetUserID: targetUserID, isOnline: isOnline, expiresAt: expiresAt))
        }
    }

    /// Authorization is identical for all devices owned by one observer. Run
    /// each unique database check once with a small concurrency ceiling rather
    /// than serializing every watcher behind this registry actor.
    private func authorizedObservationKeys(_ keys: Set<V2LiveObservationKey>) async -> Set<V2LiveObservationKey> {
        guard let liveActivityObservationAuthorizer else { return keys }
        let values = Array(keys)
        return await withTaskGroup(of: (V2LiveObservationKey, Bool).self) { group in
            var nextIndex = 0
            let maximumConcurrency = min(8, values.count)
            for index in 0..<maximumConcurrency {
                let key = values[index]
                group.addTask {
                    do {
                        try await liveActivityObservationAuthorizer.authorizeObservation(
                            roomID: key.roomID,
                            viewerUserID: key.observerUserID,
                            subjectUserID: key.subjectUserID,
                            now: Date()
                        )
                        return (key, true)
                    } catch { return (key, false) }
                }
                nextIndex += 1
            }
            var allowed: Set<V2LiveObservationKey> = []
            while let (key, isAllowed) = await group.next() {
                if isAllowed { allowed.insert(key) }
                if nextIndex < values.count {
                    let key = values[nextIndex]
                    group.addTask {
                        do {
                            try await liveActivityObservationAuthorizer.authorizeObservation(
                                roomID: key.roomID,
                                viewerUserID: key.observerUserID,
                                subjectUserID: key.subjectUserID,
                                now: Date()
                            )
                            return (key, true)
                        } catch { return (key, false) }
                    }
                    nextIndex += 1
                }
            }
            return allowed
        }
    }

    private func removePresenceSubscription(connectionID: UUID) async {
        guard let previous = presenceByConnection.removeValue(forKey: connectionID) else { return }
        presenceWatchersByTarget[previous.targetUserID]?.removeValue(forKey: connectionID)
        if presenceWatchersByTarget[previous.targetUserID]?.isEmpty == true {
            presenceWatchersByTarget.removeValue(forKey: previous.targetUserID)
            if let liveActivityBroker {
                await liveActivityBroker.deactivatePresence(targetUserID: previous.targetUserID)
                if presenceWatchersByTarget[previous.targetUserID] != nil {
                    try? await liveActivityBroker.activatePresence(targetUserID: previous.targetUserID)
                }
            }
        }
    }

    private func removeTypingSubscription(connectionID: UUID) async {
        guard let roomID = typingRoomByConnection.removeValue(forKey: connectionID) else { return }
        typingWatchersByRoom[roomID]?.removeValue(forKey: connectionID)
        if typingWatchersByRoom[roomID]?.isEmpty == true {
            typingWatchersByRoom.removeValue(forKey: roomID)
            if let liveActivityBroker {
                await liveActivityBroker.deactivateTyping(roomID: roomID)
                if typingWatchersByRoom[roomID] != nil {
                    try? await liveActivityBroker.activateTyping(roomID: roomID)
                }
            }
        }
    }

    private func removeForegroundGroupSubscription(connectionID: UUID) async {
        guard let roomID = foregroundGroupByConnection.removeValue(forKey: connectionID) else { return }
        streamsByForegroundGroup[roomID]?.removeValue(forKey: connectionID)
        if streamsByForegroundGroup[roomID]?.isEmpty == true {
            streamsByForegroundGroup.removeValue(forKey: roomID)
            if let foregroundGroupInterestManager {
                await foregroundGroupInterestManager.deactivate(roomID: roomID)
                if streamsByForegroundGroup[roomID] != nil {
                    try? await foregroundGroupInterestManager.activate(roomID: roomID)
                }
            }
        }
    }

    private func rollbackRegistration(
        connectionID: UUID,
        identity: V2AuthenticatedConnection,
        lifecycle: UUID
    ) {
        guard lifecycleByConnection[connectionID] == lifecycle,
              identityByConnection[connectionID] == identity
        else { return }
        lifecycleByConnection.removeValue(forKey: connectionID)
        identityByConnection.removeValue(forKey: connectionID)
        streamsByDevice[identity.deviceID]?.removeValue(forKey: connectionID)
        if streamsByDevice[identity.deviceID]?.isEmpty == true {
            streamsByDevice.removeValue(forKey: identity.deviceID)
        }
        streamsByUser[identity.userID]?.removeValue(forKey: connectionID)
        if streamsByUser[identity.userID]?.isEmpty == true {
            streamsByUser.removeValue(forKey: identity.userID)
        }
    }

    /// Internal invariant probe used by churn tests. Mutation generations are
    /// transient reentrancy fences and must never become a connection-history
    /// ledger.
    func transientMutationTokenCount() -> Int {
        foregroundMutationByConnection.count
            + presenceMutationByConnection.count
            + typingMutationByConnection.count
    }

}

private struct V2LiveObservationKey: Hashable, Sendable {
    let roomID: RoomID
    let observerUserID: UserID
    let subjectUserID: UserID
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
