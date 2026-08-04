import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 HTTP device-session client")
struct V2HTTPDeviceSessionClientTests {
    @Test("list and remote revoke use only the authenticated no-store contract")
    func listAndRevokeRequests() async throws {
        let endpoint = try #require(URL(string: "https://account.example/v2/devices"))
        let current = try DeviceID("00000000-0000-0000-0000-000000000901")
        let other = try DeviceID("00000000-0000-0000-0000-000000000902")
        let transport = RecordingDeviceSessionTransport(responses: [
            try response(status: 200, endpoint: endpoint, body: "[{\"deviceID\":\"\(current.rawValue)\",\"deviceName\":\"iPhone\",\"platform\":\"iPhone\",\"createdAtMilliseconds\":1750000000000,\"lastActiveAtMilliseconds\":1750000001000,\"isCurrentDevice\":true}]"),
            try response(status: 204, endpoint: endpoint.appendingPathComponent("revoke"), body: "")
        ])
        let client = try V2HTTPDeviceSessionClient(
            endpoint: endpoint,
            credentials: FixedDeviceSessionCredentials(accessToken: "edge-token", deviceID: current),
            transport: transport
        )

        let sessions = try await client.list()
        #expect(sessions.count == 1)
        #expect(sessions[0].deviceName == "iPhone")
        #expect(sessions[0].isCurrentDevice)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000903")!
        try await client.revoke(deviceID: other, operationID: operationID)

        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[1].httpMethod == "POST")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer edge-token" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-IM-Device-ID") == current.rawValue })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        let body = try #require(requests[1].httpBody)
        let decoded = try JSONDecoder().decode(MutationBody.self, from: body)
        #expect(decoded.deviceID == other.rawValue)
        #expect(decoded.operationID == operationID)
    }

    @Test("not-found revoke is a distinct idempotent-safe outcome")
    func unavailableRemoteSession() async throws {
        let endpoint = try #require(URL(string: "https://account.example/v2/devices"))
        let current = try DeviceID("00000000-0000-0000-0000-000000000911")
        let client = try V2HTTPDeviceSessionClient(
            endpoint: endpoint,
            credentials: FixedDeviceSessionCredentials(accessToken: "edge-token", deviceID: current),
            transport: RecordingDeviceSessionTransport(responses: [try response(status: 404, endpoint: endpoint.appendingPathComponent("revoke"), body: "")])
        )
        await #expect(throws: V2ClientDeviceSessionError.sessionUnavailable) {
            try await client.revoke(deviceID: try DeviceID("00000000-0000-0000-0000-000000000912"), operationID: UUID())
        }
    }

    private func response(status: Int, endpoint: URL, body: String) throws -> (Data, HTTPURLResponse) {
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: ["Cache-Control": "no-store"]))
        return (Data(body.utf8), response)
    }
}

private struct FixedDeviceSessionCredentials: V2ClientDeviceSessionCredentialProvider {
    let accessToken: String; let deviceID: DeviceID
    func deviceSessionCredentials() -> V2ClientDeviceSessionCredentials { .init(accessToken: accessToken, deviceID: deviceID) }
}
private struct MutationBody: Decodable { let deviceID: String?; let operationID: UUID }
private actor RecordingDeviceSessionTransport: V2ClientDeviceSessionHTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private var captured: [URLRequest] = []
    init(responses: [(Data, HTTPURLResponse)]) { self.responses = responses }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !responses.isEmpty else { throw V2ClientDeviceSessionError.networkFailure }
        return responses.removeFirst()
    }
    func requests() -> [URLRequest] { captured }
}
