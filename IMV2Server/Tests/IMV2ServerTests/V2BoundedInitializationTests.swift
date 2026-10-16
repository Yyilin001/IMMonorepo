@testable import IMV2ServerApplication
import Foundation
import Testing

@Suite("Bounded initialization ownership", .timeLimit(.minutes(1)))
struct V2BoundedInitializationTests {
    @Test("a control change arriving during the finishing step is retained by the same owned job")
    func finishingStepResignal() async throws {
        let owner = V2BoundedInitialization(maximumConcurrent: 1, maximumJobs: 1)
        let barrier = InitializationBarrier(), probe = InitializationStepProbe(), id = UUID()
        let first = try await owner.submit(id: id) {
            let step = await probe.record("work")
            if step == 1 { await barrier.hold() }
            return .finished
        }
        await barrier.waitForStarts(1)
        let second = try await owner.submit(id: id, repeatExisting: true) {
            Issue.record("duplicate account replaced its actual operation"); return .finished
        }
        await barrier.release()
        try await first.wait(); try await second.wait()
        #expect(await probe.order == ["work", "work"])
        #expect(await owner.snapshot.jobs == 0)
        await owner.shutdown()
    }
    @Test("one thousand queued accounts own only four actual workers and queued cancellation starts no work")
    func boundedWorkers() async throws {
        let owner = V2BoundedInitialization(maximumConcurrent: 4, maximumJobs: 1000)
        let barrier = InitializationBarrier()
        var tickets: [V2BoundedInitialization.Ticket] = []
        for _ in 0..<1000 {
            tickets.append(try await owner.submit(id: UUID()) {
                await barrier.hold(); return .finished
            })
        }
        await barrier.waitForStarts(4)
        let pending = await owner.snapshot
        #expect(pending.active == 4 && pending.ready == 996 && pending.jobs == 1000)
        await tickets.last?.cancelAndDrain()
        #expect(await owner.snapshot.ready == 995)
        #expect(await barrier.started == 4)
        await barrier.release()
        for ticket in tickets.dropLast() { try await ticket.wait() }
        #expect(await barrier.started == 999)
        #expect(await owner.snapshot.jobs == 0)
        await owner.shutdown()
    }
    @Test("paged steps yield to another account before taking their next turn")
    func stepFairness() async throws {
        let owner = V2BoundedInitialization(maximumConcurrent: 1, maximumJobs: 2)
        let barrier = InitializationBarrier(), probe = InitializationStepProbe()
        let first = try await owner.submit(id: UUID()) {
            let step = await probe.record("first")
            if step == 1 { await barrier.hold(); return .again(at: .now) }
            return .finished
        }
        await barrier.waitForStarts(1)
        let second = try await owner.submit(id: UUID()) {
            _ = await probe.record("second"); return .finished
        }
        await barrier.release()
        try await first.wait(); try await second.wait()
        #expect(await probe.order == ["first", "second", "first"])
        await owner.shutdown()
    }
    @Test("shutdown waits for actual cancelled work without releasing its execution slot early")
    func shutdownDrainsActualWork() async throws {
        let owner = V2BoundedInitialization(maximumConcurrent: 1, maximumJobs: 2)
        let barrier = InitializationBarrier()
        let first = try await owner.submit(id: UUID()) {
            await barrier.hold(); return .finished
        }
        await barrier.waitForStarts(1)
        let queued = try await owner.submit(id: UUID()) { Issue.record("closed queued work executed"); return .finished }
        let stop = Task { await owner.shutdown() }
        // Queued work settles before the active operation is allowed to return.
        do { try await queued.wait(); Issue.record("shutdown must cancel queued work") }
        catch { #expect(error is CancellationError) }
        #expect(await owner.snapshot.active == 1)
        stop.cancel()
        await barrier.release()
        await stop.value
        do { try await first.wait(); Issue.record("active cancellation must settle as cancelled") }
        catch { #expect(error is CancellationError) }
        #expect(await owner.snapshot.jobs == 0)
    }
}
private actor InitializationBarrier {
    private(set) var started = 0
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func hold() async {
        started += 1
        let ready = observers.filter { $0.0 <= started }; observers.removeAll { $0.0 <= started }
        for (_, waiter) in ready { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { held.append($0) }
    }
    func waitForStarts(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release() {
        released = true
        let waiters = held; held.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
private actor InitializationStepProbe {
    private(set) var order: [String] = []
    func record(_ value: String) -> Int { order.append(value); return order.count }
}
