import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Revoke-only HTTP client")
struct V2HTTPDeviceRevocationClientTests {
    private let endpoint = URL(string: "https://account.example/v2/device-credentials/revoke")!

    @Test("Retries carry the same old capability and operation without account credentials")
    func responseLoss() async throws {
        let transport = RevocationHTTPRecorder(endpoint: endpoint, status: 204, loseFirst: true)
        let client = try V2HTTPDeviceRevocationClient(endpoint: endpoint, transport: transport)
        let credential = V2DeviceRevocationCredential.generate(), operation = UUID()
        await #expect(throws: V2DeviceRevocationClientError.networkFailure) {
            try await client.revoke(credential: credential, operationID: operation)
        }
        #expect(try await client.revoke(credential: credential, operationID: operation) == .revoked)
        let requests = await transport.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.url == endpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "X-IM-Device-ID") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
            #expect(request.timeoutInterval == 15)
            let data = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(Set(body.keys) == Set(["credential", "operationID"]))
            let preserved = body["credential"] == credential.rawValue && body["operationID"] == operation.uuidString
            #expect(preserved)
        }
    }

    @Test("Only 204 means revocation confirmed", arguments: [204, 401, 410, 409, 403, 400, 500, 503, 200, 302])
    func statusMapping(status: Int) async throws {
        let transport = RevocationHTTPRecorder(endpoint: endpoint, status: status)
        let client = try V2HTTPDeviceRevocationClient(endpoint: endpoint, transport: transport)
        let expected: V2DeviceRevocationResult? = [204: .revoked, 401: .invalidCredential, 410: .expired, 409: .operationConflict][status]
        if let expected {
            #expect(try await client.revoke(credential: .generate(), operationID: UUID()) == expected)
        } else {
            await #expect(throws: V2DeviceRevocationClientError.serverStatus(status)) {
                try await client.revoke(credential: .generate(), operationID: UUID())
            }
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("Reject unsafe endpoint components before sending", arguments: [
        "http://account.example/revoke", "https://user:password@account.example/revoke",
        "https://account.example/revoke?credential=secret", "https://account.example/revoke#secret"
    ])
    func endpointValidation(value: String) throws {
        #expect(throws: V2DeviceRevocationClientError.invalidEndpoint) {
            try V2HTTPDeviceRevocationClient(endpoint: #require(URL(string: value)))
        }
    }

    @Test("Rate limit advice preserves valid seconds without treating failure as completion", arguments: ["19", "-1", "invalid", "999999999999999999999999999999"])
    func retryAdvice(value: String) async throws {
        let client = try V2HTTPDeviceRevocationClient(endpoint: endpoint,
            transport: RevocationHTTPRecorder(endpoint: endpoint, status: 429, retryAfter: value))
        await #expect(throws: V2DeviceRevocationClientError.rateLimited(retryAfterSeconds: value == "19" ? 19 : nil)) {
            try await client.revoke(credential: .generate(), operationID: UUID())
        }
    }

    @Test("A cancelled operation cannot accept a late successful response")
    func cancellation() async throws {
        let transport = RevocationHTTPRecorder(endpoint: endpoint, status: 204, cancelOnResponse: true)
        let client = try V2HTTPDeviceRevocationClient(endpoint: endpoint, transport: transport)
        let task = Task { try await client.revoke(credential: .generate(), operationID: UUID()) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }
}

private actor RevocationHTTPRecorder: V2AuthHTTPTransport {
    let endpoint: URL
    let status: Int
    let loseFirst: Bool
    let retryAfter: String?
    let cancelOnResponse: Bool
    private(set) var requests: [URLRequest] = []
    init(endpoint: URL, status: Int, loseFirst: Bool = false, retryAfter: String? = nil, cancelOnResponse: Bool = false) {
        self.endpoint = endpoint; self.status = status; self.loseFirst = loseFirst
        self.retryAfter = retryAfter; self.cancelOnResponse = cancelOnResponse
    }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if loseFirst && requests.count == 1 { throw URLError(.networkConnectionLost) }
        if cancelOnResponse { withUnsafeCurrentTask { $0?.cancel() } }
        return (Data(), try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] })))
    }
}
