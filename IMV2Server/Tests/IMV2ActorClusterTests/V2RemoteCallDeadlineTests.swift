import IMV2ActorCluster
import Distributed
import IMActorSystem
import Foundation
import Synchronization
import Testing

@Suite("Remote call timer ownership", .serialized, .timeLimit(.minutes(1)))
struct V2RemoteCallDeadlineTests {
    @Test func timeoutLateReplyAndShutdownSettleExactlyOnce() async throws {
        let methods = [try await IMActorSystem.register(id: 1, actor: DeadlineProbe.self) { _ = try await $0.echo(milliseconds: 0) }]
        let port = Int.random(in: 30_000...39_000)
        func settings(_ name: String, _ port: Int) -> IMActorSystemSettings {
            var value = IMActorSystemSettings(name: name, host: "127.0.0.1", port: port)
            value.threadPoolSize = 1;
            value.methods = methods
            return value
        }
        let caller = try await V2ActorRPCManifest.makeSystem("deadline-caller", settings: settings("deadline-caller", port))
        let peer = try await V2ActorRPCManifest.makeSystem("deadline-peer", settings: settings("deadline-peer", port + 1))
        let observation = DeadlineObservation()
        let local = DeadlineProbe(observation: observation, actorSystem: peer)
        var failure: (any Error)?
        do {
            let remote = try DeadlineProbe.resolve(id: local.id, using: caller)
            #expect(try await IMRemoteCall.with(timeout: .seconds(5)) { try await remote.echo(milliseconds: 0) } == 42)
            do {
                _ = try await IMRemoteCall.with(timeout: .milliseconds(10)) { try await remote.echo(milliseconds: 100) }
                Issue.record("slow RPC did not time out")
            } catch { #expect(error is IMActorError) }
            try await Task.sleep(for: .milliseconds(150)) // late reply must not complete a later call
            #expect(try await IMRemoteCall.with(timeout: .seconds(2)) { try await remote.echo(milliseconds: 0) } == 42)
            observation.entered.withLock { $0 = false }
            let pending = Task {
                try await IMRemoteCall.with(timeout: .seconds(30)) { try await remote.echo(milliseconds: 500) }
            }
            let limit = ContinuousClock.now + .seconds(3)
            while !observation.entered.withLock({ $0 }), ContinuousClock.now < limit {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(observation.entered.withLock { $0 })
            try await caller.shutdown()
            do { _ = try await pending.value; Issue.record("shutdown RPC unexpectedly succeeded") }
            catch { #expect(error is IMActorError) }
        } catch { failure = error }
        try await caller.shutdown()
        try await peer.shutdown()
        if let failure { throw failure }
    }
}

private distributed actor DeadlineProbe {
    typealias ActorSystem = IMActorSystem
    let observation: DeadlineObservation
    init(observation: DeadlineObservation, actorSystem: IMActorSystem) {
        self.observation = observation; self.actorSystem = actorSystem
    }
    distributed func echo(milliseconds: UInt64) async throws -> Int {
        observation.entered.withLock { $0 = true }
        try await Task.sleep(for: .milliseconds(milliseconds))
        return 42
    }
}

private final class DeadlineObservation: Sendable {
    let entered = Mutex(false)
}
