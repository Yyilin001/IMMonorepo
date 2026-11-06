import Distributed
import Foundation
import IMActorSystem
import Synchronization
import Testing

@Suite("Actor shutdown and traffic reservations", .serialized, .timeLimit(.minutes(1)))
struct IMRuntimeIsolationTests {
    @Test func peerObserversFinishOutsideStateLock() async throws {
        let system = try await makeSystem("observer", methods: [])
        var iterator = system.peerEvents.makeAsyncIterator()
        #expect(await iterator.next()?.available[system.node] == true)
        try await system.shutdown()
        #expect(await iterator.next() == nil)
        // A subscription after shutdown must finish without reentering the lock.
        var stopped = system.peerEvents.makeAsyncIterator()
        #expect(await stopped.next() == nil)
        try await system.shutdown()
    }

    @Test(arguments: [false, true])
    func smallCallsCannotConsumeOtherTrafficReservations(senderLimited: Bool) async throws {
        let methods = try await methods()
        let host = try await makeSystem("host", methods: methods, calls: senderLimited ? 128 : 4)
        let caller = try await makeSystem("caller", methods: methods, calls: senderLimited ? 4 : 128, caller: true)
        let gate = IsolationGate(), local = IsolationEndpoint(actorSystem: host, gate: gate)
        let remote = try IsolationEndpoint.resolve(id: local.id, using: caller)
        // Four total slots: two RPC, one bulk, one control. Both busy data lanes
        // must reject further work while control still completes a real RPC.
        let first = Task { try await remote.rpc(true) }
        let second = Task { try await remote.rpc(true) }
        let bulk = Task { try await remote.bulk(true) }
        let entered = await waitFor { await gate.enteredCount == 3 }
        var rpcFailure: (any Error)?, bulkFailure: (any Error)?, control: Int?
        do { _ = try await remote.rpc(false) } catch { rpcFailure = error }
        do { _ = try await remote.bulk(false) } catch { bulkFailure = error }
        do { control = try await remote.control() } catch { Issue.record(error) }
        await gate.release()
        let results = [await first.result, await second.result, await bulk.result]
        try await caller.shutdown(); try await host.shutdown()
        #expect(entered)
        #expect(rpcFailure as? IMActorError == .overloaded)
        #expect(bulkFailure as? IMActorError == .overloaded)
        #expect(control == 7)
        for result in results { #expect((try? result.get()) == 42) }
        #expect(caller.transportMetrics?.pendingCalls == 0)
        #expect(host.transportMetrics?.executingCalls == 0)
    }

    @Test(arguments: [false, true])
    func callerShutdownRetainsAdmittedOutboundRequests(retryAfterTimeout: Bool) async throws {
        let methods = try await methods()
        let host = try await makeSystem("drain-host", methods: methods)
        let caller = try await makeSystem("drain-caller", methods: methods, caller: true,
            shutdownTimeout: retryAfterTimeout ? .milliseconds(30) : .seconds(3))
        let gate = IsolationGate(), local = IsolationEndpoint(actorSystem: host, gate: gate)
        let remote = try IsolationEndpoint.resolve(id: local.id, using: caller)
        let call = Task { try await remote.rpc(true) }
        let entered = await waitFor { await gate.enteredCount == 1 }
        let stopped = Mutex(false)
        let stopping = Task {
            try await caller.shutdown()
            stopped.withLock { $0 = true }
        }
        if retryAfterTimeout {
            do { try await stopping.value; Issue.record("held call must exceed drain deadline") }
            catch { #expect(error as? IMActorError == .deadlineExceeded) }
            #expect(caller.transportMetrics?.pendingCalls == 1)
            #expect((caller.transportMetrics?.connections ?? 0) > 0)
            await gate.release()
        } else {
            // Concurrent shutdown joins the same attempt and does not close the
            // EventLoop underneath the first drain or the pending response.
            let joining = Task { try await caller.shutdown() }
            let returnedEarly = await waitFor(timeout: .milliseconds(50)) { stopped.withLock { $0 } }
            await gate.release()
            try await stopping.value; try await joining.value
            #expect(!returnedEarly)
        }
        let result = await call.result
        try await caller.shutdown(); try await host.shutdown()
        #expect(entered)
        #expect((try? result.get()) == 42)
        #expect(caller.transportMetrics?.pendingCalls == 0)
        #expect(caller.transportMetrics?.connections == 0)
    }

    private func methods() async throws -> [IMMethod] {
        [try await IMActorSystem.register(id: 1, traffic: .rpc, actor: IsolationEndpoint.self) { _ = try await $0.rpc(false) },
         try await IMActorSystem.register(id: 2, traffic: .bulk, actor: IsolationEndpoint.self) { _ = try await $0.bulk(false) },
         try await IMActorSystem.register(id: 3, traffic: .control, actor: IsolationEndpoint.self) { _ = try await $0.control() }]
    }

    private func makeSystem(_ name: String, methods: [IMMethod], calls: Int = 128,
                            caller: Bool = false, shutdownTimeout: Duration = .seconds(3)) async throws -> IMActorSystem {
        var settings = IMActorSystemSettings(name: name, host: "127.0.0.1",
            port: Int.random(in: caller ? 45_000...59_999 : 30_000...44_999))
        settings.threadPoolSize = 1; settings.methods = methods
        settings.maximumExecutingCalls = calls; settings.shutdownTimeout = shutdownTimeout
        return try await IMActorSystem(name, settings: settings)
    }

    private func waitFor(timeout: Duration = .seconds(2), _ check: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while !(await check()), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(2)) }
        return await check()
    }
}

private actor IsolationGate {
    var enteredCount = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
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

private distributed actor IsolationEndpoint {
    typealias ActorSystem = IMActorSystem
    let gate: IsolationGate
    init(actorSystem: IMActorSystem, gate: IsolationGate) { self.actorSystem = actorSystem; self.gate = gate }
    distributed func rpc(_ hold: Bool) async throws -> Int { if hold { await gate.hold() }; return 42 }
    distributed func bulk(_ hold: Bool) async throws -> Int { if hold { await gate.hold() }; return 42 }
    distributed func control() async throws -> Int { 7 }
}
