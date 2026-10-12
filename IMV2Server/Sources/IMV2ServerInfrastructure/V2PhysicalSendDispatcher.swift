import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import Synchronization

/// One bounded, fair room buffer per physical message-write pool. Fixed workers
/// hold real connections and execute independent room turns on those connections'
/// EventLoops. No per-turn connection request or settlement task is created.
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
        let continuation: CheckedContinuation<V2ScheduledSendOutcome, any Error>
    }
    private enum Read: Sendable { case turn(Pending), wait, closed }
    private enum WorkerPhase { case acquiring, idle, executing }
    private final class Worker {
        let root = V2SendDispatchRoot()
        var phase: WorkerPhase = .acquiring
        var connectionClosed = false
        var idleSince: ContinuousClock.Instant?
        var readySince: ContinuousClock.Instant?
        var readers: [UUID: CheckedContinuation<Pending?, Never>] = [:]
        var executingTurns = 0
        var busySince: ContinuousClock.Instant?
    }
    private let state: Mutex<State>
    private let preparationStore: PostgresV2MessageSendOperationStore
    init(store: PostgresV2MessageSendOperationStore,
        configuration: V2SendOperationSchedulingConfiguration,
        maximumRetainedBytes: Int, capacity: Int,
        borrow: @escaping V2ScheduledSendConnection,
        execute: @escaping V2ScheduledSendExecution) {
        preparationStore = store
        state = Mutex(State(store: store, configuration: configuration,
            maximumRetainedBytes: maximumRetainedBytes, capacity: capacity,
            borrow: borrow, execute: execute))
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
        let prepared = try preparationStore.preparingScheduledCommandPlan(prepared)
        let id = UUID(), trace = V2SendPathTrace.current
        let deadline = min(V2RoomSQLDeadline.current ?? prepared.originalDeadline, prepared.originalDeadline)
        return try await withTaskCancellationHandler {
            let outcome: V2ScheduledSendOutcome = try await withCheckedThrowingContinuation { continuation in
                do {
                    try update { try $0.enqueue(prepared, id: id, deadline: deadline,
                        trace: trace, continuation: continuation) }
                } catch { continuation.resume(throwing: error) }
            }
            // The existing room execution task owns committed completion. Do not
            // check cancellation here: a committed result still requires memory
            // updates before this room's next turn, even if its client left.
            let started = ContinuousClock.now
            await outcome.finalize()
            trace?.record("post_commit_finalization", from: started)
            update { $0.roomCompleted(id) }
            return try outcome.result.get()
        } onCancel: { self.update { $0.cancelQueued(id: id, roomID: prepared.activationToken.roomID) } }
    }
    func shutdown() async {
        await withCheckedContinuation { continuation in update { $0.close(continuation) } }
    }
    func requestShutdown() { update { $0.close(nil) } }
    func metrics() -> V2SendOperationOwnerMetricsSnapshot { update { $0.snapshot() } }
    func pressureSnapshot() -> (retainedItems: Int, retainedBytes: Int, queuedTurns: Int,
        inFlightBatches: Int, occupiedRooms: Int, closed: Bool, drainingWaiters: Int) {
        update { ($0.retainedItems, $0.retainedBytes, $0.queues.values.reduce(0) { $0 + $1.count },
            $0.active.count, $0.occupiedRooms.count, $0.closed, $0.drainWaiters.count) }
    }
    private func flushIfCurrent(_ generation: UUID) { update { $0.flushIfCurrent(generation) } }
    private func nextTurn(workerID: UUID, laneID: UUID) async -> Pending? {
        // Accumulated work stays on the connection task's running stack. A
        // continuation is needed only when there is no executable room.
        switch update({ $0.take(workerID) }) {
        case .turn(let pending): return pending
        case .closed: return nil
        case .wait:
            return await withCheckedContinuation { continuation in
                update { value in
                    switch value.take(workerID) {
                    case .turn(let pending): value.effects.append { continuation.resume(returning: pending) }
                    case .closed: value.effects.append { continuation.resume(returning: nil) }
                    case .wait: value.workers[workerID]!.readers[laneID] = continuation
                    }
                }
            }
        }
    }
    private func runLane(workerID: UUID, laneID: UUID, executor: V2OwnerConnectionExecutor,
        execute: @escaping V2ScheduledSendExecution) async -> Bool {
        while let pending = await nextTurn(workerID: workerID, laneID: laneID) {
            let timeline = V2OwnerConnectionTimeline()
            timeline.configure(self.preparationStore.scheduledSendMetrics)
            let selectedAt = ContinuousClock.now
            let intervals = self.update { value -> (ContinuousClock.Instant?, ContinuousClock.Instant?) in
                guard let worker = value.workers[workerID] else { return (nil, nil) }
                let result = (worker.idleSince, worker.readySince)
                worker.idleSince = nil; worker.readySince = nil
                return result
            }
            if let idle = intervals.0 { timeline.record(.ownerWorkerIdle, from: idle, to: selectedAt) }
            if let ready = intervals.1 { timeline.record(.ownerWorkerDispatchGap, from: ready, to: selectedAt) }
            timeline.mark("driver_entered", at: selectedAt)
            timeline.record(.ownerReadyWait, from: pending.enqueuedAt, to: selectedAt)
            timeline.attach(trace: pending.trace, enqueuedAt: pending.enqueuedAt)
            let turn = executor.makeTurn()
            let result: Result<[V2RoomMessagingResult], any Error>
            do {
                result = .success(try await V2SendPathTrace.$current.withValue(pending.trace) {
                    try await V2OwnerConnectionTimeline.$current.withValue(timeline) {
                        try await V2RoomSQLDeadline.withDeadline(pending.deadline) {
                            guard executor.isUsable() else { throw V2RoomCallFailure.notAccepted(.unavailable) }
                            return try await execute(turn, pending.prepared)
                        }
                    }
                })
            } catch { result = .failure(error) }
            // ReadyForQuery is a local driver barrier, not another SQL
            // round trip. Only an idle confirmed connection is reusable.
            let reusable = executor.independentlySettledTurns ? executor.isUsable() : await executor.confirmIdle()
            self.update { value in
                value.turnExecuted(workerID: workerID, pending: pending,
                    outcome: .init(result: result, finalize: turn.finalize), timeline: timeline)
            }
            if !reusable {
                self.update { value in
                    guard let worker = value.workers[workerID] else { return }
                    worker.connectionClosed = true
                    let readers = Array(worker.readers.values)
                    worker.readers.removeAll()
                    for reader in readers { value.effects.append { reader.resume(returning: nil) } }
                }
                return false
            }
        }
        return true
    }
    private func runWorker(_ id: UUID) async {
        let (borrow, execute) = update { ($0.borrow, $0.execute) }
        while update({ !$0.closed }) && !Task.isCancelled {
            update { $0.workers[id]?.phase = .acquiring }
            let entered = Mutex(false)
            do {
                // Startup/replace only. Actual pool acquisition still has its
                // bounded timeout; no message supplies a worker lifetime budget.
                try await borrow(.now + .seconds(30)) { executor in
                    entered.withLock { $0 = true }
                    self.update { value in
                        guard let worker = value.workers[id] else { return }
                        worker.phase = .idle
                        worker.connectionClosed = false
                        worker.idleSince = .now
                        if !value.readyRooms.isEmpty { worker.readySince = .now }
                        value.connectionsOpened = State.add(value.connectionsOpened, 1)
                    }
                    let disarm = executor.observeClose {
                        self.update { value in
                            guard let worker = value.workers[id] else { return }
                            worker.connectionClosed = true
                            let readers = Array(worker.readers.values)
                            worker.readers.removeAll()
                            for reader in readers { value.effects.append { reader.resume(returning: nil) } }
                        }
                    }
                    defer { disarm() }
                    let depth = executor.independentlySettledTurns ? self.update { $0.configuration.pipelineDepth } : 1
                    let healthy: Bool
                    if depth == 1 {
                        healthy = await self.runLane(workerID: id, laneID: UUID(), executor: executor, execute: execute)
                    } else {
                        healthy = await withTaskGroup(of: Bool.self) { group in
                            for _ in 0..<depth {
                                group.addTask(executorPreference: executor.taskExecutor) {
                                    await self.runLane(workerID: id, laneID: UUID(), executor: executor, execute: execute)
                                }
                            }
                            var allHealthy = true
                            for await result in group { allHealthy = result && allHealthy }
                            return allHealthy
                        }
                    }
                    if !healthy { throw V2RoomCallFailure.notAccepted(.unavailable) }
                    if !self.update({ $0.closed }) && !executor.isUsable() {
                        throw V2RoomCallFailure.notAccepted(.unavailable)
                    }
                }
            } catch {
                update { value in
                    value.workers[id]?.phase = .acquiring
                    value.connectionsLost = State.add(value.connectionsLost, 1)
                    if !entered.withLock({ $0 }) { value.rejectOneForAcquisition(error) }
                }
                if !update({ $0.closed }) && !Task.isCancelled {
                    // Prevent failed connection establishment from spinning.
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
        }
        update { value in
            for reader in value.workers[id]?.readers.values ?? [:].values { value.effects.append { reader.resume(returning: nil) } }
            value.workers[id] = nil
            value.finishDrainIfSettled()
        }
    }
    private final class State {
        weak var owner: V2PhysicalSendDispatcher?
        var effects: [@Sendable () -> Void] = []
        let store: PostgresV2MessageSendOperationStore
        let configuration: V2SendOperationSchedulingConfiguration
        let maximumRetainedBytes: Int
        let capacity: Int
        let borrow: V2ScheduledSendConnection
        let execute: V2ScheduledSendExecution
        var workers: [UUID: Worker] = [:]
        var workersStarted = false
        var connectionsOpened: UInt64 = 0
        var connectionsLost: UInt64 = 0
        var queues: [RoomID: V2IndexedFIFO<UUID, Pending>] = [:]
        var readyRooms = V2IndexedFIFO<RoomID, RoomID>()
        var occupiedRooms: Set<RoomID> = []
        var active: [UUID: Pending] = [:]
        var finalizing: Set<UUID> = []
        var deficits: [RoomID: Int] = [:]
        var nextQueuedDeadline: ContinuousClock.Instant?
        var batchesStarted: UInt64 = 0
        var batchesCompleted: UInt64 = 0
        var commandsSubmitted: UInt64 = 0
        var largestBatch = 0
        var retainedItems = 0
        var retainedBytes = 0
        var roomUsage: [RoomID: (items: Int, bytes: Int)] = [:]
        var flushTask: V2SendDispatchRoot?
        var flushGeneration: UUID?
        var flushWake: ContinuousClock.Instant?
        var queueExpirations: UInt64 = 0
        var closed = false
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
        init(store: PostgresV2MessageSendOperationStore,
            configuration: V2SendOperationSchedulingConfiguration,
            maximumRetainedBytes: Int, capacity: Int,
            borrow: @escaping V2ScheduledSendConnection, execute: @escaping V2ScheduledSendExecution) {
            self.store = store; self.configuration = configuration
            self.maximumRetainedBytes = maximumRetainedBytes
            self.capacity = max(1, min(configuration.maximumPendingRequests, capacity))
            self.borrow = borrow; self.execute = execute
        }
        func enqueue(_ prepared: V2PreparedMessageSendBatch, id: UUID,
            deadline: ContinuousClock.Instant, trace: V2SendPathTrace?,
            continuation: CheckedContinuation<V2ScheduledSendOutcome, any Error>) throws {
            guard !Task.isCancelled else { throw V2RoomCallFailure.notAccepted(.cancelled) }
            guard store.ownsPreparedBatch(prepared) else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            guard !closed else { throw V2RoomCallFailure.notAccepted(.retired) }
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            if let replay = try store.replayedPreparedBatch(prepared) {
                effects.append { continuation.resume(returning: .init(result: .success(replay), finalize: {})) }
                return
            }
            let items = prepared.commandPayload.count, bytes = prepared.retainedByteBudget
            let roomID = prepared.activationToken.roomID, usage = roomUsage[roomID] ?? (0, 0)
            guard items > 0, items <= 256 else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
            guard items <= configuration.maximumPendingRequests - retainedItems,
                bytes <= maximumRetainedBytes - retainedBytes,
                items <= max(256, configuration.maximumPendingRequests / 4) - usage.items,
                bytes <= max(1, max(maximumRetainedBytes / 4,
                    maximumRetainedBytes / configuration.maximumPendingRequests)) - usage.bytes
            else { throw V2RoomCallFailure.notAccepted(.overloaded) }
            let empty = queues[roomID, default: .init()].isEmpty
            queues[roomID, default: .init()].append(.init(id: id, roomID: roomID, prepared: prepared,
                items: items, bytes: bytes, deadline: deadline, enqueuedAt: .now,
                trace: trace, continuation: continuation), key: id)
            retainedItems += items; retainedBytes += bytes
            roomUsage[roomID] = (usage.items + items, usage.bytes + bytes)
            nextQueuedDeadline = min(nextQueuedDeadline ?? deadline, deadline)
            if empty && !occupiedRooms.contains(roomID) { readyRooms.append(roomID, key: roomID) }
            if !workersStarted {
                workersStarted = true
                for _ in 0..<capacity {
                    let id = UUID(), worker = Worker(), dispatcher = owner!
                    workers[id] = worker
                    let root = worker.root
                    effects.append { root.start { await dispatcher.runWorker(id) } }
                }
            }
            schedule()
        }
        func take(_ id: UUID) -> Read {
            guard !closed, let worker = workers[id], !worker.connectionClosed else { return .closed }
            _ = pruneExpiredQueued(now: .now)
            guard let room = nextReadyRoom(), var queue = queues.removeValue(forKey: room),
                let pending = queue.removeFirst() else { return .wait }
            worker.phase = .executing
            worker.executingTurns += 1
            if worker.busySince == nil { worker.busySince = .now }
            queues[room] = queue.isEmpty ? nil : queue
            occupiedRooms.insert(room)
            active[pending.id] = pending
            batchesStarted = Self.add(batchesStarted, 1)
            commandsSubmitted = Self.add(commandsSubmitted, UInt64(pending.items))
            largestBatch = max(largestBatch, pending.items)
            return .turn(pending)
        }
        private func wakeReaders() {
            let now = ContinuousClock.now
            if !readyRooms.isEmpty {
                for worker in workers.values where worker.phase == .idle && worker.readySince == nil {
                    worker.readySince = now
                }
            }
            // Fill idle connections before adding a second protocol cycle to
            // an executing connection. Otherwise dictionary iteration can pin
            // a room behind another SQL while a physical connection sits idle.
            dispatch: while !readyRooms.isEmpty {
                var selected: (id: UUID, worker: Worker, lane: UUID, reader: CheckedContinuation<Pending?, Never>)?
                for (id, worker) in workers {
                    guard let (lane, reader) = worker.readers.first else { continue }
                    if selected == nil || worker.executingTurns < selected!.worker.executingTurns {
                        selected = (id, worker, lane, reader)
                    }
                }
                guard let selected else { break }
                let reader = selected.reader
                switch take(selected.id) {
                case .turn(let pending):
                    selected.worker.readers[selected.lane] = nil
                    effects.append { reader.resume(returning: pending) }
                case .closed:
                    selected.worker.readers[selected.lane] = nil
                    effects.append { reader.resume(returning: nil) }
                case .wait: break dispatch
                }
            }
            if readyRooms.isEmpty {
                for worker in workers.values where worker.phase == .idle { worker.readySince = nil }
            }
        }
        func turnExecuted(workerID: UUID, pending: Pending, outcome: V2ScheduledSendOutcome, timeline: V2OwnerConnectionTimeline) {
            finalizing.insert(pending.id)
            if let worker = workers[workerID] {
                worker.executingTurns -= 1
                if worker.executingTurns == 0 {
                    let ended = ContinuousClock.now
                    if let start = worker.busySince { effects.append { timeline.record(.ownerWorkerBusy, from: start, to: ended) } }
                    worker.busySince = nil
                    worker.phase = .idle; worker.idleSince = ended
                    worker.readySince = readyRooms.isEmpty ? nil : ended
                }
            }
            let delivered: V2ScheduledSendOutcome
            if case .success(let values) = outcome.result, values.count != pending.items {
                delivered = .init(result: .failure(V2RoomCallFailure.outcomeUnknown), finalize: outcome.finalize)
            } else { delivered = outcome }
            effects.append { pending.continuation.resume(returning: delivered) }
        }
        func roomCompleted(_ id: UUID) {
            guard let pending = active.removeValue(forKey: id) else { return }
            finalizing.remove(id)
            occupiedRooms.remove(pending.roomID)
            release(pending)
            batchesCompleted = Self.add(batchesCompleted, 1)
            if !closed && queues[pending.roomID]?.isEmpty == false {
                readyRooms.append(pending.roomID, key: pending.roomID)
            }
            schedule()
            finishDrainIfSettled()
        }
        func rejectOneForAcquisition(_ error: any Error) {
            guard !closed else { return }
            _ = pruneExpiredQueued(now: .now)
            guard let room = nextReadyRoom(), var queue = queues.removeValue(forKey: room),
                let pending = queue.removeFirst() else { return }
            queues[room] = queue.isEmpty ? nil : queue
            release(pending)
            let failure: any Error
            if let loan = error as? V2PhysicalDatabaseLoanFailure {
                switch loan {
                case .queueFull, .timedOut: failure = V2RoomCallFailure.notAccepted(.overloaded)
                case .cancelled: failure = V2RoomCallFailure.notAccepted(.cancelled)
                case .closed: failure = V2RoomCallFailure.notAccepted(.unavailable)
                case .invalidPolicy: failure = loan
                }
            } else { failure = error }
            effects.append { pending.continuation.resume(throwing: failure) }
            if !queue.isEmpty { readyRooms.append(room, key: room) }
            schedule()
        }
        func cancelQueued(id: UUID, roomID: RoomID) {
            guard var queue = queues.removeValue(forKey: roomID) else { return }
            guard let pending = queue.remove(id) else { queues[roomID] = queue; return }
            queues[roomID] = queue.isEmpty ? nil : queue
            if queue.isEmpty { readyRooms.remove(roomID) }
            release(pending)
            effects.append { pending.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled)) }
            schedule()
        }
        private func cancelTimer() { if let timer = flushTask { effects.append { timer.cancel() } } }
        private func schedule() {
            guard !closed else { return }
            _ = pruneExpiredQueued(now: .now)
            wakeReaders()
            // A parked worker may have taken all queued turns synchronously.
            // Only remaining queued work needs a deadline task.
            guard let wake = pruneExpiredQueued(now: .now) else {
                cancelTimer(); flushTask = nil; flushGeneration = nil; flushWake = nil
                return
            }
            if flushTask != nil, let flushWake, flushWake <= wake { return }
            cancelTimer()
            let generation = UUID(), dispatcher = owner!, timer = V2SendDispatchRoot()
            flushGeneration = generation; flushWake = wake; flushTask = timer
            effects.append {
                timer.start {
                    do { try await Task.sleep(until: wake, clock: .continuous) } catch { return }
                    dispatcher.flushIfCurrent(generation)
                }
            }
        }
        func flushIfCurrent(_ generation: UUID) {
            guard flushGeneration == generation else { return }
            flushTask = nil; flushGeneration = nil; flushWake = nil
            schedule()
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
                queue.removeAll(where: { pending in
                    if pending.deadline > now {
                        earliest = earliest.map { min($0, pending.deadline) } ?? pending.deadline
                        return false
                    }
                    return true
                }, onRemove: { pending in
                    release(pending)
                    queueExpirations = Self.add(queueExpirations, 1)
                    effects.append {
                        pending.continuation.resume(
                            throwing: V2RoomCallFailure.notAccepted(.deadlineExceeded))
                    }
                })
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
            guard closed, workers.isEmpty, active.isEmpty else { return }
            let waiters = drainWaiters; drainWaiters.removeAll()
            for waiter in waiters { effects.append { waiter.resume() } }
        }
        static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let value = lhs.addingReportingOverflow(rhs)
            return value.overflow ? .max : value.partialValue
        }
        func snapshot() -> V2SendOperationOwnerMetricsSnapshot {
            var result = V2SendOperationOwnerMetricsSnapshot()
            result.retainedItems = retainedItems; result.retainedBytes = retainedBytes
            result.queuedTurns = queues.values.reduce(0) { $0 + $1.count }
            result.inFlightBatches = active.count
            result.stages = [.executing: active.count - finalizing.count,
                .finalizing: finalizing.count]
            result.batchesStarted = batchesStarted; result.batchesCompleted = batchesCompleted
            result.commandsSubmitted = commandsSubmitted; result.largestBatch = largestBatch
            result.largestRoomCount = batchesStarted == 0 ? 0 : 1
            result.connectionWorkers = workers.count
            result.acquiringConnectionWorkers = workers.values.filter { $0.phase == .acquiring }.count
            result.idleConnectionWorkers = workers.values.filter { $0.phase == .idle }.count
            result.executingConnectionWorkers = workers.values.filter { $0.phase == .executing }.count
            result.workerConnectionsOpened = connectionsOpened
            result.workerConnectionFailures = connectionsLost
            return result
        }
        func close(_ continuation: CheckedContinuation<Void, Never>?) {
            closed = true
            cancelTimer(); flushTask = nil; flushGeneration = nil; flushWake = nil
            for queue in queues.values {
                queue.forEach { borrowed in
                    let pending = copy borrowed
                    release(pending)
                    effects.append { pending.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.retired)) }
                }
            }
            queues.removeAll(); readyRooms.removeAll()
            for worker in workers.values {
                let readers = Array(worker.readers.values)
                worker.readers.removeAll()
                for reader in readers { effects.append { reader.resume(returning: nil) } }
                // Connected work drains. Cancelling only an acquisition cannot
                // interrupt a transaction whose durable outcome is being settled.
                if worker.phase == .acquiring { let root = worker.root; effects.append { root.cancel() } }
            }
            if let continuation { drainWaiters.append(continuation) }
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
