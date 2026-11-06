import Distributed
import IMActorSystem
import IMV2ActorContracts
import IMV2ActorCluster
import Testing

@Suite("Late invocation replies cannot schedule on closed event loops", .serialized)
struct V2InvocationReplyShutdownTests {
    @Test(arguments: [false, true])
    func lateReplyAfterShutdown(throwing: Bool) async throws {
        func system(_ port: Int) async throws -> IMActorSystem {
            var settings = IMActorSystemSettings(name: "late-reply", host: "127.0.0.1", port: port)
            settings.threadPoolSize = 1
            settings.methods = [try await IMActorSystem.register(id: 1, actor: LateReplyEndpoint.self) { _ = try await $0.held(throwing: false) }]

            settings.errorTypes = [V2ActorAuthenticationError.self]

            return try await V2ActorRPCManifest.makeSystem("late-reply", settings: settings)
        }
        let host = try await system(Int.random(in: 30_000...44_000))
        let caller = try await system(Int.random(in: 45_000...60_000))
        let gate = LateReplyGate()
        let local = LateReplyEndpoint(actorSystem: host, gate: gate)
        let remote = try LateReplyEndpoint.resolve(id: local.id, using: caller)
        let request = Task {
            do {
                _ = try await IMRemoteCall.with(timeout: .seconds(3)) {
                    try await remote.held(throwing: throwing)
                }
            } catch {}
        }
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while !(await gate.started), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await gate.started)
            let shutdown = Task { try await host.shutdown() }
            await gate.release()
            try await shutdown.value
            await request.value
            #expect(await gate.finished)
            try await caller.shutdown()
        } catch {
            await gate.release()
            await request.value
            try? await host.shutdown()
            try? await caller.shutdown()
            throw error
        }
    }
}
private actor LateReplyGate {
    var started = false
    var finished = false
    var released = false
    var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        started = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        finished = true
    }
    func release() {
        released = true
        waiter?.resume(); waiter = nil
    }
}
private distributed actor LateReplyEndpoint {
    typealias ActorSystem = IMActorSystem
    let gate: LateReplyGate
    init(actorSystem: IMActorSystem, gate: LateReplyGate) {
        self.actorSystem = actorSystem; self.gate = gate
    }
    distributed func held(throwing: Bool) async throws -> Int {
        await gate.hold()
        if throwing { throw V2ActorAuthenticationError.invalidRequest }
        return 7
    }
}
