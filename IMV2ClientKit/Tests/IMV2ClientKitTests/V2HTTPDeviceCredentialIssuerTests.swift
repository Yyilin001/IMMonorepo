import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 HTTP device credential issuer")
struct V2HTTPDeviceCredentialIssuerTests {
    @Test("registration persists its operation before a no-store request and finalizes only after handoff")
    func persistsThenFinalizesRegistration() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/device-credentials"))
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000901")
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
        let expected = try credentials(deviceID: deviceID)
        let store = RegistrationOperationStore()
        let transport = IssuerHTTPTransport(result: .success((try responseData(for: expected), try response(status: 200, endpoint: endpoint))))
        let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: endpoint,
            assertionProvider: FixedAssertionProvider(value: "opaque-account-assertion"),
            deviceIdentityProvider: FixedDeviceIdentityProvider(deviceID: deviceID),
            operationStore: store,
            transport: transport,
            makeUUID: { operationID }
        )

        let issued = try await provider.issueDeviceCredentials()

        #expect(issued == expected)
        #expect(await store.value() == .init(deviceID: deviceID, operationID: operationID))
        let request = try #require(await transport.lastRequest())
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(IssueRequestBody.self, from: body)
        #expect(decoded.accountAssertion == "opaque-account-assertion")
        #expect(decoded.deviceID == deviceID.rawValue)
        #expect(decoded.operationID == operationID)

        try await provider.finalizeIssuedDeviceCredentials(issued)
        #expect(await store.value() == nil)
    }

    @Test("response loss retains the exact registration operation for a fresh provider retry")
    func responseLossReusesRegistrationOperation() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/device-credentials"))
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000911")
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000912")!
        let expected = try credentials(deviceID: deviceID)
        let store = RegistrationOperationStore()
        let first = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: endpoint,
            assertionProvider: FixedAssertionProvider(value: "opaque-account-assertion"),
            deviceIdentityProvider: FixedDeviceIdentityProvider(deviceID: deviceID),
            operationStore: store,
            transport: IssuerHTTPTransport(result: .failure(URLError(.networkConnectionLost))),
            makeUUID: { operationID }
        )

        await #expect(throws: V2HTTPAuthTransportError.networkFailure) {
            _ = try await first.issueDeviceCredentials()
        }
        #expect(await store.value() == .init(deviceID: deviceID, operationID: operationID))

        let retryTransport = IssuerHTTPTransport(result: .success((try responseData(for: expected), try response(status: 200, endpoint: endpoint))))
        let retry = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: endpoint,
            assertionProvider: FixedAssertionProvider(value: "opaque-account-assertion"),
            deviceIdentityProvider: FixedDeviceIdentityProvider(deviceID: deviceID),
            operationStore: store,
            transport: retryTransport,
            makeUUID: { UUID() }
        )

        #expect(try await retry.issueDeviceCredentials() == expected)
        let body = try #require((await retryTransport.lastRequest())?.httpBody)
        #expect(try JSONDecoder().decode(IssueRequestBody.self, from: body).operationID == operationID)
    }

    @Test("a rejected assertion does not clear the persisted operation before credentials exist")
    func rejectionRetainsOperation() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/device-credentials"))
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000921")
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000922")!
        let store = RegistrationOperationStore()
        let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: endpoint,
            assertionProvider: FixedAssertionProvider(value: "opaque-account-assertion"),
            deviceIdentityProvider: FixedDeviceIdentityProvider(deviceID: deviceID),
            operationStore: store,
            transport: IssuerHTTPTransport(result: .success((Data(), try response(status: 401, endpoint: endpoint)))),
            makeUUID: { operationID }
        )

        await #expect(throws: V2AccountAssertionCredentialProviderError.assertionRejected) {
            _ = try await provider.issueDeviceCredentials()
        }
        #expect(await store.value() == .init(deviceID: deviceID, operationID: operationID))
    }

    @Test("account-factor validation errors remain actionable to the app")
    func preservesAccountAuthenticationError() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/device-credentials"))
        let deviceID = try DeviceID("00000000-0000-0000-0000-000000000931")
        let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: endpoint,
            assertionProvider: ThrowingDeviceBoundAssertionProvider(error: .invalidPassword),
            deviceIdentityProvider: FixedDeviceIdentityProvider(deviceID: deviceID),
            operationStore: RegistrationOperationStore(),
            transport: IssuerHTTPTransport(result: .failure(URLError(.badServerResponse)))
        )

        await #expect(throws: V2AccountAuthenticationError.invalidPassword) {
            _ = try await provider.issueDeviceCredentials()
        }
    }

    private func credentials(deviceID: DeviceID) throws -> V2AuthCredentials {
        try .init(
            userID: .init("00000000-0000-0000-0000-000000000900"),
            deviceID: deviceID,
            accessToken: "issued-access",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_750_003_000.250),
            refreshCredential: "issued-refresh"
        )
    }

    private func responseData(for credentials: V2AuthCredentials) throws -> Data {
        try JSONEncoder().encode(IssueResponseBody(
            userID: credentials.userID.rawValue,
            deviceID: credentials.deviceID.rawValue,
            accessToken: credentials.accessToken,
            accessTokenExpiresAtMilliseconds: Int64(credentials.accessTokenExpiresAt.timeIntervalSince1970 * 1_000),
            refreshCredential: credentials.refreshCredential
        ))
    }

    private func response(status: Int, endpoint: URL) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil))
    }
}

private actor RegistrationOperationStore: V2DeviceCredentialRegistrationOperationStore {
    private var pending: V2PendingDeviceCredentialRegistration?
    func load() -> V2PendingDeviceCredentialRegistration? { pending }
    func save(_ registration: V2PendingDeviceCredentialRegistration) { pending = registration }
    func delete() { pending = nil }
    func value() -> V2PendingDeviceCredentialRegistration? { pending }
}

private struct FixedAssertionProvider: V2AccountAssertionProvider {
    let value: String
    func accountAssertion() -> String { value }
}

private struct ThrowingDeviceBoundAssertionProvider: V2DeviceBoundAccountAssertionProvider {
    let error: V2AccountAuthenticationError
    func accountAssertion() throws -> String { throw error }
    func accountAssertion(for _: DeviceID) async throws -> String { throw error }
}

private struct FixedDeviceIdentityProvider: V2DeviceIdentityProvider {
    let fixedDeviceID: DeviceID
    init(deviceID: DeviceID) { fixedDeviceID = deviceID }
    func deviceID() -> DeviceID { fixedDeviceID }
}

private actor IssuerHTTPTransport: V2AuthHTTPTransport {
    private let result: Result<(Data, HTTPURLResponse), Error>
    private var request: URLRequest?
    init(result: Result<(Data, HTTPURLResponse), Error>) { self.result = result }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try result.get()
    }
    func lastRequest() -> URLRequest? { request }
}

private struct IssueRequestBody: Decodable {
    let accountAssertion: String
    let deviceID: String
    let operationID: UUID
}

private struct IssueResponseBody: Encodable {
    let userID: String
    let deviceID: String
    let accessToken: String
    let accessTokenExpiresAtMilliseconds: Int64
    let refreshCredential: String
}
