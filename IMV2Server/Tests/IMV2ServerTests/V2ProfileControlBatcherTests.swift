@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite(.serialized)
struct V2ProfileControlBatcherTests {
    @Test("service shutdown also drains readers already past the SQL batch boundary")
    func serviceAdmissionDrain() async throws {
        let admission = V2ProfilePresentationAdmission(), probe = ControlCloseRecorder(), device = DeviceID(uuid: UUID())
        #expect(try await admission.enter(device))
        #expect(try await admission.enter(device))
        #expect(try await !admission.enter(device))
        await admission.stop()
        await #expect(throws: V2ProfileControlBatchError.closed) { _ = try await admission.enter(.init(uuid: UUID())) }
        let closing = Task { await admission.waitForIdle(); await probe.finish() }
        await admission.leave(device)
        #expect(await probe.count == 0)
        await admission.leave(device)
        await closing.value
        #expect(await probe.count == 1)
    }

    @Test("different viewers coalesce within key and byte budgets and retain their own result")
    func multiViewerDemultiplexing() async throws {
        let recorder = ControlBatchRecorder()
        let batcher = V2ProfileControlBatcher(configuration: .init(maximumKeys: 3)) { requests, _ in
            await recorder.record(requests)
            return requests.map { .success(controlSnapshot($0)) }
        }
        let requests = (0..<30).map { _ in controlRequest() }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for request in requests {
                    group.addTask {
                        let value = try await batcher.read(request, deadline: .now + .seconds(5))
                        #expect(value.rows.first?.directShardID == request.actor.rawValue)
                        #expect(value.rows.first?.directRoomID == request.keys.first?.userID.uuidValue)
                    }
                }
                try await group.waitForAll()
            }
            let batches = await recorder.requests
            #expect(batches.count < requests.count)
            #expect(batches.flatMap { $0 }.count == requests.count)
            #expect(batches.contains { Set($0.map(\.actor)).count > 1 })
            for batch in batches {
                #expect(batch.reduce(0, { $0 + $1.keys.count }) <= 3)
                #expect(try PostgresV2ProfileControlReader.payload(batch).count <= 65_536)
            }
            #expect(await batcher.statistics().waiters == 0)
            await batcher.close()
        } catch { await batcher.close(); throw error }
    }

    @Test("cancelled noncooperative SQL retains capacity and queued callers are bounded")
    func cancellationAndOverload() async throws {
        let gate = ControlBatchGate()
        let batcher = V2ProfileControlBatcher(configuration: .init(maximumKeys: 1, maximumPendingKeys: 1, maximumInFlight: 1, delay: .zero)) { requests, _ in
            await gate.hold()
            return requests.map { .success(controlSnapshot($0)) }
        }
        let first = Task { try await batcher.read(controlRequest(), deadline: .now + .seconds(5)) }
        do {
            try await controlEventually { await gate.arrivals == 1 }
            first.cancel()
            await #expect(throws: CancellationError.self) { _ = try await first.value }
            #expect(await batcher.statistics().inFlightBatches == 1)
            await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) {
                _ = try await batcher.read(controlRequest(), deadline: .now + .seconds(5))
            }
            let state = await batcher.statistics()
            #expect(state.inFlightBatches == 1 && state.pendingKeys == 0 && state.waiters == 0)
            #expect(state.executedBatches == 1 && state.rejected == 1)
            await gate.release(); await batcher.close()
            #expect(await batcher.statistics().inFlightBatches == 0)
        } catch { first.cancel(); await gate.release(); _ = await first.result; await batcher.close(); throw error }
    }

    @Test("queued cancellation does not dispatch; parallel close waits for the actual SQL owner")
    func queuedCancellationAndClose() async throws {
        let gate = ControlBatchGate(), closed = ControlCloseRecorder()
        let batcher = V2ProfileControlBatcher(configuration: .init(maximumKeys: 1, maximumPendingKeys: 1, maximumInFlight: 1, delay: .zero)) { requests, _ in
            await gate.hold()
            return requests.map { .success(controlSnapshot($0)) }
        }
        let first = Task { try await batcher.read(controlRequest(), deadline: .now + .seconds(5)) }
        do {
            try await controlEventually { await gate.arrivals == 1 }
            let pending = Task { try await batcher.read(controlRequest(), deadline: .now + .seconds(5)) }
            try await controlEventually { await batcher.statistics().pendingKeys == 1 }
            pending.cancel()
            await #expect(throws: CancellationError.self) { _ = try await pending.value }
            #expect(await batcher.statistics().pendingKeys == 0)
            let close1 = Task { await batcher.close(); await closed.finish() }
            let close2 = Task { await batcher.close(); await closed.finish() }
            await #expect(throws: V2ProfileControlBatchError.closed) { _ = try await first.value }
            #expect(await closed.count == 0)
            #expect(await batcher.statistics().inFlightBatches == 1)
            await #expect(throws: V2ProfileControlBatchError.closed) {
                _ = try await batcher.read(controlRequest(), deadline: .now + .seconds(5))
            }
            await gate.release(); await close1.value; await close2.value
            #expect(await closed.count == 2)
            #expect(await gate.arrivals == 1)
            #expect(await batcher.statistics().inFlightBatches == 0)
        } catch { first.cancel(); await gate.release(); _ = await first.result; await batcher.close(); throw error }
    }

    @Test("caller deadline expires independently of a noncooperative query")
    func inFlightDeadline() async throws {
        let gate = ControlBatchGate()
        let batcher = V2ProfileControlBatcher(configuration: .init(delay: .zero)) { requests, _ in
            await gate.hold()
            return requests.map { .success(controlSnapshot($0)) }
        }
        let task = Task { try await batcher.read(controlRequest(), deadline: .now + .milliseconds(40)) }
        do {
            try await controlEventually { await gate.arrivals == 1 }
            await #expect(throws: V2ProfileControlBatchError.deadlineExceeded) { _ = try await task.value }
            #expect(await batcher.statistics().inFlightBatches == 1)
            #expect(await batcher.statistics().waiters == 0)
            await gate.release(); await batcher.close()
        } catch { task.cancel(); await gate.release(); _ = await task.result; await batcher.close(); throw error }
    }

    @Test("invalid bytes, expired and precancelled requests consume no query slots")
    func earlyRejection() async throws {
        let batcher = V2ProfileControlBatcher(configuration: .init(maximumBytes: 256)) { requests, _ in
            Issue.record("Invalid input reached SQL")
            return requests.map { .success(controlSnapshot($0)) }
        }
        await #expect(throws: V2ProfileViewReadError.invalidRequest) {
            _ = try await batcher.read(controlRequest(keys: 2), deadline: .now + .seconds(5))
        }
        await #expect(throws: V2ProfileControlBatchError.deadlineExceeded) {
            _ = try await batcher.read(controlRequest(), deadline: .now)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await batcher.read(controlRequest(), deadline: .now + .seconds(5))
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(await batcher.statistics().executedBatches == 0)
        await batcher.close()
    }

    @Test("a malformed result count fails the entire batch and releases capacity")
    func malformedResult() async throws {
        let batcher = V2ProfileControlBatcher(configuration: .init(delay: .zero)) { _, _ in [] }
        for _ in 0..<2 {
            await #expect(throws: V2ProfileControlBatchError.corruptResult) {
                _ = try await batcher.read(controlRequest(), deadline: .now + .seconds(5))
            }
        }
        #expect(await batcher.statistics().executedBatches == 2)
        #expect(await batcher.statistics().inFlightBatches == 0)
        await batcher.close()
    }
}

private func controlRequest(keys: Int = 1) -> V2ProfileControlRequest {
    .init(keys: (0..<keys).map { _ in .init(userID: .init(uuid: UUID()), context: .relationship) },
        actor: .init(uuid: UUID()), device: .init(uuid: UUID()))
}
private func controlSnapshot(_ request: V2ProfileControlRequest) -> V2ProfileControlSnapshot {
    // Markers exercise request demultiplexing; real permissions are covered by
    // the PostgreSQL tests and never use this replacement executor.
    .init(rows: request.keys.map { .init(view: nil, directRoomID: $0.userID.uuidValue, directRouteEpoch: 0,
        directShardID: request.actor.rawValue, relationshipAllowed: false, relationshipUpdatedAt: nil) },
        observedAt: Date(), deviceExpiresAt: Date().addingTimeInterval(300))
}
private func controlEventually(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while .now < deadline {
        if await predicate() { return }
        await Task.yield()
    }
    throw V2ProfileControlBatchError.deadlineExceeded
}
private actor ControlBatchRecorder {
    var requests: [[V2ProfileControlRequest]] = []
    func record(_ values: [V2ProfileControlRequest]) { requests.append(values) }
}
private actor ControlCloseRecorder {
    var count = 0
    func finish() { count += 1 }
}
private actor ControlBatchGate {
    var arrivals = 0
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        arrivals += 1
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
