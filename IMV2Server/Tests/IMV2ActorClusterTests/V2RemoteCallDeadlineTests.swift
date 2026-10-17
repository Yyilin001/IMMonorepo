import Distributed
import DistributedCluster
import Foundation
import Synchronization
import Testing

@Suite("Remote call timer ownership", .serialized, .timeLimit(.minutes(1)))
struct V2RemoteCallDeadlineTests {
    @Test func timeoutLateReplyAndShutdownSettleExactlyOnce() async throws {
        let port = Int.random(in: 30_000...39_000)
        func settings(_ name: String, _ port: Int) -> ClusterSystemSettings {
            var value = ClusterSystemSettings(name: name, host: "127.0.0.1", port: port)
            value.threadPoolSize = 1; value.downingStrategy = .none; value.onDownAction = .none
            return value
        }
        let caller = await ClusterSystem("deadline-caller", settings: settings("deadline-caller", port))
        let peer = await ClusterSystem("deadline-peer", settings: settings("deadline-peer", port + 1))
        let observation = DeadlineObservation()
        let local = DeadlineProbe(observation: observation, actorSystem: peer)
        var failure: (any Error)?
        do {
            let remote = try DeadlineProbe.resolve(id: local.id, using: caller)
            #expect(try await RemoteCall.with(timeout: .seconds(5)) { try await remote.echo(milliseconds: 0) } == 42)
            do {
                _ = try await RemoteCall.with(timeout: .milliseconds(10)) { try await remote.echo(milliseconds: 100) }
                Issue.record("slow RPC did not time out")
            } catch { #expect(error is RemoteCallError) }
            try await Task.sleep(for: .milliseconds(150)) // late reply must not complete a later call
            #expect(try await RemoteCall.with(timeout: .seconds(2)) { try await remote.echo(milliseconds: 0) } == 42)
            observation.entered.withLock { $0 = false }
            let pending = Task {
                try await RemoteCall.with(timeout: .seconds(30)) { try await remote.echo(milliseconds: 500) }
            }
            let limit = ContinuousClock.now + .seconds(3)
            while !observation.entered.withLock({ $0 }), ContinuousClock.now < limit {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(observation.entered.withLock { $0 })
            try await caller.shutdown().wait()
            do { _ = try await pending.value; Issue.record("shutdown RPC unexpectedly succeeded") }
            catch { #expect(error is RemoteCallError) }
        } catch { failure = error }
        try await caller.shutdown().wait()
        try await peer.shutdown().wait()
        if let failure { throw failure }
    }
}

private distributed actor DeadlineProbe {
    typealias ActorSystem = ClusterSystem
    let observation: DeadlineObservation
    init(observation: DeadlineObservation, actorSystem: ClusterSystem) {
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
