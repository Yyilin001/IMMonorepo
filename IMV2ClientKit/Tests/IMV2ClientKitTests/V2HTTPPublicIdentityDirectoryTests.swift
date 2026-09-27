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
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        let transport = PublicIdentityHTTPTransport(result: .success((try JSONEncoder().encode(resolution()), response)))
        let client = try V2HTTPPublicIdentityDirectory(endpoint: endpoint, actorUserID: .init("actor"), credentials: PublicIdentityCredentials(), transport: transport)

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
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        let data = Data(#"{"userID":"target-user","handle":"target_user","displayName":"Target"}"#.utf8)
        let client = try V2HTTPPublicIdentityDirectory(
            endpoint: endpoint,
            actorUserID: .init("actor"),
            credentials: PublicIdentityCredentials(),
            transport: PublicIdentityHTTPTransport(result: .success((data, response)))
        )

        await #expect(throws: V2PublicIdentityDirectoryClientError.invalidResponse) {
            try await client.resolve(handle: "target_user")
        }
    }

    @Test(arguments: ["actor", "device", "handle", "oldBare", "oversized", "lifetime", "reversed", "malformedHandle"])
    func rejectsUnboundOrMalformedResponse(kind: String) async throws {
        let endpoint = URL(string: "https://account.invalid/v2/public-identities/resolve")!
        let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(resolution())) as? [String: Any])
        switch kind {
        case "actor": body["actorUserID"] = ["rawValue": "another-actor"]
        case "device": body["deviceID"] = ["rawValue": "00000000-0000-0000-0000-000000000902"]
        case "handle", "malformedHandle":
            var identity = try #require(body["identity"] as? [String: Any])
            identity["handle"] = ["rawValue": kind == "handle" ? "another_handle" : "??"]
            body["identity"] = identity
        case "oldBare": body = ["userID": "target-user", "handle": "target_user", "displayName": "Target", "accountKind": "regular"]
        case "oversized": body["padding"] = String(repeating: "x", count: 8 * 1_024)
        case "lifetime": body["validUntilUnixMilliseconds"] = 2_000_000_061_000 as Int64
        default: body["serverNowUnixMilliseconds"] = 1_999_999_999_000 as Int64
        }
        let client = try V2HTTPPublicIdentityDirectory(endpoint: endpoint, actorUserID: .init("actor"),
            credentials: PublicIdentityCredentials(), transport: PublicIdentityHTTPTransport(result:
                .success((try JSONSerialization.data(withJSONObject: body), response))))
        await #expect(throws: V2PublicIdentityDirectoryClientError.invalidResponse) {
            try await client.resolveForPresentation(handle: "target_user")
        }
    }

    @Test func localDeadlineSubtractsRoundTripAndDoesNotUseDeviceWallClock() throws {
        let started = ContinuousClock.now
        let result = try resolution()
        let snapshot = try V2PublicIdentityLookupSnapshot(resolution: result, requestStartedAt: started,
            responseReceivedAt: started + .seconds(4))
        #expect(snapshot.deadline == started + .seconds(60))
        #expect(snapshot.isValid(at: started + .seconds(59)))
        #expect(!snapshot.isValid(at: started + .seconds(60)))
        #expect(throws: V2PublicIdentityDirectoryClientError.invalidResponse) {
            try V2PublicIdentityLookupSnapshot(resolution: result, requestStartedAt: started,
                responseReceivedAt: started + .seconds(60))
        }
    }

    private func resolution() throws -> V2PublicIdentityResolution {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        return try .init(identity: .init(userID: .init("target-user"), handle: .init("target_user"), displayName: "Target", accountKind: .regular),
            actorUserID: .init("actor"), deviceID: .init("00000000-0000-0000-0000-000000000901"),
            observedAt: now, validUntil: now.addingTimeInterval(60), serverNow: now)
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
