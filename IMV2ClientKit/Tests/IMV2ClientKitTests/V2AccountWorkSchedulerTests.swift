import XCTest
import Synchronization
@testable import IMV2ClientKit

final class V2AccountWorkSchedulerTests: XCTestCase, @unchecked Sendable {
    func testControlWaitersHaveBoundedCapacityIndependentOfFullOrdinaryQueue() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1, waiterLimit: 1, controlWaiterLimit: 1))
        let ordinary = try await scheduler.acquire(.init(service: "api"))
        let control = try await scheduler.acquire(.init(service: "authentication", kind: .authentication))
        let ordinaryQueue = Task { try await scheduler.acquire(.init(service: "api")) }
        try await awaitWaiting(1, on: scheduler)
        let controlQueue = Task { try await scheduler.acquire(.init(service: "tcpControl", priority: .critical, kind: .authentication)) }
        try await awaitWaiting(2, on: scheduler)
        do { _ = try await scheduler.acquire(.init(service: "api")); XCTFail("ordinary queue borrowed control capacity") }
        catch V2AccountWorkScheduler.AdmissionError.overloaded {}
        do { _ = try await scheduler.acquire(.init(service: "tcpControl", kind: .authentication)); XCTFail("control queue exceeded its bound") }
        catch V2AccountWorkScheduler.AdmissionError.overloaded {}
        _ = await scheduler.release(control)
        let nextControl = try await controlQueue.value
        let state = await scheduler.snapshot()
        XCTAssertEqual(state.active, 2)
        XCTAssertEqual(state.waiting, 1)
        // The ordinary request is still blocked by its original I/O, while the
        // acknowledgement has obtained the reserved execution slot.
        _ = await scheduler.release(nextControl)
        _ = await scheduler.release(ordinary)
        _ = await scheduler.release(try await ordinaryQueue.value)
        await scheduler.closeAndDrain()
    }

    func testControlWaiterCancellationDeadlineAndCloseDoNotLeakReservation() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(waiterLimit: 0, controlWaiterLimit: 1))
        let context = V2NetworkWorkContext(service: "control", priority: .critical, kind: .authentication)
        let running = try await scheduler.acquire(context)
        let cancelled = Task { try await scheduler.acquire(context) }
        try await awaitWaiting(1, on: scheduler)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("cancelled waiter survived") } catch is CancellationError {}
        do {
            _ = try await scheduler.acquire(context, deadline: .now.advanced(by: .milliseconds(20)))
            XCTFail("expired waiter survived")
        } catch V2AccountWorkScheduler.AdmissionError.deadlineExceeded {}
        let queued = Task { try await scheduler.acquire(context) }
        try await awaitWaiting(1, on: scheduler)
        await scheduler.beginClose()
        do { _ = try await queued.value; XCTFail("closed waiter survived") }
        catch V2AccountWorkScheduler.AdmissionError.closed {}
        let state = await scheduler.snapshot()
        XCTAssertEqual(state.waiting, 0)
        XCTAssertEqual(state.active, 1)
        _ = await scheduler.release(running)
        await scheduler.closeAndDrain()
    }

    func testRestoredSystemTransfersBlockNewBytesUntilActualDrain() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(byteTransferLimit: 1))
        let context = V2NetworkWorkContext(service: "objects", kind: .byteTransfer, isRetry: true)
        let id = UUID()
        let first = try await scheduler.adoptExistingByteTransfer(id: id, context: context)
        let duplicate = try await scheduler.adoptExistingByteTransfer(id: id, context: context)
        XCTAssertEqual(first, duplicate)
        let second = try await scheduler.adoptExistingByteTransfer(id: UUID(), context: context)
        let queued = Task { try await scheduler.acquire(context) }
        try await awaitWaiting(1, on: scheduler)
        let ordinary = try await scheduler.acquire(.init(service: "api"))
        _ = await scheduler.release(ordinary)
        _ = await scheduler.release(first)
        let halfDrained = await scheduler.snapshot()
        XCTAssertEqual(halfDrained.active, 1); XCTAssertEqual(halfDrained.waiting, 1)
        _ = await scheduler.release(second)
        let resumed = try await queued.value
        _ = await scheduler.release(resumed)
        // Adoption consumed no retry tokens: only the queued attempt used one.
        for _ in 0..<4 {
            let permit = try await scheduler.acquire(context)
            _ = await scheduler.release(permit)
        }
        do {
            _ = try await scheduler.acquire(context, deadline: .now.advanced(by: .milliseconds(20)))
            XCTFail("Expected exhausted quota")
        } catch V2AccountWorkScheduler.AdmissionError.deadlineExceeded {}
        await scheduler.closeAndDrain()
    }
    func testAdoptionDuringCooldownPreservesIdentityAndCloseDrain() async throws {
        let scheduler = V2AccountWorkScheduler()
        let initial = try await scheduler.acquire(.init(service: "objects"))
        await scheduler.coolDown(service: "objects", for: 100)
        _ = await scheduler.release(initial)
        let id = UUID()
        let context = V2NetworkWorkContext(service: "objects", kind: .byteTransfer)
        let restored = try await scheduler.adoptExistingByteTransfer(id: id, context: context)
        do {
            _ = try await scheduler.adoptExistingByteTransfer(id: id, context: .init(service: "other", kind: .byteTransfer))
            XCTFail("Expected identity mismatch")
        } catch V2AccountWorkScheduler.AdmissionError.invalidAdoption {}
        do {
            _ = try await scheduler.adoptExistingByteTransfer(id: UUID(), context: .init(service: "api"))
            XCTFail("Expected byte transfer requirement")
        } catch V2AccountWorkScheduler.AdmissionError.invalidAdoption {}
        await scheduler.beginClose()
        do {
            _ = try await scheduler.adoptExistingByteTransfer(id: UUID(), context: context)
            XCTFail("Expected closed")
        } catch V2AccountWorkScheduler.AdmissionError.closed {}
        let state = await scheduler.snapshot()
        XCTAssertEqual(state.active, 1)
        _ = await scheduler.release(restored)
        let duplicateRelease = await scheduler.release(restored)
        XCTAssertFalse(duplicateRelease)
        await scheduler.closeAndDrain()
    }
    func testCooldownWakesWithoutAnotherRequestAndServiceRegistryIsBounded() async throws {
        let scheduler = V2AccountWorkScheduler()
        let first = try await scheduler.acquire(.init(service: "service-0"))
        await scheduler.coolDown(service: "service-0", for: 0.02)
        _ = await scheduler.release(first)
        let afterCooldown = try await scheduler.acquire(.init(service: "service-0"), deadline: .now.advanced(by: .seconds(2)))
        _ = await scheduler.release(afterCooldown)
        for index in 1..<64 {
            let permit = try await scheduler.acquire(.init(service: "service-\(index)"))
            _ = await scheduler.release(permit)
        }
        do { _ = try await scheduler.acquire(.init(service: "overflow")); XCTFail("Expected bounded service registry") }
        catch V2AccountWorkScheduler.AdmissionError.overloaded {}
        let auth = try await scheduler.acquire(.init(service: "authentication", kind: .authentication))
        _ = await scheduler.release(auth)
        await scheduler.closeAndDrain()
    }
    func testSharedRetryQuotaDoesNotConsumeInitialOrOtherServiceAttempts() async throws {
        let clock = Mutex<TimeInterval>(0)
        let scheduler = V2AccountWorkScheduler(monotonicNow: { clock.withLock { $0 } })
        for _ in 0..<5 {
            let permit = try await scheduler.acquire(.init(service: "api", isRetry: true))
            _ = await scheduler.release(permit)
        }
        let blocked = Task { try await scheduler.acquire(.init(service: "api", isRetry: true)) }
        try await awaitWaiting(1, on: scheduler)
        let initial = try await scheduler.acquire(.init(service: "api"))
        let independent = try await scheduler.acquire(.init(service: "other", isRetry: true))
        let auth = try await scheduler.acquire(.init(service: "api", kind: .authentication, isRetry: true))
        _ = await scheduler.release(initial); _ = await scheduler.release(independent); _ = await scheduler.release(auth)
        clock.withLock { $0 = 2 }
        await scheduler.setDegraded(false)
        let retry = try await blocked.value
        _ = await scheduler.release(retry)
        // Refilling once grants one attempt, not a fresh burst of five.
        do {
            _ = try await scheduler.acquire(.init(service: "api", isRetry: true), deadline: .now.advanced(by: .milliseconds(20)))
            XCTFail("Expected exhausted quota")
        } catch V2AccountWorkScheduler.AdmissionError.deadlineExceeded {}
        await scheduler.closeAndDrain()
    }
    func testServiceCooldownBlocksNewWorkCannotShortenAndKeepsOtherServiceAvailable() async throws {
        let clock = Mutex<TimeInterval>(0)
        let scheduler = V2AccountWorkScheduler(monotonicNow: { clock.withLock { $0 } })
        let permit = try await scheduler.acquire(.init(service: "api"))
        await scheduler.coolDown(service: "api", for: 5)
        _ = await scheduler.release(permit)
        await scheduler.coolDown(service: "api", for: 1)
        let waiting = Task { try await scheduler.acquire(.init(service: "api")) }
        try await awaitWaiting(1, on: scheduler)
        let independent = try await scheduler.acquire(.init(service: "other"))
        _ = await scheduler.release(independent)
        clock.withLock { $0 = 2 }
        await scheduler.setDegraded(false)
        let before = await scheduler.snapshot()
        XCTAssertEqual(before.waiting, 1); XCTAssertEqual(before.active, 0)
        clock.withLock { $0 = 5 }
        await scheduler.setDegraded(false)
        let recovered = try await waiting.value
        _ = await scheduler.release(recovered)
        await scheduler.closeAndDrain()
    }
    func testCancelledRetryDoesNotConsumeFutureTokenAndCloseDrainsWaiter() async throws {
        let clock = Mutex<TimeInterval>(0)
        let scheduler = V2AccountWorkScheduler(monotonicNow: { clock.withLock { $0 } })
        for _ in 0..<5 {
            let permit = try await scheduler.acquire(.init(service: "api", isRetry: true))
            _ = await scheduler.release(permit)
        }
        let cancelled = Task { try await scheduler.acquire(.init(service: "api", isRetry: true)) }
        try await awaitWaiting(1, on: scheduler)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        clock.withLock { $0 = 2 }
        let permit = try await scheduler.acquire(.init(service: "api", isRetry: true))
        _ = await scheduler.release(permit)
        let closed = Task { try await scheduler.acquire(.init(service: "api", isRetry: true)) }
        try await awaitWaiting(1, on: scheduler)
        await scheduler.closeAndDrain()
        do { _ = try await closed.value; XCTFail("Expected close") } catch V2AccountWorkScheduler.AdmissionError.closed {}
    }
    private func awaitWaiting(_ count: Int, on scheduler: V2AccountWorkScheduler) async throws {
        for _ in 0..<10_000 { if await scheduler.snapshot().waiting == count { return }; await Task.yield() }
        XCTFail("Waiter count did not reach \(count)")
    }
    func testBlackHoleDoesNotBlockIndependentServiceOrAuthAndReleaseIsIdempotent() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 2, serviceLimit: 1))
        let blackHole = try await scheduler.acquire(.init(service: "tcp", orderingKey: "room-a"))
        let other = try await scheduler.acquire(.init(service: "https", orderingKey: "room-b"))
        let auth = try await scheduler.acquire(.init(service: "https", kind: .authentication))
        let first = await scheduler.release(auth); let duplicate = await scheduler.release(auth)
        XCTAssertTrue(first); XCTAssertFalse(duplicate)
        _ = await scheduler.release(other); _ = await scheduler.release(blackHole)
        await scheduler.closeAndDrain()
    }
    func testCancellationDoesNotReleaseRunningIOUntilDrained() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        let gate = WorkTestGate()
        let running = Task { try await scheduler.withPermit(.init(service: "api")) { _ in await gate.wait(); return 1 } }
        while await scheduler.snapshot().active == 0 { await Task.yield() }
        running.cancel()
        let next = Task { try await scheduler.acquire(.init(service: "api")) }
        try await awaitWaiting(1, on: scheduler)
        let snapshot = await scheduler.snapshot(); XCTAssertEqual(snapshot.active, 1)
        await gate.open(); _ = try await running.value
        let permit = try await next.value; _ = await scheduler.release(permit)
    }
    func testSameKeyFIFOOverridesPriorityAndIndependentCancellation() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        let head = try await scheduler.acquire(.init(service: "api", orderingKey: "key"))
        let a = Task { try await scheduler.acquire(.init(service: "api", priority: .background, orderingKey: "key")) }
        try await awaitWaiting(1, on: scheduler)
        let b = Task { try await scheduler.acquire(.init(service: "api", priority: .critical, orderingKey: "key")) }
        try await awaitWaiting(2, on: scheduler)
        b.cancel(); do { _ = try await b.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        _ = await scheduler.release(head)
        let permit = try await a.value; _ = await scheduler.release(permit)
    }
    func testCapacityAndCloseDrain() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1, waiterLimit: 1))
        let permit = try await scheduler.acquire(.init(service: "api"))
        let queued = Task { try await scheduler.acquire(.init(service: "api")) }
        try await awaitWaiting(1, on: scheduler)
        let auth = try await scheduler.acquire(.init(service: "api", kind: .authentication))
        _ = await scheduler.release(auth)
        do { _ = try await scheduler.acquire(.init(service: "api")); XCTFail("Expected overload") }
        catch V2AccountWorkScheduler.AdmissionError.overloaded {}
        let close = Task { await scheduler.closeAndDrain() }
        do { _ = try await queued.value; XCTFail("Expected closed") } catch V2AccountWorkScheduler.AdmissionError.closed {}
        let snapshot = await scheduler.snapshot(); XCTAssertEqual(snapshot.active, 1); XCTAssertTrue(snapshot.closed)
        _ = await scheduler.release(permit); await close.value
    }
    func testWeightedFairnessGivesBackgroundOpportunity() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        var permit = try await scheduler.acquire(.init(service: "api"))
        var jobs: [Task<V2RequestPermit, any Error>] = []
        for index in 0..<12 {
            jobs.append(Task { try await scheduler.acquire(.init(service: "api", priority: index == 11 ? .background : .critical)) })
            try await awaitWaiting(index + 1, on: scheduler)
        }
        var priorities: [V2NetworkWorkPriority] = []
        for _ in 0..<12 {
            _ = await scheduler.release(permit)
            // Identify the granted token without relying on task completion scheduling.
            while await scheduler.snapshot().active == 0 { await Task.yield() }
            // Critical FIFO and the 4:4:2:1 wheel place background within two wheel rotations.
            let index = priorities.count == 3 ? 11 : priorities.filter { $0 == .critical }.count
            permit = try await jobs[index].value; priorities.append(permit.context.priority)
        }
        XCTAssertEqual(priorities[3], .background)
        _ = await scheduler.release(permit)
    }
    func testQueueDeadlineRemovesWaiterWithoutReleasingRunningSlot() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        let running = try await scheduler.acquire(.init(service: "api"))
        do {
            _ = try await scheduler.acquire(.init(service: "api"), deadline: .now.advanced(by: .milliseconds(20)))
            XCTFail("Expected queue deadline")
        } catch V2AccountWorkScheduler.AdmissionError.deadlineExceeded {}
        let state = await scheduler.snapshot()
        XCTAssertEqual(state.active, 1); XCTAssertEqual(state.waiting, 0)
        _ = await scheduler.release(running)
    }
    func testAccountRuntimesHaveSeparateAdmissionDomains() async throws {
        let a = V2AccountRuntime(configuration: .init(ordinaryLimit: 1))
        let b = V2AccountRuntime(configuration: .init(ordinaryLimit: 1))
        let first = try await a.scheduler.acquire(.init(service: "api"))
        let second = try await b.scheduler.acquire(.init(service: "api"))
        let foreign = await a.scheduler.release(second)
        XCTAssertFalse(foreign)
        _ = await a.scheduler.release(first); _ = await b.scheduler.release(second)
        await a.close(); await b.close()
    }
    func testRetryBudgetAndServerCooldown() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(V2NetworkWorkPolicy.commandRecovery.nextAttempt(now: now, startedAt: now, attemptsCompleted: 1, randomUnit: 1), now.addingTimeInterval(0.5))
        XCTAssertNil(V2NetworkWorkPolicy.interactiveRead.nextAttempt(now: now, startedAt: now, attemptsCompleted: 2, randomUnit: 0))
        XCTAssertNil(V2NetworkWorkPolicy.interactiveRead.nextAttempt(now: now, startedAt: now, attemptsCompleted: 1, randomUnit: 0, serverRetryNotBefore: now.addingTimeInterval(11)))
        var bucket = V2NetworkRetryTokenBucket(now: 0)
        for _ in 0..<5 { XCTAssertTrue(bucket.consume(now: 0)) }; XCTAssertFalse(bucket.consume(now: 1)); XCTAssertTrue(bucket.consume(now: 2))
    }
    func testQualitySeparatesServicesAndIgnoresCooldown() async {
        let observer = V2QualityObserver()
        for window in 0..<2 { for index in 0..<5 { _ = await observer.record(.timeout, service: "tcp", now: Double(window * 10 + index)) } }
        _ = await observer.record(.timeout, service: "tcp", now: 20)
        let tcp = await observer.quality(for: "tcp"); let api = await observer.quality(for: "api")
        XCTAssertEqual(tcp, .degraded); XCTAssertEqual(api, .normal)
        for index in 0..<50 { _ = await observer.record(.serviceCooldown, service: "api", now: Double(index)) }
        let unchanged = await observer.quality(for: "api"); XCTAssertEqual(unchanged, .normal)
    }
}
private actor WorkTestGate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { continuations.append($0) } }
    func open() { opened = true; for continuation in continuations { continuation.resume() }; continuations.removeAll() }
}
