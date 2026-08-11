import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 HTTP own profile client")
struct V2HTTPOwnProfileClientTests {
    @Test("profile read and revision-fenced write use the authenticated no-store contract")
    func readsAndWritesProfile() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/profile/me"))
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: [:]))
        let body = try JSONEncoder().encode(ProfileBody(
            userID: "00000000-0000-0000-0000-000000000761",
            handle: "own_profile",
            displayName: "更新后的名称",
            accountKind: "regular",
            avatarMediaID: "00000000-0000-0000-0000-000000000762",
            state: "active",
            revision: 4,
            visibilityRevision: 4
        ))
        let transport = OwnProfileHTTPTransport(responses: [(body, response), (body, response)])
        let client = try V2HTTPOwnProfileClient(endpoint: endpoint, credentials: OwnProfileCredentials(), transport: transport)

        let current = try await client.currentProfile()
        #expect(current.publicIdentity?.displayName == "更新后的名称")
        #expect(current.avatar?.mediaID.rawValue == "00000000-0000-0000-0000-000000000762")
        let operationID = try ProfileUpdateOperationID("00000000-0000-0000-0000-000000000763")
        _ = try await client.updateProfile(
            operationID: operationID,
            expectedRevision: current.revision,
            displayName: "更新后的名称",
            avatar: current.avatar
        )

        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-token" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        let payload = try #require(requests[1].httpBody)
        let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(decoded?["operation_id"] as? String == operationID.rawValue)
        #expect(decoded?["expected_revision"] as? Int == 4)
    }

    @Test("revision conflict exposes the current version")
    func exposesRevisionConflict() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/profile/me"))
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 409, httpVersion: nil, headerFields: [:]))
        let transport = OwnProfileHTTPTransport(responses: [(Data("{\"current_revision\":9}".utf8), response)])
        let client = try V2HTTPOwnProfileClient(endpoint: endpoint, credentials: OwnProfileCredentials(), transport: transport)
        await #expect(throws: V2OwnProfileClientError.revisionConflict(.init(rawValue: 9)!)) {
            try await client.updateProfile(
                operationID: try .init("00000000-0000-0000-0000-000000000764"),
                expectedRevision: .init(rawValue: 4)!,
                displayName: "名称",
                avatar: nil
            )
        }
    }
}

private struct OwnProfileCredentials: V2ClientPushEndpointCredentialProvider {
    func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials {
        .init(accessToken: "access-token", deviceID: try .init("00000000-0000-0000-0000-000000000765"))
    }
}

private actor OwnProfileHTTPTransport: V2ClientPushEndpointHTTPTransport {
    private var pending: [(Data, HTTPURLResponse)]
    private var recorded: [URLRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) { pending = responses }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        guard !pending.isEmpty else { throw URLError(.badServerResponse) }
        return pending.removeFirst()
    }

    func requests() -> [URLRequest] { recorded }
}

private struct ProfileBody: Encodable {
    let userID: String
    let handle: String
    let displayName: String
    let accountKind: String
    let avatarMediaID: String?
    let state: String
    let revision: UInt64
    let visibilityRevision: UInt64

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", handle
        case displayName = "display_name", accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id", state, revision
        case visibilityRevision = "visibility_revision"
    }
}
