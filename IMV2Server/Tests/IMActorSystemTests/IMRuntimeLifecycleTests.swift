import Distributed
import Foundation
import IMActorSystem
import NIOCore
import NIOPosix
import Synchronization
import Testing

@Suite("Native actor lifecycle", .serialized, .timeLimit(.minutes(1)))
struct IMRuntimeLifecycleTests {
    @Test func deadlineIncludesStalledHandshake() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let children = Mutex<[(any Channel)]>([])
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            children.withLock { $0.append(channel) }
            return channel.eventLoop.makeSucceededVoidFuture()
        }.bind(host: "127.0.0.1", port: 0).get()
        let settings = IMActorSystemSettings(name: "handshake", host: "127.0.0.1", port: Int.random(in: 30_000...44_999))
        let system = try await IMActorSystem(settings.name, settings: settings)
        var failure: (any Error)?
        do {
            let endpoint = IMEndpoint(host: "127.0.0.1", port: try #require(server.localAddress?.port))
            let began = ContinuousClock.now
            do {
                _ = try await IMRemoteCall.with(timeout: .milliseconds(30)) {
                    try await system.lookup(IMServiceKey(HeldActor.self, id: "never"), at: endpoint)
                }
                Issue.record("stalled handshake returned successfully")
            } catch { #expect(error as? IMActorError == .deadlineExceeded) }
            #expect(began.duration(to: .now) < .seconds(1))
        } catch { failure = error }
        try await system.shutdown()
        for child in children.withLock({ $0 }) { try? await child.close() }
        try await server.close(); try await group.shutdownGracefully()
        if let failure { throw failure }
    }

    @Test func cancellationKeepsExecutionCreditUntilBodyReturns() async throws {
        let methods = [
            try await IMActorSystem.register(id: 1, actor: HeldActor.self) { _ = try await $0.run(false) },
            try await IMActorSystem.register(id: 2, actor: HeldActor.self) { _ = try await $0.refuseAfterDispatch() },
        ]
        func make(_ name: String, _ port: Int) async throws -> IMActorSystem {
            var settings = IMActorSystemSettings(name: name, host: "127.0.0.1", port: port)
            settings.threadPoolSize = 1; settings.maximumCallsPerConnection = 1; settings.methods = methods
            return try await IMActorSystem(name, settings: settings)
        }
        let host = try await make("held-host", Int.random(in: 30_000...44_999))
        let caller = try await make("held-caller", Int.random(in: 45_000...59_999))
        let gate = ExecutionGate(), local = HeldActor(actorSystem: host, gate: gate)
        let remote = try HeldActor.resolve(id: local.id, using: caller)
        let call = Task { try await remote.run(true) }
        var failure: (any Error)?
        do {
            let end = ContinuousClock.now + .seconds(3)
            while !(await gate.entered), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            try #require(await gate.entered)
            call.cancel()
            do { _ = try await call.value; Issue.record("cancelled caller returned") }
            catch { #expect(error as? IMActorError == .cancelled) }
            #expect(host.transportMetrics?.executingCalls == 1)
            do { _ = try await remote.run(false); Issue.record("cancel returned execution credit early") }
            catch { #expect(error as? IMActorError == .overloaded) }
            await #expect(throws: IMRPCAdmission.Refusal(reason: .messageCreditWaitTimeout)) {
                try await IMRPCAdmission.$usesMessageWindow.withValue(true) { try await remote.run(false) }
            }
            #expect(caller.transportMetrics?.rpcRejections[.sendCallCredit] == 1)
            #expect(caller.transportMetrics?.rpcRejections[.messageCreditWaitTimeout] == 1)
            func waitForEnqueue(_ count: UInt64) async throws {
                while (caller.transportMetrics?.messageCreditWaits[.enqueued] ?? 0) < count {
                    guard ContinuousClock.now < end else { throw IMActorError.deadlineExceeded }
                    try await Task.sleep(for: .microseconds(100))
                }
            }
            let abandoned = Task {
                try await IMRPCAdmission.$usesMessageWindow.withValue(true) { try await remote.run(false) }
            }
            try await waitForEnqueue(2)
            await #expect(throws: IMRPCAdmission.Refusal(reason: .sendCallCredit)) {
                try await IMRPCAdmission.$usesMessageWindow.withValue(true) { try await remote.run(false) }
            }
            abandoned.cancel()
            await #expect(throws: IMActorError.cancelled) { try await abandoned.value }
            #expect(caller.transportMetrics?.messageCreditWaits[.dispatched, default: 0] == 0)
            let waiting = Task {
                try await IMRPCAdmission.$usesMessageWindow.withValue(true) { try await remote.run(false) }
            }
            try await waitForEnqueue(3)
            await gate.release()
            #expect(try await waiting.value == 42)
            #expect(caller.transportMetrics?.messageCreditWaits[.dispatched] == 1)
            while host.transportMetrics?.executingCalls != 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            #expect(host.transportMetrics?.executingCalls == 0)
            // The peer can also return overloaded after its method executed.
            // A locally generated rejection can never be reconstructed from that reply.
            while true {
                do {
                    _ = try await IMRPCAdmission.$usesMessageWindow.withValue(true) {
                        try await remote.refuseAfterDispatch()
                    }
                    Issue.record("expected receiver overload")
                    break
                } catch let refusal as IMRPCAdmission.Refusal where refusal.reason == .messageCreditWaitTimeout {
                    guard ContinuousClock.now < end else { throw IMActorError.deadlineExceeded }
                    try await Task.sleep(for: .milliseconds(5))
                } catch let error as IMActorError {
                    #expect(error == .overloaded)
                    break
                }
            }
        } catch { failure = error }
        await gate.release(); _ = try? await call.value
        try await caller.shutdown(); try await host.shutdown()
        if let failure { throw failure }
    }

    @Test func messagePreDispatchRefusalsPreserveFrameAndProcessBudgetReasons() async throws {
        let methods = [
            try await IMActorSystem.register(id: 1, actor: HeldActor.self) { _ = try await $0.run(false) },
            try await IMActorSystem.register(id: 2, actor: HeldActor.self) { _ = try await $0.textLength("") }
        ]
        var hostSettings = IMActorSystemSettings(name: "frame-host", host: "127.0.0.1",
            port: Int.random(in: 30_000...44_999))
        hostSettings.maximumInboundFrameBytes = 1024
        hostSettings.maximumBytesPerConnection = 1024
        hostSettings.methods = methods
        var callerSettings = IMActorSystemSettings(name: "budget-caller", host: "127.0.0.1",
            port: Int.random(in: 45_000...59_999))
        callerSettings.maximumExecutingCalls = 4
        callerSettings.methods = methods
        let host = try await IMActorSystem(hostSettings.name, settings: hostSettings)
        let caller = try await IMActorSystem(callerSettings.name, settings: callerSettings)
        let gate = ExecutionGate(), local = HeldActor(actorSystem: host, gate: gate)
        let remote = try HeldActor.resolve(id: local.id, using: caller)
        var failure: (any Error)?
        var held: [Task<Int, any Error>] = []
        do {
            await #expect(throws: IMRPCAdmission.Refusal(reason: .peerFrame)) {
                try await IMRPCAdmission.$usesMessageWindow.withValue(true) {
                    try await remote.textLength(String(repeating: "a", count: 2048))
                }
            }
            held = (0..<2).map { _ in Task { try await remote.run(true) } }
            let deadline = ContinuousClock.now + .seconds(3)
            while await gate.enteredCount < 2 {
                guard .now < deadline else { throw IMActorError.deadlineExceeded }
                try await Task.sleep(for: .milliseconds(1))
            }
            await #expect(throws: IMRPCAdmission.Refusal(reason: .pendingBudget)) {
                try await IMRPCAdmission.$usesMessageWindow.withValue(true) { try await remote.run(false) }
            }
            await #expect(throws: IMActorError.overloaded) { try await remote.run(false) }
            #expect(host.transportMetrics?.executingCalls == 2)
        } catch { failure = error }
        await gate.release()
        for task in held { _ = try? await task.value }
        try await caller.shutdown()
        try await host.shutdown()
        if let failure { throw failure }
    }

    @Test func messageWaitersLeaveCreditForOtherRPCs() async throws {
        let method = try await IMActorSystem.register(id: 1, actor: HeldActor.self) { _ = try await $0.run(false) }
        func make(_ name: String, port: Int) async throws -> IMActorSystem {
            var settings = IMActorSystemSettings(name: name, host: "127.0.0.1", port: port)
            settings.maximumCallsPerConnection = 8
            settings.methods = [method]
            return try await IMActorSystem(name, settings: settings)
        }
        let server = try await make("reserve-host", port: Int.random(in: 30_000...44_999))
        let caller = try await make("reserve-caller", port: Int.random(in: 45_000...59_999))
        let gate = ExecutionGate(), local = HeldActor(actorSystem: server, gate: gate)
        let remote = try HeldActor.resolve(id: local.id, using: caller)
        let held = (0..<7).map { _ in
            Task { try await IMRPCAdmission.$usesMessageWindow.withValue(true) { try await remote.run(true) } }
        }
        var failure: (any Error)?
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            while await gate.enteredCount < 7 {
                guard .now < deadline else { throw IMActorError.deadlineExceeded }
                try await Task.sleep(for: .milliseconds(1))
            }
            await #expect(throws: IMRPCAdmission.Refusal(reason: .messageCreditWaitTimeout)) {
                try await IMRPCAdmission.$usesMessageWindow.withValue(true) { try await remote.run(false) }
            }
            #expect(try await remote.run(false) == 42)
        } catch { failure = error }
        await gate.release()
        for task in held { _ = try? await task.value }
        try await caller.shutdown()
        try await server.shutdown()
        if let failure { throw failure }
    }

    @Test func largeReplyLimitDoesNotSerializeSmallControlCalls() async throws {
        let methods = [try await IMActorSystem.register(id: 1, traffic: .control, actor: HeldActor.self) {
            _ = try await $0.run(false)
        }]
        func make(_ name: String, _ port: Int) async throws -> IMActorSystem {
            var settings = IMActorSystemSettings(name: name, host: "127.0.0.1", port: port)
            settings.threadPoolSize = 1; settings.methods = methods
            settings.maximumInboundFrameBytes = 8 * 1_048_576 + 65_536
            return try await IMActorSystem(name, settings: settings)
        }
        let host = try await make("control-host", Int.random(in: 30_000...44_999))
        let caller = try await make("control-caller", Int.random(in: 45_000...59_999))
        let gate = ExecutionGate(), local = HeldActor(actorSystem: host, gate: gate)
        let remote = try HeldActor.resolve(id: local.id, using: caller)
        let first = Task { try await remote.run(true) }, second = Task { try await remote.run(true) }
        let end = ContinuousClock.now + .seconds(3)
        while await gate.enteredCount < 2, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.enteredCount == 2)
        #expect(host.transportMetrics?.executingCalls == 2)
        await gate.release()
        let firstResult = await first.result, secondResult = await second.result
        try await caller.shutdown(); try await host.shutdown()
        #expect(try firstResult.get() == 42)
        #expect(try secondResult.get() == 42)
    }
}
private actor ExecutionGate {
    var enteredCount = 0
    var entered: Bool { enteredCount > 0 }
    var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func hold() async {
        enteredCount += 1
        if !released { await withCheckedContinuation { continuations.append($0) } }
    }
    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}
private distributed actor HeldActor {
    typealias ActorSystem = IMActorSystem
    let gate: ExecutionGate
    init(actorSystem: IMActorSystem, gate: ExecutionGate) { self.actorSystem = actorSystem; self.gate = gate }
    distributed func textLength(_ text: String) -> Int { text.utf8.count }
    distributed func refuseAfterDispatch() throws -> Int { throw IMActorError.overloaded }
    distributed func run(_ hold: Bool) async throws -> Int {
        if hold { await gate.hold() }; return 42
    }
}
