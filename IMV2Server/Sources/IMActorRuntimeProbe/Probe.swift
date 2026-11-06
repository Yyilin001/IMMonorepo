import Distributed
import Foundation
import IMActorSystem
import NIOSSL
import Logging
import Synchronization

private final class StopFlag: Sendable { let value = Mutex(false) }
private distributed actor Probe {
    typealias ActorSystem = IMActorSystem
    let stop: StopFlag
    init(actorSystem: IMActorSystem, stop: StopFlag) { self.actorSystem = actorSystem; self.stop = stop }
    distributed func echo(_ bytes: Data) throws -> Data { bytes }
    distributed func sleep(_ milliseconds: Int) async throws -> Int {
        try await Task.sleep(for: .milliseconds(milliseconds)); return milliseconds
    }
    distributed func reject() throws -> Int { throw IMActorError.forbidden }
    distributed func finish() { stop.value.withLock { $0 = true } }
}

/// Small real-process acceptance probe. It does not initialize databases or run a load campaign.
@main struct IMActorRuntimeProbe {
    static func main() async throws {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label); handler.logLevel = .debug; return handler
        }
        let args = CommandLine.arguments
        guard args.count >= 4, let port = Int(args[2]) else {
            print("usage: IMActorRuntimeProbe server|client PORT REFERENCE_FILE [TLS_DIRECTORY]")
            return
        }
        var settings = IMActorSystemSettings(name: "runtime-probe", host: "localhost", port: port)
        settings.threadPoolSize = 1
        settings.maximumCallsPerConnection = 8
        if args.count > 4 {
            let dir = URL(fileURLWithPath: args[4])
            let certs = try NIOSSLCertificate.fromPEMFile(dir.appendingPathComponent("cert.pem").path)
            var tls = TLSConfiguration.makeServerConfiguration(certificateChain: certs.map { .certificate($0) },
                privateKey: .privateKey(try NIOSSLPrivateKey(file: dir.appendingPathComponent("key.pem").path, format: .pem)))
            tls.minimumTLSVersion = .tlsv13; tls.maximumTLSVersion = .tlsv13
            tls.certificateVerification = .fullVerification; tls.trustRoots = .certificates(certs)
            settings.tls = tls
        }
        settings.methods = [
            try await IMActorSystem.register(id: 1, actor: Probe.self) { _ = try await $0.echo(Data()) },
            try await IMActorSystem.register(id: 2, actor: Probe.self) { _ = try await $0.sleep(0) },
            try await IMActorSystem.register(id: 3, actor: Probe.self) { _ = try await $0.reject() },
            try await IMActorSystem.register(id: 4, traffic: .control, actor: Probe.self) { try await $0.finish() },
        ]
        let system = try await IMActorSystem(settings.name, settings: settings)
        do {
            let file = URL(fileURLWithPath: args[3])
            if args[1] == "server" {
                let flag = StopFlag()
                // Keep the published actor alive explicitly for the whole server lifecycle.
                let endpoint = Probe(actorSystem: system, stop: flag)
                try system.publish(endpoint, as: .init(Probe.self, id: "probe"))
                try JSONEncoder().encode(endpoint.id).write(to: file, options: .atomic)
                let end = ContinuousClock.now + .seconds(45)
                while !flag.value.withLock({ $0 }), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
                withExtendedLifetime(endpoint) {}
            } else {
                let id = try JSONDecoder().decode(IMActorID.self, from: Data(contentsOf: file))
                let endpoints = try await system.lookup(IMServiceKey(Probe.self, id: "probe"), at: id.node.endpoint)
                guard endpoints.count == 1, endpoints[0].id == id else { throw IMActorError.unknownActor }
                let remote = endpoints[0]
                let bytes = Data(repeating: 173, count: 131_072)
                guard try await remote.echo(bytes) == bytes else { throw IMActorError.malformed }
                do { _ = try await remote.reject(); throw IMActorError.malformed } catch IMActorError.forbidden {}
                do {
                    _ = try await IMRemoteCall.with(timeout: .milliseconds(20)) { try await remote.sleep(200) }
                    throw IMActorError.malformed
                } catch IMActorError.deadlineExceeded {}
                let cancelled = Task { try await remote.sleep(200) }
                try await Task.sleep(for: .milliseconds(20)); cancelled.cancel()
                do { _ = try await cancelled.value; throw IMActorError.malformed } catch IMActorError.cancelled {}
                // Late replies and credit return must not break subsequent calls.
                guard try await remote.sleep(0) == 0 else { throw IMActorError.malformed }
                let stale = try Probe.resolve(id: .init(node: .init(id: id.node.id, endpoint: id.node.endpoint), localID: id.localID), using: system)
                do { _ = try await stale.echo(Data()); throw IMActorError.malformed } catch IMActorError.staleIncarnation {}
                try await remote.finish()
                print("PASS: real-process discovery, binary RPC, typed error, timeout, cancellation, stale incarnation and shutdown")
            }
            try await system.shutdown()
        } catch { try? await system.shutdown(); throw error }
    }
}
