import Distributed
import DistributedCluster
import IMV2ActorContracts
import IMV2ActorCluster
import Testing

@Suite("Late invocation replies cannot schedule on closed event loops", .serialized)
struct V2InvocationReplyShutdownTests {
    @Test(arguments: [false, true])
    func lateReplyAfterShutdown(throwing: Bool) async throws {
        func system(_ port: Int) async -> ClusterSystem {
            var settings = ClusterSystemSettings(name: "late-reply", host: "127.0.0.1", port: port)
            settings.threadPoolSize = 1
            settings.downingStrategy = .none; settings.onDownAction = .none
            settings.serialization.registerInbound(V2ActorAuthenticationError.self)
            settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
            return await ClusterSystem("late-reply", settings: settings)
        }
        let host = await system(Int.random(in: 30_000...44_000))
        let caller = await system(Int.random(in: 45_000...60_000))
        let gate = LateReplyGate()
        let local = LateReplyEndpoint(actorSystem: host, gate: gate)
        let remote = try LateReplyEndpoint.resolve(id: local.id, using: caller)
        let request = Task {
            do {
                _ = try await RemoteCall.with(timeout: .seconds(3)) {
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
            try await host.shutdown().wait()
            await gate.release()
            await request.value
            #expect(await gate.finished)
            try await caller.shutdown().wait()
        } catch {
            await gate.release()
            await request.value
            try? await host.shutdown().wait()
            try? await caller.shutdown().wait()
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
    typealias ActorSystem = ClusterSystem
    let gate: LateReplyGate
    init(actorSystem: ClusterSystem, gate: LateReplyGate) {
        self.actorSystem = actorSystem; self.gate = gate
    }
    distributed func held(throwing: Bool) async throws -> Int {
        await gate.hold()
        if throwing { throw V2ActorAuthenticationError.invalidRequest }
        return 7
    }
}
