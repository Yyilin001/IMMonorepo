import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2Core

/// 每个实例只对应一个物理所有者数据库。它只合并宿主已批准的轮次，
/// 因此持有第一个房间的 SQL 围栏时，不会等待第二个房间的准入。
public actor V2HostRoomRecoveryQueryBatcher {
    public struct Configuration: Sendable, Equatable {
        public static let defaultMaximumInFlightBatches = 4
        public let maximumItems: Int
        public let maximumBytes: Int
        public let maximumResponseBytes: Int
        public let maximumPendingItems: Int
        public let maximumInFlightBatches: Int

        public init(maximumItems: Int = 100, maximumBytes: Int = 64 * 1024,
                    maximumResponseBytes: Int = 256 * 1024,
                    maximumPendingItems: Int = 400, maximumInFlightBatches: Int = Self.defaultMaximumInFlightBatches) throws {
            guard (1...100).contains(maximumItems), (256...1_048_576).contains(maximumBytes),
                  (1_024...4_194_304).contains(maximumResponseBytes),
                  maximumPendingItems > maximumItems, maximumPendingItems <= 10_000,
                  (1...64).contains(maximumInFlightBatches) else {
                throw V2ActorContractError.invalidConfiguration("room recovery query batcher")
            }
            self.maximumItems = maximumItems
            self.maximumBytes = maximumBytes
            self.maximumResponseBytes = maximumResponseBytes
            self.maximumPendingItems = maximumPendingItems
            self.maximumInFlightBatches = maximumInFlightBatches
        }
    }

    private enum Origin: Equatable, Sendable { case ordinary, authenticatedRecoveryCohort }
    private enum Kind: Hashable, Sendable { case state, latestVisible, pull, statesCohort }
    private enum Request: Sendable {
        case scalar(V2GrantedRoomReadTurn, Kind)
        case states([V2GrantedRoomReadTurn])
        case pull(V2GrantedRoomLogPull)
        var kind: Kind {
            switch self { case .scalar(_, let kind): kind; case .states: .statesCohort; case .pull: .pull }
        }
        var turns: [V2GrantedRoomReadTurn] {
            switch self { case .scalar(let turn, _): [turn]; case .states(let turns): turns; case .pull: [] }
        }
        var tokens: [V2RoomActivationToken] {
            switch self { case .pull(let item): [item.token]; default: turns.map(\.token) }
        }
        var deadline: ContinuousClock.Instant {
            switch self { case .pull(let item): item.callDeadline; default: turns.map(\.callDeadline).min()! }
        }
        var due: ContinuousClock.Instant {
            switch self { case .states, .pull: .now; case .scalar(let turn, _): min(turn.batchDeadline, turn.callDeadline) }
        }
        var items: Int { if case .states(let turns) = self { return turns.count }; return 1 }
    }
    private enum Value: Sendable {
        case state(V2RoomStateReadResult)
        case latestVisible(V2RoomLatestVisibleResult)
        case states([V2RoomStateReadKey: Result<V2RoomStateReadResult, any Error>])
        case pull(V2RoomLogQueryResult)
    }
    private struct Pending: Sendable {
        let id: UUID
        let request: Request
        let origin: Origin
        let byteCount: Int
        let due: ContinuousClock.Instant
        let enqueued: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        let admissionDeadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Value, any Error>
    }
    private struct Actual: Sendable {
        var items: [UUID: Pending]
        let started: ContinuousClock.Instant
        let observation: UUID
    }
    public struct CollectorSnapshot: Sendable {
        public let pendingItems: Int
        public let retainedItems: Int
        public let retainedBytes: Int
        public let ordinaryRetainedItems: Int
        public let actualBatches: Int
        public let oldestQueuedMilliseconds: Double
        public let oldestActualMilliseconds: Double
        public let batchesStarted: UInt64
        public let itemsSelected: UInt64
        public let itemsSettled: UInt64
    }
    private let execute: @Sendable (V2RoomRecoveryQuery, [V2RoomActivationToken]) async throws -> V2RoomRecoveryResult
    private let executeStates: @Sendable ([V2GrantedRoomReadTurn]) async throws -> [V2RoomStateReadKey: Result<V2RoomStateReadResult, any Error>]
    private let executePulls: @Sendable ([V2GrantedRoomLogPull], Int, @escaping @Sendable (UUID, Result<V2RoomLogQueryResult, any Error>) async -> Void) async throws -> Void
    private let configuration: Configuration
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private let sqlContinuationMetrics: V2SendOperationBatchMetrics?
    private var pending: [Pending] = []
    private var actual: [UUID: Actual] = [:]
    private var cancelledActual: Set<UUID> = []
    private var nextOrigin: Origin = .authenticatedRecoveryCohort
    private var wake: Task<Void, Never>?
    private var wakeGeneration: UUID?
    private var closed = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var retainedItems = 0
    private var retainedBytes = 0
    private var ordinaryRetainedItems = 0
    private var ordinaryRetainedBytes = 0
    private var batchesStarted: UInt64 = 0
    private var itemsSelected: UInt64 = 0
    private var itemsSettled: UInt64 = 0
    internal var scheduledKeyCount: Int { wakeGeneration == nil ? 0 : 1 }
    internal var pendingCount: Int { pending.reduce(0) { $0 + $1.request.items } }
    private nonisolated let observation = Mutex(BatchObservation())

    public func collectorSnapshot() -> CollectorSnapshot {
        let now = ContinuousClock.now
        return .init(pendingItems: pendingCount, retainedItems: retainedItems,
            retainedBytes: retainedBytes, ordinaryRetainedItems: ordinaryRetainedItems,
            actualBatches: actual.count,
            oldestQueuedMilliseconds: pending.map { Self.milliseconds($0.enqueued.duration(to: now)) }.max() ?? 0,
            oldestActualMilliseconds: actual.values.map { Self.milliseconds($0.started.duration(to: now)) }.max() ?? 0,
            batchesStarted: batchesStarted, itemsSelected: itemsSelected, itemsSettled: itemsSettled)
    }

    public nonisolated func pressureSnapshot() -> V2RoomRecoveryBatchPressureSnapshot {
        let now = ContinuousClock.now
        return observation.withLock { state in
            var result = state.completed
            result.oldestQueuedMilliseconds = state.oldestQueuedAt.map { Self.milliseconds($0.duration(to: now)) } ?? 0
            result.oldestActualMilliseconds = state.oldestActualAt.map { Self.milliseconds($0.duration(to: now)) } ?? 0
            for active in state.active.values {
                var item = result.purposes[active.purpose, default: .init()]
                item.inFlight += 1; item.items += active.items
                item.oldestMilliseconds = max(item.oldestMilliseconds, Self.milliseconds(active.started.duration(to: now)))
                result.purposes[active.purpose] = item
            }
            return result
        }
    }

    private func beginObservation(_ purpose: V2RoomRecoveryBatchPurpose, items: Int) -> UUID {
        let id = UUID(), now = ContinuousClock.now
        observation.withLock { state in
            state.active[id] = .init(purpose: purpose, items: items, started: now)
            var item = state.completed.purposes[purpose, default: .init()]
            item.started = Self.increment(item.started)
            state.completed.purposes[purpose] = item
        }
        return id
    }

    private func finishObservation(_ id: UUID) {
        let now = ContinuousClock.now
        observation.withLock { state in
            guard let active = state.active.removeValue(forKey: id) else { return }
            var item = state.completed.purposes[active.purpose, default: .init()]
            let duration = Self.milliseconds(active.started.duration(to: now))
            item.completed = Self.increment(item.completed)
            item.durationMillisecondsSum += duration
            item.durationMillisecondsMax = max(item.durationMillisecondsMax, duration)
            state.completed.purposes[active.purpose] = item
        }
    }

    private func recordBusy(_ purpose: V2RoomRecoveryBatchPurpose) {
        observation.withLock { state in
            var item = state.completed.purposes[purpose, default: .init()]
            item.busyBeforeAcquire = Self.increment(item.busyBeforeAcquire)
            state.completed.purposes[purpose] = item
        }
    }

    private nonisolated static func increment(_ value: UInt64) -> UInt64 { value == .max ? value : value + 1 }
    private nonisolated static func milliseconds(_ value: Duration) -> Double {
        let parts = value.components
        return max(0, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000)
    }
    private struct BatchObservation: Sendable {
        struct Active: Sendable {
            let purpose: V2RoomRecoveryBatchPurpose
            var items: Int
            let started: ContinuousClock.Instant
        }
        var active: [UUID: Active] = [:]
        var completed = V2RoomRecoveryBatchPressureSnapshot()
        var oldestQueuedAt: ContinuousClock.Instant?
        var oldestActualAt: ContinuousClock.Instant?
    }

    // Mirror only bounded scalar accounting into the existing synchronous
    // physical-owner snapshot. No scrape awaits the collector actor, and age is
    // computed at scrape time from the immutable earliest owned start.
    private func synchronizeCollectorObservation() {
        let queued = pendingCount, oldestQueued = pending.map(\.enqueued).min()
        let oldestActual = actual.values.map(\.started).min()
        let retained = retainedItems, bytes = retainedBytes, ordinary = ordinaryRetainedItems
        let batches = actual.count, started = batchesStarted, selected = itemsSelected, settled = itemsSettled
        observation.withLock { state in
            state.completed.pendingItems = queued
            state.completed.retainedItems = retained
            state.completed.retainedBytes = bytes
            state.completed.ordinaryRetainedItems = ordinary
            state.completed.actualBatches = batches
            state.completed.batchesStarted = started
            state.completed.itemsSelected = selected
            state.completed.itemsSettled = settled
            state.oldestQueuedAt = oldestQueued; state.oldestActualAt = oldestActual
        }
    }

    public init(executor: V2ActorRoomQueryExecutor, configuration: Configuration,
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
                sqlContinuationMetrics: V2SendOperationBatchMetrics? = nil) {
        self.execute = { query, tokens in try await executor.recovery(query, tokens: tokens) }
        self.executeStates = { turns in try await executor.recoveryStates(turns) }
        self.executePulls = { items, bytes, settled in
            try await executor.pullSnapshots(items, maximumResponseBytes: bytes, onSettled: settled)
        }
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        self.sqlContinuationMetrics = sqlContinuationMetrics
    }

    // 为准入和容量测试提供确定性的阶段屏障；
    // 生产构造始终提供上方受激活围栏保护的执行器。
    init(configuration: Configuration,
         databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
         sqlContinuationMetrics: V2SendOperationBatchMetrics? = nil,
         executeStates: @escaping @Sendable ([V2GrantedRoomReadTurn]) async throws -> [V2RoomStateReadKey: Result<V2RoomStateReadResult, any Error>],
         executePulls: @escaping @Sendable ([V2GrantedRoomLogPull], Int, @escaping @Sendable (UUID, Result<V2RoomLogQueryResult, any Error>) async -> Void) async throws -> Void = { _, _, _ in
             throw V2HostRoomRecoveryBatchError.corruptResult
         },
         execute: @escaping @Sendable (V2RoomRecoveryQuery, [V2RoomActivationToken]) async throws -> V2RoomRecoveryResult) {
        self.executeStates = executeStates
        self.executePulls = executePulls
        self.execute = execute
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        self.sqlContinuationMetrics = sqlContinuationMetrics
    }

    // Existing single-viewer test fixtures keep their one-execution seam.
    // Production always supplies the true multi-viewer executor above.
    init(configuration: Configuration,
         databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
         sqlContinuationMetrics: V2SendOperationBatchMetrics? = nil,
         execute: @escaping @Sendable (V2RoomRecoveryQuery, [V2RoomActivationToken]) async throws -> V2RoomRecoveryResult) {
        self.init(configuration: configuration, databaseWorkAdmission: databaseWorkAdmission,
            sqlContinuationMetrics: sqlContinuationMetrics, executeStates: { turns in
                guard let viewer = turns.first?.actorUserID, turns.allSatisfy({ $0.actorUserID == viewer }) else {
                    throw V2HostRoomRecoveryBatchError.corruptResult
                }
                let rooms = Array(Set(turns.map { $0.token.roomID }))
                let tokens = rooms.map { room in turns.first(where: { $0.token.roomID == room })!.token }
                let wire = try V2ActorRoomRecoveryBatchQueryWire(roomIDs: rooms, actorUserID: viewer)
                let result = try await execute(.states(wire), tokens)
                guard case .states(let states) = result else {
                    if case .failure(let error) = result { throw error.domainValue() }
                    throw V2HostRoomRecoveryBatchError.corruptResult
                }
                let values = try states.domainValue(expectedRoomIDs: rooms)
                return Dictionary(uniqueKeysWithValues: values.map {
                    (V2RoomStateReadKey(roomID: $0.key, viewerUserID: viewer), .success($0.value))
                })
            }, execute: execute)
    }

    public func state(_ turn: V2GrantedRoomReadTurn) async throws -> V2RoomStateReadResult {
        guard case .state(let value) = try await accept(.scalar(turn, .state), origin: .ordinary) else {
            throw V2HostRoomRecoveryBatchError.corruptResult
        }
        return value
    }
    public func latestVisible(_ turn: V2GrantedRoomReadTurn) async throws -> V2RoomLatestVisibleResult {
        guard case .latestVisible(let value) = try await accept(.scalar(turn, .latestVisible), origin: .ordinary) else {
            throw V2HostRoomRecoveryBatchError.corruptResult
        }
        return value
    }
    /// Dedicated callback of the signed service recovery-batch Host admission.
    /// Ordinary user state requests enter `state`, never infer purpose from kind.
    package func states(_ turns: [V2GrantedRoomReadTurn]) async throws
        -> [V2RoomStateReadKey: Result<V2RoomStateReadResult, any Error>] {
        guard !turns.isEmpty, turns.count <= configuration.maximumItems,
              Set(turns.map { V2RoomStateReadKey(roomID: $0.token.roomID, viewerUserID: $0.actorUserID) }).count == turns.count else {
            throw V2HostRoomRecoveryBatchError.corruptResult
        }
        guard case .states(let value) = try await accept(.states(turns), origin: .authenticatedRecoveryCohort) else {
            throw V2HostRoomRecoveryBatchError.corruptResult
        }
        return value
    }
    package func pull(_ item: V2GrantedRoomLogPull) async throws -> V2RoomLogQueryResult {
        guard item.token.roomID == item.query.roomID else { throw V2HostRoomRecoveryBatchError.corruptResult }
        guard case .pull(let value) = try await accept(.pull(item), origin: .ordinary, id: item.id) else {
            throw V2HostRoomRecoveryBatchError.corruptResult
        }
        return value
    }

    // Encode each immutable input array once. Combining nonempty JSON arrays
    // shares one array allocation charge; item costs are additive.
    private struct ReadInput {
        let token: V2RoomActivationToken
        let query: Query
        enum Query: Encodable {
            case state(UserID), latestVisible(UserID), pull(V2ActorRoomLogPullWire)
        }
    }
    private func inputs(_ request: Request) -> [ReadInput] {
        switch request {
        case .pull(let item): return [.init(token: item.token, query: .pull(item.query))]
        case .states(let turns): return turns.map { .init(token: $0.token, query: .state($0.actorUserID)) }
        case .scalar(let turn, let kind):
            return [.init(token: turn.token, query: kind == .state ? .state(turn.actorUserID) : .latestVisible(turn.actorUserID))]
        }
    }
    private func accept(_ request: Request, origin: Origin, id: UUID = UUID()) async throws -> Value {
        let bytes = V2ActorPayloadBudget.retainedBytes(of: inputs(request)), enqueued = ContinuousClock.now
        let due = request.due
        let deadline = V2RoomSQLDeadline.current.map { min($0, request.deadline) } ?? request.deadline
        let admissionDeadline = databaseWorkAdmission.map { min(deadline, enqueued + $0.maximumQueueWait) } ?? deadline
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(.init(id: id, request: request, origin: origin, byteCount: bytes,
                    due: min(due, admissionDeadline), enqueued: enqueued, deadline: deadline,
                    admissionDeadline: admissionDeadline, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func purpose(_ request: Request) -> V2RoomRecoveryBatchPurpose {
        switch request { case .states: .statesCohort; case .pull: .purePull; case .scalar: .scalar }
    }
    private var maximumRetainedBytes: Int { configuration.maximumPendingItems * configuration.maximumBytes }
    private func enqueue(_ item: Pending) {
        guard !closed, !Task.isCancelled else { item.continuation.resume(throwing: CancellationError()); return }
        guard item.admissionDeadline > .now else {
            item.continuation.resume(throwing: queuedExpiry(item)); return
        }
        guard item.byteCount <= configuration.maximumBytes else {
            item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.oversized); return
        }
        let ordinary = item.origin == .ordinary
        guard item.request.items <= configuration.maximumPendingItems - retainedItems,
              item.byteCount <= maximumRetainedBytes - retainedBytes,
              !ordinary || (item.request.items <= configuration.maximumPendingItems - configuration.maximumItems - ordinaryRetainedItems
                && item.byteCount <= maximumRetainedBytes - configuration.maximumBytes - ordinaryRetainedBytes) else {
            recordBusy(purpose(item.request)); item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.busy); return
        }
        guard !pending.contains(where: { $0.id == item.id }), !actual.values.contains(where: { $0.items[item.id] != nil }) else {
            item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.corruptResult); return
        }
        retainedItems += item.request.items; retainedBytes += item.byteCount
        if ordinary { ordinaryRetainedItems += item.request.items; ordinaryRetainedBytes += item.byteCount }
        pending.append(item)
        pump()
    }
    private func release(_ item: Pending) {
        retainedItems -= item.request.items; retainedBytes -= item.byteCount
        if item.origin == .ordinary { ordinaryRetainedItems -= item.request.items; ordinaryRetainedBytes -= item.byteCount }
    }
    private nonisolated static func add(_ value: UInt64, _ count: Int) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(UInt64(count)); return overflow ? .max : sum
    }
    private func queuedExpiry(_ item: Pending) -> any Error {
        if item.deadline <= .now { return V2HostRoomRecoveryBatchError.deadlineExceeded }
        return V2RoomCallFailure.notAccepted(.overloaded)
    }
    private func prune() {
        let now = ContinuousClock.now
        var live: [Pending] = []
        for item in pending {
            if item.admissionDeadline <= now {
                release(item); item.continuation.resume(throwing: queuedExpiry(item))
            } else { live.append(item) }
        }
        pending = live
    }

    private func compatible(_ a: Request, _ b: Request) -> Bool {
        guard a.kind == b.kind, a.kind != .statesCohort else { return false }
        if case .scalar(let x, .latestVisible) = a, case .scalar(let y, .latestVisible) = b,
           x.actorUserID != y.actorUserID { return false }
        var tokens: [RoomID: V2RoomActivationToken] = [:]
        for token in a.tokens + b.tokens {
            if let old = tokens[token.roomID], old != token { return false }
            tokens[token.roomID] = token
        }
        return true
    }
    private func selectedIndices(origin: Origin) -> [Int] {
        let indices = pending.indices.filter { pending[$0].origin == origin }
        guard let head = indices.first else { return [] }
        var selected = [head], requests = [pending[head].request], count = pending[head].request.items
        var bytes = pending[head].byteCount
        for index in indices.dropFirst() {
            let next = pending[index]
            guard requests.allSatisfy({ compatible($0, next.request) }),
                  count + next.request.items <= configuration.maximumItems,
                  next.byteCount - 32 <= configuration.maximumBytes - bytes else { break }
            selected.append(index); requests.append(next.request); count += next.request.items
            bytes += next.byteCount - 32
        }
        return selected
    }
    private func isDue(_ indices: [Int], now: ContinuousClock.Instant) -> Bool {
        guard let head = indices.first else { return false }
        return pending[head].due <= now
            || indices.reduce(0) { $0 + pending[$1].request.items } >= configuration.maximumItems
    }
    private func pump() {
        defer { synchronizeCollectorObservation() }
        wake?.cancel(); wake = nil; wakeGeneration = nil
        prune()
        guard !closed else { return }
        while actual.count < configuration.maximumInFlightBatches {
            let now = ContinuousClock.now
            let ordinary = selectedIndices(origin: .ordinary), coverage = selectedIndices(origin: .authenticatedRecoveryCohort)
            let ordinaryDue = isDue(ordinary, now: now), coverageDue = isDue(coverage, now: now)
            guard ordinaryDue || coverageDue else { break }
            let origin: Origin = ordinaryDue && coverageDue ? nextOrigin : (coverageDue ? .authenticatedRecoveryCohort : .ordinary)
            let indices = origin == .ordinary ? ordinary : coverage
            let selected = indices.map { pending[$0] }
            for index in indices.reversed() { pending.remove(at: index) }
            start(selected)
            nextOrigin = origin == .ordinary ? .authenticatedRecoveryCohort : .ordinary
        }
        scheduleWake()
    }
    private func scheduleWake() {
        guard !closed, !pending.isEmpty else { return }
        var deadline = pending.map { $0.admissionDeadline }.min()!
        if actual.count < configuration.maximumInFlightBatches {
            for origin: Origin in [.ordinary, .authenticatedRecoveryCohort] {
                if let head = pending.first(where: { $0.origin == origin }) { deadline = min(deadline, head.due) }
            }
        }
        let generation = UUID(); wakeGeneration = generation
        wake = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            await self?.wakeIfCurrent(generation)
        }
    }
    private func wakeIfCurrent(_ generation: UUID) {
        guard wakeGeneration == generation else { return }
        pump()
    }
    private func start(_ items: [Pending]) {
        let id = UUID(), observed = beginObservation(purpose(items[0].request), items: items.reduce(0) { $0 + $1.request.items })
        actual[id] = .init(items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }), started: .now, observation: observed)
        batchesStarted = Self.increment(batchesStarted)
        itemsSelected = Self.add(itemsSelected, items.reduce(0) { $0 + $1.request.items })
        let deadline = items.map { $0.deadline }.min()!
        synchronizeCollectorObservation()
        let metrics = sqlContinuationMetrics
        let admissionDeadline = items.map { $0.admissionDeadline }.min()!
        // A shared batch must not inherit a first caller's cancellation/TaskLocal
        // deadline. The selected original absolute budget is explicitly restored.
        Task.detached {
            await V2RoomSQLContinuationObservation.$metrics.withValue(metrics) {
                await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                    await self.run(items, batchID: id, admissionDeadline: admissionDeadline)
                }
            }
        }
    }
    private func settle(_ id: UUID, batchID: UUID, result: Result<Value, any Error>) {
        defer { synchronizeCollectorObservation() }
        guard let item = actual[batchID]?.items.removeValue(forKey: id) else { return }
        itemsSettled = Self.add(itemsSettled, item.request.items)
        release(item)
        if let observed = actual[batchID]?.observation {
            observation.withLock { state in
                if var active = state.active[observed] {
                    active.items -= item.request.items; state.active[observed] = active
                }
            }
        }
        let cancelled = cancelledActual.remove(id) != nil
        switch result {
        case .failure(let error): item.continuation.resume(throwing: error)
        case .success(let value):
            if cancelled { item.continuation.resume(throwing: CancellationError()) }
            else if item.deadline <= .now { item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.deadlineExceeded) }
            else { item.continuation.resume(returning: value) }
        }
    }
    private func settlePull(_ id: UUID, batchID: UUID, result: Result<V2RoomLogQueryResult, any Error>) {
        guard let item = actual[batchID]?.items[id], case .pull(let grant) = item.request else { return }
        switch result {
        case .success(.page(let page)) where page.roomID != grant.query.roomID:
            settle(id, batchID: batchID, result: .failure(V2HostRoomRecoveryBatchError.corruptResult))
        case .success(.subscription):
            settle(id, batchID: batchID, result: .failure(V2HostRoomRecoveryBatchError.corruptResult))
        default: settle(id, batchID: batchID, result: result.map(Value.pull))
        }
    }
    private func run(_ items: [Pending], batchID: UUID, admissionDeadline: ContinuousClock.Instant) async {
        let readPurpose: V2InteractiveReadAdmissionPurpose = items[0].origin == .authenticatedRecoveryCohort ? .coverageAuthorization : .ordinary
        do {
            try await v2WithAdmittedRoomDatabaseWork(databaseWorkAdmission, workClass: .interactiveRead,
                callerDeadline: admissionDeadline, interactiveReadPurpose: readPurpose) {
                try await self.executeSelected(items, batchID: batchID)
            }
        } catch {
            for item in items { settle(item.id, batchID: batchID, result: .failure(error)) }
        }
        // Missing/duplicate executor outcomes never invent a success. Actual
        // callbacks remain owned through the executor's final return/throw.
        if let remaining = actual[batchID]?.items {
            for item in remaining.values { settle(item.id, batchID: batchID, result: .failure(V2HostRoomRecoveryBatchError.corruptResult)) }
        }
        if let finished = actual.removeValue(forKey: batchID) { finishObservation(finished.observation) }
        pump()
        if closed && actual.isEmpty {
            let waiters = drainWaiters; drainWaiters.removeAll(); for waiter in waiters { waiter.resume() }
        }
    }
    private func executeSelected(_ items: [Pending], batchID: UUID) async throws {
        switch items[0].request.kind {
        case .pull:
            let grants = items.compactMap { if case .pull(let grant) = $0.request { return grant }; return nil }
            guard grants.count == items.count else { throw V2HostRoomRecoveryBatchError.corruptResult }
            try await executePulls(grants, configuration.maximumResponseBytes) { id, result in
                await self.settlePull(id, batchID: batchID, result: result)
            }
        case .state, .statesCohort:
            let turns = items.flatMap { $0.request.turns }
            let values = try await executeStates(turns)
            let keys = Set(turns.map { V2RoomStateReadKey(roomID: $0.token.roomID, viewerUserID: $0.actorUserID) })
            guard Set(values.keys) == keys else { throw V2HostRoomRecoveryBatchError.corruptResult }
            let largestFailure = try Self.maximumEncodedWireFailure()
            let replies = try turns.map { turn -> StateReplyBudgetEnvelope in
                let key = V2RoomStateReadKey(roomID: turn.token.roomID, viewerUserID: turn.actorUserID)
                switch values[key]! {
                case .success(let state):
                    if case .state(let value) = state, value.roomID != key.roomID { throw V2HostRoomRecoveryBatchError.corruptResult }
                    return .init(key: key, outcome: .response(.recovery(.state(.init(state)))))
                case .failure: return .init(key: key, outcome: .failure(largestFailure))
                }
            }
            guard V2ActorPayloadBudget.retainedBytes(of: replies) <= configuration.maximumResponseBytes else { throw V2HostRoomRecoveryBatchError.oversized }
            for item in items {
                if case .states(let original) = item.request {
                    var outcomes = values
                    for turn in original where turn.callDeadline <= .now {
                        let key = V2RoomStateReadKey(roomID: turn.token.roomID, viewerUserID: turn.actorUserID)
                        if case .success? = outcomes[key] { outcomes[key] = .failure(V2HostRoomRecoveryBatchError.deadlineExceeded) }
                    }
                    settle(item.id, batchID: batchID, result: .success(.states(outcomes)))
                } else if let turn = item.request.turns.first {
                    let key = V2RoomStateReadKey(roomID: turn.token.roomID, viewerUserID: turn.actorUserID)
                    settle(item.id, batchID: batchID, result: values[key]!.map(Value.state))
                }
            }
        case .latestVisible:
            let turns = items.flatMap { $0.request.turns }, rooms = Array(Set(items.flatMap { $0.request.turns.map { $0.token.roomID } }))
            let tokens = rooms.map { room in turns.first { $0.token.roomID == room }!.token }
            let query = try V2ActorRoomRecoveryBatchQueryWire(roomIDs: rooms, actorUserID: turns[0].actorUserID)
            let result = try await execute(.latestVisible(query), tokens)
            guard V2ActorPayloadBudget.retainedBytes(of: result) <= configuration.maximumResponseBytes else { throw V2HostRoomRecoveryBatchError.oversized }
            switch result {
            case .latestVisible(let batch):
                let values = try batch.domainValue(expectedRoomIDs: rooms)
                for item in items {
                    guard let value = values[item.request.turns[0].token.roomID] else { throw V2HostRoomRecoveryBatchError.corruptResult }
                    settle(item.id, batchID: batchID, result: .success(.latestVisible(value)))
                }
            case .failure(let error): throw error.domainValue()
            default: throw V2HostRoomRecoveryBatchError.corruptResult
            }
        }
    }
    private func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let item = pending.remove(at: index); release(item)
            item.continuation.resume(throwing: CancellationError()); pump()
        } else if actual.values.contains(where: { $0.items[id] != nil }) { cancelledActual.insert(id) }
    }
    public func shutdown() async {
        closed = true; wake?.cancel(); wake = nil; wakeGeneration = nil
        let queued = pending; pending.removeAll()
        for item in queued { release(item); item.continuation.resume(throwing: CancellationError()) }
        synchronizeCollectorObservation()
        guard !actual.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private struct StateReplyBudgetEnvelope: Encodable {
        let key: V2RoomStateReadKey
        let outcome: Outcome
        enum Outcome: Encodable {
            case response(V2RoomResponse)
            case failure(V2RoomCallFailure)
        }
    }

    /// Complete currently closed wire failure vocabulary. Encoding the actual
    /// envelope avoids an assumed byte bound for arbitrary Error values.
    private static func maximumEncodedWireFailure() throws -> V2RoomCallFailure {
        let reasons: [V2RoomFailureReason] = [.staleActivation, .notReady, .retired, .authorityLost,
            .unavailable, .overloaded, .deadlineExceeded, .cancelled, .notFound,
            .forbidden, .invalidRequest, .unsupportedVersion, .idempotencyConflict]
        let failures: [V2RoomCallFailure] = [.outcomeUnknown] + reasons.flatMap {
            [.notAccepted($0), .rolledBack($0)]
        }
        var largest = V2RoomCallFailure.outcomeUnknown
        var maximum = 0
        for failure in failures {
            let bytes = V2ActorPayloadBudget.retainedBytes(of: StateReplyBudgetEnvelope.Outcome.failure(failure))
            if bytes > maximum { maximum = bytes; largest = failure }
        }
        return largest
    }

}
