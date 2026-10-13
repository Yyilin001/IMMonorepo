import Dispatch
import Logging
import NIOCore
import Synchronization
import Testing
@testable import IMV2Server

struct V2DatabaseWorkloadResourcesTests {
    @Test("message and foreground resources continue while the background event loop is blocked")
    func isolatedMessageProgress() async throws {
        let resources = V2DatabaseWorkloadResources(controlEventLoopThreads: 1,
            messageEventLoopThreads: 2, logger: Logger(label: "imv2.workload.resources.tests"))
        let messages = try #require(resources.messageWrite)
        let foreground = try #require(resources.foreground)
        #expect(resources.resources(for: .messageWrite) === messages)
        #expect(resources.resources(for: .foreground) === foreground)
        #expect(resources.resources(for: .sync) === resources.control)
        #expect(messages.databases !== resources.control.databases)
        #expect(foreground.databases !== resources.control.databases)
        let control = resources.control.eventLoopGroup.next()
        let messageLoops = Array(messages.eventLoopGroup.makeIterator())
        #expect(messageLoops.count == 2)
        #expect(messageLoops.allSatisfy { ObjectIdentifier($0) != ObjectIdentifier(control) })
        let foregroundLoop = foreground.eventLoopGroup.next()
        #expect(ObjectIdentifier(foregroundLoop) != ObjectIdentifier(control))
        #expect(messageLoops.allSatisfy { ObjectIdentifier($0) != ObjectIdentifier(foregroundLoop) })
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
            foregroundLoop.execute { completed.withLock { $0 += 1 } }
            while completed.withLock({ $0 }) != 3, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(completed.withLock { $0 } == 3)
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
        #expect(resources.foreground == nil)
        #expect(resources.resources(for: .foreground) === resources.control)
        #expect(resources.resources(for: .messageWrite) === resources.control)
        try await resources.shutdown()
        try await resources.shutdown()
    }
}
