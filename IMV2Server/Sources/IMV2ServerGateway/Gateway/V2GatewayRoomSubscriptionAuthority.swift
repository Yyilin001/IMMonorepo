import Foundation
import Synchronization
@preconcurrency import NIOCore
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts

/// Room mutations are serialized by separate actors. Socket submission consumes
/// a connection-local EventLoop projection; it never queries the room directory.
public final class V2GatewayRoomSubscriptionAuthority: Sendable {
    public struct Permit: Sendable, Equatable {
        public let fence: V2RoomSubscriptionFence
        public let userID: UserID
        public let memberRevision: UInt64
        public let connectionID: UUID
        public let lifecycle: UUID
        public let scopeGeneration: UInt64
        public let baselineSequence: UInt64
        let roomInterestID: UUID
        let authorizationID: UUID
        var requiresRoomInterest = true
        var socketGate: V2RoomSubscriptionSocketGate? = nil
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.fence == rhs.fence && lhs.userID == rhs.userID && lhs.memberRevision == rhs.memberRevision
                && lhs.connectionID == rhs.connectionID && lhs.lifecycle == rhs.lifecycle
                && lhs.scopeGeneration == rhs.scopeGeneration && lhs.baselineSequence == rhs.baselineSequence
                && lhs.roomInterestID == rhs.roomInterestID && lhs.authorizationID == rhs.authorizationID
                && lhs.requiresRoomInterest == rhs.requiresRoomInterest
        }
    }
    public enum ApplyResult: Sendable, Equatable {
        case applied(permits: [Permit])
        case stale, invalid, snapshotRequired
    }
    private struct Catalog: Sendable {
        var rooms: [RoomID: V2RoomSubscriptionActor] = [:]
        var active: Set<RoomID> = []
        var retired: Set<RoomID> = []
        var requiresReset = false
        var sessions: [V2ActorHostIdentity: V2RoomDeliverySessionGate] = [:]
        var hostsByRoom: [RoomID: V2ActorHostIdentity] = [:]
        var closed = false
    }
    private let catalog = Mutex(Catalog())
    fileprivate let connections: V2RoomSubscriptionConnections
    private let maximumRooms: Int
    private let maximumRetiredRooms: Int
    private let maximumMembersPerRoom: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    public init(maximumRooms: Int = 256, maximumRetiredRooms: Int? = nil, maximumConnections: Int = 16_384,
                maximumMembersPerRoom: Int = V2GroupCapacityPolicy.largeMaximumMembers,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        precondition(maximumRooms > 0 && maximumConnections > 0 && maximumMembersPerRoom > 0)
        precondition(maximumRetiredRooms.map { $0 > 0 } ?? true)
        self.maximumRooms = maximumRooms; self.maximumRetiredRooms = maximumRetiredRooms ?? maximumRooms
        self.maximumMembersPerRoom = maximumMembersPerRoom; self.now = now
        connections = .init(maximumConnections: maximumConnections)
    }
    private func room(_ id: RoomID) -> V2RoomSubscriptionActor? { catalog.withLock { $0.closed ? nil : $0.rooms[id] } }
    public func sessionGate(_ session: V2RoomDeliverySession, serviceID: String) -> V2RoomDeliverySessionGate? {
        catalog.withLock { value in
            guard !value.closed, let gate = value.sessions[session.host], gate.session == session,
                  gate.serviceID == serviceID else { return nil }
            return gate
        }
    }
    public func sessionRooms(host: V2ActorHostIdentity) -> [RoomID] {
        catalog.withLock { $0.hostsByRoom.compactMap { $0.value == host ? $0.key : nil } }
    }
    /// Only a grant installed from a confirmed native room route may supersede
    /// an incarnation. An unsolicited open/pulse is not that proof. Room and
    /// socket projections retain the retired gate, never a catalog lookup.
    package func releaseSupersededHostSessions(confirmed session: V2RoomDeliverySession,
                                              serviceID: String) -> [V2ActorHostIdentity] {
        catalog.withLock { value in
            guard !value.closed, let current = value.sessions[session.host],
                  current.session == session, current.serviceID == serviceID,
                  current.isReady(at: now()) else { return [] }
            let obsolete = value.sessions.keys.filter {
                $0.hostID == session.host.hostID && $0 != session.host
            }
            for host in obsolete {
                value.sessions.removeValue(forKey: host)?.retire()
            }
            return obsolete
        }
    }
    public func applyDeliverySession(_ pulse: V2RoomDeliverySessionPulse, serviceID: String) -> V2RoomDeliverySessionResult {
        guard (try? pulse.session.validate()) != nil, pulse.sequence > 0, !serviceID.isEmpty else { return .stale }
        return catalog.withLock { value in
            guard !value.closed else { return .stale }
            let old = value.sessions[pulse.session.host]
            switch pulse.kind {
            case .open:
                if let old {
                    guard old.serviceID == serviceID else { return .stale }
                    if old.session == pulse.session {
                        return old.heartbeat(sequence: pulse.sequence, at: now()) ? .accepted : .resetRequired
                    }
                    guard pulse.session.generation > old.session.generation else { return .stale }
                    old.retire()
                } else if value.sessions.count >= 128 { return .stale }
                value.sessions[pulse.session.host] = .init(session: pulse.session, serviceID: serviceID,
                    openedAt: now(), sequence: pulse.sequence)
                return .accepted
            case .heartbeat:
                guard let old, old.session == pulse.session, old.serviceID == serviceID else { return .stale }
                return old.heartbeat(sequence: pulse.sequence, at: now()) ? .accepted : .resetRequired
            case .retire:
                guard let old, old.session == pulse.session, old.serviceID == serviceID else { return .stale }
                old.retire(); return .accepted
            }
        }
    }
    public func install(fence: V2RoomSubscriptionFence, serviceID: String, session: V2RoomDeliverySession,
                        afterAuthoritativeReset: Bool = false) async -> Bool {
        guard (try? fence.validate()) != nil, session.host == fence.activation.host,
              let gate = sessionGate(session, serviceID: serviceID), gate.isReady(at: now()), !serviceID.isEmpty,
              serviceID.utf8.count <= 128 else { return false }
        let selected = catalog.withLock { value -> V2RoomSubscriptionActor? in
            guard !value.closed,
                  value.rooms[fence.roomID] != nil || value.rooms.count < maximumRooms + maximumRetiredRooms, value.rooms[fence.roomID] != nil || !value.requiresReset || afterAuthoritativeReset,
                  value.active.contains(fence.roomID) || value.active.count < maximumRooms else { return nil }
            let cell = value.rooms[fence.roomID] ?? V2RoomSubscriptionActor(roomID: fence.roomID,
                connections: connections, maximumMembersPerRoom: maximumMembersPerRoom, now: now)
            value.rooms[fence.roomID] = cell
            return cell
        }
        guard let selected else { return false }
        let result = await selected.install(fence: fence, serviceID: serviceID, session: gate,
            reserve: { self.catalog.withLock { value in
                guard !value.closed, value.rooms[fence.roomID] === selected,
                      value.active.contains(fence.roomID) || value.active.count < self.maximumRooms else { return false }
                value.active.insert(fence.roomID); value.retired.remove(fence.roomID); value.hostsByRoom[fence.roomID] = fence.activation.host; return true
            } })
        if !result {
            catalog.withLock { value in
                if value.rooms[fence.roomID] === selected, !value.active.contains(fence.roomID), !value.retired.contains(fence.roomID) {
                    value.rooms.removeValue(forKey: fence.roomID)
                }
            }
        }
        return result
    }
    public func pause(fence: V2RoomSubscriptionFence) async -> Bool {
        await room(fence.roomID)?.mutate { $0.pause(fence: fence) } ?? false
    }
    public func retire(fence: V2RoomSubscriptionFence) async -> Bool {
        guard let cell = room(fence.roomID) else { return false }
        return await cell.retire(fence: fence) { self.catalog.withLock { value in
            guard value.rooms[fence.roomID] === cell else { return }
            value.active.remove(fence.roomID); value.retired.insert(fence.roomID)
            if value.retired.count > self.maximumRetiredRooms, let evicted = value.retired.first {
                value.retired.remove(evicted); value.rooms.removeValue(forKey: evicted); value.requiresReset = true
            }
        } }
    }
    public func apply(_ delivery: V2RoomSubscriptionDelivery, authenticatedServiceID: String) async -> ApplyResult {
        await room(delivery.fence.roomID)?.apply(delivery, serviceID: authenticatedServiceID) ?? .stale
    }
    public func capturePermits(roomID: RoomID) async -> [Permit] { await room(roomID)?.capture(detail: true) ?? [] }
    public func captureOnlinePermits(roomID: RoomID) async -> [Permit] { await room(roomID)?.capture(detail: false) ?? [] }
    public func progressSnapshot(connectionID: UUID) async -> (authorization: Permit, highWatermark: UInt64)? {
        guard let interest = connections.snapshot().connections[connectionID]?.interest,
              let cell = room(interest.roomID) else { return nil }
        return await cell.progress(connectionID: connectionID)
    }
    public func authorizedMemberRevision(roomID: RoomID, userID: UserID) async -> UInt64? {
        await room(roomID)?.read { $0.authorizedMemberRevision(roomID: roomID, userID: userID) } ?? nil
    }
    public func authorizationCheckpoint(fence: V2RoomSubscriptionFence, serviceID: String) async -> UInt64? {
        await room(fence.roomID)?.read { $0.authorizationCheckpoint(fence: fence, serviceID: serviceID) } ?? nil
    }
    public func recordCommittedHead(fence: V2RoomSubscriptionFence, serviceID: String, highWatermark: UInt64) async -> Bool {
        await room(fence.roomID)?.read { $0.recordCommittedHead(fence: fence, serviceID: serviceID, highWatermark: highWatermark) } ?? false
    }
    public func recoveryHighWatermark(roomID: RoomID) async -> UInt64? {
        await room(roomID)?.read { $0.recoveryHighWatermark(roomID: roomID) } ?? nil
    }
    public func requiresBaseline(fence: V2RoomSubscriptionFence) async -> Bool {
        if let cell = room(fence.roomID) { return await cell.read { $0.requiresBaseline(fence: fence) } }
        return catalog.withLock { $0.requiresReset }
    }
    func validateDeviceProgress(connectionID: UUID, userID: UserID,
        reports: [(RoomID, UInt64)]) async throws -> [V2DeviceRoomProgress] {
        guard reports.count <= 64, Set(reports.map { $0.0 }).count == reports.count,
              connections.snapshot().connections[connectionID]?.userID == userID else { throw V2RoomRecoveryReadError.invalidRequest }
        var result: [V2DeviceRoomProgress] = []
        for report in reports {
            guard let cell = room(report.0) else { throw V2RoomRecoveryReadError.topologyChanged }
            result += try await cell.read { try $0.validateDeviceProgress(connectionID: connectionID, userID: userID, reports: [report]) }
        }
        return result
    }
    @discardableResult
    public func registerConnection(_ connectionID: UUID, userID: UserID, lifecycle: UUID) -> Bool {
        let old = connections.snapshot().connections[connectionID]
        let accepted = connections.registerConnection(connectionID, userID: userID, lifecycle: lifecycle)
        if accepted, let old, old.lifecycle != lifecycle || old.userID != userID { _ = old.socketGate?.close() }
        return accepted
    }
    func bindSocket(_ connectionID: UUID, lifecycle: UUID, gate: V2RoomSubscriptionSocketGate) async {
        guard connections.bindSocket(connectionID, lifecycle: lifecycle, gate: gate) else { return }
        if let pending = connections.snapshot().connections[connectionID]?.publication { try? await pending.get() }
    }
    public func removeConnection(_ connectionID: UUID, lifecycle: UUID) {
        let gate = connections.snapshot().connections[connectionID]?.socketGate
        connections.removeConnection(connectionID, lifecycle: lifecycle)
        if gate != nil, connections.snapshot().connections[connectionID] == nil { _ = gate?.close() }
    }
    @discardableResult
    public func registerRoomInterest(connectionID: UUID, lifecycle: UUID, roomID: RoomID, scopeGeneration: UInt64) async -> Bool {
        guard connections.registerRoomInterest(connectionID: connectionID, lifecycle: lifecycle, roomID: roomID,
            scopeGeneration: scopeGeneration) else { return false }
        if let pending = connections.snapshot().connections[connectionID]?.publication { try? await pending.get() }
        return true
    }
    public func removeRoomInterest(connectionID: UUID, lifecycle: UUID, roomID: RoomID) async {
        connections.removeRoomInterest(connectionID: connectionID, lifecycle: lifecycle, roomID: roomID)
        if let pending = connections.snapshot().connections[connectionID]?.publication { try? await pending.get() }
    }
    func interestPermit(connectionID: UUID, lifecycle: UUID, roomID: RoomID,
                        generation: UInt64) -> @Sendable (@Sendable () -> Void) -> Bool {
        let gate = connections.snapshot().connections[connectionID]?.socketGate
        return { enqueue in
            guard let gate, gate.eventLoop.inEventLoop else { return false }
            return gate.enqueueInterest(lifecycle: lifecycle, roomID: roomID, generation: generation, body: enqueue)
        }
    }
    public func enqueueIfCurrent(_ permit: Permit, enqueue: @Sendable () -> Void) -> Bool {
        guard let gate = permit.socketGate, gate.eventLoop.inEventLoop else { return false }
        return gate.enqueue(permit, now: now(), body: enqueue)
    }
    public func shutdown() async {
        let cells = catalog.withLock { value in let cells = Array(value.rooms.values); for gate in value.sessions.values { gate.retire() }; value = Catalog(); value.closed = true; return cells }
        connections.shutdown()
        for cell in cells { await cell.mutate { $0.shutdown() } }
    }
}

fileprivate actor V2RoomSubscriptionActor {
    private var executing = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []
    private func enter() async {
        if !executing { executing = true; return }
        await withCheckedContinuation { turnWaiters.append($0) }
    }
    private func leave() {
        if turnWaiters.isEmpty { executing = false }
        else { turnWaiters.removeFirst().resume() }
    }
    private let roomID: RoomID
    private let machine: V2RoomSubscriptionStateMachine
    private let connections: V2RoomSubscriptionConnections
    private var projectionDirty = false
    private var users: Set<UserID> = []
    private var publicationBarrier: [UUID: EventLoopFuture<Void>] = [:]
    private var projected: [UUID: (UserID, V2RoomSubscriptionSocketGate, V2RoomSubscriptionSocketGate.RoomPermission)] = [:]
    init(roomID: RoomID, connections: V2RoomSubscriptionConnections, maximumMembersPerRoom: Int,
         now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.roomID = roomID; self.connections = connections
        machine = .init(directory: connections, maximumMembersPerRoom: maximumMembersPerRoom, now: now)
    }
    func read<T: Sendable>(_ body: @Sendable (V2RoomSubscriptionStateMachine) throws -> T) async rethrows -> T {
        await enter(); defer { leave() }; return try body(machine)
    }
    func mutate<T: Sendable>(_ body: @Sendable (V2RoomSubscriptionStateMachine) -> T) async -> T {
        await enter(); defer { leave() }
        return await commit(body)
    }
    private func commit<T: Sendable>(_ body: @Sendable (V2RoomSubscriptionStateMachine) -> T) async -> T {
        let result = body(machine)
        projectionDirty = true
        await settle()
        return result
    }
    func install(fence: V2RoomSubscriptionFence, serviceID: String, session: V2RoomDeliverySessionGate,
                 reserve: @Sendable () -> Bool) async -> Bool {
        await enter(); defer { leave() }
        // Reserve only after all state-machine validation, immediately before
        // mutation. Rejection/expiry cannot leak a shared active-room slot.
        guard machine.install(fence: fence, serviceID: serviceID, session: session, reserve: reserve) else { return false }
        projectionDirty = true
        await settle()
        return true
    }
    func retire(fence: V2RoomSubscriptionFence, release: @Sendable () -> Void) async -> Bool {
        await enter(); defer { leave() }
        let accepted = machine.retire(fence: fence)
        projectionDirty = true
        await settle()
        // Do not evict the actor/free its slot until its denial publications
        // finish. A new actor for the same room must never be overwritten by
        // an old actor's late denial on the same connection EventLoop.
        if accepted { release() }
        return accepted
    }
    func capture(detail: Bool) async -> [V2GatewayRoomSubscriptionAuthority.Permit] {
        await enter(); defer { leave() }
        let permits = bind(detail ? machine.capturePermits(roomID: roomID) : machine.captureOnlinePermits(roomID: roomID))
        await settle()
        return permits
    }
    func progress(connectionID: UUID) async -> (authorization: V2GatewayRoomSubscriptionAuthority.Permit, highWatermark: UInt64)? {
        await enter(); defer { leave() }
        guard let result = machine.progressSnapshot(connectionID: connectionID) else { return nil }
        let permit = bind([result.authorization])[0]
        await settle()
        return (permit, result.highWatermark)
    }
    func apply(_ delivery: V2RoomSubscriptionDelivery, serviceID: String) async -> V2GatewayRoomSubscriptionAuthority.ApplyResult {
        await enter(); defer { leave() }
        var result = machine.apply(delivery, authenticatedServiceID: serviceID)
        if delivery.payload.isAuthorizationControl { projectionDirty = true }
        if case .applied = result {} else { projectionDirty = true }
        if case .applied(let permits) = result { result = .applied(permits: bind(permits)) }
        await settle()
        return result
    }
    private func bind(_ permits: [V2GatewayRoomSubscriptionAuthority.Permit]) -> [V2GatewayRoomSubscriptionAuthority.Permit] {
        let liveConnections = connections.snapshot().connections
        return permits.map { original in
            var permit = original
            if users.insert(permit.userID).inserted { projectionDirty = true }
            if let gate = liveConnections[permit.connectionID]?.socketGate {
                permit.socketGate = gate
                if projected[permit.connectionID]?.1 !== gate || projected[permit.connectionID]?.0 != permit.userID {
                    projected[permit.connectionID] = (permit.userID, gate, .denied); projectionDirty = true
                }
            }
            return permit
        }
    }
    private func settle() async {
        let pending = publish()
        for future in pending { try? await future.get() }
        // enter/leave owns the complete turn, so no later publication can be
        // installed while this barrier is being awaited or cleared.
        publicationBarrier.removeAll(keepingCapacity: true)
    }
    private func publish() -> [EventLoopFuture<Void>] {
        guard projectionDirty else { return Array(publicationBarrier.values) }
        projectionDirty = false
        let permissions = Dictionary(uniqueKeysWithValues: users.map { ($0, machine.permission(roomID: roomID, userID: $0)) })
        let liveConnections = connections.snapshot().connections
        for (id, (user, gate, previous)) in projected {
            let permission = permissions[user] ?? .denied
            if permission != previous {
                // Submit all publications before the first await. Actor
                // reentrancy cannot reorder older updates after newer ones.
                let future = gate.install(roomID: roomID, permission: permission)
                publicationBarrier[id] = future
                projected[id] = (user, gate, permission)
            }
            if liveConnections[id]?.socketGate !== gate { projected.removeValue(forKey: id); publicationBarrier.removeValue(forKey: id) }
        }
        return Array(publicationBarrier.values)
    }
}

/// Mutable room state is exclusively owned by one room actor. Connection
/// selection uses short directory snapshots; transitions execute no socket
/// callback, SQL, or await.
fileprivate final class V2RoomSubscriptionStateMachine {
    typealias Permit = V2GatewayRoomSubscriptionAuthority.Permit
    typealias ApplyResult = V2GatewayRoomSubscriptionAuthority.ApplyResult
    private struct Member: Sendable {
        let revision: UInt64
        let baselineSequence: UInt64
        let authorizationID: UUID
    }
    private struct AuthorizationState: Sendable {
        var sequence: UInt64 = 0
        var ready = false
        var baselineTotalMembers: Int?
        var members: [UserID: Member] = [:]
        var revisionFloors: [UserID: UInt64] = [:]
        var history: [UInt64: Data] = [:]
    }
    private struct MessageProgress: Sendable {
        var deliverySequence: UInt64 = 0
        var eventSequence: UInt64 = 0
        var recoveryHighWatermark: UInt64 = 0
    }
    // This reference never leaves the owning room actor. Mutating a room must
    // not copy its membership and replay dictionaries on every delivery.
    private final class Room {
        let fence: V2RoomSubscriptionFence
        let serviceID: String
        var session: V2RoomDeliverySessionGate
        var authorization = AuthorizationState()
        var messages = MessageProgress()
        var deliverySequence: UInt64 = 0
        var receiptHistory: [UInt64: Data] = [:]
        var retired = false

        init(fence: V2RoomSubscriptionFence, serviceID: String, session: V2RoomDeliverySessionGate) {
            self.fence = fence; self.serviceID = serviceID; self.session = session
        }

        func recordReceipt(sequence: UInt64, digest: Data) {
            let previousHead = deliverySequence
            deliverySequence = max(previousHead, sequence)
            if deliverySequence > 256 {
                let expiredThrough = deliverySequence - 256
                if previousHead <= expiredThrough {
                    receiptHistory.removeAll(keepingCapacity: true)
                } else {
                    let firstExpired = previousHead > 256 ? previousHead - 255 : 1
                    if firstExpired <= expiredThrough {
                        for expired in firstExpired...expiredThrough {
                            receiptHistory.removeValue(forKey: expired)
                        }
                    }
                }
                guard sequence > expiredThrough else { return }
            }
            receiptHistory[sequence] = digest
        }
    }
    private struct State {
        var rooms: [RoomID: Room] = [:]
        var activeRoomCount = 0
        var retiredRooms: Set<RoomID> = []
        var unknownRoomsRequireReset = false
        var closed = false
        let directory: V2RoomSubscriptionConnections
        var connections: [UUID: V2RoomSubscriptionConnections.Connection] { directory.snapshot().connections }
        var connectionsByUser: [UserID: Set<UUID>] { directory.snapshot().connectionsByUser }
        var connectionsByRoomUser: [V2RoomSubscriptionConnections.RoomUser: Set<UUID>] { directory.snapshot().connectionsByRoomUser }
    }
    private var state: State
    private func withState<T>(_ body: (inout State) throws -> T) rethrows -> T { try body(&state) }
    private let now: @Sendable () -> ContinuousClock.Instant
    private let maximumRooms: Int
    private let maximumRetiredRooms: Int
    /// Reports use account delivery authority, never the foreground interest.
    func validateDeviceProgress(connectionID: UUID, userID: UserID,
        reports: [(RoomID, UInt64)]) throws -> [V2DeviceRoomProgress] {
        try withState { value in
            guard reports.count <= 64, Set(reports.map { $0.0 }).count == reports.count,
                  !value.closed, let connection = value.connections[connectionID],
                  connection.userID == userID else { throw V2RoomRecoveryReadError.invalidRequest }
            return try reports.map { roomID, applied in
                guard let room = value.rooms[roomID], room.authorization.ready, room.session.isReady(at: now()) else {
                    throw V2RoomRecoveryReadError.topologyChanged
                }
                guard room.authorization.members[userID] != nil else {
                    throw V2RoomRecoveryReadError.invalidCursor
                }
                guard applied <= room.messages.recoveryHighWatermark else { throw V2RoomRecoveryReadError.topologyChanged }
                return try .init(roomID: roomID, appliedThrough: applied,
                    authorizedHighWatermark: room.messages.recoveryHighWatermark)
            }
        }
    }
    private let maximumMembersPerRoom: Int
    init(directory: V2RoomSubscriptionConnections, maximumMembersPerRoom: Int,
         now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.state = State(directory: directory)
        self.maximumRooms = 1; self.maximumRetiredRooms = 1
        self.maximumMembersPerRoom = maximumMembersPerRoom; self.now = now
    }
    /// Baseline/Ready and H capture the same exact room/user/device gate as bodies.
    func capturePermits(roomID: RoomID) -> [Permit] {
        withState { value in
            guard !value.closed, let room = value.rooms[roomID], room.authorization.ready, room.session.isReady(at: now()) else { return [] }
            return room.authorization.members.flatMap { userID, member in
                (value.connectionsByRoomUser[V2RoomSubscriptionConnections.RoomUser(roomID: roomID, userID: userID)] ?? []).compactMap { connectionID -> Permit? in
                    guard let connection = value.connections[connectionID], let interest = connection.interest else { return nil }
                    return Permit(fence: room.fence, userID: userID, memberRevision: member.revision,
                        connectionID: connectionID, lifecycle: connection.lifecycle, scopeGeneration: interest.scopeGeneration,
                        baselineSequence: member.baselineSequence, roomInterestID: interest.id, authorizationID: member.authorizationID)
                }
            }
        }
    }

    /// Account delivery includes every authenticated device of a current member.
    func captureOnlinePermits(roomID: RoomID) -> [Permit] {
        withState { value in
            guard !value.closed, let room = value.rooms[roomID], room.authorization.ready,
                  room.session.isReady(at: now()) else { return [] }
            return room.authorization.members.flatMap { userID, member in
                (value.connectionsByUser[userID] ?? []).compactMap { connectionID in
                    guard let connection = value.connections[connectionID] else { return nil }
                    return accountPermit(room: room, member: member, connectionID: connectionID, connection: connection)
                }
            }
        }
    }

    /// O(1) connection-local snapshot. Neither caller room IDs nor progress
    /// reports select authority; only the authenticated connection's interest does.
    func progressSnapshot(connectionID: UUID) -> (authorization: Permit, highWatermark: UInt64)? {
        withState { value in
            guard !value.closed, let connection = value.connections[connectionID],
                  let interest = connection.interest else {
                V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.progressNoInterest); return nil
            }
            guard let room = value.rooms[interest.roomID] else {
                V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.progressNoRoom); return nil
            }
            guard room.authorization.ready else {
                V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.progressAuthorityNotReady); return nil
            }
            guard room.session.isReady(at: now()) else {
                V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.progressSessionUnavailable); return nil
            }
            guard let member = room.authorization.members[connection.userID] else {
                V2RoomSubscriptionHeadDeliveryMetrics.shared.record(.progressNoMember); return nil
            }
            let permit = Permit(fence: room.fence, userID: connection.userID, memberRevision: member.revision,
                connectionID: connectionID, lifecycle: connection.lifecycle, scopeGeneration: interest.scopeGeneration,
                baselineSequence: member.baselineSequence, roomInterestID: interest.id, authorizationID: member.authorizationID)
            return (permit, room.messages.recoveryHighWatermark)
        }
    }

    /// A new fence requires a baseline; equal live fences renew without making
    /// other users/devices stale. Epoch/generation history survives retirement.
    @discardableResult
    func install(fence: V2RoomSubscriptionFence, serviceID: String,
                        session: V2RoomDeliverySessionGate, afterAuthoritativeReset: Bool = false,
                        reserve: @Sendable () -> Bool = { true }) -> Bool {
        withState { value in
            do { try fence.validate() } catch { return false }
            guard !value.closed, session.isReady(at: now()),
                  !serviceID.isEmpty, serviceID.utf8.count <= 128,
                  value.rooms[fence.roomID].map({ !$0.retired }) == true || value.activeRoomCount < maximumRooms else { return false }
            // This flag comes only from a locally validated reset RPC, never
            // from a delivery packet. Once history is evicted, unknown rooms
            // cannot use an ordinary grant to bypass the missing fence floor.
            guard value.rooms[fence.roomID] != nil || !value.unknownRoomsRequireReset || afterAuthoritativeReset else { return false }
            if let old = value.rooms[fence.roomID] {
                if old.fence == fence {
                    guard !old.retired, old.serviceID == serviceID, old.session.isReady(at: now()) else { return false }
                    guard reserve() else { return false }
                    return old.session === session
                }
                if fence.activation == old.fence.activation {
                    guard fence.generation > old.fence.generation else { return false }
                } else {
                    // Same data epoch can start a new activation at generation 1.
                    // An equal activation epoch on another host is a conflict,
                    // never a newer lease or a reason to revive old authority.
                    guard fence.activation.isNewer(than: old.fence.activation) else { return false }
                }
            }
            guard reserve() else { return false }
            let previous = value.rooms[fence.roomID]
            let retainedHead = previous?.fence.activation.owner == fence.activation.owner
                ? previous?.messages.recoveryHighWatermark ?? 0 : 0
            let replacement = Room(fence: fence, serviceID: serviceID, session: session)
            replacement.messages.recoveryHighWatermark = max(retainedHead, fence.baselineSequence)
            if previous == nil || previous?.retired == true { value.activeRoomCount += 1 }
            value.retiredRooms.remove(fence.roomID)
            value.rooms[fence.roomID] = replacement
            return true
        }
    }

    @discardableResult
    func pause(fence: V2RoomSubscriptionFence) -> Bool {
        withState { value in
            guard let room = value.rooms[fence.roomID], room.fence == fence else { return false }
            room.authorization.ready = false; room.authorization.members.removeAll()
            // A pre-baseline pause also needs a new fence, not initial activation.
            room.deliverySequence = max(1, room.deliverySequence)
            return true
        }
    }

    func authorizedMemberRevision(roomID: RoomID, userID: UserID) -> UInt64? {
        withState { value in
            guard !value.closed, let room = value.rooms[roomID], room.authorization.ready, room.session.isReady(at: now()) else { return nil }
            return room.authorization.members[userID]?.revision
        }
    }

    func authorizationCheckpoint(fence: V2RoomSubscriptionFence, serviceID: String) -> UInt64? {
        withState { value in
            guard !value.closed, let room = value.rooms[fence.roomID], room.fence == fence,
                  room.serviceID == serviceID, room.authorization.ready, room.session.isReady(at: now()) else { return nil }
            return room.authorization.sequence
        }
    }

    /// Publishing H grants no members and cannot extend a permission deadline.
    @discardableResult
    func recordCommittedHead(fence: V2RoomSubscriptionFence, serviceID: String, highWatermark: UInt64) -> Bool {
        withState { value in
            guard !value.closed, let room = value.rooms[fence.roomID], !room.retired, room.fence == fence,
                  room.serviceID == serviceID, highWatermark >= fence.baselineSequence,
                  highWatermark <= UInt64(Int64.max) else { return false }
            room.messages.recoveryHighWatermark = max(room.messages.recoveryHighWatermark, highWatermark)
            return true
        }
    }

    func requiresBaseline(fence: V2RoomSubscriptionFence) -> Bool {
        withState { value in
            guard let room = value.rooms[fence.roomID] else { return value.unknownRoomsRequireReset }
            guard room.fence == fence else { return false }
            return room.retired || !room.session.isReady(at: now()) || (!room.authorization.ready && room.deliverySequence > 0)
        }
    }

    func apply(_ delivery: V2RoomSubscriptionDelivery, authenticatedServiceID: String) -> ApplyResult {
        // Immutable validation and replay hashing do not need the state lock.
        do { try delivery.validate(maximumMembers: maximumMembersPerRoom) } catch { return .invalid }
        let digest = V2RoomSubscriptionDeliveryFingerprint.digest(delivery)
        return withState { value in
            let id = delivery.fence.roomID
            guard !value.closed, let room = value.rooms[id], room.fence == delivery.fence,
                  room.serviceID == authenticatedServiceID else { return .stale }
            let terminal = delivery.payload == .authorizationInvalidated
            // Closing an exact, authenticated fence grants no authority. Its
            // actual receipt must remain possible after local expiry/retirement;
            // otherwise the Owner cannot finish this cut or issue a fresh fence.
            guard terminal || (!room.retired && room.session.isReady(at: now())) else {
                room.authorization.ready = false; room.authorization.members.removeAll()
                return .stale
            }
            if let previous = room.receiptHistory[delivery.deliverySequence] {
                guard previous == digest else {
                    // A stale body/head cannot change authorization. A
                    // conflicting control, however, destroys its proof.
                    guard delivery.payload.isAuthorizationControl else { return .stale }
                    room.authorization.ready = false; room.authorization.members.removeAll()
                    room.deliverySequence = max(1, room.deliverySequence)
                    return .snapshotRequired
                }
                return .applied(permits: [])
            }
            if delivery.payload.isAuthorizationControl {
                if delivery.authorizationSequence <= room.authorization.sequence {
                    guard let previous = room.authorization.history[delivery.authorizationSequence] else { return .stale }
                    guard previous == digest else {
                        room.authorization.ready = false; room.authorization.members.removeAll()
                        room.deliverySequence = max(1, room.deliverySequence)
                        return .snapshotRequired
                    }
                    return .applied(permits: [])
                }
                guard terminal || (room.authorization.sequence < UInt64.max &&
                      delivery.authorizationSequence == room.authorization.sequence + 1) else {
                    room.authorization.ready = false; room.authorization.members.removeAll()
                    room.deliverySequence = max(1, room.deliverySequence)
                    return .snapshotRequired
                }
            } else {
                // Data consumes an exact authorization cut. Missing data is
                // recovered by room sequence; it never destroys member grants.
                guard room.authorization.ready else { return .snapshotRequired }
                guard delivery.authorizationSequence == room.authorization.sequence else { return .stale }
                if delivery.deliverySequence <= room.messages.deliverySequence { return .applied(permits: []) }
            }
            var permits: [Permit] = []
            switch delivery.payload {
            case .baseline(let members):
                guard !room.authorization.ready, room.deliverySequence == 0,
                      validMembers(members) else { return .invalid }
                room.authorization.members = Dictionary(uniqueKeysWithValues: members.map {
                    ($0.userID, Member(revision: $0.memberRevision, baselineSequence: delivery.fence.baselineSequence,
                                      authorizationID: UUID()))
                })
                room.authorization.revisionFloors = Dictionary(uniqueKeysWithValues: members.map { ($0.userID, $0.memberRevision) })
                room.authorization.ready = true; room.messages.eventSequence = room.fence.baselineSequence
                room.messages.recoveryHighWatermark = max(room.messages.recoveryHighWatermark, room.fence.baselineSequence)
            case .baselinePage(let index, let total, let members):
                guard !room.authorization.ready,
                      room.authorization.baselineTotalMembers.map({ $0 == total }) ?? (index == 0),
                      validMembers(members),
                      members.allSatisfy({ room.authorization.members[$0.userID] == nil }) else {
                    return .snapshotRequired
                }
                room.authorization.baselineTotalMembers = total
                for member in members {
                    room.authorization.members[member.userID] = Member(revision: member.memberRevision,
                        baselineSequence: room.fence.baselineSequence, authorizationID: UUID())
                    room.authorization.revisionFloors[member.userID] = member.memberRevision
                }
                if room.authorization.members.count == total {
                    room.authorization.ready = true
                    room.authorization.baselineTotalMembers = nil
                    room.messages.eventSequence = room.fence.baselineSequence
                    room.messages.recoveryHighWatermark = max(room.messages.recoveryHighWatermark, room.fence.baselineSequence)
                }
            case .grant(let member, let baselineSequence):
                guard room.authorization.ready else { return .snapshotRequired }
                // Floors reject older membership incarnations; an ordered grant
                // may resubscribe the current incarnation with a NEW authority ID.
                guard room.authorization.revisionFloors[member.userID].map({ member.memberRevision >= $0 }) ?? true,
                      room.authorization.members[member.userID]?.revision != member.memberRevision,
                      room.authorization.revisionFloors[member.userID] != nil || room.authorization.revisionFloors.count < maximumMembersPerRoom,
                      baselineSequence >= room.fence.baselineSequence else { return .invalid }
                room.authorization.members[member.userID] = Member(revision: member.memberRevision,
                    baselineSequence: baselineSequence, authorizationID: UUID())
                room.authorization.revisionFloors[member.userID] = member.memberRevision
            case .revoke(let userID, let revision):
                guard room.authorization.ready else { return .snapshotRequired }
                guard room.authorization.revisionFloors[userID].map({ revision >= $0 }) ?? true,
                      room.authorization.revisionFloors[userID] != nil || room.authorization.revisionFloors.count < maximumMembersPerRoom else { return .invalid }
                room.authorization.members.removeValue(forKey: userID); room.authorization.revisionFloors[userID] = revision
            case .event(let event, let members):
                guard room.authorization.ready else { return .snapshotRequired }
                guard event.roomID == id, event.roomSequence > room.messages.eventSequence, validMembers(members) else { return .invalid }
                room.messages.eventSequence = event.roomSequence
                room.messages.recoveryHighWatermark = max(room.messages.recoveryHighWatermark, event.highWatermark)
                let directory = value.directory.snapshot()
                for recipient in members {
                    let userID = recipient.userID
                    guard (event.recipientUserIDs.isEmpty && event.groupMembershipRevision != nil)
                            || event.recipientUserIDs.contains(userID),
                          let member = room.authorization.members[userID], recipient.memberRevision == member.revision,
                          event.roomSequence > member.baselineSequence else { continue }
                    // Enumerate only this delivery's users and their devices.
                    for connectionID in directory.connectionsByUser[userID] ?? [] {
                        guard connectionID != event.excludedConnectionID,
                              let connection = directory.connections[connectionID] else { continue }
                        permits.append(accountPermit(room: room, member: member, connectionID: connectionID, connection: connection))
                    }
                }
            case .broadcast(let event):
                guard room.authorization.ready else { return .snapshotRequired }
                guard event.roomID == id, event.roomSequence > room.messages.eventSequence else { return .invalid }
                room.messages.eventSequence = event.roomSequence
                room.messages.recoveryHighWatermark = max(room.messages.recoveryHighWatermark, event.highWatermark)
                let directory = value.directory.snapshot()
                for (userID, member) in room.authorization.members {
                    guard event.roomSequence > member.baselineSequence else { continue }
                    // Enumerate only this delivery's users and their devices.
                    for connectionID in directory.connectionsByUser[userID] ?? [] {
                        guard connectionID != event.excludedConnectionID,
                              let connection = directory.connections[connectionID] else { continue }
                        permits.append(accountPermit(room: room, member: member, connectionID: connectionID, connection: connection))
                    }
                }
            case .authorizationInvalidated:
                // A terminal can close a cut with missing preceding controls,
                // including history cleared by retirement. It cannot apply a
                // grant, revive a deadline or acknowledge a different fence.
                room.authorization.ready = false; room.authorization.members.removeAll()
            case .head(let highWatermark):
                guard room.authorization.ready else { return .snapshotRequired }
                room.messages.recoveryHighWatermark = max(room.messages.recoveryHighWatermark, highWatermark)
                // H is advisory. It never installs body or membership authority.
            }
            room.recordReceipt(sequence: delivery.deliverySequence, digest: digest)
            if delivery.payload.isAuthorizationControl {
                room.authorization.sequence = delivery.authorizationSequence
                room.authorization.history[delivery.authorizationSequence] = digest
                if delivery.authorizationSequence > 256 { room.authorization.history.removeValue(forKey: delivery.authorizationSequence - 256) }
            }
            if !delivery.payload.isAuthorizationControl { room.messages.deliverySequence = delivery.deliverySequence }
            return .applied(permits: permits)
        }
    }

    /// Recovery H is advisory, independent of the last body event sequence.
    func recoveryHighWatermark(roomID: RoomID) -> UInt64? {
        withState { value in value.closed ? nil : value.rooms[roomID]?.messages.recoveryHighWatermark }
    }
    /// Retain only the fence and advisory progress needed by a later fresh
    /// baseline. Historical authorization and receipts do not consume active
    /// room capacity or authorize delayed packets after this boundary.
    @discardableResult
    func retire(fence: V2RoomSubscriptionFence) -> Bool {
        withState { value in
            guard !value.closed, let room = value.rooms[fence.roomID], room.fence == fence else { return false }
            guard !room.retired else { return true }
            room.retired = true
            room.authorization = AuthorizationState()
            room.receiptHistory.removeAll()
            let head = room.messages.recoveryHighWatermark
            room.messages = MessageProgress()
            room.messages.recoveryHighWatermark = head
            value.activeRoomCount -= 1
            value.retiredRooms.insert(fence.roomID)
            if value.retiredRooms.count > maximumRetiredRooms, let evicted = value.retiredRooms.first {
                value.retiredRooms.remove(evicted)
                value.rooms.removeValue(forKey: evicted)
                value.unknownRoomsRequireReset = true
            }
            return true
        }
    }
    func shutdown() {
        withState { value in
            value = State(directory: value.directory); value.closed = true
        }
    }
    private func accountPermit(room: Room, member: Member, connectionID: UUID, connection: V2RoomSubscriptionConnections.Connection) -> Permit {
        var permit = Permit(fence: room.fence, userID: connection.userID, memberRevision: member.revision,
            connectionID: connectionID, lifecycle: connection.lifecycle, scopeGeneration: 0,
            baselineSequence: member.baselineSequence, roomInterestID: connection.lifecycle,
            authorizationID: member.authorizationID)
        permit.requiresRoomInterest = false
        return permit
    }
    private func validMembers(_ members: [V2RoomSubscriptionMember]) -> Bool {
        members.count <= maximumMembersPerRoom && Set(members.map(\.userID)).count == members.count && members.allSatisfy { $0.memberRevision <= UInt64(Int64.max) }
    }
    func permission(roomID: RoomID, userID: UserID) -> V2RoomSubscriptionSocketGate.RoomPermission {
        guard !state.closed, let room = state.rooms[roomID], !room.retired, room.authorization.ready,
              let member = room.authorization.members[userID] else { return .denied }
        return .init(fence: room.fence, session: room.session,
            authorizationID: member.authorizationID, memberRevision: member.revision)
    }

}

fileprivate final class V2RoomSubscriptionConnections: Sendable {
    fileprivate struct RoomInterest: Sendable {
        let roomID: RoomID
        let scopeGeneration: UInt64
        let id: UUID
    }
    fileprivate struct Connection: Sendable {
        let userID: UserID
        let lifecycle: UUID
        var interest: RoomInterest?
        var lastScopeGeneration: UInt64 = 0
        var socketGate: V2RoomSubscriptionSocketGate? = nil
        var publication: EventLoopFuture<Void>? = nil
    }
    fileprivate struct RoomUser: Hashable, Sendable {
        let roomID: RoomID
        let userID: UserID
    }
    fileprivate struct ConnectionState: Sendable {
        var connections: [UUID: Connection] = [:]
        var connectionsByUser: [UserID: Set<UUID>] = [:]
        var connectionsByRoomUser: [RoomUser: Set<UUID>] = [:]
        var closed = false
    }
    private let state = Mutex(ConnectionState())
    let maximumConnections: Int
    init(maximumConnections: Int) { self.maximumConnections = maximumConnections }
    func snapshot() -> ConnectionState { state.withLock { $0 } }
    private func withLock<T>(_ body: (inout sending ConnectionState) throws -> sending T) rethrows -> T {
        try state.withLock(body)
    }
    /// Registry calls this after authenticating the exact connection lifecycle.
    /// Adding another device never changes room/user authorization IDs.
    @discardableResult
    func registerConnection(_ connectionID: UUID, userID: UserID, lifecycle: UUID) -> Bool {
        withLock { value in
            guard !value.closed else { return false }
            if let old = value.connections[connectionID], old.lifecycle == lifecycle, old.userID == userID { return true }
            guard value.connections[connectionID] != nil || value.connections.count < maximumConnections else { return false }
            if let old = value.connections[connectionID] {
                removeInterestIndex(connectionID, connection: old, in: &value)
                removeUserIndex(connectionID, connection: old, in: &value)
            }
            value.connections[connectionID] = Connection(userID: userID, lifecycle: lifecycle)
            value.connectionsByUser[userID, default: []].insert(connectionID)
            return true
        }
    }
    func removeConnection(_ connectionID: UUID, lifecycle: UUID) {
        withLock { value in
            guard let connection = value.connections[connectionID], connection.lifecycle == lifecycle else { return }
            value.connections.removeValue(forKey: connectionID)
            removeInterestIndex(connectionID, connection: connection, in: &value)
            removeUserIndex(connectionID, connection: connection, in: &value)
        }
    }

    /// Called only after this authenticated device requests this detail room.
    /// Detail interest controls detail Ready only; account grants independently
    /// authorize message delivery to all online devices of that member.
    @discardableResult
    func registerRoomInterest(connectionID: UUID, lifecycle: UUID, roomID: RoomID,
                                     scopeGeneration: UInt64) -> Bool {
        withLock { value in
            guard !value.closed, scopeGeneration > 0, var connection = value.connections[connectionID],
                  connection.lifecycle == lifecycle else { return false }
            if let old = connection.interest {
                if old.roomID == roomID, old.scopeGeneration == scopeGeneration { return true }
            }
            guard scopeGeneration > connection.lastScopeGeneration else { return false }
            removeInterestIndex(connectionID, connection: connection, in: &value)
            connection.lastScopeGeneration = scopeGeneration
            connection.interest = RoomInterest(roomID: roomID, scopeGeneration: scopeGeneration, id: UUID())
            connection.publication = connection.socketGate?.interest(lifecycle: lifecycle, roomID: roomID, generation: scopeGeneration)
            value.connections[connectionID] = connection
            value.connectionsByRoomUser[RoomUser(roomID: roomID, userID: connection.userID), default: []].insert(connectionID)
            return true
        }
    }
    func removeRoomInterest(connectionID: UUID, lifecycle: UUID, roomID: RoomID) {
        withLock { value in
            guard var connection = value.connections[connectionID], connection.lifecycle == lifecycle,
                  connection.interest?.roomID == roomID else { return }
            removeInterestIndex(connectionID, connection: connection, in: &value)
            connection.interest = nil
            connection.publication = connection.socketGate?.interest(lifecycle: lifecycle, roomID: nil)
            value.connections[connectionID] = connection
        }
    }
    private func removeUserIndex(_ connectionID: UUID, connection: Connection, in value: inout ConnectionState) {
        value.connectionsByUser[connection.userID]?.remove(connectionID)
        if value.connectionsByUser[connection.userID]?.isEmpty == true {
            value.connectionsByUser.removeValue(forKey: connection.userID)
        }
    }
    private func removeInterestIndex(_ connectionID: UUID, connection: Connection, in value: inout ConnectionState) {
        guard let interest = connection.interest else { return }
        let key = RoomUser(roomID: interest.roomID, userID: connection.userID)
        value.connectionsByRoomUser[key]?.remove(connectionID)
        if value.connectionsByRoomUser[key]?.isEmpty == true { value.connectionsByRoomUser.removeValue(forKey: key) }
    }
    func bindSocket(_ id: UUID, lifecycle: UUID, gate: V2RoomSubscriptionSocketGate) -> Bool {
        state.withLock { value in
            guard var connection = value.connections[id], connection.lifecycle == lifecycle else { return false }
            if let previous = connection.socketGate, previous !== gate { _ = previous.close() }
            connection.socketGate = gate
            let registered = gate.register(lifecycle: lifecycle)
            let interest = connection.interest
            let installed = gate.interest(lifecycle: lifecycle, roomID: interest?.roomID, generation: interest?.scopeGeneration ?? 0)
            connection.publication = registered.and(installed).map { _ in () }
            value.connections[id] = connection; return true
        }
    }
    func shutdown() {
        let gates = state.withLock { value in
            let gates = value.connections.values.compactMap(\.socketGate)
            value = ConnectionState(); value.closed = true; return gates
        }
        for gate in gates { _ = gate.close() }
    }
}
