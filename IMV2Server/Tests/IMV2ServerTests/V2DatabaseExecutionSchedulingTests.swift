@testable import IMV2ServerInfrastructure
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import Testing

@Suite("Database execution scheduling", .serialized)
struct V2DatabaseExecutionSchedulingTests {
    @Test("SQL future success and failure resume on the preferred physical loop")
    func futureResumption() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        do {
            let executor = V2DatabaseEventLoopTaskExecutor(loop)
            let task = Task(executorPreference: executor) {
                #expect(loop.inEventLoop)
                let value = try await loop.scheduleTask(in: .milliseconds(1)) { 17 }.futureResult.get()
                #expect(value == 17)
                #expect(loop.inEventLoop)
                do {
                    try await loop.scheduleTask(in: .milliseconds(1)) { throw ProbeFailure.expected }.futureResult.get()
                    Issue.record("Expected failed SQL future")
                } catch {
                    #expect(error is ProbeFailure)
                    #expect(loop.inEventLoop)
                }
            }
            try await task.value
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

    @Test("queued cancelled deadline cannot act after its loan ends")
    func queuedDeadlineCancellation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let fired = Mutex(false)
        // Hold only this test's EventLoop to force the timer callback to be late.
        loop.execute {
            entered.continuation.yield(())
            release.wait()
        }
        for await _ in entered.stream { break }
        let timer = V2RoomDeadlineTimer(deadline: .now, eventLoop: loop) {
            fired.withLock { $0 = true }
        }
        timer.disarm()
        release.signal()
        do {
            try await loop.scheduleTask(in: .milliseconds(1)) {}.futureResult.get()
            #expect(!fired.withLock { $0 })
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

    @Test("post-commit work drains exactly once and runs outside its storage lock")
    func postCommitDrain() async {
        let work = V2OwnerPostCommitWork()
        let count = Mutex(0)
        work.append {
            count.withLock { $0 += 1 }
            work.append { count.withLock { $0 += 1 } }
        }
        await work.finish()
        #expect(count.withLock { $0 } == 1)
        await work.finish()
        await work.finish()
        #expect(count.withLock { $0 } == 2)
    }
}

private enum ProbeFailure: Error { case expected }
