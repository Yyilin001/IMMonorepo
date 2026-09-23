import Foundation
import IMV2ActorContracts
import IMV2Core

/// One already admitted room turn. This value carries scheduling context, not
/// authority beyond the exact activation token granted by the host.
struct V2GrantedRoomReceiptTurn: Sendable {
    let command: V2RoomReceiptCommand
    let token: V2RoomActivationToken
    let batchDeadline: ContinuousClock.Instant
    let callDeadline: ContinuousClock.Instant
    let ingressAt: Date
}

/// One batcher belongs to one physical owner. It groups independently granted
/// turns without acquiring a second RoomRef while holding a SQL transaction.
public actor V2HostRoomReceiptBatcher: V2ReadReceiptBatchMetricsReading {
    private struct OperationKey: Hashable, Sendable {
        let actorUserID: UserID
        let operationID: ReadReceiptOperationID
    }

    private struct Pending: Sendable {
        let id: UUID
        let turn: V2GrantedRoomReceiptTurn
        let queuedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<V2RoomReceiptResult, any Error>
    }

    private struct InFlight {
        let work: Task<Void, Never>
        let deadlineTimer: Task<Void, Never>
    }

    private let configuration: V2ReadReceiptBatcher.Configuration
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private let execute: @Sendable (V2ActorReadReceiptRecordBatchWire, V2RoomActivationWriteScope, [Date]) async throws -> V2ActorReadReceiptRecordBatchResultWire
    private var queue: [UUID] = []
    private var pending: [UUID: Pending] = [:]
    private var flushTask: Task<Void, Never>?
    private var flushGeneration: UInt64 = 0
    private var inFlight: [UUID: InFlight] = [:]
    private var completedBatches: UInt64 = 0
    private var completedRequests: UInt64 = 0
    private var maximumObservedBatchSize = 0
    private var queueFullRejections: UInt64 = 0
    private var cancelledPendingRequests: UInt64 = 0

    var pendingCount: Int { pending.count }
    var inFlightBatchCount: Int { inFlight.count }

    public func snapshot() -> V2ReadReceiptBatcher.Snapshot {
        .init(pendingRequests: pending.count, inFlightBatches: inFlight.count,
              completedBatches: completedBatches, completedRequests: completedRequests,
              maximumObservedBatchSize: maximumObservedBatchSize,
              queueFullRejections: queueFullRejections,
              cancelledPendingRequests: cancelledPendingRequests)
    }

    public init(executor: V2ActorRoomReceiptExecutor,
                configuration: V2ReadReceiptBatcher.Configuration,
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil) {
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        self.execute = { batch, scope, ingressTimes in
            try await executor.recordBatch(batch, scope: scope, ingressTimes: ingressTimes)
        }
    }

    // A deterministic executor seam permits queue, admission and cancellation
    // tests without weakening the production activation-fenced initializer.
    init(configuration: V2ReadReceiptBatcher.Configuration,
         databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
         execute: @escaping @Sendable (V2ActorReadReceiptRecordBatchWire, V2RoomActivationWriteScope, [Date]) async throws -> V2ActorReadReceiptRecordBatchResultWire) {
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        self.execute = execute
    }

    func record(_ turn: V2GrantedRoomReceiptTurn) async throws -> V2RoomReceiptResult {
        guard turn.token.roomID == turn.command.roomID else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(.init(id: id, turn: turn, queuedAt: .now, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelPending(id) }
        }
    }

    private func enqueue(_ item: Pending) {
        guard !Task.isCancelled else {
            item.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled))
            return
        }
        guard item.turn.callDeadline > .now else {
            item.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.deadlineExceeded))
            return
        }
        guard pending.count < configuration.maximumPendingRequests else {
            queueFullRejections = Self.saturatingIncrement(queueFullRejections)
            item.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.overloaded))
            return
        }
        pending[item.id] = item
        queue.append(item.id)
        dispatchAvailable(forceUnderfilled: false)
        scheduleFlush()
    }

    private func cancelPending(_ id: UUID) {
        guard let item = pending.removeValue(forKey: id) else {
            // A dispatched batch owns the DB work until it has settled. The
            // cancelled caller still receives the known result or uncertainty.
            return
        }
        cancelledPendingRequests = Self.saturatingIncrement(cancelledPendingRequests)
        item.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.cancelled))
        compactQueue()
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = nil
        flushGeneration &+= 1
        guard !pending.isEmpty else { return }
        let generation = flushGeneration
        let deadline: ContinuousClock.Instant
        if inFlight.count == configuration.maximumInFlightBatches {
            deadline = pending.values.map(\.turn.callDeadline).min()!
        } else {
            deadline = pending.values.map {
                min($0.turn.batchDeadline, $0.turn.callDeadline,
                    $0.queuedAt + configuration.maximumDelay)
            }.min()!
        }
        flushTask = Task {
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            flush(generation: generation)
        }
    }

    private func flush(generation: UInt64) {
        guard generation == flushGeneration else { return }
        flushTask = nil
        dispatchAvailable(forceUnderfilled: true)
        scheduleFlush()
    }

    private func dispatchAvailable(forceUnderfilled: Bool) {
        expirePending()
        var allowUnderfilled = forceUnderfilled
        while inFlight.count < configuration.maximumInFlightBatches {
            guard pending.count >= configuration.maximumBatchSize ||
                  (allowUnderfilled && !pending.isEmpty) else { break }
            allowUnderfilled = false
            let selected = takeBatch()
            guard !selected.isEmpty else { break }
            maximumObservedBatchSize = max(maximumObservedBatchSize, selected.count)
            flushTask?.cancel()
            flushTask = nil
            flushGeneration &+= 1
            let batchID = UUID()
            let deadline = selected.map(\.turn.callDeadline).min()!
            let work = Task {
                let result: Result<[V2RoomReceiptResult], any Error>
                do {
                    let values = try await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                        try await perform(selected, deadline: deadline)
                    }
                    result = .success(values)
                } catch {
                    result = .failure(error)
                }
                complete(batchID: batchID, selected: selected, result: result)
            }
            let deadlineTimer = Task {
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                cancelInFlight(batchID)
            }
            inFlight[batchID] = .init(work: work, deadlineTimer: deadlineTimer)
        }
    }

    private func cancelInFlight(_ batchID: UUID) {
        // Cancellation wakes DB admission or closes the borrowed PostgreSQL
        // connection. The worker remains tracked until that work has settled.
        inFlight[batchID]?.work.cancel()
    }

    private func expirePending() {
        let expired = pending.values.filter { $0.turn.callDeadline <= .now }
        for item in expired {
            pending.removeValue(forKey: item.id)
            item.continuation.resume(throwing: V2RoomCallFailure.notAccepted(.deadlineExceeded))
        }
        if !expired.isEmpty { compactQueue() }
    }

    private func takeBatch() -> [Pending] {
        var selected: [Pending] = []
        var operations: Set<OperationKey> = []
        var tokens: [RoomID: V2RoomActivationToken] = [:]
        var remaining: [UUID] = []
        for id in queue {
            guard let item = pending[id] else { continue }
            let operation = OperationKey(actorUserID: item.turn.command.actorUserID,
                                         operationID: item.turn.command.operationID)
            let room = item.turn.command.roomID
            if selected.count < configuration.maximumBatchSize,
               !operations.contains(operation),
               tokens[room].map({ $0 == item.turn.token }) ?? true {
                selected.append(item)
                operations.insert(operation)
                tokens[room] = item.turn.token
                pending.removeValue(forKey: id)
            } else {
                remaining.append(id)
            }
        }
        queue = remaining
        return selected
    }

    private func perform(_ selected: [Pending], deadline: ContinuousClock.Instant) async throws -> [V2RoomReceiptResult] {
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        if let databaseWorkAdmission {
            switch await databaseWorkAdmission.acquire(.foregroundWrite, callerDeadline: deadline) {
            case .admitted: break
            case .rejected(.queueFull): throw V2RoomCallFailure.notAccepted(.overloaded)
            case .rejected(.timeout):
                throw V2RoomCallFailure.notAccepted(deadline <= .now ? .deadlineExceeded : .overloaded)
            case .cancelled:
                throw V2RoomCallFailure.notAccepted(deadline <= .now ? .deadlineExceeded : .cancelled)
            }
        }
        do {
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let wires = selected.map { item -> V2ActorRecordReadReceiptWire in
                switch item.turn.command { case .record(let wire): return wire }
            }
            let batch = try V2ActorReadReceiptRecordBatchWire(requests: wires)
            var tokens: [RoomID: V2RoomActivationToken] = [:]
            for item in selected { tokens[item.turn.token.roomID] = item.turn.token }
            let scope = try V2RoomActivationWriteScope(tokens: Array(tokens.values))
            // The existing store handles group rows in one SQL transaction,
            // then direct-room rows in further transactions. If it throws,
            // an earlier row may already be durable. Only a complete result
            // vector proves individual outcomes for this selection.
            let results: V2ActorReadReceiptRecordBatchResultWire
            do { results = try await execute(batch, scope, selected.map(\.turn.ingressAt)) }
            catch { throw V2RoomCallFailure.outcomeUnknown }
            guard results.results.count == selected.count else {
                throw V2RoomCallFailure.outcomeUnknown
            }
            let values = results.results.map { value -> V2RoomReceiptResult in
                switch value {
                case .success(let outcome): return .record(outcome)
                case .failure(let error): return .recordFailure(.store(error))
                }
            }
            if let databaseWorkAdmission { await databaseWorkAdmission.release(.foregroundWrite) }
            return values
        } catch {
            if let databaseWorkAdmission { await databaseWorkAdmission.release(.foregroundWrite) }
            throw error
        }
    }

    private func complete(batchID: UUID, selected: [Pending],
                          result: Result<[V2RoomReceiptResult], any Error>) {
        inFlight.removeValue(forKey: batchID)?.deadlineTimer.cancel()
        completedBatches = Self.saturatingIncrement(completedBatches)
        completedRequests = Self.saturatingAdd(completedRequests, UInt64(selected.count))
        switch result {
        case .success(let values) where values.count == selected.count:
            for (item, value) in zip(selected, values) {
                if value == .recordFailure(.store(.ownerChanged)) {
                    item.continuation.resume(throwing: V2RoomActivationLeaseError.activationChanged)
                } else {
                    item.continuation.resume(returning: value)
                }
            }
        case .success:
            for item in selected { item.continuation.resume(throwing: V2ActorRoomReceiptWireError.invalidResult) }
        case .failure(let error):
            for item in selected { item.continuation.resume(throwing: error) }
        }
        dispatchAvailable(forceUnderfilled: false)
        scheduleFlush()
    }

    private func compactQueue() {
        guard queue.count > pending.count * 2 + 64 else { return }
        queue.removeAll { pending[$0] == nil }
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? .max : sum.partialValue
    }
}
