import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientKit
import Testing

@Suite("Default account HTTP adapters", .serialized)
struct V2AccountHTTPAdapterTests {
    @Test(arguments: [0, 1, 2, 3])
    func adaptersBoundStreamingBodyAndUseOneLeafPermit(adapter: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountAdapterProtocol.self]
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1, serviceLimit: 1))
        let executor = V2HTTPExecutor(session: session, scheduler: scheduler)
        let request = URLRequest(url: URL(string: "https://account.example/large")!)
        do {
            switch adapter {
            case 0: _ = try await V2URLSessionDeviceSessionHTTPTransport(executor: executor).data(for: request)
            case 1: _ = try await V2URLSessionPushEndpointHTTPTransport(executor: executor).data(for: request)
            case 2: _ = try await V2URLSessionMediaEdgeHTTPTransport(executor: executor).data(for: request)
            default: _ = try await V2URLSessionGroupInvitationHTTPTransport(executor: executor).data(for: request)
            }
            Issue.record("expected streaming response limit")
        } catch let failure as V2HTTPFailure {
            #expect(failure.kind == .responseTooLarge)
            #expect(failure.statusCode == 200)
        }
        #expect(await scheduler.snapshot().active == 0)
        #expect(await scheduler.snapshot().waiting == 0)
        await scheduler.closeAndDrain()
    }
}
private final class AccountAdapterProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 1_048_576))
        client?.urlProtocol(self, didLoad: Data([2]))
        // No terminal callback: crossing the cap must cancel and drain actual I/O.
    }
    override func stopLoading() {}
}
