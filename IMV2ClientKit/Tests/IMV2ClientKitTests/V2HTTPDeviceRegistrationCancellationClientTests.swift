import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Registration cancellation HTTP client")
struct V2HTTPDeviceRegistrationCancellationClientTests {
    private let endpoint = URL(string: "https://account.example/v2/device-credentials/cancel-registration")!

    private func request() throws -> V2DeviceRegistrationCancellation {
        try .init(deviceID: DeviceID(UUID().uuidString), operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: 1_800_000_000_000)
    }

    @Test("response loss retries the same proof and deadline without account authentication")
    func responseLoss() async throws {
        let transport = CancellationHTTPRecorder(endpoint: endpoint, status: 204, failure: "lost-first")
        let client = try V2HTTPDeviceRegistrationCancellationClient(endpoint: endpoint, transport: transport)
        let cancellation = try request()
        await #expect(throws: V2DeviceRegistrationCancellationClientError.networkFailure) { try await client.cancel(cancellation) }
        #expect(try await client.cancel(cancellation) == .cancelled)
        let sent = await transport.requests
        #expect(sent.count == 2)
        for request in sent {
            #expect(request.url == endpoint && request.httpMethod == "POST")
            #expect(request.timeoutInterval == 15)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "X-IM-Device-ID") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            let data = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(body.keys) == Set(["deviceID", "operationID", "proof", "issueBeforeMilliseconds"]))
            #expect(try JSONDecoder().decode(V2DeviceRegistrationCancellation.self, from: data) == cancellation)
        }
    }

    @Test("only explicit empty 204 or 410 settles a request", arguments: [204, 410, 200, 302, 400, 401, 403, 409, 500, 503])
    func outcomes(status: Int) async throws {
        let client = try V2HTTPDeviceRegistrationCancellationClient(endpoint: endpoint,
            transport: CancellationHTTPRecorder(endpoint: endpoint, status: status))
        if status == 204 || status == 410 {
            #expect(try await client.cancel(request()) == (status == 204 ? .cancelled : .expired))
        } else {
            await #expect(throws: V2DeviceRegistrationCancellationClientError.serverStatus(status)) { try await client.cancel(request()) }
        }
    }

    @Test("unexpected completion bodies cannot clear durable work", arguments: [204, 410])
    func unexpectedBody(status: Int) async throws {
        let client = try V2HTTPDeviceRegistrationCancellationClient(endpoint: endpoint,
            transport: CancellationHTTPRecorder(endpoint: endpoint, status: status, body: Data("unexpected".utf8)))
        await #expect(throws: V2DeviceRegistrationCancellationClientError.invalidResponse) { try await client.cancel(request()) }
    }

    @Test("unsafe endpoint components never send a proof", arguments: ["http://account.example/cancel", "https://user:pass@account.example/cancel", "https://account.example/cancel?proof=x", "https://account.example/cancel#x"])
    func endpoints(value: String) throws {
        #expect(throws: V2DeviceRegistrationCancellationClientError.invalidEndpoint) {
            try V2HTTPDeviceRegistrationCancellationClient(endpoint: #require(URL(string: value)))
        }
    }

    @Test("rate limit advice is preserved without completion", arguments: ["19", "-1", "invalid", "9999999999999999999999999"])
    func rateLimit(value: String) async throws {
        let client = try V2HTTPDeviceRegistrationCancellationClient(endpoint: endpoint,
            transport: CancellationHTTPRecorder(endpoint: endpoint, status: 429, retryAfter: value))
        await #expect(throws: V2DeviceRegistrationCancellationClientError.rateLimited(retryAfterSeconds: value == "19" ? 19 : nil)) {
            try await client.cancel(request())
        }
    }

    @Test("transport cancellation and late success retain cancellation semantics", arguments: ["cancelled-url", "late-success"])
    func cancellation(failure: String) async throws {
        let transport = CancellationHTTPRecorder(endpoint: endpoint, status: 204, failure: failure)
        let client = try V2HTTPDeviceRegistrationCancellationClient(endpoint: endpoint, transport: transport)
        let task = Task { try await client.cancel(request()) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }
}

private actor CancellationHTTPRecorder: V2AuthHTTPTransport {
    let endpoint: URL
    let status: Int
    let body: Data
    let failure: String?
    let retryAfter: String?
    private(set) var requests: [URLRequest] = []
    init(endpoint: URL, status: Int, body: Data = Data(), failure: String? = nil, retryAfter: String? = nil) {
        self.endpoint = endpoint; self.status = status; self.body = body; self.failure = failure; self.retryAfter = retryAfter
    }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if failure == "lost-first", requests.count == 1 { throw URLError(.networkConnectionLost) }
        if failure == "cancelled-url" { throw URLError(.cancelled) }
        if failure == "late-success" { withUnsafeCurrentTask { $0?.cancel() } }
        return (body, try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] })))
    }
}
