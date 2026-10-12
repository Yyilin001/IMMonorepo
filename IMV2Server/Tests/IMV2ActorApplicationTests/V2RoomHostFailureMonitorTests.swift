import Foundation
import Testing
@testable import IMV2ActorApplication

@Suite("Recovery monitor lifecycle")
struct V2RoomHostFailureMonitorTests {
    private enum Failure: Error { case unavailable }
    private actor Work {
        var rounds = 0
        var failures = 0
        var exited = false
        var continuation: CheckedContinuation<Void, Never>?
        func round(entered: AsyncStream<Void>.Continuation) async throws {
            rounds += 1
            if rounds == 1 { throw Failure.unavailable }
            await withCheckedContinuation {
                continuation = $0
                entered.yield(())
            }
        }
        func failed() { failures += 1 }
        func finish() { continuation?.resume(); continuation = nil }
        func markExited() { exited = true }
    }

    @Test("Failure retries serially and cancellation awaits already-started work")
    func retryAndDrain() async throws {
        let work = Work(), entered = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { entered.continuation.finish() }
            do {
                try await V2RoomHostFailureMonitor.loop(pollInterval: .milliseconds(1), roundBudget: .seconds(1),
                    round: { deadline in
                        #expect(deadline > ContinuousClock.now)
                        try await work.round(entered: entered.continuation)
                    }, onFailure: { _ in await work.failed() })
            } catch {
                await work.markExited()
                throw error
            }
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        #expect(await work.rounds == 2)
        #expect(await work.failures == 1)
        #expect(await work.exited == false)
        await work.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await work.exited)
        #expect(await work.rounds == 2)
    }
}
