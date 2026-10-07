@testable import IMV2ServerGateway
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Core
import Foundation
import Synchronization
import Testing

struct V2RecoveryInterestReleaseExecutorTests {
    @Test("held activations retain tickets without occupying eligible cleanup workers")
    func heldActivationsDoNotBlockEligibleRelease() async throws {
        let broker = ReleaseEligibilityBroker()
        let shared = V2SharedGroupEventWakeInterests(underlying: broker)
        let owner = V2RecoveryInterestReleaseExecutor(maximumRetained: 5, maximumActual: 4)
        let tickets = (0..<5).map { _ in
            V2RecoveryInterestTicket(key: .init(connection: UUID(), kind: .roomEvents,
                id: UUID().uuidString.lowercased()), lifecycle: 1, generation: 1, interests: shared)
        }
        try await shared.activate([tickets[4].activation])
        await broker.holdActivations()
        var roots: [Task<Void, Error>] = []
        for ticket in tickets.prefix(4) {
            #expect(ticket.beginActivation())
            roots.append(Task {
                try await shared.activate([ticket.activation])
                ticket.endActivation(succeeded: true)
                await owner.activationSettled(ticket: ticket)
            })
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while await broker.activationsStarted < 4 {
            guard ContinuousClock.now < deadline else { throw ReleaseExecutorTestFailure.timeout }
            await Task.yield()
        }
        for ticket in tickets.prefix(4) {
            let accepted = await owner.trySubmit(ticket: ticket)
            #expect(accepted)
        }
        let held = await owner.snapshot()
        #expect(held.retained == 4 && held.waitingActivations == 4 && held.actual == 0)
        let accepted = await owner.trySubmit(ticket: tickets[4])
        #expect(accepted)
        let eligibleRoom = try RoomID(tickets[4].key.id)
        while !(await broker.released.contains(eligibleRoom)) {
            guard ContinuousClock.now < deadline else { throw ReleaseExecutorTestFailure.timeout }
            await Task.yield()
        }
        while true {
            let state = await owner.snapshot()
            if state.retained == 4 && state.actual == 0 { break }
            guard ContinuousClock.now < deadline else { throw ReleaseExecutorTestFailure.timeout }
            await Task.yield()
        }
        let afterEligible = await owner.snapshot()
        #expect(afterEligible.waitingActivations == 4)
        let finished = ReleaseExecutorSignal()
        let drain = Task {
            await owner.finish()
            let releases = await broker.released.count
            #expect(releases == 5) // Actual activation and cleanup must both settle.
            finished.mark()
        }
        #expect(!finished.value)
        await broker.releaseActivations()
        for root in roots { try await root.value }
        // Late duplicate notifications cannot release a different generation.
        await owner.activationSettled(tickets: tickets)
        await drain.value
        let released = await broker.released, empty = await owner.snapshot()
        #expect(released.count == 5 && finished.value)
        #expect(empty.retained == 0 && empty.actual == 0 && empty.waitingActivations == 0)
        await shared.shutdown()
    }

    @Test("Release admission and shutdown retain bounded actual cleanup ownership")
    func boundedActualReleaseAndDrain() async throws {
        let broker = ReleaseExecutorBroker()
        let shared = V2SharedGroupEventWakeInterests(underlying: broker)
        let owner = V2RecoveryInterestReleaseExecutor(maximumRetained: 2, maximumActual: 1)
        let tickets = (0..<3).map { _ in
            V2RecoveryInterestTicket(key: .init(connection: UUID(), kind: .roomEvents,
                id: UUID().uuidString.lowercased()), lifecycle: 1, generation: 1, interests: shared)
        }
        for ticket in tickets { try await shared.activate([ticket.activation]) }
        let first = await owner.trySubmit(ticket: tickets[0])
        #expect(first)
        let deadline = ContinuousClock.now + .seconds(3)
        while await broker.started == 0 {
            guard ContinuousClock.now < deadline else { throw ReleaseExecutorTestFailure.timeout }
            await Task.yield()
        }
        let second = await owner.trySubmit(ticket: tickets[1])
        #expect(second)
        let admitted = ReleaseExecutorSignal()
        let refused = await owner.trySubmit(ticket: tickets[2])
        #expect(!refused)
        // The coordinator owns this refused capability; only one pump waits.
        let pending = Task {
            await owner.waitForCapacity()
            let accepted = await owner.trySubmit(ticket: tickets[2])
            #expect(accepted)
            admitted.mark()
        }
        while !(await owner.snapshot().capacityWaiter) {
            guard ContinuousClock.now < deadline else { throw ReleaseExecutorTestFailure.timeout }
            await Task.yield()
        }
        let full = await owner.snapshot()
        #expect(full.retained == 2 && full.actual == 1 && full.pendingAdmissions == 0 && full.capacityWaiter)
        #expect(tickets.allSatisfy { !$0.isActive })
        #expect(!admitted.value)
        // A duplicate of the actual ticket cannot create overflow ownership.
        let duplicate = await owner.trySubmit(ticket: tickets[0])
        #expect(duplicate)
        let finished = ReleaseExecutorSignal(), joining = ReleaseExecutorSignal()
        let drain = Task {
            joining.mark()
            await pending.value // upstream cleanup ownership must join first.
            await owner.finish()
            finished.mark()
        }
        while !joining.value { await Task.yield() }
        #expect(!finished.value)
        await broker.open()
        await pending.value
        await drain.value
        let empty = await owner.snapshot(), releases = await broker.started
        #expect(admitted.value && finished.value)
        #expect(empty.retained == 0 && empty.actual == 0 && empty.pendingAdmissions == 0)
        #expect(releases == 3)
        await shared.shutdown()
    }
}

private enum ReleaseExecutorTestFailure: Error { case timeout }
private final class ReleaseExecutorSignal: Sendable {
    private let state = Mutex(false)
    var value: Bool { state.withLock { $0 } }
    func mark() { state.withLock { $0 = true } }
}
private actor ReleaseExecutorBroker: V2GroupEventWakeInterestManaging {
    private(set) var started = 0
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func activate(roomID: RoomID) async throws {}
    func deactivate(roomID: RoomID) async {
        started += 1
        if !opened { await withCheckedContinuation { waiting.append($0) } }
    }
    func open() {
        opened = true
        let current = waiting; waiting.removeAll()
        for continuation in current { continuation.resume() }
    }
}

private actor ReleaseEligibilityBroker: V2GroupEventWakeInterestManaging {
    private var holding = false
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var activationsStarted = 0
    private(set) var released: Set<RoomID> = []
    func holdActivations() { holding = true }
    func activate(roomID: RoomID) async throws {
        if holding {
            activationsStarted += 1
            await withCheckedContinuation { gates.append($0) }
        }
    }
    func deactivate(roomID: RoomID) async { released.insert(roomID) }
    func releaseActivations() {
        holding = false
        let current = gates; gates.removeAll()
        for gate in current { gate.resume() }
    }
}
