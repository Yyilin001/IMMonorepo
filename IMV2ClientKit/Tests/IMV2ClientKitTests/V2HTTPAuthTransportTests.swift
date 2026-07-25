import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 HTTP auth transport")
struct V2HTTPAuthTransportTests {
    @Test("refresh posts no-store credentials and decodes the server contract")
    func refreshPostsContract() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/device-credentials/refresh"))
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"]))
        let request = try refreshRequest()
        let payload = try JSONEncoder().encode(RefreshResponse(
            userID: request.userID.rawValue,
            deviceID: request.deviceID.rawValue,
            accessToken: "next-access",
            accessTokenExpiresAtMilliseconds: 1_750_000_600_125,
            refreshCredential: "next-refresh"
        ))
        let http = RecordingAuthHTTPTransport(result: .success((payload, response)))
        let transport = try V2HTTPDeviceCredentialAuthTransport(refreshEndpoint: endpoint, transport: http)

        let credentials = try await transport.refresh(request)

        #expect(credentials.userID == request.userID)
        #expect(credentials.deviceID == request.deviceID)
        #expect(credentials.accessToken == "next-access")
        #expect(credentials.accessTokenExpiresAt == Date(timeIntervalSince1970: 1_750_000_600.125))
        #expect(credentials.refreshCredential == "next-refresh")
        let sent = try #require(await http.lastRequest())
        #expect(sent.url == endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(sent.value(forHTTPHeaderField: "Pragma") == "no-cache")
        let body = try #require(sent.httpBody)
        let decoded = try JSONDecoder().decode(RefreshRequest.self, from: body)
        #expect(decoded.userID == request.userID.rawValue)
        #expect(decoded.deviceID == request.deviceID.rawValue)
        #expect(decoded.refreshCredential == request.refreshCredential)
        #expect(decoded.operationID == request.operationID)
    }

    @Test("only credential rejection is terminal")
    func mapsTerminalRejection() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/device-credentials/refresh"))
        let rejected = try #require(HTTPURLResponse(url: endpoint, statusCode: 401, httpVersion: nil, headerFields: nil))
        let unavailable = try #require(HTTPURLResponse(url: endpoint, statusCode: 503, httpVersion: nil, headerFields: nil))

        let terminal = try V2HTTPDeviceCredentialAuthTransport(
            refreshEndpoint: endpoint,
            transport: RecordingAuthHTTPTransport(result: .success((Data(), rejected)))
        )
        await #expect(throws: V2AuthTransportError.terminalRejection) { try await terminal.refresh(try refreshRequest()) }

        let retryable = try V2HTTPDeviceCredentialAuthTransport(
            refreshEndpoint: endpoint,
            transport: RecordingAuthHTTPTransport(result: .success((Data(), unavailable)))
        )
        await #expect(throws: V2HTTPAuthTransportError.serverStatus(503)) { try await retryable.refresh(try refreshRequest()) }
    }

    @Test("non-HTTPS endpoint and malformed success response are rejected")
    func rejectsUnsafeEndpointAndMalformedResponse() async throws {
        #expect(throws: V2HTTPAuthTransportError.invalidEndpoint) {
            _ = try V2HTTPDeviceCredentialAuthTransport(refreshEndpoint: #require(URL(string: "http://account.invalid/refresh")))
        }
        let endpoint = try #require(URL(string: "https://account.invalid/v2/device-credentials/refresh"))
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
        let transport = try V2HTTPDeviceCredentialAuthTransport(
            refreshEndpoint: endpoint,
            transport: RecordingAuthHTTPTransport(result: .success((Data("{}".utf8), response)))
        )
        await #expect(throws: V2HTTPAuthTransportError.invalidResponse) { try await transport.refresh(try refreshRequest()) }
    }

    private func refreshRequest() throws -> V2RefreshRequest {
        .init(
            userID: try .init("00000000-0000-0000-0000-000000000511"),
            deviceID: try .init("00000000-0000-0000-0000-000000000512"),
            refreshCredential: "predecessor-refresh",
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000513")!
        )
    }
}

private actor RecordingAuthHTTPTransport: V2AuthHTTPTransport {
    private let result: Result<(Data, HTTPURLResponse), Error>
    private var request: URLRequest?

    init(result: Result<(Data, HTTPURLResponse), Error>) { self.result = result }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try result.get()
    }

    func lastRequest() -> URLRequest? { request }
}

private struct RefreshRequest: Decodable {
    let userID: String
    let deviceID: String
    let refreshCredential: String
    let operationID: UUID
}

private struct RefreshResponse: Encodable {
    let userID: String
    let deviceID: String
    let accessToken: String
    let accessTokenExpiresAtMilliseconds: Int64
    let refreshCredential: String
}
