import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorRuntime

@Suite("Room turns serialize across suspension and preserve cancellation evidence")
struct V2RoomTurnLaneTests {
    @Test("profile cohorts obey target budgets and cannot cross send or write barriers")
    func profileCohortBoundaries() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        var tasks: [Task<Int, any Error>] = []
        do {
            let commands: [Command] = [
                .init(id: 1, send: false, profileTargets: 60), .init(id: 2, send: false, profileTargets: 40),
                .init(id: 3, send: false, profileTargets: 1), .init(id: 4, send: false),
                .init(id: 5, send: false, profileTargets: 1), .init(id: 6, send: true),
                .init(id: 7, send: false, profileTargets: 1), .init(id: 8, send: false, profileTargets: 1)
            ]
            for command in commands {
                tasks.append(fixture.submit(command))
                try await fixture.waitForQueue(tasks.count)
            }
            await fixture.executor.release()
            _ = try await first.value
            for task in tasks { _ = try await task.value }
            #expect(await fixture.executor.starts == [[0], [1, 2], [3], [4], [5], [6], [7, 8]])
            #expect(await fixture.executor.observations().maximumConcurrentTurns == 1)
            try await fixture.waitForBudget(0)
        } catch {
            await fixture.executor.release()
            _ = await first.result
            for task in tasks { _ = await task.result }
            throw error
        }
    }

    @Test("profile cohorts bound encoded bytes and treat invalid costs as barriers")
    func profileCohortByteAndCostLimits() async throws {
        let fixture = try Fixture()
        let oversized = fixture.submit(.init(id: -1, send: false, profileTargets: 1,
                                             padding: String(repeating: "x", count: 64 * 1_024)))
        await expectFailure(.notAccepted(.invalidRequest), from: oversized)
        try await fixture.waitForBudget(0)
        #expect(await fixture.executor.starts.isEmpty)
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        var tasks: [Task<Int, any Error>] = []
        do {
            let commands: [Command] = [
                .init(id: 1, send: false, profileTargets: 1, padding: String(repeating: "x", count: 33_000)),
                .init(id: 2, send: false, profileTargets: 1, padding: String(repeating: "x", count: 33_000)),
                .init(id: 3, send: false, profileTargets: Int.max),
                .init(id: 4, send: false, profileTargets: Int.min),
                .init(id: 5, send: false, profileTargets: 0),
                .init(id: 6, send: false, profileTargets: 1)
            ]
            for command in commands {
                tasks.append(fixture.submit(command))
                try await fixture.waitForQueue(tasks.count)
            }
            await fixture.executor.release()
            _ = try await first.value
            for task in tasks { _ = try await task.value }
            #expect(await fixture.executor.starts == [[0], [1], [2], [3], [4], [5], [6]])
            try await fixture.waitForBudget(0)
        } catch {
            await fixture.executor.release()
            _ = await first.result
            for task in tasks { _ = await task.result }
            throw error
        }
    }

    @Test("cancelling a dispatched profile viewer retains the entire read turn until completion")
    func profileCohortCancellation() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        let a = fixture.submit(.init(id: 1, send: false, hold: true, profileTargets: 1))
        try await fixture.waitForQueue(1)
        let b = fixture.submit(.init(id: 2, send: false, profileTargets: 1))
        try await fixture.waitForQueue(2)
        await fixture.executor.release()
        _ = try await first.value
        await fixture.executor.waitForStarts(2)
        a.cancel()
        await expectFailure(.outcomeUnknown, from: a)
        #expect(await fixture.budget.snapshot().commandCount == 2)
        let write = fixture.submit(.init(id: 3, send: false))
        do {
            try await fixture.waitForQueue(1)
            #expect(await fixture.executor.starts == [[0], [1, 2]])
            await fixture.executor.release()
            #expect(try await b.value == 2)
            #expect(try await write.value == 3)
            try await fixture.waitForBudget(0)
        } catch {
            await fixture.executor.release()
            _ = await b.result; _ = await write.result
            throw error
        }
    }

    @Test("expired queued profile demand is removed and command-count limits still split cohorts")
    func profileCohortDeadlineAndCommandLimit() async throws {
        let fixture = try Fixture(configuration: .init(maximumCommandsPerTurn: 2))
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        let expired = fixture.submit(.init(id: 1, send: false, profileTargets: 1),
                                     deadline: .now + .milliseconds(100))
        await expectFailure(.notAccepted(.deadlineExceeded), from: expired)
        var tasks: [Task<Int, any Error>] = []
        do {
            for id in 2...6 {
                tasks.append(fixture.submit(.init(id: id, send: false, profileTargets: 1)))
                try await fixture.waitForQueue(tasks.count)
            }
            await fixture.executor.release()
            _ = try await first.value
            for task in tasks { _ = try await task.value }
            #expect(await fixture.executor.starts == [[0], [2, 3], [4, 5], [6]])
            try await fixture.waitForBudget(0)
        } catch {
            await fixture.executor.release()
            _ = await first.result
            for task in tasks { _ = await task.result }
            throw error
        }
    }

    @Test("send batches stop at a barrier and never overlap an awaited turn")
    func fifoAndBatching() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        let send1 = fixture.submit(.init(id: 1, send: true))
        try await fixture.waitForQueue(1)
        let send2 = fixture.submit(.init(id: 2, send: true))
        try await fixture.waitForQueue(2)
        let barrier = fixture.submit(.init(id: 3, send: false))
        try await fixture.waitForQueue(3)
        let send3 = fixture.submit(.init(id: 4, send: true))
        try await fixture.waitForQueue(4)
        #expect(await fixture.executor.starts == [[0]])
        await fixture.executor.release()
        #expect(try await first.value == 0)
        #expect(try await send1.value == 1)
        #expect(try await send2.value == 2)
        #expect(try await barrier.value == 3)
        #expect(try await send3.value == 4)
        let observed = await fixture.executor.observations()
        #expect(observed.starts == [[0], [1, 2], [3], [4]])
        #expect(observed.maximumConcurrentTurns == 1)
        #expect(observed.ordinals == [1, 2, 3, 4, 5])
        #expect(observed.expiredBatchDeadlines.count == 2)
        try await fixture.waitForBudget(0)
    }

    @Test("durable send operations batch together but remain separated from legacy sends")
    func durableOperationSendBatchBoundaries() async throws {
        let fixture = try Fixture()
        let hold = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        let first = fixture.submit(.init(id: 1, send: false, operationSend: true))
        try await fixture.waitForQueue(1)
        let second = fixture.submit(.init(id: 2, send: false, operationSend: true))
        try await fixture.waitForQueue(2)
        let legacy = fixture.submit(.init(id: 3, send: true))
        try await fixture.waitForQueue(3)
        let last = fixture.submit(.init(id: 4, send: false, operationSend: true))
        try await fixture.waitForQueue(4)
        await fixture.executor.release()
        _ = try await hold.value
        _ = try await first.value
        _ = try await second.value
        _ = try await legacy.value
        _ = try await last.value
        #expect(await fixture.executor.starts == [[0], [1, 2], [3], [4]])
        try await fixture.waitForBudget(0)
    }

    @Test("a fresh send leaves its collection window to the shared owner batcher")
    func collectionWindowRemainsForOwnerBatcher() async throws {
        let fixture = try Fixture(configuration: .init(batchWaitMilliseconds: 1_000))
        let send = fixture.submit(.init(id: 1, send: true))
        #expect(try await send.value == 1)
        let observed = await fixture.executor.observations()
        #expect(observed.starts == [[1]])
        #expect(observed.expiredBatchDeadlines == [false])
        try await fixture.waitForBudget(0)
    }

    @Test("queued cancellation is definitely unaccepted and frees only its permit")
    func queuedCancellation() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        let cancelled = fixture.submit(.init(id: 1, send: false))
        try await fixture.waitForQueue(1)
        cancelled.cancel()
        await expectFailure(.notAccepted(.cancelled), from: cancelled)
        try await fixture.waitForBudget(1)
        #expect(await fixture.executor.starts == [[0]])
        await fixture.executor.release()
        #expect(try await first.value == 0)
        try await fixture.waitForBudget(0)
    }

    @Test("in-flight cancellation detaches the caller without releasing the turn")
    func inFlightCancellation() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        first.cancel()
        await expectFailure(.outcomeUnknown, from: first)
        #expect(await fixture.budget.snapshot().commandCount == 1)
        let next = fixture.submit(.init(id: 1, send: false))
        try await fixture.waitForQueue(1)
        #expect(await fixture.executor.starts == [[0]])
        await fixture.executor.release()
        #expect(try await next.value == 1)
        #expect(await fixture.executor.observations().maximumConcurrentTurns == 1)
        try await fixture.waitForBudget(0)
    }

    @Test("unknown transaction stops successors and holds capacity until fenced retirement")
    func unknownCompletion() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true, unknown: true))
        await fixture.executor.waitForStarts(1)
        let next = fixture.submit(.init(id: 1, send: false))
        try await fixture.waitForQueue(1)
        await fixture.executor.release()
        await expectFailure(.outcomeUnknown, from: first)
        await expectFailure(.notAccepted(.leaseLost), from: next)
        try await fixture.waitForBudget(1)
        #expect(await fixture.lane.snapshot().phase == .uncertain)
        #expect(await fixture.lane.snapshot().unresolvedCount == 1)
        #expect(await fixture.executor.starts == [[0]])
        // A host invokes this only after database fencing and executor shutdown.
        #expect(await fixture.lane.completeRetirement())
        #expect(await fixture.budget.snapshot().commandCount == 0)
        #expect(await fixture.lane.completeRetirement())
        #expect(await fixture.budget.snapshot().commandCount == 0)
    }

    @Test("drain rejects new calls but completes already admitted work")
    func drainRace() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        let queued = fixture.submit(.init(id: 1, send: false))
        try await fixture.waitForQueue(1)
        await fixture.lane.beginDrain()
        await expectFailure(.notAccepted(.retired), from: fixture.submit(.init(id: 2, send: false)))
        #expect(!(await fixture.lane.completeRetirement()))
        await fixture.executor.release()
        #expect(try await first.value == 0)
        #expect(try await queued.value == 1)
        try await fixture.waitForBudget(0)
        #expect(await fixture.lane.snapshot().isIdle)
    }

    @Test("deadline before dispatch differs from timeout while SQL is running")
    func deadlines() async throws {
        let fixture = try Fixture()
        let expired = fixture.submit(.init(id: 0, send: false), deadline: .now - .seconds(1))
        await expectFailure(.notAccepted(.deadlineExceeded), from: expired)
        let executing = fixture.submit(.init(id: 1, send: false, hold: true), deadline: .now + .milliseconds(100))
        await fixture.executor.waitForStarts(1)
        await expectFailure(.outcomeUnknown, from: executing)
        #expect(await fixture.budget.snapshot().commandCount == 1)
        #expect(!(await fixture.lane.completeRetirement()))
        await fixture.executor.release()
        try await fixture.waitForBudget(0)
    }

    @Test("invalid encoded request is rejected without consuming capacity")
    func invalidWire() async throws {
        let fixture = try Fixture()
        do {
            _ = try await fixture.lane.submit(encodedRequest: Data("{}".utf8), deadline: .now + .seconds(1))
            Issue.record("invalid request unexpectedly succeeded")
        } catch {
            #expect(error as? V2RoomCallFailure == .notAccepted(.invalidRequest))
        }
        #expect(await fixture.budget.snapshot().commandCount == 0)
        #expect(await fixture.executor.starts.isEmpty)
    }

    @Test("a reservation is a FIFO barrier and late completion cannot unlock another grant")
    func reservationBarrier() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        let reserved = Task { try await fixture.lane.reserve(requestID: UUID(), deadline: .now + .seconds(3)) }
        try await fixture.waitForQueue(1)
        let next = fixture.submit(.init(id: 1, send: true))
        try await fixture.waitForQueue(2)
        await fixture.executor.release()
        #expect(try await first.value == 0)
        let grant = try await reserved.value
        #expect(await fixture.lane.snapshot().hasReservation)
        #expect(await fixture.executor.starts == [[0]])
        try await fixture.lane.markReservationDispatched(grant)
        #expect(!(await fixture.lane.abortReservation(grant)))
        #expect(await fixture.lane.finishReservation(grant, completion: .committed))
        #expect(try await next.value == 1)
        try await fixture.waitForBudget(0)
        let successor = try await fixture.lane.reserve(requestID: UUID(), deadline: .now + .seconds(3))
        #expect(!(await fixture.lane.finishReservation(grant, completion: .committed)))
        #expect(await fixture.lane.snapshot().hasReservation)
        #expect(await fixture.lane.abortReservation(successor))
        try await fixture.waitForBudget(0)
    }

    @Test("queued reservation cancellation releases its host capacity without cancelling a turn")
    func reservationCancellation() async throws {
        let fixture = try Fixture()
        let first = fixture.submit(.init(id: 0, send: false, hold: true))
        await fixture.executor.waitForStarts(1)
        let reserved = Task { try await fixture.lane.reserve(requestID: UUID(), deadline: .now + .seconds(3)) }
        try await fixture.waitForQueue(1)
        #expect(await fixture.budget.snapshot().reservationCount == 1)
        reserved.cancel()
        await expectFailure(.notAccepted(.cancelled), from: reserved)
        try await fixture.waitForBudget(1)
        #expect(await fixture.budget.snapshot().reservationCount == 0)
        await fixture.executor.release()
        #expect(try await first.value == 0)
        try await fixture.waitForBudget(0)
    }

    @Test("reservation expiry retires the epoch rather than releasing the next command")
    func reservationExpiry() async throws {
        let fixture = try Fixture()
        let grant = try await fixture.lane.reserve(requestID: UUID(), deadline: .now + .milliseconds(100))
        try await fixture.lane.markReservationDispatched(grant)
        let next = fixture.submit(.init(id: 1, send: false))
        await expectFailure(.notAccepted(.leaseLost), from: next)
        #expect(await fixture.lane.snapshot().phase == .uncertain)
        #expect(await fixture.lane.snapshot().unresolvedCount == 1)
        #expect(await fixture.budget.snapshot().reservationCount == 1)
        #expect(await fixture.executor.starts.isEmpty)
        #expect(!(await fixture.lane.finishReservation(grant, completion: .committed)))
        #expect(await fixture.lane.completeRetirement())
        #expect(await fixture.budget.snapshot().reservationCount == 0)
    }

    @Test("unknown reservation completion stops queued work and rejects stale dispatch")
    func reservationUnknown() async throws {
        let fixture = try Fixture()
        let grant = try await fixture.lane.reserve(requestID: UUID(), deadline: .now + .seconds(3))
        try await fixture.lane.markReservationDispatched(grant)
        let next = fixture.submit(.init(id: 1, send: false))
        try await fixture.waitForQueue(1)
        #expect(await fixture.lane.finishReservation(grant, completion: .outcomeUnknown))
        await expectFailure(.notAccepted(.leaseLost), from: next)
        do {
            try await fixture.lane.markReservationDispatched(grant)
            Issue.record("stale grant was acknowledged")
        } catch { #expect(error as? V2RoomCallFailure == .notAccepted(.staleActivation)) }
        #expect(await fixture.lane.completeRetirement())
        #expect(await fixture.budget.snapshot().commandCount == 0)
    }

    @Test("reservation capacity is shared across every room on the host")
    func reservationCapacity() async throws {
        let config = try V2RoomRuntimeConfiguration(maximumConcurrentReservations: 1)
        let budget = V2RoomCommandBudget(configuration: config)
        let first = try Fixture(configuration: config, sharedBudget: budget)
        let second = try Fixture(configuration: config, sharedBudget: budget)
        let grant = try await first.lane.reserve(requestID: UUID(), deadline: .now + .seconds(3))
        let rejected = Task { try await second.lane.reserve(requestID: UUID(), deadline: .now + .seconds(3)) }
        await expectFailure(.notAccepted(.overloaded), from: rejected)
        #expect(await budget.snapshot().reservationCount == 1)
        #expect(await first.lane.abortReservation(grant))
        let next = try await second.lane.reserve(requestID: UUID(), deadline: .now + .seconds(3))
        #expect(await second.lane.abortReservation(next))
        #expect(await budget.snapshot().commandCount == 0)
    }

    private func expectFailure<Value: Sendable>(_ expected: V2RoomCallFailure, from task: Task<Value, any Error>) async {
        do {
            _ = try await task.value
            Issue.record("request unexpectedly succeeded")
        } catch { #expect(error as? V2RoomCallFailure == expected) }
    }

    private struct Command: Codable, Sendable {
        let id: Int
        let send: Bool
        var operationSend = false
        var hold = false
        var unknown = false
        var profileTargets: Int? = nil
        var padding = ""
    }

    private struct Fixture {
        let budget: V2RoomCommandBudget
        let lane: V2RoomTurnLane<Command, Int>
        let executor: Executor

        init(configuration: V2RoomRuntimeConfiguration? = nil, sharedBudget: V2RoomCommandBudget? = nil) throws {
            let config = try configuration ?? V2RoomRuntimeConfiguration()
            budget = sharedBudget ?? .init(configuration: config)
            executor = Executor()
            let executor = executor
            lane = .init(
                token: .init(
                    roomID: RoomID(uuid: UUID()), owner: try .init(shardID: "test", epoch: 0),
                    activationEpoch: try .init(1),
                    host: .init(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
                ),
                configuration: config, budget: budget,
                classify: { command in
                    if command.operationSend { return .sendOperation }
                    if command.send { return .send }
                    if let count = command.profileTargets { return .profileVisibility(targetCount: count) }
                    return .barrier
                },
                execute: { await executor.run($0) }, onUncertain: { _ in }
            )
        }

        func submit(_ command: Command, deadline: ContinuousClock.Instant = .now + .seconds(5)) -> Task<Int, any Error> {
            Task { try await lane.submit(encodedRequest: JSONEncoder().encode(command), deadline: deadline) }
        }

        func waitForQueue(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while await lane.snapshot().queuedCount != count {
                guard ContinuousClock.now < deadline else { throw WaitFailure.phaseNotReached }
                await Task.yield()
            }
        }

        func waitForBudget(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while await budget.snapshot().commandCount != count {
                guard ContinuousClock.now < deadline else { throw WaitFailure.phaseNotReached }
                await Task.yield()
            }
        }
    }

    private enum WaitFailure: Error { case phaseNotReached }

    private actor Executor {
        var starts: [[Int]] = []
        private var concurrentTurns = 0
        private var maximumConcurrentTurns = 0
        private var ordinals: [UInt64] = []
        private var expiredBatchDeadlines: [Bool] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func run(_ turn: V2RoomTurn<Command>) async -> V2RoomTransactionCompletion<[Int]> {
            concurrentTurns += 1
            maximumConcurrentTurns = max(maximumConcurrentTurns, concurrentTurns)
            starts.append(turn.items.map(\.request.id))
            ordinals.append(contentsOf: turn.items.map(\.ordinal))
            if turn.items.first?.request.send == true {
                expiredBatchDeadlines.append(turn.context.batchDeadline <= ContinuousClock.now)
            }
            let ready = startWaiters.filter { $0.0 <= starts.count }
            startWaiters.removeAll { $0.0 <= starts.count }
            // Install the hold before waking phase observers.
            if turn.items.contains(where: { $0.request.hold }) {
                await withCheckedContinuation { continuation in
                    gate = continuation
                    for (_, waiter) in ready { waiter.resume() }
                }
            } else {
                for (_, waiter) in ready { waiter.resume() }
            }
            concurrentTurns -= 1
            return turn.items.contains(where: { $0.request.unknown })
                ? .outcomeUnknown : .committed(turn.items.map(\.request.id))
        }

        func waitForStarts(_ count: Int) async {
            if starts.count >= count { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        func release() {
            let held = gate
            gate = nil
            held?.resume()
        }

        func observations() -> (starts: [[Int]], maximumConcurrentTurns: Int, ordinals: [UInt64], expiredBatchDeadlines: [Bool]) {
            (starts, maximumConcurrentTurns, ordinals, expiredBatchDeadlines)
        }
    }
}
