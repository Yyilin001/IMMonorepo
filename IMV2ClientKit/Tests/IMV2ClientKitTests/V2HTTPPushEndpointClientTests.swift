import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 HTTP Push endpoint client")
struct V2HTTPPushEndpointClientTests {
    @Test("registration sends only the authenticated no-store contract")
    func registrationRequest() async throws {
        let endpoint = try #require(URL(string: "https://account.example/v2/push-endpoint"))
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000981")
        let transport = RecordingPushEndpointTransport(response: try response(status: 204, endpoint: endpoint))
        let client = try V2HTTPPushEndpointClient(
            endpoint: endpoint,
            credentials: FixedPushCredentials(accessToken: "edge-access-token", deviceID: deviceID),
            transport: transport
        )

        try await client.register(provider: .apns, environment: .development, token: "opaque-device-token")

        let request = try #require(await transport.request())
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer edge-access-token")
        #expect(request.value(forHTTPHeaderField: "X-IM-Device-ID") == deviceID.rawValue)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(PushRegistrationBody.self, from: body)
        #expect(decoded.provider == "apns")
        #expect(decoded.environment == "development")
        #expect(decoded.token == "opaque-device-token")
    }

    @Test("registration rejects malformed tokens before acquiring credentials")
    func rejectsMalformedToken() async throws {
        let endpoint = try #require(URL(string: "https://account.example/v2/push-endpoint"))
        let transport = RecordingPushEndpointTransport(response: try response(status: 204, endpoint: endpoint))
        let client = try V2HTTPPushEndpointClient(
            endpoint: endpoint,
            credentials: FixedPushCredentials(accessToken: "edge-access-token", deviceID: try DeviceID("00000000-0000-0000-0000-000000000982")),
            transport: transport
        )

        await #expect(throws: V2ClientPushEndpointError.invalidRegistration) {
            try await client.register(provider: .apns, environment: .production, token: " token-with-space")
        }
        #expect(await transport.request() == nil)
    }

    @Test("delete maps terminal and retryable edge outcomes without a request body")
    func removeErrorMapping() async throws {
        let endpoint = try #require(URL(string: "https://account.example/v2/push-endpoint"))
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000983")
        let denied = try V2HTTPPushEndpointClient(
            endpoint: endpoint,
            credentials: FixedPushCredentials(accessToken: "edge-access-token", deviceID: deviceID),
            transport: RecordingPushEndpointTransport(response: try response(status: 401, endpoint: endpoint))
        )
        await #expect(throws: V2ClientPushEndpointError.authorizationUnavailable) {
            try await denied.remove()
        }

        let unavailable = try V2HTTPPushEndpointClient(
            endpoint: endpoint,
            credentials: FixedPushCredentials(accessToken: "edge-access-token", deviceID: deviceID),
            transport: RecordingPushEndpointTransport(response: try response(status: 503, endpoint: endpoint))
        )
        await #expect(throws: V2HTTPFailure(kind: .httpStatus, service: "pushEndpoints", statusCode: 503, certainty: .responseReceived)) {
            try await unavailable.remove()
        }
    }

    @Test(arguments: [429, 503])
    func longHTTPDateCooldownSurvivesPushWrite(status: Int) async throws {
        let endpoint = try #require(URL(string: "https://account.example/v2/push-endpoint"))
        let formatter = DateFormatter(); formatter.locale = .init(identifier: "en_US_POSIX"); formatter.timeZone = .init(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil,
            headerFields: ["Retry-After": formatter.string(from: Date().addingTimeInterval(7200))]))
        let client = try V2HTTPPushEndpointClient(endpoint: endpoint,
            credentials: FixedPushCredentials(accessToken: "token", deviceID: .init(uuid: UUID())),
            transport: RecordingPushEndpointTransport(response: response))
        do { try await client.remove(); Issue.record("expected throttle") }
        catch V2ClientPushEndpointError.rateLimited(let seconds) { #expect(status == 429 && seconds >= 7198) }
        catch let failure as V2HTTPFailure {
            #expect(status == 503 && failure.statusCode == 503 && failure.certainty == .responseReceived)
            #expect((failure.retryAfter?.timeIntervalSinceNow ?? 0) >= 7198)
        }
    }

    private func response(status: Int, endpoint: URL) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: ["Cache-Control": "no-store"]))
    }
}

private struct PushRegistrationBody: Decodable {
    let provider: String
    let environment: String
    let token: String
}

private struct FixedPushCredentials: V2ClientPushEndpointCredentialProvider {
    let accessToken: String
    let deviceID: DeviceID

    func pushEndpointCredentials() -> V2ClientPushEndpointCredentials {
        .init(accessToken: accessToken, deviceID: deviceID)
    }
}

private actor RecordingPushEndpointTransport: V2ClientPushEndpointHTTPTransport {
    private let response: HTTPURLResponse
    private var capturedRequest: URLRequest?

    init(response: HTTPURLResponse) {
        self.response = response
    }

    func data(for request: URLRequest) -> (Data, HTTPURLResponse) {
        capturedRequest = request
        return (Data(), response)
    }

    func request() -> URLRequest? { capturedRequest }
}
