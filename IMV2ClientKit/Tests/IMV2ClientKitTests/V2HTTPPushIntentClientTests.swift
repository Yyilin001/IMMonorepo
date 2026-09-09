import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientKit
import IMV2Core
import Testing

@Suite("Versioned Push HTTP client")
struct V2HTTPPushIntentClientTests {
    private let device = DeviceID(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000812")!)
    private let endpoint = URL(string: "https://account.example/v2/push-endpoint")!

    @Test("metadata, claim and desired writes preserve exact integer versions and device binding")
    func requestContract() async throws {
        let transport = IntentHTTPTransport(replies: [(200, "{\"epoch\":0}"), (200, "{\"epoch\":1}"), (204, ""), (204, "")])
        let client = try V2HTTPPushEndpointClient(endpoint: endpoint, credentials: IntentCredentials(device: device), transport: transport)
        #expect(try await client.intentEpoch(deviceID: device) == 0)
        let claim = try V2PushIntentSessionClaim(requestID: UUID(), expectedEpoch: 0)
        #expect(try await client.claimIntentSession(deviceID: device, claim: claim) == 1)
        try await client.publishIntent(deviceID: device, version: .init(epoch: 1, revision: UInt64(Int64.max) - 1), intent: .disabled)
        try await client.publishIntent(deviceID: device, version: .init(epoch: 1, revision: UInt64(Int64.max)), intent: .enabled(provider: .apns, environment: .development, token: "opaque-token"))
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "PUT", "PUT"])
        #expect(requests.map { $0.url?.path } == ["/v2/push-endpoint/session", "/v2/push-endpoint/session", "/v2/push-endpoint/intent", "/v2/push-endpoint/intent"])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "X-IM-Device-ID") == device.rawValue)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(request.timeoutInterval == 15)
        }
        #expect(requests[0].httpBody == nil)
        struct Claim: Decodable { let requestID: UUID; let expectedEpoch: UInt64 }
        let sentClaim = try JSONDecoder().decode(Claim.self, from: #require(requests[1].httpBody))
        #expect(sentClaim.requestID == claim.requestID && sentClaim.expectedEpoch == 0)
        struct Intent: Decodable { let epoch: UInt64; let revision: UInt64; let enabled: Bool; let token: String? }
        let disabled = try JSONDecoder().decode(Intent.self, from: #require(requests[2].httpBody))
        let enabled = try JSONDecoder().decode(Intent.self, from: #require(requests[3].httpBody))
        #expect(disabled.epoch == 1 && disabled.revision == UInt64(Int64.max) - 1 && !disabled.enabled && disabled.token == nil)
        #expect(enabled.revision == UInt64(Int64.max) && enabled.enabled && enabled.token == "opaque-token")
    }

    @Test("stale, conflict and version-required replies never cause an automatic claim or retry")
    func conditionalFailures() async throws {
        for (status, body, error) in [(409, "{\"code\":\"stale_intent\"}", V2ClientPushEndpointError.staleIntent), (409, "{\"code\":\"intent_conflict\"}", .intentConflict), (409, "{\"code\":\"unknown\"}", .invalidResponse), (428, "", .intentVersionRequired), (401, "", .authorizationDenied), (403, "", .authorizationDenied), (503, "", .serverStatus(503))] {
            let transport = IntentHTTPTransport(replies: [(status, body)])
            let client = try V2HTTPPushEndpointClient(endpoint: endpoint, credentials: IntentCredentials(device: device), transport: transport)
            await #expect(throws: error) { try await client.publishIntent(deviceID: device, version: .init(epoch: 1, revision: 1), intent: .disabled) }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test("epoch metadata validates response shape, bigint domain and exact claim successor")
    func epochValidation() async throws {
        for body in ["{}", "{\"epoch\":-1}", "{\"epoch\":9223372036854775808}", "{\"epoch\":\"1\"}", String(repeating: " ", count: 1_025)] {
            let client = try V2HTTPPushEndpointClient(endpoint: endpoint, credentials: IntentCredentials(device: device), transport: IntentHTTPTransport(replies: [(200, body)]))
            await #expect(throws: V2ClientPushEndpointError.invalidResponse) { try await client.intentEpoch(deviceID: device) }
        }
        let client = try V2HTTPPushEndpointClient(endpoint: endpoint, credentials: IntentCredentials(device: device), transport: IntentHTTPTransport(replies: [(200, "{\"epoch\":2}")]))
        await #expect(throws: V2ClientPushEndpointError.invalidResponse) {
            try await client.claimIntentSession(deviceID: device, claim: .init(requestID: UUID(), expectedEpoch: 0))
        }
    }

    @Test("429 retains the server's retry minimum")
    func retryMinimum() async throws {
        let client = try V2HTTPPushEndpointClient(endpoint: endpoint, credentials: IntentCredentials(device: device), transport: IntentHTTPTransport(replies: [(429, "")], retryAfter: "120"))
        await #expect(throws: V2ClientPushEndpointError.rateLimited(retryAfter: 120)) {
            try await client.publishIntent(deviceID: device, version: .init(epoch: 1, revision: 1), intent: .disabled)
        }
    }

    @Test("different credential device and malformed token are rejected before HTTP")
    func deviceFence() async throws {
        let transport = IntentHTTPTransport(replies: [])
        let credentials = IntentCredentials(device: .init(uuid: UUID()))
        let client = try V2HTTPPushEndpointClient(endpoint: endpoint, credentials: credentials, transport: transport)
        await #expect(throws: V2ClientPushEndpointError.authorizationUnavailable) {
            try await client.publishIntent(deviceID: device, version: .init(epoch: 1, revision: 1), intent: .disabled)
        }
        await #expect(throws: V2ClientPushEndpointError.invalidRegistration) {
            try await client.publishIntent(deviceID: device, version: .init(epoch: 1, revision: 1), intent: .enabled(provider: .apns, environment: .development, token: " invalid"))
        }
        #expect(await transport.requests.isEmpty)
    }
}

private struct IntentCredentials: V2ClientPushEndpointCredentialProvider {
    let device: DeviceID
    func pushEndpointCredentials() -> V2ClientPushEndpointCredentials { .init(accessToken: "access-token", deviceID: device) }
}

private actor IntentHTTPTransport: V2ClientPushEndpointHTTPTransport {
    private var replies: [(Int, String)]
    var requests: [URLRequest] = []
    private let retryAfter: String?
    init(replies: [(Int, String)], retryAfter: String? = nil) { self.replies = replies; self.retryAfter = retryAfter }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = try #require(replies.first)
        replies.removeFirst()
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil, headerFields: retryAfter.map { ["Retry-After": $0] }))
        return (Data(reply.1.utf8), response)
    }
}
