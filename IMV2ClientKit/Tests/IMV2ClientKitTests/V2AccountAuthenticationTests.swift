import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 account authentication")
struct V2AccountAuthenticationTests {
    @Test("password fallback posts no-store and does not change the assertion contract")
    func passwordFallbackPostsNoStore() async throws {
        let registration = try #require(URL(string: "https://account.invalid/v2/account-auth/password/register"))
        let assertion = try #require(URL(string: "https://account.invalid/v2/account-auth/password/assertion"))
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000901")
        let transport = AccountHTTPTransport(result: .success((try JSONEncoder().encode(AssertionBody(accountAssertion: "short-lived")), try response(for: assertion))))
        let authenticator = try V2HTTPPasswordAccountAuthenticator(registrationEndpoint: registration, assertionEndpoint: assertion, transport: transport)

        let value = try await authenticator.authenticate(accountHandle: "alice_01", password: "correct horse battery staple", deviceID: deviceID)

        #expect(value.value == "short-lived")
        let request = try #require(await transport.lastRequest())
        #expect(request.url == assertion)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(PasswordBody.self, from: body)
        #expect(decoded.accountHandle == "alice_01")
        #expect(decoded.password == "correct horse battery staple")
        #expect(decoded.deviceID == deviceID.rawValue)
    }

    @Test("passkey provider submits only the authorizer result for the server challenge")
    func passkeyProviderChainsChallengeAndResult() async throws {
        let request = try V2PasskeyAssertionRequest(challengeID: "challenge-1", challenge: Data([1, 2, 3]), relyingPartyID: "im.example.com", allowedCredentialIDs: [Data([7])])
        let result = try V2PasskeyAssertionResult(credentialID: Data([7]), clientDataJSON: Data([1]), authenticatorData: Data([2]), signature: Data([3]), userHandle: nil)
        let provider = V2PasskeyAccountAssertionProvider(
            accountHandle: "alice_01",
            requestProvider: FixedPasskeyRequestProvider(request: request),
            authorizer: FixedPasskeyAuthorizer(result: result),
            submitter: FixedPasskeySubmitter(assertion: try V2AccountAssertion("passkey-assertion"))
        )

        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000902")
        #expect(try await provider.accountAssertion(for: deviceID) == "passkey-assertion")
    }

    @Test("unsafe endpoint and weak password are rejected before transport")
    func rejectsUnsafeInput() throws {
        #expect(throws: V2AccountAuthenticationError.invalidEndpoint) {
            _ = try V2HTTPPasswordAccountAuthenticator(
                registrationEndpoint: #require(URL(string: "http://account.invalid/register")),
                assertionEndpoint: #require(URL(string: "https://account.invalid/assertion"))
            )
        }
    }

    private func response(for url: URL) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "no-store"]))
    }
}

private actor AccountHTTPTransport: V2AuthHTTPTransport {
    private let result: Result<(Data, HTTPURLResponse), Error>
    private var request: URLRequest?
    init(result: Result<(Data, HTTPURLResponse), Error>) { self.result = result }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try result.get()
    }
    func lastRequest() -> URLRequest? { request }
}

private struct AssertionBody: Encodable { let accountAssertion: String }
private struct PasswordBody: Decodable { let accountHandle: String; let password: String; let deviceID: String }
private struct FixedPasskeyRequestProvider: V2PasskeyAssertionRequestProviding {
    let request: V2PasskeyAssertionRequest
    func assertionRequest(accountHandle _: String?, deviceID _: DeviceID) -> V2PasskeyAssertionRequest { request }
}
private struct FixedPasskeyAuthorizer: V2PasskeyAuthorizing {
    let result: V2PasskeyAssertionResult
    func authorize(_: V2PasskeyAssertionRequest) -> V2PasskeyAssertionResult { result }
}
private struct FixedPasskeySubmitter: V2PasskeyAssertionSubmitting {
    let assertion: V2AccountAssertion
    func submit(_: V2PasskeyAssertionResult, for _: V2PasskeyAssertionRequest) -> V2AccountAssertion { assertion }
}
