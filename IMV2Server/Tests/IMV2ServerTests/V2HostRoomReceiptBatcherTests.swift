import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
@testable import IMV2Server
import Testing

@Suite("Host room receipt batching")
struct V2HostRoomReceiptBatcherTests {
    @Test("two granted rooms share one fenced batch and the earliest SQL deadline")
    func batchesGrantedRooms() async throws {
        let tokens = try [makeToken(), makeToken()]
        let observed = Mutex<[(Int, ContinuousClock.Instant?, [Date])]>([])
        let batcher = V2HostRoomReceiptBatcher(configuration: configuration(size: 2)) { batch, _, ingressTimes in
            observed.withLock { $0.append((batch.requests.count, V2RoomSQLDeadline.current, ingressTimes)) }
            return .init(results: batch.requests.map { _ in .success(.idempotencyConflict) })
        }
        let early = ContinuousClock.now + .seconds(2)
        let late = early + .seconds(2)
        let first = Task { try await batcher.record(try makeTurn(tokens[0], deadline: early)) }
        try await waitPending(batcher, count: 1)
        let second = Task { try await V2RoomSQLDeadline.withSelectedDeadline(late + .seconds(5)) {
            try await batcher.record(try makeTurn(tokens[1], deadline: late))
        } }
        #expect(try await first.value == .record(.idempotencyConflict))
        #expect(try await second.value == .record(.idempotencyConflict))
        #expect(observed.withLock { $0 }.count == 1)
        #expect(observed.withLock { $0 }[0].0 == 2)
        #expect(observed.withLock { $0 }[0].1 == early)
        #expect(observed.withLock { $0 }[0].2 == Array(repeating: Date(timeIntervalSince1970: 1_750_000_000), count: 2))
        #expect(await batcher.pendingCount == 0)
        #expect(await batcher.inFlightBatchCount == 0)
        let metrics = await batcher.snapshot()
        #expect(metrics.completedBatches == 1)
        #expect(metrics.completedRequests == 2)
        #expect(metrics.maximumObservedBatchSize == 2)
    }

    @Test("owner change fails only its stale item; a sibling domain error stays typed")
    func isolatesPerItemFailures() async throws {
        let tokens = try [makeToken(), makeToken()]
        let batcher = V2HostRoomReceiptBatcher(configuration: configuration(size: 2)) { batch, _, _ in
            #expect(batch.requests.count == 2)
            return .init(results: [.failure(.ownerChanged), .failure(.roomSequenceNotFound)])
        }
        let first = Task { try await batcher.record(try makeTurn(tokens[0])) }
        try await waitPending(batcher, count: 1)
        let second = Task { try await batcher.record(try makeTurn(tokens[1])) }
        await #expect(throws: V2RoomActivationLeaseError.activationChanged) { try await first.value }
        #expect(try await second.value == .recordFailure(.store(.roomSequenceNotFound)))
    }

    @Test("pending cancellation releases its slot; dispatched cancellation stays tracked with one DB permit")
    func cancellationAndAdmission() async throws {
        let firstToken = try makeToken()
        let cancelled = V2HostRoomReceiptBatcher(configuration: configuration(size: 2)) { _, _, _ in
            Issue.record("cancelled pending item must not execute")
            return .init(results: [])
        }
        let pendingTask = Task { try await cancelled.record(try makeTurn(firstToken)) }
        try await waitPending(cancelled, count: 1)
        pendingTask.cancel()
        await #expect(throws: V2RoomCallFailure.notAccepted(.cancelled)) { try await pendingTask.value }
        #expect(await cancelled.pendingCount == 0)
        #expect((await cancelled.snapshot()).cancelledPendingRequests == 1)

        let gate = ReceiptBatchGate()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
            maximumInteractiveReadQueued: 1, maximumSyncQueued: 1,
            timeout: .seconds(2)))
        let batcher = V2HostRoomReceiptBatcher(configuration: configuration(size: 2),
            databaseWorkAdmission: admission) { batch, _, _ in
            await gate.enter()
            return .init(results: batch.requests.map { _ in .success(.idempotencyConflict) })
        }
        let tokens = try [makeToken(), makeToken()]
        let first = Task { try await batcher.record(try makeTurn(tokens[0])) }
        try await waitPending(batcher, count: 1)
        let second = Task { try await batcher.record(try makeTurn(tokens[1])) }
        try await gate.waitForEntry()
        #expect(await batcher.inFlightBatchCount == 1)
        #expect((await admission.snapshot()).foregroundWrite.inFlight == 1)
        first.cancel()
        #expect(await batcher.inFlightBatchCount == 1)
        await gate.release()
        #expect(try await first.value == .record(.idempotencyConflict))
        #expect(try await second.value == .record(.idempotencyConflict))
        #expect((await admission.snapshot()).foregroundWrite.inFlight == 0)
        #expect(await batcher.inFlightBatchCount == 0)
        #expect((await batcher.snapshot()).completedBatches == 1)
    }

    @Test("expired pending turns do not reach the executor")
    func expiredPending() async throws {
        let batcher = V2HostRoomReceiptBatcher(configuration: configuration(size: 2)) { _, _, _ in
            Issue.record("expired pending item reached executor")
            return .init(results: [])
        }
        let token = try makeToken()
        let deadline = ContinuousClock.now + .milliseconds(2)
        await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
            try await batcher.record(try makeTurn(token, deadline: deadline))
        }
        #expect(await batcher.pendingCount == 0)
        #expect(await batcher.inFlightBatchCount == 0)
    }

    @Test("queue-full rejection and completed work have distinct metrics")
    func queueFullMetrics() async throws {
        let gate = ReceiptBatchGate()
        let batcher = V2HostRoomReceiptBatcher(configuration: .init(
            maximumBatchSize: 2, maximumDelay: .milliseconds(20),
            maximumInFlightBatches: 1, maximumPendingRequests: 2)) { batch, _, _ in
            await gate.enter()
            return .init(results: batch.requests.map { _ in .success(.idempotencyConflict) })
        }
        let tokens = try (0..<5).map { _ in try makeToken() }
        let first = Task { try await batcher.record(try makeTurn(tokens[0])) }
        try await waitPending(batcher, count: 1)
        let second = Task { try await batcher.record(try makeTurn(tokens[1])) }
        try await gate.waitForEntry()
        let third = Task { try await batcher.record(try makeTurn(tokens[2])) }
        try await waitPending(batcher, count: 1)
        let fourth = Task { try await batcher.record(try makeTurn(tokens[3])) }
        try await waitPending(batcher, count: 2)
        await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try await batcher.record(try makeTurn(tokens[4]))
        }
        let active = await batcher.snapshot()
        #expect(active.pendingRequests == 2)
        #expect(active.inFlightBatches == 1)
        #expect(active.queueFullRejections == 1)
        #expect(active.completedBatches == 0)
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        _ = try await third.value
        _ = try await fourth.value
        let done = await batcher.snapshot()
        #expect(done.pendingRequests == 0)
        #expect(done.inFlightBatches == 0)
        #expect(done.completedBatches == 2)
        #expect(done.completedRequests == 4)
        #expect(done.queueFullRejections == 1)
    }

    @Test("a batch execution error cannot claim every item rolled back")
    func partialExecutionIsUnknown() async throws {
        let batcher = V2HostRoomReceiptBatcher(configuration: configuration(size: 2)) { _, _, _ in
            throw V2RoomCallFailure.rolledBack(.unavailable)
        }
        let tokens = try [makeToken(), makeToken()]
        let first = Task { try await batcher.record(try makeTurn(tokens[0])) }
        try await waitPending(batcher, count: 1)
        let second = Task { try await batcher.record(try makeTurn(tokens[1])) }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await first.value }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await second.value }
    }

    @Test("pending deadline expires while every batch slot is in flight")
    func deadlineWhileAtCapacity() async throws {
        let gate = ReceiptBatchGate()
        let batcher = V2HostRoomReceiptBatcher(configuration: configuration(size: 2)) { batch, _, _ in
            await gate.enter()
            return .init(results: batch.requests.map { _ in .success(.idempotencyConflict) })
        }
        let tokens = try [makeToken(), makeToken(), makeToken()]
        let first = Task { try await batcher.record(try makeTurn(tokens[0])) }
        try await waitPending(batcher, count: 1)
        let second = Task { try await batcher.record(try makeTurn(tokens[1])) }
        try await gate.waitForEntry()
        let thirdDeadline = ContinuousClock.now + .milliseconds(10)
        await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
            try await batcher.record(try makeTurn(tokens[2], deadline: thirdDeadline))
        }
        #expect(await batcher.inFlightBatchCount == 1)
        #expect(await batcher.pendingCount == 0)
        await gate.release()
        #expect(try await first.value == .record(.idempotencyConflict))
        #expect(try await second.value == .record(.idempotencyConflict))
    }

    private func configuration(size: Int) -> V2ReadReceiptBatcher.Configuration {
        .init(maximumBatchSize: size, maximumDelay: .milliseconds(20),
              maximumInFlightBatches: 1, maximumPendingRequests: 4)
    }

    private func makeToken() throws -> V2RoomActivationToken {
        .init(roomID: .init(uuid: UUID()), owner: try .init(shardID: "room-a", epoch: 0),
              activationEpoch: try .init(1),
              host: .init(hostID: try .init("receipt-host"), incarnationID: UUID()))
    }

    private func makeTurn(_ token: V2RoomActivationToken,
                          deadline: ContinuousClock.Instant = .now + .seconds(2)) throws -> V2GrantedRoomReceiptTurn {
        let command = try V2ActorRecordReadReceiptWire(roomID: token.roomID,
            actorUserID: .init(uuid: UUID()), operationID: .init(uuid: UUID()),
            readThroughRoomSequence: 1)
        return .init(command: .record(command), token: token,
            batchDeadline: .now + .milliseconds(30), callDeadline: deadline,
            ingressAt: Date(timeIntervalSince1970: 1_750_000_000))
    }

    private func waitPending(_ batcher: V2HostRoomReceiptBatcher, count: Int) async throws {
        for _ in 0..<200 {
            if await batcher.pendingCount == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("batcher did not reach expected pending count")
    }
}

private actor ReceiptBatchGate {
    private var entered = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        if released { return }
        await withCheckedContinuation { held = $0 }
    }

    func waitForEntry() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("batch did not enter execution")
    }

    func release() { released = true; held?.resume(); held = nil }
}
