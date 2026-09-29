@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Dispatch
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Logging
import NIOCore
import NIOPosix
import Synchronization
import Testing

struct V2DatabaseResourcesTests {
    @Test("shutdown preserves a borrowed EventLoopGroup for its owner")
    func shutdownPreservesBorrowedGroup() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resources = V2DatabaseResources(
            eventLoopGroup: group,
            logger: Logger(label: "imv2.database.resources.tests")
        )
        do {
            try await resources.shutdown()
            #expect(try await group.next().submit { 42 }.get() == 42)
            try await resources.shutdown()
            try await group.shutdownGracefully()
        } catch {
            try? await resources.shutdown()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("concurrent shutdown calls wait for the same resource drain")
    func concurrentShutdownWaitsForDrain() async throws {
        let resources = makeV2DatabaseTestResources()
        let workEntered = Mutex(false)
        let completed = Mutex(0)
        let releaseWork = DispatchSemaphore(value: 0)
        defer { releaseWork.signal() }
        resources.threadPool.submit { state in
            guard case .active = state else { return }
            workEntered.withLock { $0 = true }
            releaseWork.wait()
        }
        for _ in 0..<100 where !workEntered.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard workEntered.withLock({ $0 }) else {
            releaseWork.signal()
            try await resources.shutdown()
            Issue.record("Thread-pool blocker did not start")
            return
        }

        let first = Task {
            try await resources.shutdown()
            completed.withLock { $0 += 1 }
        }
        let second = Task {
            try await resources.shutdown()
            completed.withLock { $0 += 1 }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(completed.withLock { $0 } == 0)
        releaseWork.signal()
        try await first.value
        try await second.value
        #expect(completed.withLock { $0 } == 2)
    }
}
