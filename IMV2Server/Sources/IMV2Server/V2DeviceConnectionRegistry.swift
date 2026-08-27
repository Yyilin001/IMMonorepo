import Foundation
import IMV2Core
import Synchronization

/// Process-local index of authenticated live connections. A durable revocation
/// consumer invokes this registry on every gateway replica.
public actor V2DeviceConnectionRegistry {
    /// Foreground notifications are the high-frequency path. Keep their
    /// immutable routing snapshots outside the registry actor so unrelated
    /// rooms do not queue behind connection lifecycle and presence work.
    private nonisolated let foregroundRoutes = V2ForegroundConnectionRoutes()
    /// Every stream created by one Gateway uses this process-wide frame
    /// contract. When supplied, foreground broadcasts encode once and share
    /// immutable bytes; tests and alternate embeddings may omit it and retain
    /// the per-stream compatibility path.
    private let foregroundFrameLimits: V2FrameLimits?
    private let connectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy
    private let livePresenceRenewalConfiguration: V2LivePresenceRenewalBatcher.Configuration
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
    private var livePresenceRenewals: V2LivePresenceRenewalBatcher?
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
        ),
        livePresenceRenewalConfiguration: V2LivePresenceRenewalBatcher.Configuration = .init(),
        foregroundFrameLimits: V2FrameLimits? = nil
    ) {
        self.connectionAdmissionPolicy = connectionAdmissionPolicy
        self.livePresenceRenewalConfiguration = livePresenceRenewalConfiguration
        self.foregroundFrameLimits = foregroundFrameLimits
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
        guard let identity = identityByConnection[connectionID],
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
            foregroundRoutes.upsert(
                connectionID: connectionID,
                roomID: roomID,
                userID: identity.userID,
                stream: stream
            )
            return
        }
        await removeForegroundGroupSubscription(connectionID: connectionID)
        guard lifecycleByConnection[connectionID] == lifecycle,
              foregroundMutationByConnection[connectionID] == mutation
        else { return }
        foregroundGroupByConnection[connectionID] = roomID
        let wasInactive = streamsByForegroundGroup[roomID] == nil
        streamsByForegroundGroup[roomID, default: [:]][connectionID] = stream
        foregroundRoutes.upsert(
            connectionID: connectionID,
            roomID: roomID,
            userID: identity.userID,
            stream: stream
        )
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
    public nonisolated func notifyForegroundGroupAvailable(
        roomID: RoomID,
        highWatermark: UInt64
    ) async {
        let streams = foregroundRoutes.streams(roomID: roomID)
        let prepared = foregroundFrameLimits.flatMap {
            V2PreparedGatewayGroupEventAvailable(
                roomID: roomID,
                highWatermark: highWatermark,
                directEvent: nil,
                frameLimits: $0
            )
        }
        await Self.publishForeground(
            streams,
            roomID: roomID,
            highWatermark: highWatermark,
            prepared: prepared
        )
    }

    /// Routes a direct-event acceleration payload only to foreground streams
    /// whose authenticated identity was one of the members captured by the
    /// committing transaction.  A subscription alone is never authority.
    public nonisolated func notifyForegroundDirectEvent(
        _ event: V2DirectRoomLiveEvent
    ) async {
        let streams = foregroundRoutes.streams(
            roomID: event.roomID,
            recipientUserIDs: event.recipientUserIDs
        )
        let prepared = foregroundFrameLimits.flatMap {
            V2PreparedGatewayGroupEventAvailable(
                roomID: event.roomID,
                highWatermark: event.highWatermark,
                directEvent: event,
                frameLimits: $0
            )
        }
        await Self.publishForeground(
            streams,
            roomID: event.roomID,
            highWatermark: event.highWatermark,
            directEvent: event,
            prepared: prepared
        )
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
        livePresenceRenewals = .init(
            leases: leases,
            configuration: livePresenceRenewalConfiguration
        )
    }

    public func livePresenceRenewalMetrics() async -> V2LivePresenceRenewalBatcher.Snapshot? {
        await livePresenceRenewals?.snapshot()
    }

    public func finishLivePresenceRenewals() async {
        await livePresenceRenewals?.finish()
        livePresenceRenewals = nil
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
        let refresh: V2LivePresenceLeaseRefresh
        do {
            if let livePresenceRenewals {
                refresh = try await livePresenceRenewals.renew(
                    identity: identity,
                    connectionID: connectionID,
                    now: Date()
                )
            } else {
                let now = Date()
                let outcome = try await livePresenceLeases.renewConnection(
                    identity: identity,
                    connectionID: connectionID,
                    now: now
                )
                refresh = .init(
                    outcome: outcome,
                    allowsOnlinePresence: try await livePresenceLeases.allowsOnlinePresence(
                        userID: identity.userID
                    )
                )
            }
        } catch {
            await unregister(connectionID: connectionID)
            return false
        }
        guard lifecycleByConnection[connectionID] == lifecycle else {
            await compensateStalePresence(connectionID: connectionID, identity: identity)
            return false
        }
        guard case .accepted(let expiresAt) = refresh.outcome else {
            await unregister(connectionID: connectionID)
            return false
        }
        if refresh.allowsOnlinePresence,
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
        foregroundRoutes.remove(connectionID: connectionID, roomID: roomID)
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

    /// Socket actors are independent once the authorized stream snapshot has
    /// been captured. Direct rooms normally have only one or two local streams;
    /// creating a task group for every message costs more than those sequential
    /// actor hops and creates scheduler pressure at high message rates. Larger
    /// groups still publish in bounded waves so one slow stream cannot serialize
    /// the whole room and the gateway cannot create an unbounded task burst.
    private nonisolated static func publishForeground(
        _ streams: [V2GatewayByteStream],
        roomID: RoomID,
        highWatermark: UInt64,
        directEvent: V2DirectRoomLiveEvent? = nil,
        prepared: V2PreparedGatewayGroupEventAvailable? = nil
    ) async {
        let sequentialWriteLimit = 4
        if streams.count <= sequentialWriteLimit {
            for stream in streams {
                if Task.isCancelled { return }
                if let prepared {
                    await stream.sendGroupEventAvailable(prepared)
                } else {
                    await stream.sendGroupEventAvailable(
                        roomID: roomID,
                        highWatermark: highWatermark,
                        directEvent: directEvent
                    )
                }
            }
            return
        }

        let maximumConcurrentWrites = 16
        var lowerBound = 0
        while lowerBound < streams.count {
            if Task.isCancelled { return }
            let upperBound = min(lowerBound + maximumConcurrentWrites, streams.count)
            await withTaskGroup(of: Void.self) { group in
                for stream in streams[lowerBound..<upperBound] {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        if let prepared {
                            await stream.sendGroupEventAvailable(prepared)
                        } else {
                            await stream.sendGroupEventAvailable(
                                roomID: roomID,
                                highWatermark: highWatermark,
                                directEvent: directEvent
                            )
                        }
                    }
                }
            }
            lowerBound = upperBound
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

/// Sharded, lock-backed foreground routing snapshot. Subscription authority is
/// still established by `V2DeviceConnectionRegistry`; entries here contain
/// only the already-authenticated user identity needed to fence a direct live
/// payload and the process-local stream reference used for best-effort hints.
private final class V2ForegroundConnectionRoutes: Sendable {
    private struct Entry: Sendable {
        let userID: UserID
        let stream: V2GatewayByteStream
    }

    private struct State: Sendable {
        var entriesByRoom: [RoomID: [UUID: Entry]] = [:]
    }

    private final class Shard: Sendable {
        let state = Mutex(State())
    }

    private let shards: [Shard]

    init(shardCount: Int = 16) {
        precondition(shardCount > 0)
        shards = (0..<shardCount).map { _ in Shard() }
    }

    func upsert(
        connectionID: UUID,
        roomID: RoomID,
        userID: UserID,
        stream: V2GatewayByteStream
    ) {
        shard(for: roomID).state.withLock {
            $0.entriesByRoom[roomID, default: [:]][connectionID] = .init(
                userID: userID,
                stream: stream
            )
        }
    }

    func remove(connectionID: UUID, roomID: RoomID) {
        shard(for: roomID).state.withLock { state in
            state.entriesByRoom[roomID]?.removeValue(forKey: connectionID)
            if state.entriesByRoom[roomID]?.isEmpty == true {
                state.entriesByRoom.removeValue(forKey: roomID)
            }
        }
    }

    func streams(roomID: RoomID) -> [V2GatewayByteStream] {
        shard(for: roomID).state.withLock {
            $0.entriesByRoom[roomID].map { Array($0.values.map(\.stream)) } ?? []
        }
    }

    func streams(
        roomID: RoomID,
        recipientUserIDs: Set<UserID>
    ) -> [V2GatewayByteStream] {
        shard(for: roomID).state.withLock { state in
            guard let entries = state.entriesByRoom[roomID] else { return [] }
            return entries.values.compactMap {
                recipientUserIDs.contains($0.userID) ? $0.stream : nil
            }
        }
    }

    private func shard(for roomID: RoomID) -> Shard {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in roomID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return shards[Int(hash % UInt64(shards.count))]
    }
}

private struct V2LiveObservationKey: Hashable, Sendable {
    let roomID: RoomID
    let observerUserID: UserID
    let subjectUserID: UserID
}

extension V2DeviceConnectionRegistry: V2LiveSyncNotifier {}
extension V2DeviceConnectionRegistry: V2ConnectionMetricsSource {}
