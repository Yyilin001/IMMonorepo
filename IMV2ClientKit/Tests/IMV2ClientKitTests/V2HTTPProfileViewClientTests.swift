import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 HTTP profile view client")
struct V2HTTPProfileViewClientTests {
    @Test("batch hydration sends no-store credentials and rejects malformed unavailable data")
    func readsAuthorizedProfileViews() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/profile-views/batch"))
        let userID = "00000000-0000-0000-0000-000000000901"
        let roomID = "00000000-0000-0000-0000-000000000902"
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: [:]))
        let body = try JSONEncoder().encode(ProfileViewResponseBody(results: [
            .init(userID: userID, context: "direct", roomID: nil, unavailable: false, handle: "profile_user", displayName: "资料名称", accountKind: .regular, state: "active", revision: 4, visibilityRevision: 2),
            .init(userID: userID, context: "room", roomID: roomID, unavailable: true, handle: nil, displayName: nil, accountKind: nil, state: nil, revision: nil, visibilityRevision: nil),
        ]))
        let transport = ProfileViewHTTPTransport(result: .success((body, response)))
        let client = try V2HTTPProfileViewClient(endpoint: endpoint, credentials: ProfileViewCredentials(), transport: transport)
        let target = try UserID(userID)

        let results = try await client.readProfileViews([
            .init(userID: target, context: .directConversation),
            .init(userID: target, context: .room(try .init(roomID))),
        ])

        #expect(results.count == 2)
        guard case .profile(_, let view) = results[0] else {
            Issue.record("Expected authorized profile")
            return
        }
        #expect(view.publicIdentity?.displayName == "资料名称")
        #expect(view.publicIdentity?.accountKind == .regular)
        #expect(view.revision.rawValue == 4)
        guard case .unavailable = results[1] else {
            Issue.record("Expected unavailable result")
            return
        }
        let request = try #require(await transport.lastRequest())
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
    }
}

private struct ProfileViewCredentials: V2ClientPushEndpointCredentialProvider {
    func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials {
        .init(accessToken: "access-token", deviceID: try .init("00000000-0000-0000-0000-000000000903"))
    }
}

private actor ProfileViewHTTPTransport: V2ClientPushEndpointHTTPTransport {
    private let result: Result<(Data, HTTPURLResponse), Error>
    private var request: URLRequest?
    init(result: Result<(Data, HTTPURLResponse), Error>) { self.result = result }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try result.get()
    }
    func lastRequest() -> URLRequest? { request }
}

private struct ProfileViewResponseBody: Encodable {
    let results: [ProfileViewResponseItem]
}

private struct ProfileViewResponseItem: Encodable {
    let userID: String
    let context: String
    let roomID: String?
    let unavailable: Bool
    let handle: String?
    let displayName: String?
    let accountKind: V2AccountKind?
    let state: String?
    let revision: UInt64?
    let visibilityRevision: UInt64?
    let avatarMediaID: String? = nil

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case context
        case roomID = "room_id"
        case unavailable
        case handle
        case displayName = "display_name"
        case accountKind = "account_kind"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
        case avatarMediaID = "avatar_media_id"
    }
}
