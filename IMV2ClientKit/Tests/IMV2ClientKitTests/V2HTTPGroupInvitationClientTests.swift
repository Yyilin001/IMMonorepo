import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 HTTP group invitation client")
struct V2HTTPGroupInvitationClientTests {
    @Test("create uses authenticated no-store HTTPS and keeps the invite secret out of the URL")
    func createContract() async throws {
        let baseURL = try #require(URL(string: "https://account.example"))
        let endpoint = baseURL.appendingPathComponent("v2/group-invites")
        let token = String(repeating: "A", count: 43)
        let transport = RecordingGroupInvitationTransport(responses: [try response(
            status: 200,
            endpoint: endpoint,
            body: """
            {"invite_id":"00000000-0000-0000-0000-000000000201","room_id":"00000000-0000-0000-0000-000000000202","room_title":"测试群","token":"\(token)","state":"active","expires_at_ms":2000003600000,"maximum_approved_uses":20,"approved_use_count":0,"created_at_ms":2000000000000}
            """
        )])
        let device = try DeviceID("00000000-0000-0000-0000-000000000203")
        let client = try V2HTTPGroupInvitationClient(
            baseURL: baseURL,
            credentials: GroupInvitationCredentials(accessToken: "edge-token", deviceID: device),
            transport: transport
        )

        let link = try await client.create(
            roomID: try .init("00000000-0000-0000-0000-000000000202"),
            operationID: try .init("00000000-0000-0000-0000-000000000204"),
            lifetimeSeconds: 3_600,
            maximumApprovedUses: 20
        )

        #expect(link.secret.rawValue == token)
        let request = try #require(await transport.requests().first)
        #expect(request.url == endpoint)
        #expect(request.url?.absoluteString.contains(token) == false)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer edge-token")
        #expect(request.value(forHTTPHeaderField: "X-IM-Device-ID") == device.rawValue)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["room_id"] as? String == "00000000-0000-0000-0000-000000000202")
        #expect(object["lifetime_seconds"] as? Int == 3_600)
        #expect(object["maximum_approved_uses"] as? Int == 20)
    }

    @Test("preview sends its bearer secret only in the request body and maps unavailable links")
    func previewUnavailable() async throws {
        let baseURL = try #require(URL(string: "https://account.example"))
        let endpoint = baseURL.appendingPathComponent("v2/group-invites/preview")
        let transport = RecordingGroupInvitationTransport(responses: [try response(status: 404, endpoint: endpoint, body: "")])
        let client = try V2HTTPGroupInvitationClient(
            baseURL: baseURL,
            credentials: GroupInvitationCredentials(
                accessToken: "edge-token",
                deviceID: try .init("00000000-0000-0000-0000-000000000211")
            ),
            transport: transport
        )
        let secret = try V2GroupInviteSecret(String(repeating: "B", count: 43))

        await #expect(throws: V2ClientGroupInvitationError.unavailable) {
            _ = try await client.preview(secret: secret)
        }
        let request = try #require(await transport.requests().first)
        #expect(request.url?.absoluteString.contains(secret.rawValue) == false)
        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains(secret.rawValue))
    }

    @Test("plain HTTP endpoints are rejected before any credential access")
    func rejectsPlainHTTP() throws {
        #expect(throws: V2ClientGroupInvitationError.invalidEndpoint) {
            _ = try V2HTTPGroupInvitationClient(
                baseURL: #require(URL(string: "http://account.example")),
                credentials: GroupInvitationCredentials(
                    accessToken: "edge-token",
                    deviceID: try .init("00000000-0000-0000-0000-000000000221")
                )
            )
        }
    }

    @Test("cancellation binds request and room and accepts only complete terminal responses", arguments: ["cancelled", "approved", "rejected", "pending", "approving", "wrong-room", "wrong-request", "missing-time"])
    func cancelContract(_ scenario: String) async throws {
        let baseURL = try #require(URL(string: "https://account.example"))
        let room = RoomID(uuid: UUID()), requestID = GroupJoinRequestID(uuid: UUID())
        let endpoint = baseURL.appendingPathComponent("v2/group-join-requests/\(requestID.rawValue)/cancel")
        let state = scenario.contains("-") ? "cancelled" : scenario
        let body: [String: Any] = [
            "request_id": scenario == "wrong-request" ? UUID().uuidString : requestID.rawValue,
            "room_id": scenario == "wrong-room" ? UUID().uuidString : room.rawValue,
            "invite_id": UUID().uuidString,
            "applicant": ["user_id": UUID().uuidString, "handle": "applicant", "display_name": "Applicant", "account_kind": "regular"],
            "state": state, "created_at_ms": 1750000000000,
            "decided_at_ms": scenario == "missing-time" || state == "pending" || state == "approving" ? NSNull() : 1750000001000
        ]
        let transport = RecordingGroupInvitationTransport(responses: [try response(status: 200, endpoint: endpoint, body: String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self))])
        let client = try V2HTTPGroupInvitationClient(baseURL: baseURL, credentials: GroupInvitationCredentials(accessToken: "edge-token", deviceID: .init(uuid: UUID())), transport: transport)
        if ["cancelled", "approved", "rejected"].contains(scenario) {
            let result = try await client.cancel(roomID: room, requestID: requestID)
            #expect(result.state.rawValue == scenario && result.requestID == requestID)
        } else {
            await #expect(throws: V2ClientGroupInvitationError.invalidResponse) { _ = try await client.cancel(roomID: room, requestID: requestID) }
        }
        let sent = try #require(await transport.requests().first)
        #expect(sent.url == endpoint && sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer edge-token")
        #expect(sent.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let data = try #require(sent.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(payload == ["room_id": room.rawValue])
    }

    private func response(status: Int, endpoint: URL, body: String) throws -> (Data, HTTPURLResponse) {
        var headers = ["Cache-Control": "no-store"]
        if status == 200 { headers["Content-Type"] = "application/json" }
        return (
            Data(body.utf8),
            try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: headers))
        )
    }
}

private struct GroupInvitationCredentials: V2ClientPushEndpointCredentialProvider {
    let accessToken: String
    let deviceID: DeviceID

    func pushEndpointCredentials() -> V2ClientPushEndpointCredentials {
        .init(accessToken: accessToken, deviceID: deviceID)
    }
}

private actor RecordingGroupInvitationTransport: V2ClientGroupInvitationHTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private var captured: [URLRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) { self.responses = responses }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !responses.isEmpty else { throw V2ClientGroupInvitationError.networkFailure }
        return responses.removeFirst()
    }

    func requests() -> [URLRequest] { captured }
}
