import Configuration
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Server
import IMV2ServerHTTP
import Logging
import ServiceLifecycle
import Testing
import Vapor

@Suite("V2 HTTP process lifecycle", .serialized)
struct V2HTTPServiceTests {
    @Test("validated listener settings are independent of generic configuration providers")
    func listenerConfigurationIsExplicit() async throws {
        let app = try await V2HTTPService.makeApplication(host: "127.0.0.1", port: 0)
        #expect(app.serverConfiguration.hostname == "127.0.0.1")
        #expect(app.serverConfiguration.port == 0)
        #expect(app.configReader.string(forKey: "hostname") == nil)
        #expect(app.configReader.string(forKey: "port") == nil)
        app.get("probe") { _ in "ready" }
        try await V2HTTPService.withRunning(app, logger: .init(label: "test.http")) { _ in
            let address = try await app.server.listeningAddress
            #expect(address.host == "127.0.0.1")
            let port = try #require(address.port)
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/probe"))
            let (body, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: body, as: UTF8.self) == "ready")
        }
        try await app.shutdown()
    }

    @Test("a conflicting listener fails without entering its operation or hanging its task scope")
    func failedBindClosesScope() async throws {
        let first = try await V2HTTPService.makeApplication(host: "127.0.0.1", port: 0)
        try await V2HTTPService.withRunning(first, logger: .init(label: "test.http.first")) { _ in
            let port = try #require(try await first.server.listeningAddress.port)
            let conflicting = try await V2HTTPService.makeApplication(host: "127.0.0.1", port: port)
            await #expect(throws: (any Error).self) {
                try await V2HTTPService.withRunning(conflicting, logger: .init(label: "test.http.conflict")) { _ in
                    Issue.record("conflicting listener unexpectedly became ready")
                }
            }
            try await conflicting.shutdown()
        }
    }

    @Test("HTTP service failure cancels a role waiting for the process signal")
    func failedServiceCancelsSignalWaiter() async throws {
        let gate = HTTPServiceTestGate()
        let server = FailingHTTPTestServer(gate: gate)
        let app = try await Application(.testing, configReader: ConfigReader(provider: InMemoryProvider(values: [:])),
                                        services: .init(server: .provided(server)))
        await #expect(throws: HTTPServiceTestFailure.self) {
            try await V2HTTPService.withRunning(app, logger: .init(label: "test.http.failure"),
                waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
                await gate.open()
                await shutdown.wait()
            }
        }
        // A cancelled waiter must have left the process signal source intact
        // and removed only its own continuation, permitting another scope.
        let waiter = Task { await V2ProcessTerminationSignal.wait() }
        waiter.cancel()
        await waiter.value
    }

    @Test("cancelling the role wakes its shutdown operation without a signal waiter")
    func cancellationWakesShutdownRequest() async throws {
        let entered = HTTPServiceTestGate()
        let app = try await V2HTTPService.makeApplication(host: "127.0.0.1", port: 0)
        let running = Task {
            try await V2HTTPService.withRunning(app, logger: .init(label: "test.http.cancel")) { shutdown in
                await entered.open()
                await shutdown.wait()
            }
        }
        await entered.wait()
        running.cancel()
        _ = await running.result
        #expect(app.didShutdown)
    }

    @Test("graceful service cleanup finishes before the HTTP scope releases dependencies")
    func waitsForServiceDrain() async throws {
        let drain = HTTPServiceTestGate()
        let server = DrainingHTTPTestServer(drain: drain)
        let app = try await Application(.testing, configReader: ConfigReader(provider: InMemoryProvider(values: [:])),
                                        services: .init(server: .provided(server)))
        try await V2HTTPService.withRunning(app, logger: .init(label: "test.http.drain")) { _ in }
        #expect(await drain.isOpen)
    }

    @Test("an active streamed response finishes before the HTTP scope exits")
    func waitsForStreamedResponse() async throws {
        let streamStarted = HTTPServiceTestGate()
        let releaseStream = HTTPServiceTestGate()
        let signal = HTTPServiceTestGate()
        let scopeExited = HTTPServiceTestGate()
        let app = try await V2HTTPService.makeApplication(host: "127.0.0.1", port: 0)
        app.get("stream") { _ -> Response in
            Response(body: .init(stream: { writer in
                try await writer.write("begin")
                await streamStarted.open()
                await releaseStream.wait()
                try await writer.write("end")
            }))
        }

        let client = Task {
            let address = try await app.server.listeningAddress
            let port = try #require(address.port)
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/stream"))
            let (body, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: body, as: UTF8.self) == "beginend")
        }
        let release = Task {
            await streamStarted.wait()
            await signal.open()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!(await scopeExited.isOpen))
            await releaseStream.open()
        }
        try await V2HTTPService.withRunning(app, logger: .init(label: "test.http.stream"),
            waitForShutdown: { await signal.wait() }) { shutdown in
            await shutdown.wait()
        }
        await scopeExited.open()
        try await release.value
        try await client.value
        #expect(app.didShutdown)
    }
}

private struct HTTPServiceTestFailure: Error {}

private actor HTTPServiceTestGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct FailingHTTPTestServer: Server {
    let gate: HTTPServiceTestGate
    private let ready = HTTPServiceTestGate()
    var listeningAddress: Vapor.SocketAddress {
        get async throws { await ready.wait(); return .ipv4(host: "127.0.0.1", port: 1) }
    }
    func run() async throws {
        await ready.open()
        await gate.wait()
        throw HTTPServiceTestFailure()
    }
}

private struct DrainingHTTPTestServer: Server {
    let drain: HTTPServiceTestGate
    private let ready = HTTPServiceTestGate()
    var listeningAddress: Vapor.SocketAddress {
        get async throws { await ready.wait(); return .ipv4(host: "127.0.0.1", port: 1) }
    }
    func run() async throws {
        await ready.open()
        try await gracefulShutdown()
        try await Task.sleep(for: .milliseconds(20))
        await drain.open()
    }
}
