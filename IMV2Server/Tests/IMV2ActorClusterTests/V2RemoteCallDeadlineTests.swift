import IMV2ActorCluster
import Distributed
import IMActorSystem
import Foundation
import Testing

@Suite("Remote call timer ownership", .serialized, .timeLimit(.minutes(1)))
struct V2RemoteCallDeadlineTests {
    @Test func timeoutAndGracefulShutdownSettleCallsExactlyOnce() async throws {
        let methods = [
            try await IMActorSystem.register(id: 1, actor: DeadlineProbe.self) { _ = try await $0.echo(milliseconds: 0) },
            try await IMActorSystem.register(id: 2, actor: DeadlineProbe.self) { _ = try await $0.heldEcho() },
        ]
        let port = Int.random(in: 30_000...39_000)
        func settings(_ name: String, _ port: Int) -> IMActorSystemSettings {
            var value = IMActorSystemSettings(name: name, host: "127.0.0.1", port: port)
            value.threadPoolSize = 1;
            value.methods = methods
            return value
        }
        let caller = try await V2ActorRPCManifest.makeSystem("deadline-caller", settings: settings("deadline-caller", port))
        let peer = try await V2ActorRPCManifest.makeSystem("deadline-peer", settings: settings("deadline-peer", port + 1))
        let gate = LateReplyGate()
        let local = DeadlineProbe(gate: gate, actorSystem: peer)
        var failure: (any Error)?
        do {
            let remote = try DeadlineProbe.resolve(id: local.id, using: caller)
            #expect(try await IMRemoteCall.with(timeout: .seconds(5)) { try await remote.echo(milliseconds: 0) } == 42)
            do {
                _ = try await IMRemoteCall.with(timeout: .milliseconds(10)) { try await remote.echo(milliseconds: 100) }
                Issue.record("slow RPC did not time out")
            } catch { #expect(error as? IMActorError == .deadlineExceeded) }
            try await Task.sleep(for: .milliseconds(150)) // late reply must not complete a later call
            #expect(try await IMRemoteCall.with(timeout: .seconds(2)) { try await remote.echo(milliseconds: 0) } == 42)
            let pending = Task {
                try await IMRemoteCall.with(timeout: .seconds(30)) { try await remote.heldEcho() }
            }
            let limit = ContinuousClock.now + .seconds(3)
            while !(await gate.started), ContinuousClock.now < limit {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(await gate.started)
            let shutdown = Task { try await caller.shutdown() }
            let shutdownLimit = ContinuousClock.now + .seconds(3)
            var rejected = false
            while !rejected, ContinuousClock.now < shutdownLimit {
                do {
                    _ = try await IMRemoteCall.with(timeout: .milliseconds(100)) { try await remote.echo(milliseconds: 0) }
                } catch {
                    rejected = error as? IMActorError == .shuttingDown
                }
                await Task.yield()
            }
            #expect(rejected)
            await gate.release()
            #expect(try await pending.value == 42)
            try await shutdown.value
        } catch { failure = error }
        await gate.release()
        try await caller.shutdown()
        try await peer.shutdown()
        if let failure { throw failure }
    }
}

private distributed actor DeadlineProbe {
    typealias ActorSystem = IMActorSystem
    let gate: LateReplyGate
    init(gate: LateReplyGate, actorSystem: IMActorSystem) {
        self.gate = gate; self.actorSystem = actorSystem
    }
    distributed func echo(milliseconds: UInt64) async throws -> Int {
        try await Task.sleep(for: .milliseconds(milliseconds))
        return 42
    }
    distributed func heldEcho() async -> Int {
        await gate.hold()
        return 42
    }
}
