import Foundation

public struct V2BackgroundSyncBudget: Sendable {
    public let maximumPages: Int
    public let workDuration: Duration
    public init(maximumPages: Int = 4, workDuration: Duration = .seconds(25)) {
        precondition(maximumPages > 0 && maximumPages <= 10_000 && workDuration > .zero)
        self.maximumPages = maximumPages
        self.workDuration = workDuration
    }
}

public enum V2BackgroundSyncError: Error, Equatable, Sendable { case deadlineReached }

/// Owns a dedicated background connection, never the foreground socket.
/// Concurrent pushes share one bounded operation. A foreground transition or
/// logout stops/drains only this owner; the caller closes local stores later.
public actor V2BackgroundSyncRunner {
    private let connection: any V2RealtimeSessionConnecting
    private let syncEngine: V2SyncEngine
    private let roomSync: V2GroupEventSyncEngine?
    private let budget: V2BackgroundSyncBudget
    private var flight: (id: UUID, task: V2SharedOperation<V2IncrementalSyncResult>)?
    private var stopping: (id: UUID, task: Task<Void, Never>)?

    public init(connection: any V2RealtimeSessionConnecting, syncEngine: V2SyncEngine, roomSync: V2GroupEventSyncEngine? = nil, budget: V2BackgroundSyncBudget = .init()) {
        self.connection = connection
        self.syncEngine = syncEngine
        self.roomSync = roomSync
        self.budget = budget
    }

    deinit { flight?.task.cancel() }

    public func run(until deadline: ContinuousClock.Instant? = nil) async throws -> V2IncrementalSyncResult {
        try Task.checkCancellation()
        if let deadline, deadline <= .now { throw V2BackgroundSyncError.deadlineReached }
        guard stopping == nil else { throw CancellationError() }
        let operation: (id: UUID, task: V2SharedOperation<V2IncrementalSyncResult>)
        let joinedFlight: Bool
        if let flight { operation = flight; joinedFlight = true }
        else {
            joinedFlight = false
            let id = UUID()
            operation = (id, V2SharedOperation { [weak self, connection, syncEngine, roomSync, budget] in
                do {
                    let result = try await Self.catchUp(connection: connection, engine: syncEngine, roomSync: roomSync, budget: budget, callerDeadline: deadline)
                    await self?.finishFlight(id)
                    return result
                } catch {
                    await self?.finishFlight(id)
                    throw error
                }
            })
            flight = operation
        }
        // Each caller may have spent a different amount of its budget in
        // restoration. Leaving a shared flight does not cancel other pushes.
        // The initiating caller waits for its owned connection to drain at
        // the shared deadline. Only a joining caller can leave sooner.
        if joinedFlight, let deadline {
            return try await withThrowingTaskGroup(of: V2IncrementalSyncResult.self) { group in
                group.addTask { try await operation.task.value }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw V2BackgroundSyncError.deadlineReached
                }
                defer { group.cancelAll() }
                let result = try await group.next()!
                return result
            }
        }
        return try await operation.task.value
    }

    private func finishFlight(_ id: UUID) {
        if flight?.id == id { flight = nil }
    }

    public func stop() async {
        let drainingID = flight?.id
        let operation: (id: UUID, task: Task<Void, Never>)
        if let stopping { operation = stopping }
        else {
            let current = flight
            operation = (UUID(), Task { [connection] in
                current?.task.cancel()
                await connection.disconnect()
                _ = await current?.task.result
            })
            stopping = operation
        }
        await operation.task.value
        if stopping?.id == operation.id {
            stopping = nil
            if flight?.id == drainingID { flight = nil }
        }
    }

    private static func catchUp(connection: any V2RealtimeSessionConnecting, engine: V2SyncEngine, roomSync: V2GroupEventSyncEngine?, budget: V2BackgroundSyncBudget, callerDeadline: ContinuousClock.Instant?) async throws -> V2IncrementalSyncResult {
        let ownDeadline = ContinuousClock.now.advanced(by: budget.workDuration)
        let deadline = min(ownDeadline, callerDeadline ?? ownDeadline)
        return try await withThrowingTaskGroup(of: V2IncrementalSyncResult.self) { group in
            group.addTask {
                _ = try await connection.connect()
                try Task.checkCancellation()
                // Reserve room-log work so a hot personal stream cannot
                // consume every push budget. Both feeds share the deadline.
                let personalBudget = roomSync == nil ? budget.maximumPages : max(1, budget.maximumPages / 2)
                let personal = try await engine.synchronizeIncrementally(maximumPages: personalBudget)
                guard personal.stopReason != .resetPending, let roomSync,
                      budget.maximumPages > personal.processedPageCount else { return personal }
                try Task.checkCancellation()
                let rooms = try await roomSync.synchronizeBackgroundKnownRooms(maximumPages: budget.maximumPages - personal.processedPageCount)
                return .init(processedPageCount: personal.processedPageCount + rooms.processedPageCount,
                             didCommitNewRecords: personal.didCommitNewRecords || rooms.appliedEventCount > 0,
                             stopReason: personal.stopReason == .pageLimit || rooms.mayHaveRemainingWork ? .pageLimit : .caughtUp)
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                throw V2BackgroundSyncError.deadlineReached
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                await connection.disconnect()
                return result
            } catch {
                group.cancelAll()
                // Cancels the owned coordinator handshake and NWConnection
                // so the task group can drain an in-flight send/receive.
                await connection.disconnect()
                throw error
            }
        }
    }
}
