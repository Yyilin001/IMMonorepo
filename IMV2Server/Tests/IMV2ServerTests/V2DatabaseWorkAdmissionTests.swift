import Foundation
@testable import IMV2Server
import Testing

@Suite("V2 database work admission")
struct V2DatabaseWorkAdmissionTests {
    @Test("foreground writes, interactive reads and Sync own independent queue reservations")
    func isolatesWorkClassQueues() async throws {
        let controller = makeController(timeout: .seconds(1))
        #expect(await controller.acquire(.foregroundWrite) == .admitted)
        #expect(await controller.acquire(.interactiveRead) == .admitted)
        #expect(await controller.acquire(.sync) == .admitted)

        let queuedForegroundWrite = Task { await controller.acquire(.foregroundWrite) }
        let queuedInteractiveRead = Task { await controller.acquire(.interactiveRead) }
        let queuedSync = Task { await controller.acquire(.sync) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await controller.snapshot().foregroundWriteQueued == 1)
        #expect(await controller.snapshot().interactiveReadQueued == 1)
        #expect(await controller.snapshot().syncQueued == 1)

        // Filling one lane does not consume either other lane's queue budget.
        #expect(await controller.acquire(.foregroundWrite) == .rejected(.queueFull))
        #expect(await controller.acquire(.interactiveRead) == .rejected(.queueFull))
        #expect(await controller.acquire(.sync) == .rejected(.queueFull))
        await controller.release(.foregroundWrite)
        await controller.release(.interactiveRead)
        await controller.release(.sync)
        #expect(await queuedForegroundWrite.value == .admitted)
        #expect(await queuedInteractiveRead.value == .admitted)
        #expect(await queuedSync.value == .admitted)
        await controller.release(.foregroundWrite)
        await controller.release(.interactiveRead)
        await controller.release(.sync)

        let snapshot = await controller.snapshot()
        #expect(snapshot.foregroundWrite.queueFullRejections == 1)
        #expect(snapshot.interactiveRead.queueFullRejections == 1)
        #expect(snapshot.sync.queueFullRejections == 1)
        #expect(snapshot.foregroundWrite.admittedRequests == 2)
        #expect(snapshot.interactiveRead.admittedRequests == 2)
        #expect(snapshot.sync.admittedRequests == 2)
        #expect(snapshot.queued == 0)
    }

    @Test("a queued request acquires after the older permit releases")
    func releasesToQueuedRequest() async throws {
        let controller = makeController(timeout: .milliseconds(200))
        #expect(await controller.acquire(.foregroundWrite) == .admitted)
        #expect(await controller.acquire(.interactiveRead) == .admitted)
        let queued = Task { await controller.acquire(.foregroundWrite) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await controller.snapshot().queued == 1)
        await controller.release(.foregroundWrite)
        #expect(await queued.value == .admitted)
        await controller.release(.foregroundWrite)
        await controller.release(.interactiveRead)
    }

    @Test("cancelling a queued request removes it without recording overload")
    func cancellationRemovesWaiter() async throws {
        let controller = makeController(timeout: .seconds(1))
        #expect(await controller.acquire(.foregroundWrite) == .admitted)
        #expect(await controller.acquire(.interactiveRead) == .admitted)
        let queued = Task { await controller.acquire(.foregroundWrite) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await controller.snapshot().foregroundWriteQueued == 1)
        queued.cancel()
        #expect(await queued.value == .cancelled)
        let snapshot = await controller.snapshot()
        #expect(snapshot.foregroundWriteInFlight == 1)
        #expect(snapshot.foregroundWriteQueued == 0)
        #expect(snapshot.foregroundWrite.cancelledRequests == 1)
        #expect(snapshot.rejectedRequests == 0)
        await controller.release(.foregroundWrite)
        await controller.release(.interactiveRead)
    }

    @Test("timeout and queue-full rejections remain distinct counters")
    func distinguishesRejectionReasons() async {
        let controller = makeController(timeout: .milliseconds(10))
        #expect(await controller.acquire(.sync) == .admitted)
        let timedOut = Task { await controller.acquire(.sync) }
        while await controller.snapshot().syncQueued == 0 { await Task.yield() }
        #expect(await controller.acquire(.sync) == .rejected(.queueFull))
        #expect(await timedOut.value == .rejected(.timeout))
        let snapshot = await controller.snapshot().sync
        #expect(snapshot.queueFullRejections == 1)
        #expect(snapshot.timeoutRejections == 1)
        #expect(snapshot.rejectedRequests == 2)
        await controller.release(.sync)
    }

    @Test("one lane grants queued work in FIFO order")
    func grantsInFIFOOrder() async throws {
        let controller = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 16,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .seconds(2)
        ))
        #expect(await controller.acquire(.foregroundWrite) == .admitted)
        #expect(await controller.acquire(.interactiveRead) == .admitted)
        let order = AdmissionOrderRecorder()
        var tasks: [Task<Void, Never>] = []
        for index in 0..<16 {
            tasks.append(Task {
                let result = await controller.acquire(.foregroundWrite)
                if result == .admitted {
                    await order.append(index)
                    await controller.release(.foregroundWrite)
                }
            })
            while await controller.snapshot().foregroundWriteQueued != index + 1 {
                await Task.yield()
            }
        }

        await controller.release(.foregroundWrite)
        for task in tasks { await task.value }
        #expect(await order.values() == Array(0..<16))
        let snapshot = await controller.snapshot().foregroundWrite
        #expect(snapshot.inFlight == 0)
        #expect(snapshot.queued == 0)
        #expect(snapshot.admittedRequests == 17)
        await controller.release(.interactiveRead)
    }

    @Test("cancellation racing permit release neither leaks nor overspends permits")
    func cancellationReleaseRaceIsBalanced() async throws {
        let controller = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 4,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 512,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .seconds(3)
        ))
        for _ in 0..<4 {
            #expect(await controller.acquire(.foregroundWrite) == .admitted)
        }
        #expect(await controller.acquire(.interactiveRead) == .admitted)
        let tasks = (0..<256).map { _ in
            Task {
                let result = await controller.acquire(.foregroundWrite)
                if result == .admitted {
                    await controller.release(.foregroundWrite)
                }
                return result
            }
        }
        while await controller.snapshot().foregroundWriteQueued != tasks.count {
            await Task.yield()
        }

        for index in stride(from: 0, to: tasks.count, by: 2) {
            tasks[index].cancel()
        }
        for _ in 0..<4 { await controller.release(.foregroundWrite) }
        var results: [V2DatabaseWorkAdmissionResult] = []
        results.reserveCapacity(tasks.count)
        for task in tasks {
            results.append(await task.value)
        }

        let admitted = results.filter { $0 == .admitted }.count
        let cancelled = results.filter { $0 == .cancelled }.count
        #expect(admitted + cancelled == tasks.count)
        let snapshot = await controller.snapshot().foregroundWrite
        #expect(snapshot.inFlight == 0)
        #expect(snapshot.queued == 0)
        #expect(snapshot.admittedRequests == UInt64(4 + admitted))
        #expect(snapshot.cancelledRequests == UInt64(cancelled))
        #expect(snapshot.rejectedRequests == 0)
        await controller.release(.interactiveRead)
    }

    @Test("idle interactive-read reservation is borrowed by foreground writes")
    func foregroundWriteBorrowsIdleInteractiveReadCapacity() async throws {
        let controller = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 2,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 4,
            maximumInteractiveReadQueued: 4,
            maximumSyncQueued: 1,
            timeout: .seconds(1)
        ))

        for _ in 0..<3 {
            #expect(await controller.acquire(.foregroundWrite) == .admitted)
        }
        #expect(await controller.snapshot().foregroundWriteInFlight == 3)
        #expect(await controller.snapshot().interactiveReadInFlight == 0)

        let queuedRead = Task { await controller.acquire(.interactiveRead) }
        while await controller.snapshot().interactiveReadQueued != 1 { await Task.yield() }
        await controller.release(.foregroundWrite)
        #expect(await queuedRead.value == .admitted)
        let snapshot = await controller.snapshot()
        #expect(snapshot.foregroundWriteInFlight == 2)
        #expect(snapshot.interactiveReadInFlight == 1)
        await controller.release(.foregroundWrite)
        await controller.release(.foregroundWrite)
        await controller.release(.interactiveRead)
    }

    @Test("queued peer reservation receives the next borrowed foreground permit")
    func queuedPeerReservationWinsNextReleasedPermit() async throws {
        let controller = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 2,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 4,
            maximumInteractiveReadQueued: 4,
            maximumSyncQueued: 1,
            timeout: .seconds(1)
        ))

        for _ in 0..<3 {
            #expect(await controller.acquire(.foregroundWrite) == .admitted)
        }
        let queuedRead = Task { await controller.acquire(.interactiveRead) }
        while await controller.snapshot().interactiveReadQueued != 1 { await Task.yield() }
        let queuedWrite = Task { await controller.acquire(.foregroundWrite) }
        while await controller.snapshot().foregroundWriteQueued != 1 { await Task.yield() }

        await controller.release(.foregroundWrite)
        #expect(await queuedRead.value == .admitted)
        #expect(await controller.snapshot().foregroundWriteQueued == 1)
        await controller.release(.interactiveRead)
        #expect(await queuedWrite.value == .admitted)
        await controller.release(.foregroundWrite)
        await controller.release(.foregroundWrite)
        await controller.release(.foregroundWrite)
    }

    private func makeController(
        timeout: Duration
    ) -> V2DatabaseWorkAdmissionController {
        V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 1,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: timeout
        ))
    }
}

private actor AdmissionOrderRecorder {
    private var recorded: [Int] = []

    func append(_ value: Int) {
        recorded.append(value)
    }

    func values() -> [Int] {
        recorded
    }
}
