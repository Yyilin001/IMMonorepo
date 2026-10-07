import Foundation
import FluentKit
import SQLKit
import IMV2Core
import IMV2ServerContracts

/// Immutable deployment ownership, including routes discovered after startup.
/// No time-based expiry. A precise invalidation may confirm the same route;
/// observing online ownership changes requires a new deployment snapshot.
public actor V2DeploymentRoomShardRouter: V2RoomShardRouting {
    public enum Failure: Error, Equatable, Sendable { case capacityExceeded, closed, invalidated, deploymentChanged }
    public typealias ColdLoader = @Sendable ([RoomID]) async throws -> [RoomID: V2RoomShardRoute]
    private struct Entry { let route: V2RoomShardRoute; let generation: UUID }
    private struct Pending { let id: UUID; let expectedGeneration: UUID?; var deadline: ContinuousClock.Instant?; var waiters: Set<UUID>; var selected = false }
    private struct Waiter {
        var missing: Set<RoomID>
        var result: [RoomID: V2RoomShardRoute]
        let continuation: CheckedContinuation<[RoomID: V2RoomShardRoute], any Error>
    }
    private var entries: [RoomID: Entry]
    private var invalidated: Set<RoomID> = []
    private var changed: Set<RoomID> = []
    private var pending: [RoomID: Pending] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var collector: Task<Void, Never>?
    private var closed = false
    private var shutdownTask: Task<Void, Never>?
    private static let maximumSnapshotBytes = 128 * 1_024 * 1_024
    private var snapshotBytes: Int
    private let maximumEntries: Int
    private let loader: ColdLoader

    /// The loader seam has the same partial-row contract as PostgreSQL: missing
    /// rooms are absent, so one unknown room cannot poison other fetched facts.
    public init(snapshot: [RoomID: V2RoomShardRoute], maximumEntries: Int = 250_000,
                loadCold: @escaping ColdLoader) throws {
        guard (1...250_000).contains(maximumEntries), snapshot.count <= maximumEntries,
              snapshot.allSatisfy({ $0.key.uuidValue != nil && $0.value.shardID.utf8.count <= 128 }) else { throw Failure.capacityExceeded }
        let bytes = snapshot.reduce(0) { $0 + Self.entryBytes(room: $1.key, route: $1.value) }
        guard bytes <= Self.maximumSnapshotBytes else { throw Failure.capacityExceeded }
        snapshotBytes = bytes
        self.maximumEntries = maximumEntries; loader = loadCold
        entries = snapshot.mapValues { .init(route: $0, generation: UUID()) }
    }
    private static func entryBytes(room: RoomID, route: V2RoomShardRoute) -> Int {
        room.rawValue.utf8.count + route.shardID.utf8.count + 256
    }
    public static func load(database: any Database, maximumEntries: Int = 250_000) async throws -> V2DeploymentRoomShardRouter {
        guard (1...250_000).contains(maximumEntries), let sql = database as? any SQLDatabase else { throw V2RoomShardRouteError.corruptPersistenceState }
        let rows = try await V2DatabaseLoanObservationContext.$source.withValue(.routeLookup) {
            try await sql.raw("""
                SELECT room_id, room_shard_id, route_epoch FROM im_v2.room_owner_routes
                ORDER BY room_id LIMIT \(bind: maximumEntries + 1)
                """).all(decoding: DeploymentRouteRow.self)
        }
        guard rows.count <= maximumEntries else { throw Failure.capacityExceeded }
        let snapshot = try decode(rows)
        return try .init(snapshot: snapshot, maximumEntries: maximumEntries) { rooms in
            let ids = try rooms.map { room -> UUID in
                guard let id = room.uuidValue else { throw V2RoomShardRouteError.corruptPersistenceState }; return id
            }
            let json = String(decoding: try JSONEncoder().encode(ids.map(\.uuidString)), as: UTF8.self)
            // Shared work owns its own finite deadline. Waiter cancellation is
            // never forwarded to this task or the underlying physical future.
            let workDeadline = min(V2RoomSQLDeadline.current ?? (.now + .seconds(2)), .now + .seconds(2))
            return try await V2RoomSQLDeadline.$current.withValue(workDeadline) {
                try await V2DatabaseLoanObservationContext.$source.withValue(.routeLookup) {
                    let rows = try await sql.raw("""
                        SELECT route.room_id, route.room_shard_id, route.route_epoch
                        FROM im_v2.room_owner_routes route
                        JOIN jsonb_array_elements_text(\(bind: json)::jsonb) requested(room_id)
                          ON route.room_id = requested.room_id::uuid
                        """).all(decoding: DeploymentRouteRow.self)
                    return try decode(rows)
                }
            }
        }
    }
    private static func decode(_ rows: [DeploymentRouteRow]) throws -> [RoomID: V2RoomShardRoute] {
        var result: [RoomID: V2RoomShardRoute] = [:]
        for row in rows {
            let key = RoomID(uuid: row.roomID)
            guard result[key] == nil, row.roomShardID.utf8.count <= 128 else { throw V2RoomShardRouteError.corruptPersistenceState }
            result[key] = try .init(shardID: row.roomShardID, epoch: row.routeEpoch)
        }
        return result
    }
    public struct Pressure: Sendable {
        public let cachedEntries: Int
        public let retainedColdRooms: Int
        public let waitingCallers: Int
        public let actualQueries: Int
    }
    public func pressureSnapshot() -> Pressure {
        .init(cachedEntries: entries.count, retainedColdRooms: pending.count,
              waitingCallers: waiters.count, actualQueries: workers.count)
    }
    public func route(for roomID: RoomID) async throws -> V2RoomShardRoute {
        guard let route = try await routes(for: [roomID])[roomID] else { throw V2RoomShardRouteError.roomNotFound }
        return route
    }
    public func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        let unique = Set(roomIDs)
        guard unique.count <= maximumEntries, unique.allSatisfy({ $0.uuidValue != nil }) else { throw V2RoomShardRouteError.corruptPersistenceState }
        guard changed.isDisjoint(with: unique) else { throw Failure.deploymentChanged }
        var result: [RoomID: V2RoomShardRoute] = [:], missing: Set<RoomID> = []
        for room in unique {
            if let value = entries[room], !invalidated.contains(room) { result[room] = value.route }
            else { missing.insert(room) }
        }
        if missing.isEmpty { return result }
        guard waiters.count < 256, pending.count + missing.filter({ pending[$0] == nil }).count <= 256 else { throw Failure.capacityExceeded }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = .init(missing: missing, result: result, continuation: continuation)
                for room in missing {
                    if var current = pending[room] {
                        current.waiters.insert(id)
                        if !current.selected, let deadline = V2RoomSQLDeadline.current { current.deadline = min(current.deadline ?? deadline, deadline) }
                        pending[room] = current
                    } else { pending[room] = .init(id: UUID(), expectedGeneration: entries[room]?.generation,
                        deadline: V2RoomSQLDeadline.current, waiters: [id]) }
                }
                schedule()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    /// Matching the whole old route avoids invalidating a successor. In-flight
    /// reads carrying the earlier generation cannot reinstall after this call.
    @discardableResult public func invalidate(for roomID: RoomID, matching route: V2RoomShardRoute) -> Bool {
        guard let current = entries[roomID], current.route == route, !changed.contains(roomID) else { return false }
        entries[roomID] = .init(route: current.route, generation: UUID()); invalidated.insert(roomID); return true
    }
    private func cancel(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        detach(id, rooms: waiter.missing)
    }
    private func detach(_ id: UUID, rooms: Set<RoomID>) {
        for room in rooms {
            guard var current = pending[room] else { continue }
            current.waiters.remove(id)
            if current.waiters.isEmpty && !current.selected { pending.removeValue(forKey: room) }
            else { pending[room] = current }
        }
    }
    private func schedule() {
        guard !closed, collector == nil, workers.count < 4, pending.values.contains(where: { !$0.selected }) else { return }
        collector = Task {
            try? await Task.sleep(for: .milliseconds(2))
            self.collect()
        }
    }
    private func collect() {
        collector = nil
        guard !closed else { return }
        while workers.count < 4 {
            let rooms = Array(pending.filter { !$0.value.selected }.keys.sorted().prefix(128))
            guard !rooms.isEmpty else { return }
            var selected: [RoomID: UUID] = [:]
            for room in rooms { pending[room]?.selected = true; selected[room] = pending[room]?.id }
            let id = UUID()
            let deadline = rooms.compactMap { pending[$0]?.deadline }.min()
            workers[id] = Task { await V2RoomSQLDeadline.$current.withValue(deadline) { await self.fetch(id, selected: selected) } }
        }
    }
    private func fetch(_ id: UUID, selected: [RoomID: UUID]) async {
        let fetched: Result<[RoomID: V2RoomShardRoute], any Error>
        do {
            let rows = try await loader(Array(selected.keys).sorted())
            guard Set(rows.keys).isSubset(of: Set(selected.keys)) else { throw V2RoomShardRouteError.corruptPersistenceState }
            fetched = .success(rows)
        } catch { fetched = .failure(error) }
        for (room, generation) in selected {
            guard let operation = pending[room], operation.id == generation else { continue }
            pending.removeValue(forKey: room)
            let result: Result<V2RoomShardRoute, any Error>
            do {
                guard !closed else { throw Failure.closed }
                let rows = try fetched.get()
                guard let route = rows[room] else { throw V2RoomShardRouteError.roomNotFound }
                guard route.shardID.utf8.count <= 128 else { throw V2RoomShardRouteError.corruptPersistenceState }
                guard entries[room]?.generation == operation.expectedGeneration else { throw Failure.invalidated }
                if let previous = entries[room], previous.route != route {
                    changed.insert(room); throw Failure.deploymentChanged
                }
                guard entries[room] != nil || entries.count < maximumEntries else { throw Failure.capacityExceeded }
                if entries[room] == nil {
                    let bytes = Self.entryBytes(room: room, route: route)
                    guard bytes <= Self.maximumSnapshotBytes - snapshotBytes else { throw Failure.capacityExceeded }
                    snapshotBytes += bytes
                }
                entries[room] = .init(route: route, generation: UUID()); invalidated.remove(room)
                result = .success(route)
            } catch { result = .failure(error) }
            for waiterID in operation.waiters {
                guard var waiter = waiters[waiterID] else { continue }
                switch result {
                case .success(let route):
                    waiter.missing.remove(room); waiter.result[room] = route
                    if waiter.missing.isEmpty { waiters.removeValue(forKey: waiterID); waiter.continuation.resume(returning: waiter.result) }
                    else { waiters[waiterID] = waiter }
                case .failure(let error):
                    waiters.removeValue(forKey: waiterID); detach(waiterID, rooms: waiter.missing)
                    waiter.continuation.resume(throwing: error)
                }
            }
        }
        workers.removeValue(forKey: id); schedule()
    }
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true
        let callers = waiters; waiters.removeAll()
        for waiter in callers.values { waiter.continuation.resume(throwing: Failure.closed) }
        let task = Task {
            await self.collector?.value
            for worker in self.workers.values { await worker.value }
            self.pending.removeAll()
        }
        shutdownTask = task; await task.value
    }
}
private struct DeploymentRouteRow: Decodable {
    let roomID: UUID; let roomShardID: String; let routeEpoch: Int64
    enum CodingKeys: String, CodingKey { case roomID = "room_id", roomShardID = "room_shard_id", routeEpoch = "route_epoch" }
}
