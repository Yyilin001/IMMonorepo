import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import IMV2ClientNetwork
import IMV2ClientRuntime

@Suite("Portable HTTP execution", .serialized, .timeLimit(.minutes(1)))
struct V2PortableHTTPTransportTests {
    private struct Transport: V2HTTPTransport {
        let pool: V2FoundationHTTPSession
        init(session: URLSession) { pool = .init(configurationSource: session) }
        func makeExecution(events: V2HTTPTransportEvents) -> any V2HTTPTransportExecution {
            V2FoundationHTTPExecution(pool: pool, events: events)
        }
    }
    @Test func sharedSessionRoutesConcurrentResponsesToTheirOwners() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortableHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let executor = V2HTTPExecutor(transport: Transport(session: session))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let name = index.isMultiple(of: 2) ? "one" : "two"
                    let (body, _) = try await executor.execute(.init(url: URL(string: "https://test.invalid/" + name)!))
                    #expect(String(decoding: body, as: UTF8.self) == name)
                }
            }
            try await group.waitForAll()
        }
    }
    @Test func headerCooldownPrecedesBodyLimitFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortableHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
        let metrics = V2NetworkDiagnostics()
        let executor = V2HTTPExecutor(transport: Transport(session: session), scheduler: scheduler, metrics: { metrics.record($0) })
        do {
            _ = try await executor.execute(.init(url: URL(string: "https://test.invalid/cooldown")!), budget: .init(maximumResponseBytes: 1))
            Issue.record("Expected cap failure")
        } catch let error as V2HTTPFailure { #expect(error.kind == .responseTooLarge) }
        do {
            _ = try await executor.execute(.init(url: URL(string: "https://test.invalid/ok")!), budget: .init(timeout: 0.02))
            Issue.record("Expected admission deadline")
        } catch let error as V2HTTPFailure {
            #expect(error.kind == .deadlineExceeded); #expect(error.certainty == .notStarted)
        }
        #expect(await scheduler.snapshot().active == 0)
        #expect(metrics.snapshot().samples.count == 2)
        await scheduler.closeAndDrain()
    }
    @Test func delegateSupportsSuccessExactLimitAndRepeatedPreCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortableHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = Transport(session: session)
        let executor = V2HTTPExecutor(transport: transport)
        let request = URLRequest(url: URL(string: "https://test.invalid/ok")!)
        let (body, response) = try await executor.execute(request, budget: .init(maximumResponseBytes: 2))
        #expect(body == Data("ok".utf8)); #expect(response.statusCode == 200)
        for _ in 0..<20 {
            let execution = transport.makeExecution(events: .init())
            execution.cancel(); execution.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await execution.execute(request, maximumResponseBytes: 2, service: "test", onResponse: { _ in })
            }
        }
    }
}
private final class PortableHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let cooldown = request.url!.path == "/cooldown"
        let name = request.url!.lastPathComponent
        let body = Data((["one", "two"].contains(name) ? name : "ok").utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: cooldown ? 503 : 200, httpVersion: nil,
            headerFields: cooldown ? ["Retry-After": "60", "Content-Length": "2"] : ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
