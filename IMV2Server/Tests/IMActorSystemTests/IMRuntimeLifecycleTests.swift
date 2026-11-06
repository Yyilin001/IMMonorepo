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
        let methods = [try await IMActorSystem.register(id: 1, actor: HeldActor.self) { _ = try await $0.run(false) }]
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
            await gate.release()
            while host.transportMetrics?.executingCalls != 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            #expect(host.transportMetrics?.executingCalls == 0)
        } catch { failure = error }
        await gate.release(); _ = try? await call.value
        try await caller.shutdown(); try await host.shutdown()
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
    func hold() async { enteredCount += 1; await withCheckedContinuation { continuations.append($0) } }
    func release() { for continuation in continuations { continuation.resume() }; continuations.removeAll() }
}
private distributed actor HeldActor {
    typealias ActorSystem = IMActorSystem
    let gate: ExecutionGate
    init(actorSystem: IMActorSystem, gate: ExecutionGate) { self.actorSystem = actorSystem; self.gate = gate }
    distributed func run(_ hold: Bool) async throws -> Int {
        if hold { await gate.hold() }; return 42
    }
}
