import Dispatch
import Logging
import NIOCore
import Synchronization
import Testing
@testable import IMV2Server

struct V2DatabaseWorkloadResourcesTests {
    @Test("message driver resources and loops are disjoint from control work")
    func isolatedMessageProgress() async throws {
        let resources = V2DatabaseWorkloadResources(controlEventLoopThreads: 1,
            messageEventLoopThreads: 2, logger: Logger(label: "imv2.workload.resources.tests"))
        let messages = try #require(resources.messageWrite)
        #expect(resources.resources(for: .messageWrite) === messages)
        #expect(resources.resources(for: .foreground) === resources.control)
        #expect(resources.resources(for: .sync) === resources.control)
        #expect(messages.databases !== resources.control.databases)
        let control = resources.control.eventLoopGroup.next()
        let messageLoops = Array(messages.eventLoopGroup.makeIterator())
        #expect(messageLoops.count == 2)
        #expect(messageLoops.allSatisfy { ObjectIdentifier($0) != ObjectIdentifier(control) })
        let entered = Mutex(false), completed = Mutex(0)
        let unblock = DispatchSemaphore(value: 0)
        control.execute { entered.withLock { $0 = true }; unblock.wait() }
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while !entered.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(entered.withLock { $0 })
            for loop in messageLoops { loop.execute { completed.withLock { $0 += 1 } } }
            while completed.withLock({ $0 }) != 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(completed.withLock { $0 } == 2)
            unblock.signal()
            async let first: Void = resources.shutdown()
            async let second: Void = resources.shutdown()
            _ = try await (first, second)
        } catch {
            unblock.signal(); try? await resources.shutdown(); throw error
        }
    }

    @Test("explicit shared-pool mode creates no extra driver group")
    func sharedMode() async throws {
        let resources = V2DatabaseWorkloadResources(controlEventLoopThreads: 1,
            messageEventLoopThreads: nil, logger: Logger(label: "imv2.workload.resources.shared.tests"))
        #expect(resources.messageWrite == nil)
        #expect(resources.resources(for: .messageWrite) === resources.control)
        try await resources.shutdown()
        try await resources.shutdown()
    }
}
