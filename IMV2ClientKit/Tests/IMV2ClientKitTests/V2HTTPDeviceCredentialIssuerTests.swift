import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 HTTP device credential issuer")
struct V2HTTPDeviceCredentialIssuerTests {
    @Test("missing, malformed or mismatched server confirmation relinquishes received credentials", arguments: ["missing", "malformed", "mismatch"])
    func rejectsUnconfirmedBinding(confirmation: String) async throws {
        let endpoint = URL(string: "https://account.invalid/v2/device-credentials")!
        let device = try DeviceID(UUID().uuidString)
        let credentials = try credentials(deviceID: device)
        let persistence = IssuedRecoveryTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let recovery = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        let operation = RegistrationOperationStore()
        let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(issueEndpoint: endpoint,
            assertionProvider: FixedAssertionProvider(value: "account-assertion"), deviceIdentityProvider: FixedDeviceIdentityProvider(deviceID: device),
            operationStore: operation, recovery: recovery,
            transport: IssuerHTTPTransport(result: .success((try responseData(for: credentials), try response(status: 200, endpoint: endpoint))), confirmation: confirmation))
        await #expect(throws: V2AccountAssertionCredentialProviderError.issuedCredentialMismatch) { try await provider.issueDeviceCredentials() }
        #expect(try await queue.jobs().first?.intent.credential == credentials.revocationCredential)
        #expect(try persistence.load() == nil)
        #expect(await operation.value() == nil)
    }

    @Test("expired registration never sends HTTP or replaces its proof")
    func expiredRegistration() async throws {
        let start = Date()
        let device = try DeviceID(UUID().uuidString)
        let pending = try V2PendingDeviceCredentialRegistration.prepare(deviceID: device, operationID: UUID(), now: start)
        let operation = RegistrationOperationStore()
        await operation.save(pending)
        let transport = IssuerHTTPTransport(result: .failure(URLError(.networkConnectionLost)))
        let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(issueEndpoint: URL(string: "https://account.invalid/v2/device-credentials")!,
            assertionProvider: FixedAssertionProvider(value: "account-assertion"), deviceIdentityProvider: FixedDeviceIdentityProvider(deviceID: device),
            operationStore: operation, transport: transport, now: { start.addingTimeInterval(601) })
        await #expect(throws: V2AccountAssertionCredentialProviderError.registrationExpired) { try await provider.issueDeviceCredentials() }
        #expect(await transport.lastRequest() == nil)
        #expect(await operation.value() == pending)
    }

    @Test("received result must be durable before the issuer returns or finalizes")
    func persistsReceivedAuthority() async throws {
        let endpoint = URL(string: "https://account.invalid/v2/device-credentials")!
        let device = try DeviceID(UUID().uuidString)
        let credentials = try credentials(deviceID: device)
        let persistence = IssuedRecoveryTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let recovery = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        let operation = RegistrationOperationStore()
        let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(issueEndpoint: endpoint,
            assertionProvider: FixedAssertionProvider(value: "account-assertion"),
            deviceIdentityProvider: FixedDeviceIdentityProvider(deviceID: device), operationStore: operation,
            recovery: recovery,
            transport: IssuerHTTPTransport(result: .success((try responseData(for: credentials), try response(status: 200, endpoint: endpoint)))))
        persistence.setFailure(.save)
        await #expect(throws: V2IssuedCredentialRecoveryError.unavailable) { try await provider.issueDeviceCredentials() }
        #expect(await operation.value() != nil)
        persistence.setFailure(nil)
        #expect(try await provider.issueDeviceCredentials() == credentials)
        #expect(try persistence.load() != nil)
        #expect(try await queue.jobs().isEmpty)
        try await provider.finalizeIssuedDeviceCredentials(credentials)
        #expect(try persistence.load() == nil)
        #expect(await operation.value() == nil)
    }

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
        #expect(await store.value()?.deviceID == deviceID)
        #expect(await store.value()?.operationID == operationID)
        let request = try #require(await transport.lastRequest())
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Pragma") == "no-cache")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(IssueRequestBody.self, from: body)
        #expect(decoded.accountAssertion == "opaque-account-assertion")
        #expect(decoded.deviceID == deviceID.rawValue)
        #expect(decoded.operationID == operationID)
        #expect(decoded.cancellation == (await store.value())?.cancellation)

        try await provider.finalizeIssuedDeviceCredentials(issued)
        #expect(await store.value() == nil)
    }

    @Test("response loss reopens the registration owner and reuses both persisted identifiers")
    func responseLossReusesRegistrationOperation() async throws {
        let endpoint = try #require(URL(string: "https://account.invalid/v2/device-credentials"))
        let persistence = DeviceRegistrationTestPersistence()
        let registration = try await V2DeviceRegistrationStore(persistence: persistence).prepare(accountHandle: "replay_account")
        let pending = try #require(try await registration.load())
        let expected = try credentials(deviceID: pending.deviceID)
        let firstTransport = IssuerHTTPTransport(result: .failure(URLError(.networkConnectionLost)))
        let first = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: endpoint,
            assertionProvider: FixedAssertionProvider(value: "opaque-account-assertion"),
            deviceIdentityProvider: registration, operationStore: registration,
            transport: firstTransport
        )
        await #expect(throws: V2HTTPAuthTransportError.networkFailure) {
            _ = try await first.issueDeviceCredentials()
        }
        let originalBody = try #require((await firstTransport.lastRequest())?.httpBody)
        let original = try JSONDecoder().decode(IssueRequestBody.self, from: originalBody)
        #expect(original.deviceID == pending.deviceID.rawValue)
        #expect(original.operationID == pending.operationID)

        let reopened = V2DeviceRegistrationStore(persistence: persistence)
        let retryRegistration = try await reopened.prepare(accountHandle: "replay_account")
        let retryTransport = IssuerHTTPTransport(result: .success((try responseData(for: expected), try response(status: 200, endpoint: endpoint))))
        let retry = try V2HTTPAccountAssertionDeviceCredentialProvider(
            issueEndpoint: endpoint,
            assertionProvider: FixedAssertionProvider(value: "new-account-assertion"),
            deviceIdentityProvider: retryRegistration, operationStore: retryRegistration,
            transport: retryTransport
        )
        let issuedMatches = try await retry.issueDeviceCredentials() == expected
        #expect(issuedMatches)
        let body = try #require((await retryTransport.lastRequest())?.httpBody)
        let replay = try JSONDecoder().decode(IssueRequestBody.self, from: body)
        #expect(replay.deviceID == original.deviceID)
        #expect(replay.operationID == original.operationID)
        #expect(replay.cancellation == original.cancellation)
        #expect(replay.accountAssertion != original.accountAssertion)
        try await retry.finalizeIssuedDeviceCredentials(expected)
        #expect(try persistence.load() == nil)
        let next = try await reopened.prepare(accountHandle: "replay_account")
        #expect(try await next.deviceID() != pending.deviceID)
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
        #expect(await store.value()?.deviceID == deviceID)
        #expect(await store.value()?.operationID == operationID)
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
            refreshCredential: credentials.refreshCredential,
            revocationCredential: credentials.revocationCredential,
            revocationCredentialExpiresAtMilliseconds: Int64(credentials.revocationCredentialExpiresAt.timeIntervalSince1970 * 1_000)
        ))
    }

    private func response(status: Int, endpoint: URL) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: endpoint,
            statusCode: status,
            httpVersion: nil,
            headerFields: status == 200 ? ["Content-Type": "application/json"] : nil
        ))
    }
}

private actor RegistrationOperationStore: V2DeviceCredentialRegistrationOperationStore {
    private var pending: V2PendingDeviceCredentialRegistration?
    func load() -> V2PendingDeviceCredentialRegistration? { pending }
    func save(_ registration: V2PendingDeviceCredentialRegistration) { pending = registration }
    func delete() { pending = nil }
    func value() -> V2PendingDeviceCredentialRegistration? { pending }
}

private struct FixedAssertionProvider: V2DeviceBoundAccountAssertionProvider {
    let value: String
    func accountAssertion(for _: DeviceID) async throws -> String { value }
}

private struct ThrowingDeviceBoundAssertionProvider: V2DeviceBoundAccountAssertionProvider {
    let error: V2AccountAuthenticationError
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
    private let confirmation: String
    init(result: Result<(Data, HTTPURLResponse), Error>, confirmation: String = "echo") { self.result = result; self.confirmation = confirmation }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        self.request = request
        let (data, response) = try result.get()
        guard response.statusCode == 200,
              var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestData = request.httpBody,
              let sent = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              var binding = sent["cancellation"] as? [String: Any] else { return (data, response) }
        switch confirmation {
        case "missing": break
        case "malformed": body["registrationCancellation"] = "invalid"
        case "mismatch":
            binding["operationID"] = UUID().uuidString
            body["registrationCancellation"] = binding
        default: body["registrationCancellation"] = binding
        }
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
    func lastRequest() -> URLRequest? { request }
}

private struct IssueRequestBody: Decodable {
    let accountAssertion: String
    let deviceID: String
    let operationID: UUID
    let cancellation: V2DeviceRegistrationCancellation
}

private struct IssueResponseBody: Encodable {
    let userID: String
    let deviceID: String
    let accessToken: String
    let accessTokenExpiresAtMilliseconds: Int64
    let refreshCredential: String
    let revocationCredential: V2DeviceRevocationCredential
    let revocationCredentialExpiresAtMilliseconds: Int64
}
