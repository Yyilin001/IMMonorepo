@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing

// Reuse the existing serialized disposable-database suite: preparation handles
// are real, immutable and store-bound. Only owner execution is held at a
// deterministic boundary; Store SQL correctness has separate integration tests.
extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("physical return and selection progress before borrower resumption and room finalization", arguments: [false, true])
    func durableOwnerPhysicalDispatchProgress(delayBorrowerResume: Bool) async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let resources = DurablePhysicalConnectionGate(), execution = DurableCoordinatorExecutionGate()
            let finalization = DurableCoordinatorExecutionGate(), borrowerResume = DurableCoordinatorExecutionGate()
            await resources.grantAll()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 8, fallbackConnectionCapacity: 1), maximumRetainedBytes: 65_536,
                resourceDemandLimit: 1,
                scheduledConnection: { _, body in
                    let outcome = try await resources.borrow {
                        try await body(.init(finalize: { _ = try? await finalization.execute([handles[0]]) },
                            execute: { prepared, _, _, _ in try await execution.execute([prepared])[0].get() }))
                    }
                    if delayBorrowerResume {
                        // Models the real pool callback preceding the suspended borrower's resumption.
                        V2ScheduledSendLoanReturn.current?.notify()
                        _ = try? await borrowerResume.execute([handles[0]])
                    }
                    return outcome
                }, scheduledExecute: { executor, prepared in
                    try await executor.execute(prepared, try self.forwardImportTestProfile(), .init(), Date.init)
                })
            let first = Task { try await batcher.execute(handles[0]) }
            try await durableCoordinatorObserve { await execution.entries.count == 1 }
            let same = Task { try await batcher.execute(handles[1]) }
            let peer = Task { try await batcher.execute(handles[2]) }
            try await durableCoordinatorObserve { batcher.pressureSnapshot().queuedTurns == 2 }
            do {
                await execution.release(0)
                try await durableCoordinatorObserve(deadline: .now + .milliseconds(500)) { await execution.entries.count == 2 }
                #expect(await resources.returned == 1)
                #expect(await execution.entries[1] == handles[2].commandPayload.map { $0.command.text })
                #expect(batcher.pressureSnapshot().occupiedRooms == 2)
                await borrowerResume.releaseAll(); await execution.releaseAll(); await finalization.releaseAll()
                _ = try await first.value; _ = try await peer.value; _ = try await same.value
                await batcher.shutdown()
                #expect(batcher.pressureSnapshot().retainedItems == 0)
            } catch {
                await borrowerResume.releaseAll(); await execution.releaseAll(); await finalization.releaseAll()
                first.cancel(); same.cancel(); peer.cancel()
                await batcher.shutdown()
                _ = await first.result; _ = await same.result; _ = await peer.result
                throw error
            }
        }
    }

    @Test("a granted unbound ticket does not clip the selected room transaction deadline")
    func durableOwnerSelectedRoomOwnsDeadline() async throws {
        let observer = DurablePostCommitObserver()
        try await withDurableCoordinatorHandles(committedMessageObserver: observer) { store, handles in
            let finalizer = Mutex<(@Sendable () async -> Void)?>(nil)
            try await store.withScheduledSendConnection(deadline: .now + .seconds(1)) { executor in
                try await Task.sleep(for: .milliseconds(1_100))
                let results = try await executor.execute(handles[0], try self.forwardImportTestProfile(),
                    .init(), { Date(timeIntervalSince1970: 1_750_000_000) })
                #expect(!results.isEmpty)
                #expect(observer.count == 0)
                finalizer.withLock { $0 = executor.finalize }
            }
            #expect(observer.count == 0)
            let finish = try #require(finalizer.withLock { $0 })
            await finish()
            #expect(observer.count == handles[0].commandPayload.count)
            await finish()
            #expect(observer.count == handles[0].commandPayload.count)
        }
    }
    @Test("a hot room cannot consume all retained owner capacity including its active turn")
    func durableOwnerHotRoomBudgetLeavesPeerCapacity() async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let gate = DurableCoordinatorExecutionGate()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 1_024, fallbackConnectionCapacity: 1),
                maximumRetainedBytes: 2 * 1_024 * 1_024,
                executeOwnerBatch: { try await gate.execute($0) })
            var workers = [Task { try await batcher.execute(handles[0]) }]
            do {
                try await durableCoordinatorObserve { await gate.entries.count == 1 }
                // Repeated immutable handles exercise retained scheduling only;
                // the real executor's operation replay is tested separately.
                for _ in 1..<256 { workers.append(Task { try await batcher.execute(handles[0]) }) }
                try await durableCoordinatorObserve { batcher.pressureSnapshot().retainedItems == 256 }
                await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
                    try await batcher.execute(handles[1])
                }
                workers.append(Task { try await batcher.execute(handles[2]) })
                try await durableCoordinatorObserve { batcher.pressureSnapshot().retainedItems == 257 }
                for worker in workers.dropFirst() { worker.cancel() }
                for worker in workers.dropFirst() { _ = await worker.result }
                #expect(batcher.pressureSnapshot().retainedItems == 1)
                await gate.releaseAll()
                _ = try await workers[0].value
                await batcher.shutdown()
                #expect(batcher.pressureSnapshot().retainedItems == 0)
            } catch {
                for worker in workers { worker.cancel() }
                await gate.releaseAll(); await batcher.shutdown()
                for worker in workers { _ = await worker.result }
                throw error
            }
        }
    }
    @Test("single-room transactions preserve room FIFO and drain all retained work")
    func durableOwnerCoordinatorRoomFIFOAndDrain() async throws {
        try await withDurableCoordinatorHandles { store, prepared in
            let gate = DurableCoordinatorExecutionGate()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 4, fallbackConnectionCapacity: 1), maximumRetainedBytes: 16_384,
                executeOwnerBatch: { try await gate.execute($0) })
            var workers: [Task<[V2RoomMessagingResult], any Error>] = []
            do {
                workers.append(Task { try await batcher.execute(prepared[0]) })
                try await durableCoordinatorObserve { await gate.entries.count == 1 }
                workers.append(Task { try await batcher.execute(prepared[1]) })
                try await durableCoordinatorObserve { batcher.pressureSnapshot().queuedTurns == 1 }
                workers.append(Task { try await batcher.execute(prepared[2]) })
                try await durableCoordinatorObserve { batcher.pressureSnapshot().queuedTurns == 2 }
                workers.append(Task { try await batcher.execute(prepared[3]) })
                try await durableCoordinatorObserve { batcher.pressureSnapshot().queuedTurns == 3 }
                let held = await batcher.sendOperationOwnerMetricsSnapshot()
                #expect(held.retainedItems == 4 && held.inFlightBatches == 1 && held.largestRoomCount == 1)
                for index in 0..<4 {
                    try await durableCoordinatorObserve { await gate.entries.count == index + 1 }
                    await gate.release(index)
                }
                for worker in workers { #expect(try await worker.value == [.sendOperation(.unresolved)]) }
                #expect(await gate.entries == [["a1"], ["b1"], ["a2"], ["b2"]])
                await batcher.shutdown()
                let metrics = await batcher.sendOperationOwnerMetricsSnapshot()
                #expect(metrics.batchesStarted == 4 && metrics.batchesCompleted == 4)
                #expect(metrics.commandsSubmitted == 4 && metrics.largestBatch == 1 && metrics.largestRoomCount == 1)
                #expect(metrics.retainedItems == 0 && metrics.retainedBytes == 0 && metrics.inFlightBatches == 0)
            } catch {
                await gate.releaseAll(); await batcher.shutdown()
                for worker in workers { _ = await worker.result }
                throw error
            }
        }
    }

    @Test("durable owner cancellation and repeated shutdown retain actual submitted work")
    func durableOwnerCoordinatorCancellationAndDrain() async throws {
        try await withDurableCoordinatorHandles { store, prepared in
            let gate = DurableCoordinatorExecutionGate()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 2, fallbackConnectionCapacity: 1),
                maximumRetainedBytes: 16_384,
                executeOwnerBatch: { try await gate.execute($0) })
            let completed = Mutex(false), closes = Mutex(0)
            do {
                let submitted = Task {
                    defer { completed.withLock { $0 = true } }
                    return try await batcher.execute(prepared[0])
                }
                try await durableCoordinatorObserve { await gate.entries.count == 1 }
                submitted.cancel()
                let queued = Task { try await batcher.execute(prepared[2]) }
                try await durableCoordinatorObserve { batcher.pressureSnapshot().queuedTurns == 1 }
                await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
                    try await batcher.execute(prepared[1])
                }
                queued.cancel()
                await #expect(throws: V2RoomCallFailure.notAccepted(.cancelled)) { try await queued.value }
                let held = batcher.pressureSnapshot()
                #expect(held.retainedItems == 1 && held.inFlightBatches == 1 && held.occupiedRooms == 1)
                #expect(!completed.withLock { $0 })
                let firstClose = Task {
                    await batcher.shutdown()
                    closes.withLock { $0 += 1 }
                }
                try await durableCoordinatorObserve { batcher.pressureSnapshot().closed }
                let secondClose = Task {
                    await batcher.shutdown()
                    closes.withLock { $0 += 1 }
                }
                try await durableCoordinatorObserve { batcher.pressureSnapshot().drainingWaiters == 2 }
                // The physical executor is still held. Neither a cancelled
                // caller nor repeated close may release its connection capacity.
                #expect(closes.withLock { $0 } == 0)
                #expect(!completed.withLock { $0 })
                #expect(batcher.pressureSnapshot().retainedItems == 1)
                await gate.release(0)
                #expect(try await submitted.value == [.sendOperation(.unresolved)])
                await firstClose.value
                await secondClose.value
                #expect(closes.withLock { $0 } == 2)
                let drained = batcher.pressureSnapshot()
                #expect(drained.retainedItems == 0 && drained.retainedBytes == 0 && drained.inFlightBatches == 0 && drained.occupiedRooms == 0)
                #expect(await gate.entries == [["a1"]])
                let metrics = await batcher.sendOperationOwnerMetricsSnapshot()
                #expect(metrics.batchesStarted == 1 && metrics.batchesCompleted == 1)
                #expect(metrics.commandsSubmitted == 1 && metrics.largestBatch == 1)
                #expect(metrics.retainedItems == 0 && metrics.retainedBytes == 0 && metrics.queuedTurns == 0)
            } catch {
                await gate.releaseAll()
                await batcher.shutdown()
                throw error
            }
        }
    }

    @Test("distinct rooms on the same shard execute concurrently within the owner limit")
    func durableOwnerCoordinatorIsolatesRoomsOnSameShard() async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let gate = DurableCoordinatorExecutionGate()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 2, fallbackConnectionCapacity: 2),
                maximumRetainedBytes: 16_384, executeOwnerBatch: { try await gate.execute($0) })
            var workers: [Task<[V2RoomMessagingResult], any Error>] = []
            do {
                workers.append(Task { try await batcher.execute(handles[0]) })
                try await durableCoordinatorObserve { await gate.entries.count == 1 }
                workers.append(Task { try await batcher.execute(handles[2]) })
                try await durableCoordinatorObserve { batcher.pressureSnapshot().retainedItems == 2 }
                try await durableCoordinatorObserve { await gate.entries.count == 2 }
                let concurrent = batcher.pressureSnapshot()
                #expect(concurrent.inFlightBatches == 2 && concurrent.occupiedRooms == 2 && concurrent.queuedTurns == 0)
                #expect(await gate.entries == [["a1"], ["b1"]])
                await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
                    try await batcher.execute(handles[1])
                }
                await gate.release(0)
                _ = try await workers[0].value
                try await durableCoordinatorObserve { await gate.entries.count == 2 }
                #expect(await gate.entries == [["a1"], ["b1"]])
                #expect(batcher.pressureSnapshot().occupiedRooms == 1)
                await gate.release(1)
                _ = try await workers[1].value
                await batcher.shutdown()
                let drained = batcher.pressureSnapshot()
                #expect(drained.retainedItems == 0 && drained.retainedBytes == 0 && drained.occupiedRooms == 0)
            } catch {
                await gate.releaseAll()
                await batcher.shutdown()
                for worker in workers { _ = await worker.result }
                throw error
            }
        }
    }

    @Test("queued deadlines release only queued budget while actual quota ownership is held", arguments: [false, true])
    func durableOwnerCoordinatorQueuedDeadlineWhileBusy(occupiedRoom: Bool) async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let gate = DurableCoordinatorExecutionGate()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 2, fallbackConnectionCapacity: 1),
                maximumRetainedBytes: 16_384, executeOwnerBatch: { try await gate.execute($0) })
            var workers: [Task<[V2RoomMessagingResult], any Error>] = []
            do {
                workers.append(Task { try await batcher.execute(handles[0]) })
                try await durableCoordinatorObserve { await gate.entries.count == 1 }
                // Prepare through the actual Store after execution is held so
                // the absolute deadline belongs to this queued request alone.
                let source = handles[occupiedRoom ? 1 : 2]
                let queuedHandle = try await store.prepareSendBatch(source.commandPayload,
                    token: source.activationToken, deadline: .now + .milliseconds(500),
                    now: { Date(timeIntervalSince1970: 1_750_000_000) })
                let queuedSettled = Mutex(false)
                workers.append(Task {
                    defer { queuedSettled.withLock { $0 = true } }
                    return try await batcher.execute(queuedHandle)
                })
                try await durableCoordinatorObserve { batcher.pressureSnapshot().queuedTurns == 1 }
                try await durableCoordinatorObserve { queuedSettled.withLock { $0 } }
                await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
                    try await workers[1].value
                }
                // No release signal has reached the physical executor. Expiry
                // must remove queued work without retiring the selected batch.
                let held = batcher.pressureSnapshot()
                #expect(held.queuedTurns == 0 && held.retainedItems == 1)
                #expect(held.inFlightBatches == 1 && held.occupiedRooms == 1 && held.occupiedRooms == 1)
                #expect(await gate.entries == [["a1"]])
                await gate.release(0)
                _ = try await workers[0].value
                await batcher.shutdown()
                let drained = batcher.pressureSnapshot()
                #expect(drained.retainedItems == 0 && drained.occupiedRooms == 0)
            } catch {
                await gate.releaseAll()
                await batcher.shutdown()
                for worker in workers { _ = await worker.result }
                throw error
            }
        }
    }

    @Test("occupied room FIFO does not block independent rooms within owner capacity")
    func durableOwnerCoordinatorRoomFIFOAndIndependentProgress() async throws {
        try await withDurableCoordinatorHandles(includeDisjoint: true) { store, handles in
            let gate = DurableCoordinatorExecutionGate()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 4, fallbackConnectionCapacity: 2),
                maximumRetainedBytes: 32_768, executeOwnerBatch: { try await gate.execute($0) })
            var workers: [Task<[V2RoomMessagingResult], any Error>] = []
            do {
                workers.append(Task { try await batcher.execute(handles[0]) })
                try await durableCoordinatorObserve { await gate.entries.count == 1 }
                workers.append(Task { try await batcher.execute(handles[2]) })
                try await durableCoordinatorObserve { await gate.entries.count == 2 }
                workers.append(Task { try await batcher.execute(handles[1]) })
                try await durableCoordinatorObserve { batcher.pressureSnapshot().queuedTurns == 1 }
                workers.append(Task { try await batcher.execute(handles[4]) })
                try await durableCoordinatorObserve { batcher.pressureSnapshot().queuedTurns == 2 }
                await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
                    try await batcher.execute(handles[5])
                }
                #expect(await gate.entries == [["a1"], ["b1"]])
                await gate.release(1)
                _ = try await workers[1].value
                try await durableCoordinatorObserve { await gate.entries.count == 3 }
                #expect(await gate.entries == [["a1"], ["b1"], ["c1"]])
                // a2 still waits for its own room's actual first transaction.
                #expect(batcher.pressureSnapshot().queuedTurns == 1)
                await gate.release(0)
                _ = try await workers[0].value
                try await durableCoordinatorObserve { await gate.entries.count == 4 }
                #expect(await gate.entries == [["a1"], ["b1"], ["c1"], ["a2"]])
                await gate.release(2); await gate.release(3)
                for worker in workers { _ = try await worker.value }
                await batcher.shutdown()
                let drained = batcher.pressureSnapshot()
                #expect(drained.retainedItems == 0 && drained.occupiedRooms == 0 && drained.inFlightBatches == 0)
            } catch {
                await gate.releaseAll(); await batcher.shutdown()
                for worker in workers { _ = await worker.result }
                throw error
            }
        }
    }

    @Test("shutdown joins both independent physical executions despite caller cancellation", arguments: [false, true])
    func durableOwnerIndependentShutdownJoins(cancelSubmitted: Bool) async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let gate = DurableCoordinatorExecutionGate()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 3, fallbackConnectionCapacity: 2),
                maximumRetainedBytes: 16_384, executeOwnerBatch: { try await gate.execute($0) })
            let first = Task { try await batcher.execute(handles[0]) }
            try await durableCoordinatorObserve { await gate.entries.count == 1 }
            let peer = Task { try await batcher.execute(handles[2]) }
            do {
                try await durableCoordinatorObserve { await gate.entries.count == 2 }
                if cancelSubmitted { first.cancel() }
                let done = Mutex(false)
                let shutdown = Task { await batcher.shutdown(); done.withLock { $0 = true } }
                try await durableCoordinatorObserve { batcher.pressureSnapshot().closed }
                #expect(!done.withLock { $0 })
                #expect(batcher.pressureSnapshot().inFlightBatches == 2)
                await gate.release(0)
                _ = try await first.value
                #expect(!done.withLock { $0 })
                #expect(batcher.pressureSnapshot().inFlightBatches == 1)
                await gate.release(1)
                _ = try await peer.value
                await shutdown.value
                #expect(done.withLock { $0 })
                let drained = batcher.pressureSnapshot()
                #expect(drained.retainedItems == 0 && drained.retainedBytes == 0 && drained.occupiedRooms == 0)
            } catch {
                await gate.releaseAll(); await batcher.shutdown()
                _ = await first.result; _ = await peer.result
                throw error
            }
        }
    }
    @Test("same-shard independent rooms own simultaneous real PostgreSQL transactions")
    func durableOwnerRealRoomTransactionsAreIndependent() async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let gate = DurableActualTransactionGate()
            let observed = store.observingOwnerTransactions { pid, _, _ in await gate.enter(pid) }
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            let batcher = V2DurableSendOperationOwnerBatcher(store: observed, capacityProfile: profile,
                now: { Date(timeIntervalSince1970: 1_750_000_000) },                 configuration: .init(maximumPendingRequests: 4, fallbackConnectionCapacity: 2), maximumRetainedBytes: 16_384)
            let first = Task { try await batcher.execute(handles[0]) }
            let second = Task { try await batcher.execute(handles[2]) }
            do {
                try await durableCoordinatorObserve { await gate.backends.count == 2 }
                let backends = await gate.backends
                #expect(Set(backends).count == 2)
                #expect(batcher.pressureSnapshot().inFlightBatches == 2)
                await gate.release()
                for result in [try await first.value, try await second.value] {
                    guard result.count == 1, case .sendOperation(.receipt(let receipt)) = result[0],
                          case .accepted = receipt.outcome else {
                        Issue.record("both independent room transactions must commit their acceptance")
                        continue
                    }
                }
                await batcher.shutdown()
                #expect(batcher.pressureSnapshot().retainedItems == 0)
            } catch {
                await gate.release(); await batcher.shutdown()
                _ = await first.result; _ = await second.result
                throw error
            }
        }
    }

    @Test("each room retains its physical backend across confirmed rollback and scalar fallback")
    func durableOwnerPinnedBackendAcrossFallback() async throws {
        try await withDurableCoordinatorHandles(includeDisjoint: true, complexLast: true) { store, handles in
            let profile = try V2CapacityProfile(id: "standard", limits: .init(
                maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
            for (index, handle) in [handles[0], handles[2], handles[4], handles[6]].enumerated() {
                let observations = Mutex<[(Int32, Bool, Int)]>([])
                let observedStore = store.observingOwnerTransactions { pid, scalar, count in
                    let first = observations.withLock { values in
                        let first = values.isEmpty; values.append((pid, scalar, count)); return first
                    }
                    // The failed BEGIN must actually roll back before this room
                    // retries on its original physical connection.
                    if index == 0 && first { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
                }
                let admissionOrder = Mutex<[String]>([])
                let result = try await observedStore.executePreparedRoomSendPreborrowing(handle,
                    capacityProfile: profile, identifiers: .init(),
                    now: { Date(timeIntervalSince1970: 1_750_000_000) },
                    control: .init(connectionAcquired: { admissionOrder.withLock { $0.append("connection") } },
                        beforeFirstBegin: { admissionOrder.withLock { $0.append("execution") } }, interrupted: { _ in }))
                #expect(admissionOrder.withLock { $0 } == ["execution", "connection"])
                #expect(result.count == 1)
                guard case .sendOperation(.receipt(let receipt)) = result[0], case .accepted = receipt.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let recorded = observations.withLock { $0 }
                #expect(recorded.allSatisfy { $0.2 == 1 })
                #expect(Set(recorded.map { $0.0 }).count == 1)
                if index == 0 {
                    #expect(recorded.count == 2 && recorded.first?.1 == false && recorded.last?.1 == true)
                } else if index == 3 {
                    #expect(recorded.count == 1 && recorded.first?.1 == true)
                } else {
                    // Plain group turns are excluded from the direct append kernel
                    // and then use their strict scalar business implementation.
                    #expect(recorded.count == 2 && recorded.first?.1 == false && recorded.last?.1 == true)
                }
            }
        }
    }

    @Test("physical connection scheduling bypasses logical admission and selects only live rooms after grant")
    func durableOwnerPhysicalConnectionSelection() async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let resources = DurablePhysicalConnectionGate()
            let execution = DurableCoordinatorExecutionGate()
            let admission = V2DatabaseWorkAdmissionController(policy: .init(
                maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
                maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
                maximumInteractiveReadQueued: 1, maximumSyncQueued: 1, timeout: .seconds(5)))
            #expect(await admission.acquire(.foregroundWrite) == .admitted)
            #expect(await admission.acquire(.interactiveRead) == .admitted)
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 8, fallbackConnectionCapacity: 1), maximumRetainedBytes: 65_536,
                resourceDemandLimit: 1,
                scheduledConnection: { _, body in
                    try await resources.borrow {
                        try await body(.init { prepared, _, _, _ in try await execution.execute([prepared])[0].get() })
                    }
                },
                scheduledExecute: { executor, prepared in
                    try await executor.execute(prepared, try self.forwardImportTestProfile(), .init(), Date.init)
                })
            let cancelled = Task { try await batcher.execute(handles[0]) }
            try await durableCoordinatorObserve { await resources.waitingCount == 1 }
            #expect(batcher.pressureSnapshot().occupiedRooms == 0)
            cancelled.cancel()
            _ = await cancelled.result
            try await durableCoordinatorObserve { await resources.waitingCount == 0 }
            let live = Task { try await batcher.execute(handles[2]) }
            do {
                try await durableCoordinatorObserve { await resources.waitingCount == 1 }
                #expect(await admission.snapshot().foregroundWrite.queued == 0)
                #expect(batcher.pressureSnapshot().occupiedRooms == 0)
                await resources.grantAll()
                try await durableCoordinatorObserve { await execution.entries.count == 1 }
                #expect(await execution.entries[0] == handles[2].commandPayload.map { $0.command.text })
                await execution.releaseAll()
                _ = try await live.value
                await batcher.shutdown()
                #expect(await resources.returned == 1)
                #expect(batcher.pressureSnapshot().retainedItems == 0)
                await admission.release(.foregroundWrite); await admission.release(.interactiveRead)
            } catch {
                live.cancel(); await resources.grantAll(); await execution.releaseAll()
                await batcher.shutdown(); _ = await live.result
                await admission.release(.foregroundWrite); await admission.release(.interactiveRead)
                throw error
            }
        }
    }

    @Test("physical connection shutdown waits for actual execution and loan return")
    func durableOwnerPhysicalConnectionDrain() async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let resources = DurablePhysicalConnectionGate()
            let execution = DurableCoordinatorExecutionGate()
            await resources.grantAll()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 8, fallbackConnectionCapacity: 1), maximumRetainedBytes: 65_536,
                resourceDemandLimit: 1,
                scheduledConnection: { _, body in
                    try await resources.borrow {
                        try await body(.init { prepared, _, _, _ in try await execution.execute([prepared])[0].get() })
                    }
                }, scheduledExecute: { executor, prepared in
                    try await executor.execute(prepared, try self.forwardImportTestProfile(), .init(), Date.init)
                })
            let worker = Task { try await batcher.execute(handles[0]) }
            try await durableCoordinatorObserve { await execution.entries.count == 1 }
            let closing = Task { await batcher.shutdown() }
            try await durableCoordinatorObserve { batcher.pressureSnapshot().drainingWaiters == 1 }
            #expect(await resources.returned == 0)
            #expect(batcher.pressureSnapshot().occupiedRooms == 1)
            await execution.releaseAll()
            _ = try await worker.value
            await closing.value
            #expect(await resources.returned == 1)
            #expect(batcher.pressureSnapshot().inFlightBatches == 0)
        }
    }

    @Test("returned connection serves another room while finalization retains FIFO and drain", arguments: [false, true])
    func durableOwnerPhysicalPostCommitFinalization(closeDuringFinalization: Bool) async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let resources = DurablePhysicalConnectionGate()
            let execution = DurableCoordinatorExecutionGate()
            let finalization = DurableCoordinatorExecutionGate()
            await resources.grantAll()
            await execution.releaseAll()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 8, fallbackConnectionCapacity: 1), maximumRetainedBytes: 65_536,
                resourceDemandLimit: 1,
                scheduledConnection: { _, body in
                    try await resources.borrow {
                        try await body(.init(finalize: {
                            _ = try? await finalization.execute([handles[0]])
                        }, execute: { prepared, _, _, _ in
                            try await execution.execute([prepared])[0].get()
                        }))
                    }
                }, scheduledExecute: { executor, prepared in
                    try await executor.execute(prepared, try self.forwardImportTestProfile(), .init(), Date.init)
                })
            let first = Task { try await batcher.execute(handles[0]) }
            var sameRoom: Task<[V2RoomMessagingResult], any Error>?
            var otherRoom: Task<[V2RoomMessagingResult], any Error>?
            do {
                try await durableCoordinatorObserve { await finalization.entries.count == 1 }
                #expect(await resources.returned == 1)
                #expect(batcher.pressureSnapshot().occupiedRooms == 1)
                #expect(await batcher.sendOperationOwnerMetricsSnapshot().batchesCompleted == 0)
                sameRoom = Task { try await batcher.execute(handles[1]) }
                otherRoom = Task { try await batcher.execute(handles[2]) }
                try await durableCoordinatorObserve { await finalization.entries.count == 2 }
                #expect(await resources.returned == 2)
                #expect(await execution.entries.count == 2)
                #expect(await execution.entries[1] == handles[2].commandPayload.map { $0.command.text })
                await finalization.release(1)
                _ = try await otherRoom!.value
                try await durableCoordinatorObserve { batcher.pressureSnapshot().inFlightBatches == 1 }
                #expect(await execution.entries.count == 2)
                #expect(batcher.pressureSnapshot().occupiedRooms == 1)
                if closeDuringFinalization {
                    first.cancel()
                    let closing = Task { await batcher.shutdown() }
                    try await durableCoordinatorObserve { batcher.pressureSnapshot().drainingWaiters == 1 }
                    #expect(batcher.pressureSnapshot().inFlightBatches == 1)
                    await finalization.releaseAll()
                    _ = try await first.value
                    _ = await sameRoom!.result
                    await closing.value
                } else {
                    await finalization.releaseAll()
                    _ = try await first.value
                    _ = try await sameRoom!.value
                    #expect(await execution.entries[2] == handles[1].commandPayload.map { $0.command.text })
                    await batcher.shutdown()
                }
                #expect(batcher.pressureSnapshot().inFlightBatches == 0)
                #expect(batcher.pressureSnapshot().retainedItems == 0)
            } catch {
                await finalization.releaseAll()
                first.cancel(); sameRoom?.cancel(); otherRoom?.cancel()
                await batcher.shutdown()
                _ = await first.result
                _ = await sameRoom?.result
                _ = await otherRoom?.result
                throw error
            }
        }
    }

    @Test("physical queue rejection remains a retryable pre-BEGIN overload", arguments: [false, true])
    func durableOwnerPhysicalQueueFailure(timeout: Bool) async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 8, fallbackConnectionCapacity: 1), maximumRetainedBytes: 65_536,
                resourceDemandLimit: 1,
                scheduledConnection: { _, _ in throw timeout ? V2PhysicalDatabaseLoanFailure.timedOut : .queueFull },
                scheduledExecute: { _, _ in throw V2RoomCallFailure.outcomeUnknown })
            await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) { try await batcher.execute(handles[0]) }
            await batcher.shutdown()
            #expect(batcher.pressureSnapshot().occupiedRooms == 0)
            #expect(await batcher.sendOperationOwnerMetricsSnapshot().batchesStarted == 0)
        }
    }

    @Test("expiry of an unbound ticket resubmits live room demand")
    func durableOwnerPhysicalExpiredTicket() async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let attempts = Mutex(0)
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 8, fallbackConnectionCapacity: 1), maximumRetainedBytes: 65_536,
                resourceDemandLimit: 1,
                scheduledConnection: { _, body in
                    let attempt = attempts.withLock { $0 += 1; return $0 }
                    if attempt == 1 { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
                    return try await store.withScheduledSendConnection(deadline: .now + .seconds(5), body)
                }, scheduledExecute: { executor, prepared in
                    try await executor.execute(prepared, try self.forwardImportTestProfile(), .init(),
                        { Date(timeIntervalSince1970: 1_750_000_000) })
                })
            let results = try await batcher.execute(handles[0])
            #expect(!results.isEmpty)
            await batcher.shutdown()
            #expect(attempts.withLock { $0 } == 2)
            #expect(batcher.pressureSnapshot().retainedItems == 0)
        }
    }

    @Test("a retained executor cannot execute SQL after its physical loan has returned")
    func durableOwnerRejectsReturnedExecutor() async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let captured = Mutex<V2OwnerConnectionExecutor?>(nil)
            try await store.withScheduledSendConnection(deadline: .now + .seconds(5)) { executor in
                captured.withLock { $0 = executor }
            }
            let returned = try #require(captured.withLock { $0 })
            await #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
                try await returned.execute(handles[0], try self.forwardImportTestProfile(), .init(), Date.init)
            }
        }
    }

    @Test("loan cleanup failure cannot lose a settled turn or leave its room occupied")
    func durableOwnerSettledTurnSurvivesLoanCleanupFailure() async throws {
        try await withDurableCoordinatorHandles { store, handles in
            let resources = DurablePhysicalConnectionGate()
            let execution = DurableCoordinatorExecutionGate()
            let finalized = Mutex(0)
            await resources.grantAll()
            await execution.releaseAll()
            let batcher = V2DurableSendOperationOwnerBatcher(store: store,
                configuration: .init(maximumPendingRequests: 8, fallbackConnectionCapacity: 1), maximumRetainedBytes: 65_536,
                resourceDemandLimit: 1,
                scheduledConnection: { _, body in
                    _ = try await resources.borrow {
                        try await body(.init(finalize: { finalized.withLock { $0 += 1 } }, execute: { prepared, _, _, _ in
                            try await execution.execute([prepared])[0].get()
                        }))
                    }
                    throw V2RoomCallFailure.outcomeUnknown
                }, scheduledExecute: { executor, prepared in
                    try await executor.execute(prepared, try self.forwardImportTestProfile(), .init(), Date.init)
                })
            let first = try await batcher.execute(handles[0])
            let second = try await batcher.execute(handles[1])
            #expect(!first.isEmpty && !second.isEmpty)
            await batcher.shutdown()
            #expect(finalized.withLock { $0 } == 2)
            #expect(await resources.returned == 2)
            #expect(batcher.pressureSnapshot().occupiedRooms == 0)
            #expect(batcher.pressureSnapshot().retainedItems == 0)
        }
    }

    private func withDurableCoordinatorHandles(
        includeDisjoint: Bool = false, complexLast: Bool = false,
        committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil,
        _ body: @escaping @Sendable (PostgresV2MessageSendOperationStore, [V2PreparedMessageSendBatch]) async throws -> Void
    ) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let peer = RoomID(uuid: UUID()), peerUUID = try #require(peer.uuidValue)
            try await sql.raw("INSERT INTO im_v2.rooms (room_id,room_shard_id,capacity_profile_id,capacity_class) VALUES (\(bind: peerUUID),'room-a','standard','large')").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes (room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: peerUUID),'room-a',0,\(bind: now),\(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.group_rooms (room_id,owner_user_id,title,created_at) VALUES (\(bind: peerUUID),\(bind: senderUUID),'Coordinator peer',\(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.room_admission (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) VALUES (\(bind: peerUUID),3,10,\(bind: leaseUUID),1)").run()
            for member in [senderUUID, memberTwoUUID, memberThreeUUID] {
                try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: peerUUID),\(bind: member),0)").run()
            }
            var extraRooms: [RoomID] = []
            if includeDisjoint {
                for shard in ["room-local-b", "room-local-c"] {
                    let extraRoom = RoomID(uuid: UUID()), extraLease = UUID()
                    try await sql.raw("""
                        INSERT INTO im_v2.shard_admission_pools
                          (room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit)
                        SELECT \(bind: shard),capacity_profile_id,\(bind: extraLease),generation,valid_until,command_window_limit
                        FROM im_v2.shard_admission_pools WHERE room_shard_id='room-a' AND capacity_profile_id='standard'
                        """).run()
                    try await sql.raw("INSERT INTO im_v2.rooms (room_id,room_shard_id,capacity_profile_id,capacity_class) VALUES (\(bind: extraRoom.uuidValue!),\(bind: shard),'standard','large')").run()
                    try await sql.raw("INSERT INTO im_v2.room_owner_routes (room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: extraRoom.uuidValue!),\(bind: shard),0,\(bind: now),\(bind: now))").run()
                    try await sql.raw("INSERT INTO im_v2.group_rooms (room_id,owner_user_id,title,created_at) VALUES (\(bind: extraRoom.uuidValue!),\(bind: senderUUID),'Distinct quota peer',\(bind: now))").run()
                    try await sql.raw("INSERT INTO im_v2.room_admission (room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) VALUES (\(bind: extraRoom.uuidValue!),3,10,\(bind: extraLease),1)").run()
                    for member in [senderUUID, memberTwoUUID, memberThreeUUID] {
                        try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: extraRoom.uuidValue!),\(bind: member),0)").run()
                    }
                    extraRooms.append(extraRoom)
                }
            }
            let disjointRooms = extraRooms
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled),
                clock: { now }, committedMessageObserver: committedMessageObserver)
            try await withRoomActivation(database: database, roomID: roomID) { first in
                try await withRoomActivation(database: database, roomID: peer) { second in
                    @Sendable func preparedHandles(_ tokens: [V2RoomActivationToken]) async throws {
                        var handles: [V2PreparedMessageSendBatch] = []
                        for (index, token) in tokens.enumerated() {
                            for suffix in ["1", "2"] {
                                let text = ["a", "b", "c", "d"][index] + suffix
                                let command = try V2MessageSendOperationCommand(command: .init(
                                    roomID: token.roomID, senderUserID: senderID, clientMessageID: .init(uuid: UUID()),
                                    text: text,
                                    mentions: complexLast && index == tokens.count - 1 ? [.user(.init(uuid: memberTwoUUID))] : [],
                                    limits: .init(maxUTF8Bytes: 64)),
                                    firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
                                handles.append(try await store.prepareSendBatch([command], token: token,
                                    deadline: .now + .seconds(30), now: { now }))
                            }
                        }
                        try await body(store, handles)
                    }
                    if includeDisjoint {
                        try await withRoomActivation(database: database, roomID: disjointRooms[0], shardID: "room-local-b") { third in
                            try await withRoomActivation(database: database, roomID: disjointRooms[1], shardID: "room-local-c") { fourth in
                                try await preparedHandles([first, second, third, fourth])
                            }
                        }
                    } else {
                        try await preparedHandles([first, second])
                    }
                }
            }
        }
    }
}

private func durableCoordinatorObserve(deadline: ContinuousClock.Instant = .now + .seconds(5),
    _ condition: @Sendable () async -> Bool) async throws {
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Coordinator did not reach its controlled observable boundary")
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        await Task.yield()
    }
}

private actor DurableCoordinatorExecutionGate {
    private(set) var entries: [[String]] = []
    private var completions: [Int: CheckedContinuation<Void, Never>] = [:]
    private var open = false

    func execute(_ prepared: [V2PreparedMessageSendBatch]) async throws -> [Result<[V2RoomMessagingResult], any Error>] {
        let index = entries.count
        entries.append(prepared.flatMap { $0.commandPayload.map { $0.command.text } })
        if !open { await withCheckedContinuation { completions[index] = $0 } }
        return prepared.map { .success(Array(repeating: .sendOperation(.unresolved), count: $0.commandPayload.count)) }
    }

    func release(_ index: Int) {
        completions.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        open = true
        let waiters = Array(completions.values)
        completions.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor DurableActualTransactionGate {
    private(set) var backends: [Int32] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func enter(_ pid: Int32) async {
        guard !opened else { return }
        backends.append(pid)
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor DurablePhysicalConnectionGate {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var open = false
    private(set) var returned = 0
    var waitingCount: Int { waiters.count }
    func borrow<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        if !open {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiters[id] = continuation }
                }
            } onCancel: { Task { await self.cancel(id) } }
        }
        try Task.checkCancellation()
        defer { returned += 1 }
        return try await body()
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func grantAll() {
        open = true
        let values = Array(waiters.values); waiters.removeAll()
        for waiter in values { waiter.resume() }
    }
}

private final class DurablePostCommitObserver: V2CommittedMessageBatchObserving, Sendable {
    private let messages = Mutex(0)
    var count: Int { messages.withLock { $0 } }
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken) {
        messages.withLock { $0 += outcomes.count }
    }
}

private extension V2DurableSendOperationOwnerBatcher {
    convenience init(store: PostgresV2MessageSendOperationStore,
        configuration: V2SendOperationSchedulingConfiguration,
        maximumRetainedBytes: Int,
        executeOwnerBatch: @escaping @Sendable ([V2PreparedMessageSendBatch]) async throws -> [Result<[V2RoomMessagingResult], any Error>]) {
        self.init(store: store, configuration: configuration,
            maximumRetainedBytes: maximumRetainedBytes,
            resourceDemandLimit: configuration.fallbackConnectionCapacity,
            scheduledConnection: { _, body in
                try await body(.init(execute: { prepared, _, _, _ in
                    try await executeOwnerBatch([prepared])[0].get()
                }))
            }, scheduledExecute: { executor, prepared in
                try await executor.execute(prepared, try V2CapacityProfile(id: "standard",
                    limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 10, retryAfterSeconds: 1)),
                    .init(), Date.init)
            })
    }
}
