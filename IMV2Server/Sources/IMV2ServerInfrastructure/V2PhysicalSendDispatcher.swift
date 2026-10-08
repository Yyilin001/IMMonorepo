import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import Synchronization

/// Synchronous, pool-local fair dispatch. Mutable scheduling state never escapes
/// the mutex; SQL and post-commit work run on owned roots outside the mutex.
/// Physical capacity is returned before room ownership, without an actor hop.
package final class V2PhysicalSendDispatcher: Sendable {
    private struct Pending: Sendable {
        let id: UUID
        let roomID: RoomID
        let prepared: V2PreparedMessageSendBatch
        let items: Int
        let bytes: Int
        let deadline: ContinuousClock.Instant
        let enqueuedAt: ContinuousClock.Instant
        let trace: V2SendPathTrace?
        let continuation: CheckedContinuation<[V2RoomMessagingResult], any Error>
    }

    private let state: Mutex<State>
    private let preparationStore: PostgresV2MessageSendOperationStore
    init(
        store: PostgresV2MessageSendOperationStore,
        configuration: V2SendOperationSchedulingConfiguration,
        maximumRetainedBytes: Int, capacity: Int,
        borrow: @escaping V2ScheduledSendConnection, startBorrow: V2ScheduledSendConnectionStart? = nil,
        execute: @escaping V2ScheduledSendExecution
    ) {
        preparationStore = store
        state = Mutex(
            State(
                store: store, configuration: configuration,
                maximumRetainedBytes: maximumRetainedBytes, capacity: capacity, borrow: borrow,
                startBorrow: startBorrow, execute: execute))
        state.withLock { $0.owner = self }
    }

    private func update<R: Sendable>(_ body: (State) throws -> R) rethrows -> R {
        let (result, effects) = try state.withLock { value in
            let result = try body(value)
            let effects = value.effects
            value.effects.removeAll(keepingCapacity: true)
            return (result, effects)
        }
        for effect in effects { effect() }
        return result
    }

    func execute(_ prepared: V2PreparedMessageSendBatch) async throws -> [V2RoomMessagingResult] {
        try Task.checkCancellation()
        // Immutable command decoding/sorting belongs before physical borrowing.
        let prepared = try preparationStore.preparingScheduledCommandPlan(prepared)
        let id = UUID()
        let trace = V2SendPathTrace.current
        let deadline =
            V2RoomSQLDeadline.current.map { min($0, prepared.originalDeadline) }
            ?? prepared.originalDeadline
        let bytes = try JSONEncoder().encode(prepared.commandPayload).count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try update {
                        try $0.enqueue(
                            prepared, id: id, bytes: bytes, deadline: deadline,
                            trace: trace, continuation: continuation)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.cancelQueued(id: id, roomID: prepared.activationToken.roomID)
        }
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            update { $0.close(continuation) }
        }
    }
    func metrics() -> V2SendOperationOwnerMetricsSnapshot {
        update { $0.sendOperationOwnerMetricsSnapshot() }
    }
    func pressureSnapshot() -> (
        retainedItems: Int, retainedBytes: Int, queuedTurns: Int,
        inFlightBatches: Int, occupiedRooms: Int, closed: Bool, drainingWaiters: Int
    ) {
        update { $0.pressureSnapshot() }
    }
    private func cancelQueued(id: UUID, roomID: RoomID) {
        update { $0.cancelQueued(id: id, roomID: roomID) }
    }
    private func flushIfCurrent(_ generation: UUID) { update { $0.flushIfCurrent(generation) } }
    private func selectConnectedRoom(id: UUID) -> (pending: Pending, diagnose: @Sendable () -> Void)? {
        let selection = update {
            value -> (
                Pending?, ContinuousClock.Instant, ContinuousClock.Instant?,
                [V2OwnerConnectionTimeline],
                Int
            ) in
            let pending = value.selectConnectedRoom(id: id)
            // Match ownerReadyWait's endpoint. Room selection after driver entry
            // is separate work and must not be attributed to resource waiting.
            let selectedAt = max(pending?.enqueuedAt ?? .now,
                value.connectionTimelines[id]?.marker("driver_entered") ?? .now)
            let timelines =
                pending.map {
                    $0.trace != nil && $0.enqueuedAt.duration(to: selectedAt) >= .milliseconds(20)
                } == true
                ? value.recentConnectionTimelines + Array(value.connectionTimelines.values) : []
            return (
                pending, selectedAt, value.diagnosticCoverageStart, timelines,
                value.maximumResourceDemands
            )
        }
        let (selected, selectedAt, coverageStart, timelines, capacity) = selection
        guard let pending = selected else { return nil }
        // Capture the covered history and fixed endpoint now, but inspect and
        // classify it on the acquisition root only after the physical loan returns.
        // Later markers lie beyond selectedAt and cannot extend this wait window.
        return (pending, {
            guard let trace = pending.trace,
                pending.enqueuedAt.duration(to: selectedAt) >= .milliseconds(20) else { return }
            let start = min(selectedAt, max(pending.enqueuedAt, coverageStart ?? pending.enqueuedAt))
            if start > pending.enqueuedAt {
                trace.record(
                    "ready_diagnostic_history_missing_sum", from: pending.enqueuedAt, to: start)
            }
            for (category, duration) in V2OwnerResourceWaitDiagnosis.durations(
                windows: timelines.map { $0.resourceWindow() }, capacity: capacity, from: start,
                to: selectedAt)
            {
                trace.record(category, from: pending.enqueuedAt, to: pending.enqueuedAt + duration)
            }
        })
    }

    private func connectionLoanReturned(id: UUID, unboundSettled: Bool = false) {
        update { $0.connectionLoanReturned(id: id, unboundSettled: unboundSettled) }
    }
    private func connectedRoomSettled(
        id: UUID, pending: Pending,
        result: Result<[V2RoomMessagingResult], any Error>
    ) { update { $0.connectedRoomSettled(id: id, pending: pending, result: result) } }
    private func connectionFailed(id: UUID, error: any Error) {
        update { $0.connectionFailed(id: id, error: error) }
    }
    private func connectionReturned(id: UUID) { update { $0.connectionReturned(id: id) } }

    private final class State {
        weak var owner: V2PhysicalSendDispatcher?
        var effects: [@Sendable () -> Void] = []
        let store: PostgresV2MessageSendOperationStore
        let configuration: V2SendOperationSchedulingConfiguration
        let maximumRetainedBytes: Int
        let maximumResourceDemands: Int
        let scheduledConnection: V2ScheduledSendConnection
        let startScheduledConnection: V2ScheduledSendConnectionStart?
        let scheduledExecute: V2ScheduledSendExecution
        var returnedConnections: Set<UUID> = []
        var connectionTasks: [UUID: V2SendDispatchRoot] = [:]
        var connectionTimelines: [UUID: V2OwnerConnectionTimeline] = [:]
        var recentConnectionTimelines: [V2OwnerConnectionTimeline] = []
        var diagnosticCoverageStart: ContinuousClock.Instant?
        var queues: [RoomID: V2IndexedFIFO<UUID, Pending>] = [:]
        var readyRooms = V2IndexedFIFO<RoomID, RoomID>()
        var occupiedRooms: Set<RoomID> = []
        var deficits: [RoomID: Int] = [:]
        var nextQueuedDeadline: ContinuousClock.Instant?
        var batchStages: [UUID: V2SendOperationOwnerBatchStage] = [:]
        var batchesStarted: UInt64 = 0
        var batchesCompleted: UInt64 = 0
        var commandsSubmitted: UInt64 = 0
        var largestBatch = 0
        var largestRoomCount = 0
        var retainedItems = 0
        var retainedBytes = 0
        var roomUsage: [RoomID: (items: Int, bytes: Int)] = [:]
        var flushTask: V2SendDispatchRoot?
        var flushGeneration: UUID?
        var flushWake: ContinuousClock.Instant?
        var queueExpirations: UInt64 = 0
        var closed = false
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
        init(
            store: PostgresV2MessageSendOperationStore,
            configuration: V2SendOperationSchedulingConfiguration,
            maximumRetainedBytes: Int, capacity: Int,
            borrow: @escaping V2ScheduledSendConnection, startBorrow: V2ScheduledSendConnectionStart?,
            execute: @escaping V2ScheduledSendExecution
        ) {
            self.store = store
            self.configuration = configuration
            self.maximumRetainedBytes = maximumRetainedBytes
            maximumResourceDemands = max(1, min(configuration.maximumPendingRequests, capacity))
            scheduledConnection = borrow
            startScheduledConnection = startBorrow
            scheduledExecute = execute
        }
        func enqueue(
            _ prepared: V2PreparedMessageSendBatch, id: UUID, bytes: Int,
            deadline: ContinuousClock.Instant, trace: V2SendPathTrace?,
            continuation: CheckedContinuation<[V2RoomMessagingResult], any Error>
        ) throws {
            guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
            guard store.ownsPreparedBatch(prepared) else {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            guard !closed else { throw V2RoomCallFailure.notAccepted(.retired) }
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            if let replay = try store.replayedPreparedBatch(prepared) {
                effects.append { continuation.resume(returning: replay) }
                return
            }
            let items = prepared.commandPayload.count
            let roomID = prepared.activationToken.roomID
            guard items > 0, items <= 256 else {
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            }
            let usage = roomUsage[roomID] ?? (0, 0)
            guard items <= configuration.maximumPendingRequests - retainedItems,
                bytes <= maximumRetainedBytes - retainedBytes,
                items <= max(256, configuration.maximumPendingRequests / 4) - usage.items,
                bytes <= max(
                    1,
                    max(
                        maximumRetainedBytes / 4,
                        maximumRetainedBytes / configuration.maximumPendingRequests)) - usage.bytes
            else { throw V2RoomCallFailure.notAccepted(.overloaded) }
            let wasEmpty = queues[roomID, default: .init()].isEmpty
            queues[roomID, default: .init()].append(
                .init(
                    id: id, roomID: roomID, prepared: prepared,
                    items: items, bytes: bytes, deadline: deadline, enqueuedAt: .now,
                    trace: trace, continuation: continuation), key: id)
            nextQueuedDeadline = nextQueuedDeadline.map { min($0, deadline) } ?? deadline
            retainedItems += items
            retainedBytes += bytes
            roomUsage[roomID] = (usage.items + items, usage.bytes + bytes)
            if wasEmpty && !occupiedRooms.contains(roomID) {
                readyRooms.append(roomID, key: roomID)
            }
            schedule()
        }
        private func cancelTimer() {
            if let timer = flushTask { effects.append { timer.cancel() } }
        }
        private func schedule() {
            guard !closed else { return }
            let wake = pruneExpiredQueued(now: .now)
            schedulePhysicalConnections()
            guard let wake else {
                cancelTimer()
                flushTask = nil
                flushGeneration = nil
                flushWake = nil
                return
            }
            if flushTask != nil, let flushWake, flushWake <= wake { return }
            cancelTimer()
            let generation = UUID()
            let dispatcher = owner!
            flushGeneration = generation
            flushWake = wake
            let timer = V2SendDispatchRoot()
            flushTask = timer
            effects.append {
                timer.start {
                    do { try await Task.sleep(until: wake, clock: .continuous) } catch { return }
                    dispatcher.flushIfCurrent(generation)
                }
            }
        }
        func cancelQueued(id: UUID, roomID: RoomID) {
            guard var queue = queues.removeValue(forKey: roomID) else {
                // Submitted work owns its turn and budget until SQL completes.
                return
            }
            guard let removed = queue.remove(id) else {
                queues[roomID] = queue
                return
            }
            queues[roomID] = queue.isEmpty ? nil : queue
            if queue.isEmpty { readyRooms.remove(roomID) }
            release(removed)
            effects.append {
                removed.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled))
            }
            if readyRooms.isEmpty {
                for (id, request) in connectionTasks where batchStages[id] == .acquiringConnection {
                    effects.append { request.cancel() }
                }
            }
            schedule()
        }

        func flushIfCurrent(_ generation: UUID) {
            guard flushGeneration == generation else { return }
            flushTask = nil
            flushGeneration = nil
            flushWake = nil
            // A deadline-only wake must prune queued work even if no batch slot or
            // quota key is available. schedule recomputes the next future deadline.
            schedule()
        }

        func selectConnectedRoom(id: UUID) -> Pending? {
            guard connectionTasks[id] != nil, !closed, !Task.isCancelled else { return nil }
            _ = pruneExpiredQueued(now: .now)
            guard let roomID = nextReadyRoom(), var queue = queues.removeValue(forKey: roomID),
                let pending = queue.removeFirst()
            else { return nil }
            queues[roomID] = queue.isEmpty ? nil : queue
            occupiedRooms.insert(roomID)
            batchStages[id] = .executing
            batchesStarted = Self.add(batchesStarted, 1)
            commandsSubmitted = Self.add(commandsSubmitted, UInt64(pending.items))
            largestBatch = max(largestBatch, pending.items)
            largestRoomCount = max(largestRoomCount, 1)
            return pending
        }

        func connectionLoanReturned(id: UUID, unboundSettled: Bool) {
            // A synchronous failed acquisition has selected no room. Keep its
            // scheduling position until the owner reports that failure, so an
            // inline return cannot recursively submit the same ready request.
            guard unboundSettled || batchStages[id] != .acquiringConnection else { return }
            guard connectionTasks[id] != nil, returnedConnections.insert(id).inserted else {
                return
            }
            connectionTimelines[id]?.mark("scheduler_release_entered")
            schedule()
        }

        func connectedRoomSettled(
            id: UUID, pending: Pending,
            result: Result<[V2RoomMessagingResult], any Error>
        ) {
            batchesCompleted = Self.add(batchesCompleted, 1)
            occupiedRooms.remove(pending.roomID)
            release(pending)
            switch result {
            case .success(let values) where values.count != pending.items:
                effects.append {
                    pending.continuation.resume(throwing: V2RoomCallFailure.outcomeUnknown)
                }
            default: effects.append { pending.continuation.resume(with: result) }
            }
            if queues[pending.roomID]?.isEmpty == false {
                readyRooms.append(pending.roomID, key: pending.roomID)
            }
            // The room becomes ready only after committed memory and notifications settle.
        }

        func connectionFailed(id: UUID, error: any Error) {
            guard !closed, !Task.isCancelled, batchStages[id] == .acquiringConnection else {
                return
            }
            _ = pruneExpiredQueued(now: .now)
            // An expired unbound ticket has no authority to reject a room that
            // arrived with a later deadline. Expired rooms were pruned above;
            // connectionReturned will submit fresh demand for any live rooms.
            if let failure = error as? V2RoomCallFailure,
                failure == .notAccepted(.deadlineExceeded)
            {
                return
            }
            guard let roomID = nextReadyRoom(), var queue = queues.removeValue(forKey: roomID),
                let pending = queue.removeFirst()
            else { return }
            queues[roomID] = queue.isEmpty ? nil : queue
            release(pending)
            let failure: any Error
            if let loan = error as? V2PhysicalDatabaseLoanFailure {
                // No room was dispatched and no BEGIN ran. Preserve the existing
                // retryable admission result instead of exposing a driver error.
                switch loan {
                case .queueFull, .timedOut: failure = V2RoomCallFailure.notAccepted(.overloaded)
                case .cancelled: failure = V2RoomCallFailure.notAccepted(.cancelled)
                case .closed: failure = V2RoomCallFailure.notAccepted(.unavailable)
                case .invalidPolicy: failure = loan
                }
            } else {
                failure = error
            }
            effects.append { pending.continuation.resume(throwing: failure) }
            if !queue.isEmpty { readyRooms.append(roomID, key: roomID) }
        }

        func connectionReturned(id: UUID) {
            if let timeline = connectionTimelines.removeValue(forKey: id), V2SendPathTrace.enabled {
                recentConnectionTimelines.append(timeline)
                if recentConnectionTimelines.count > 512 {
                    let removed = recentConnectionTimelines.removeFirst()
                    if let released = removed.marker("scheduler_release_entered") {
                        diagnosticCoverageStart = max(diagnosticCoverageStart ?? released, released)
                    }
                }
            }
            connectionTasks[id] = nil
            returnedConnections.remove(id)
            batchStages[id] = nil
            finishDrainIfSettled()
            schedule()
        }

        func schedulePhysicalConnections() {
            guard !closed else { return }
            let borrow = scheduledConnection
            let startBorrow = startScheduledConnection
            let execute = scheduledExecute
            let dispatcher = owner!
            let waiting = connectionTasks.keys.filter {
                batchStages[$0] == .acquiringConnection && !returnedConnections.contains($0)
            }.count
            var availableHeads = max(0, readyRooms.count - waiting)
            while connectionTasks.count - returnedConnections.count < maximumResourceDemands,
                availableHeads > 0
            {
                availableHeads -= 1
                let id = UUID()
                // An unbound ticket must not clip a later room to another room's deadline.
                let deadline = readyRooms.values.compactMap { queues[$0]?.first?.deadline }.max()!
                batchStages[id] = .acquiringConnection
                let timeline = V2OwnerConnectionTimeline()
                connectionTimelines[id] = timeline
                let root = V2SendDispatchRoot()
                connectionTasks[id] = root
                effects.append {
                    // Register the actual borrowing Future on the already-running
                    // caller. SQL's owned callback still enters its physical loop.
                    let completed = Mutex<V2ScheduledSendOutcome?>(nil)
                    let connected: @Sendable (V2OwnerConnectionExecutor) async throws -> V2ScheduledSendOutcome? = { executor in
                        let selecting = ContinuousClock.now
                        guard let selected = dispatcher.selectConnectedRoom(id: id)
                        else { return nil }
                        let pending = selected.pending
                        timeline.record(.ownerSelectRoom, from: selecting)
                        if let entered = timeline.marker("driver_entered") {
                            timeline.record(
                                .ownerReadyWait, from: pending.enqueuedAt,
                                to: max(pending.enqueuedAt, entered))
                        }
                        timeline.attach(
                            trace: pending.trace, enqueuedAt: pending.enqueuedAt)
                        let result: Result<[V2RoomMessagingResult], any Error>
                        do {
                            result = .success(
                                try await V2SendPathTrace.$current.withValue(
                                    pending.trace
                                ) {
                                    pending.trace?.record(
                                        "database_schedule_wait",
                                        from: pending.enqueuedAt)
                                    return try await execute(
                                        executor, pending.prepared)
                                })
                        } catch { result = .failure(error) }
                        let executed = ContinuousClock.now
                        timeline.mark("execute_returned", at: executed)
                        if let commit = timeline.marker("commit_future_completed") {
                            timeline.record(
                                .ownerCommitFutureToExecuteReturn, from: commit,
                                to: executed)
                        }
                        // Retain only the post-commit action, never the borrowed executor.
                        let finalize = executor.finalize
                        let outcome = V2ScheduledSendOutcome(
                            result: result,
                            finalize: {
                                await V2SendPathTrace.$current.withValue(
                                    pending.trace
                                ) {
                                    selected.diagnose()
                                    let startedAt = ContinuousClock.now
                                    await finalize()
                                    pending.trace?.record(
                                        "post_commit_finalization", from: startedAt)
                                }
                            },
                            settle: { result in
                                dispatcher.connectedRoomSettled(
                                    id: id, pending: pending, result: result)
                            })
                        completed.withLock { $0 = outcome }
                        timeline.record(.ownerRecordOutcome, from: executed)
                        return outcome
                    }
                    let started: Result<V2StartedRoomConnection<V2ScheduledSendOutcome?>, any Error>?
                    if let startBorrow {
                        timeline.mark("ticket_entry_started")
                        timeline.record(.ownerTicketRegistrationWait, from: timeline.requestedAt)
                        started = Result {
                            try V2ScheduledSendLoanReturn.$current.withValue(
                                V2ScheduledSendLoanReturn { dispatcher.connectionLoanReturned(id: id) }
                            ) {
                                try V2OwnerConnectionTimeline.$current.withValue(timeline) {
                                    try startBorrow(deadline, connected)
                                }
                            }
                        }
                    } else { started = nil }
                    root.start {
                        // Preserve a settled turn even if loan cleanup subsequently throws.
                        var outcome: V2ScheduledSendOutcome?
                        timeline.mark("ticket_task_started")
                        timeline.record(.ownerTicketTaskWait, from: timeline.requestedAt)
                        do {
                            if let started {
                                outcome = try await started.get().finish()
                            } else {
                                outcome = try await V2ScheduledSendLoanReturn.$current.withValue(
                                    V2ScheduledSendLoanReturn {
                                        dispatcher.connectionLoanReturned(id: id)
                                    }
                                ) {
                                    try await V2OwnerConnectionTimeline.$current.withValue(timeline) {
                                        try await borrow(deadline, connected)
                                    }
                                }
                            }
                        } catch {
                            outcome = completed.withLock { $0 }
                            if outcome == nil { dispatcher.connectionFailed(id: id, error: error) }
                        }
                        // The pool has returned the physical loan. Keep this root and
                        // room occupancy through finalization, but release its SQL slot.
                        let returned = timeline.marker("pool_returned") ?? .now
                        if let executed = timeline.marker("execute_returned") {
                            timeline.record(
                                .ownerExecuteReturnToPoolReturn, from: executed, to: returned)
                        }
                        dispatcher.connectionLoanReturned(id: id, unboundSettled: true)
                        if let outcome {
                            timeline.record(
                                .ownerPoolReturnToResourceRelease, from: returned,
                                to: timeline.marker("scheduler_release_entered") ?? .now)
                            // The acquisition root uses the global executor. The physical
                            // callback scopes its own database preference; it cannot leak
                            // into this root after the loan Future settles.
                            await outcome.finalize()
                            await outcome.settle(outcome.result)
                        }
                        dispatcher.connectionReturned(id: id)
                    }
                }
            }
        }

        func pruneExpiredQueued(now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
            if queues.isEmpty {
                nextQueuedDeadline = nil
                return nil
            }
            if let nextQueuedDeadline, nextQueuedDeadline > now { return nextQueuedDeadline }
            var earliest: ContinuousClock.Instant?
            // Expiry traverses once per deadline wake, not on every enqueue.
            for roomID in Array(queues.keys) {
                guard var queue = queues.removeValue(forKey: roomID) else { continue }
                for pending in queue.values {
                    if pending.deadline <= now {
                        queue.remove(pending.id)
                        release(pending)
                        queueExpirations = Self.add(queueExpirations, 1)
                        effects.append {
                            pending.continuation.resume(
                                throwing: V2RoomCallFailure.notAccepted(.deadlineExceeded))
                        }
                    } else {
                        earliest = earliest.map { min($0, pending.deadline) } ?? pending.deadline
                    }
                }
                queues[roomID] = queue.isEmpty ? nil : queue
                if queue.isEmpty { readyRooms.remove(roomID) }
            }
            nextQueuedDeadline = earliest
            return earliest
        }

        func nextReadyRoom() -> RoomID? {
            while let roomID = readyRooms.removeFirst() {
                guard let head = queues[roomID]?.first else {
                    deficits[roomID] = nil
                    continue
                }
                let cost = min(256, head.items + min(256, head.bytes / 4096))
                let credit = min(512, (deficits[roomID] ?? 0) + 32)
                if cost <= credit || readyRooms.isEmpty {
                    deficits[roomID] = max(0, credit - cost)
                    return roomID
                }
                deficits[roomID] = credit
                readyRooms.append(roomID, key: roomID)
            }
            return nil
        }

        func release(_ pending: Pending) {
            retainedItems -= pending.items
            retainedBytes -= pending.bytes
            let usage = roomUsage[pending.roomID]!
            let items = usage.items - pending.items
            let bytes = usage.bytes - pending.bytes
            precondition(items >= 0 && bytes >= 0)
            roomUsage[pending.roomID] = items == 0 ? nil : (items, bytes)
            if items == 0 { deficits[pending.roomID] = nil }
            precondition(retainedItems >= 0 && retainedBytes >= 0)
        }

        func finishDrainIfSettled() {
            guard closed, connectionTasks.isEmpty else { return }
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters { effects.append { waiter.resume() } }
        }
        static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let value = lhs.addingReportingOverflow(rhs)
            return value.overflow ? .max : value.partialValue
        }
        func sendOperationOwnerMetricsSnapshot() -> V2SendOperationOwnerMetricsSnapshot {
            var result = V2SendOperationOwnerMetricsSnapshot()
            result.retainedItems = retainedItems
            result.retainedBytes = retainedBytes
            result.queuedTurns = queues.values.reduce(0) { $0 + $1.count }
            result.inFlightBatches = connectionTasks.count
            result.stages = Dictionary(
                uniqueKeysWithValues: V2SendOperationOwnerBatchStage.allCases.map { stage in
                    (stage, batchStages.values.filter { $0 == stage }.count)
                })
            result.batchesStarted = batchesStarted
            result.batchesCompleted = batchesCompleted
            result.commandsSubmitted = commandsSubmitted
            result.largestBatch = largestBatch
            result.largestRoomCount = largestRoomCount
            return result
        }
        func pressureSnapshot() -> (
            retainedItems: Int, retainedBytes: Int, queuedTurns: Int,
            inFlightBatches: Int, occupiedRooms: Int, closed: Bool, drainingWaiters: Int
        ) {
            (
                retainedItems, retainedBytes, queues.values.reduce(0) { $0 + $1.count },
                connectionTasks.count, occupiedRooms.count, closed, drainWaiters.count
            )
        }
        func close(_ continuation: CheckedContinuation<Void, Never>) {
            closed = true
            cancelTimer()
            flushTask = nil
            flushGeneration = nil
            flushWake = nil
            for queue in queues.values {
                for pending in queue.values {
                    release(pending)
                    effects.append {
                        pending.continuation.resume(
                            throwing: V2RoomCallFailure.notAccepted(.retired))
                    }
                }
            }
            queues.removeAll()
            readyRooms.removeAll()
            for (id, request) in connectionTasks where batchStages[id] == .acquiringConnection {
                effects.append { request.cancel() }
            }
            drainWaiters.append(continuation)
            finishDrainIfSettled()
        }
    }
}

/// Registers ownership before launching outside the dispatcher lock. Cancellation
/// before launch is remembered and applied to the actual root once installed.
private final class V2SendDispatchRoot: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var cancelled = false
    }
    private let state = Mutex(State())
    func start(_ operation: @escaping @Sendable () async -> Void) {
        let task = Task.detached {
            if self.state.withLock({ $0.cancelled }) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            await operation()
        }
        let cancelled = state.withLock { value in
            precondition(value.task == nil)
            value.task = task
            return value.cancelled
        }
        if cancelled { task.cancel() }
    }
    func cancel() {
        let task = state.withLock { value in
            value.cancelled = true
            return value.task
        }
        task?.cancel()
    }
}
