import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 public identity directory client")
struct V2HTTPPublicIdentityDirectoryTests {
    @Test("exact public handle lookup is authenticated and never cached")
    func lookupUsesAuthenticatedNoStoreRequest() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/public-identities/resolve"))
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: [:]))
        let transport = PublicIdentityHTTPTransport(result: .success((try JSONEncoder().encode(IdentityBody(userID: "target-user", handle: "target_user", displayName: "Target", accountKind: .regular)), response)))
        let client = try V2HTTPPublicIdentityDirectory(endpoint: endpoint, credentials: PublicIdentityCredentials(), transport: transport)

        let identity = try await client.resolve(handle: "@TARGET_USER")

        #expect(identity.userID.rawValue == "target-user")
        #expect(identity.handle.rawValue == "target_user")
        #expect(identity.accountKind == .regular)
        let request = try #require(await transport.lastRequest())
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "handle", value: "target_user")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "X-IM-Device-ID") == "00000000-0000-0000-0000-000000000901")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
    }

    @Test("a response without the current account kind is rejected")
    func rejectsMissingAccountKind() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/public-identities/resolve"))
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: [:]))
        let data = Data(#"{"userID":"target-user","handle":"target_user","displayName":"Target"}"#.utf8)
        let client = try V2HTTPPublicIdentityDirectory(
            endpoint: endpoint,
            credentials: PublicIdentityCredentials(),
            transport: PublicIdentityHTTPTransport(result: .success((data, response)))
        )

        await #expect(throws: V2PublicIdentityDirectoryClientError.invalidResponse) {
            try await client.resolve(handle: "target_user")
        }
    }
}

private struct PublicIdentityCredentials: V2ClientPushEndpointCredentialProvider {
    func pushEndpointCredentials() async throws -> V2ClientPushEndpointCredentials {
        .init(accessToken: "access-token", deviceID: try .init("00000000-0000-0000-0000-000000000901"))
    }
}

private actor PublicIdentityHTTPTransport: V2ClientPushEndpointHTTPTransport {
    private let result: Result<(Data, HTTPURLResponse), Error>
    private var request: URLRequest?
    init(result: Result<(Data, HTTPURLResponse), Error>) { self.result = result }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try result.get()
    }
    func lastRequest() -> URLRequest? { request }
}

private struct IdentityBody: Encodable {
    let userID: String
    let handle: String
    let displayName: String
    let accountKind: V2AccountKind
}
