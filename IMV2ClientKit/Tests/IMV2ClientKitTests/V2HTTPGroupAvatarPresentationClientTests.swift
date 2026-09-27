import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Portable group avatar HTTP reader")
struct V2HTTPGroupAvatarPresentationClientTests {
    private let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())

    @Test("requests use account authentication and bind the returned room, viewer and device")
    func valid() async throws {
        let value = try presentation()
        let transport = GroupAvatarHTTPTransport(body: try JSONEncoder().encode(value))
        #expect(try await client(transport).readGroupAvatar(roomID: room) == value)
        let request = try #require(await transport.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/rooms/\(room.rawValue)/avatar")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer account-secret")
        #expect(request.value(forHTTPHeaderField: "X-IM-Device-ID") == device.rawValue)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }

    @Test("a response from another context or an oversized body is rejected", arguments: ["actorUserID", "deviceID", "room", "size"])
    func identityAndBounds(field: String) async throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(presentation())) as? [String: Any])
        if field == "room" {
            var state = try #require(object["state"] as? [String: Any])
            state["roomID"] = UUID().uuidString; object["state"] = state
        } else { object[field] = UUID().uuidString }
        let bytes = field == "size" ? Data(repeating: 32, count: 65 * 1_024) : try JSONSerialization.data(withJSONObject: object)
        let transport = GroupAvatarHTTPTransport(body: bytes)
        await #expect(throws: V2GroupAvatarReadError.invalidResponse) { _ = try await client(transport).readGroupAvatar(roomID: room) }
    }

    @Test("business credentials cannot be carried into the object download plan")
    func credentialsDoNotEscape() async throws {
        let transport = GroupAvatarHTTPTransport(body: try JSONEncoder().encode(presentation(leakedToken: true)))
        await #expect(throws: V2ClientMediaTransferError.invalidTarget) { _ = try await client(transport).readGroupAvatar(roomID: room) }
    }

    @Test("authorization failure and temporary overload remain distinct")
    func errors() async throws {
        await #expect(throws: V2GroupAvatarReadError.forbidden) {
            _ = try await client(GroupAvatarHTTPTransport(body: Data(), status: 403)).readGroupAvatar(roomID: room)
        }
        await #expect(throws: V2GroupAvatarReadError.unavailable) {
            _ = try await client(GroupAvatarHTTPTransport(body: Data(), status: 503)).readGroupAvatar(roomID: room)
        }
        await #expect(throws: V2GroupAvatarReadError.throttled(retryAfter: 60)) {
            _ = try await client(GroupAvatarHTTPTransport(body: Data(), status: 429, retryAfter: "100000")).readGroupAvatar(roomID: room)
        }
    }

    private func client(_ transport: GroupAvatarHTTPTransport) throws -> V2HTTPGroupAvatarPresentationClient {
        try .init(roomsEndpoint: #require(URL(string: "https://account.invalid/v2/rooms")), actorUserID: actor,
            credentials: GroupAvatarHTTPCredentials(device: device), transport: transport)
    }
    private func presentation(leakedToken: Bool = false) throws -> V2GroupAvatarPresentation {
        let now = Date(), media = MediaID(uuid: UUID()), digest = try V2ResourceChecksum(value: String(repeating: "1", count: 64))
        let plan = try V2ResourceTransferPlan(mode: .httpGet,
            url: #require(URL(string: "https://cdn.invalid/avatar" + (leakedToken ? "?token=account-secret" : ""))),
            expiresAt: now.addingTimeInterval(90), expectedByteCount: 100, checksum: digest)
        return try .init(actorUserID: actor, deviceID: device, state: .init(roomID: room, mediaID: media, revision: 2),
            membershipRevision: 3, resourceGeneration: 1, canManage: false,
            avatar: .init(mediaID: media, variantID: .init(uuid: UUID()), version: 1, checksum: digest, plan: plan),
            observedAt: now, validUntil: now.addingTimeInterval(120), serverNow: now)
    }
}

private struct GroupAvatarHTTPCredentials: V2ClientMediaEdgeCredentialProvider {
    let device: DeviceID
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials { .init(accessToken: "account-secret", deviceID: device) }
}
private actor GroupAvatarHTTPTransport: V2ClientMediaEdgeHTTPTransport {
    let body: Data; let status: Int; let retryAfter: String?
    var request: URLRequest?
    init(body: Data, status: Int = 200, retryAfter: String? = nil) { self.body = body; self.status = status; self.retryAfter = retryAfter }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        var headers = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        let url = try #require(request.url)
        return (body, try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
    }
}
