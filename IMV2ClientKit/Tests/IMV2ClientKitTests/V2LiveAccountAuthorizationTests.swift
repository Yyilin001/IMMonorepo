#if os(macOS)
import Foundation
import Security
import IMV2Core
import Testing
@testable import IMV2ClientKit

/// Opt-in only: run with scripts/verify_v2_live_account_authorization.py.
/// Ordinary package tests remain offline. The harness owns the database,
/// account process and CA; trust is scoped to this URLSession, never Keychain.
@Suite("Live account HTTPS authorization", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_ACCOUNT_HTTPS_URL"] != nil),
       .timeLimit(.minutes(2)))
struct V2LiveAccountAuthorizationTests {
    @Test("rejected access token refreshes against the real account service")
    func refreshesRejectedAccess() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let account = try await fixture.register()
        let rejected = try V2AuthCredentials(userID: account.credentials.userID, deviceID: account.credentials.deviceID,
            accessToken: "invalid-live-test-access", accessTokenExpiresAt: .distantFuture,
            refreshCredential: account.credentials.refreshCredential, revocationCredential: account.credentials.revocationCredential, revocationCredentialExpiresAt: account.credentials.revocationCredentialExpiresAt)
        let store = LiveAccountCredentialStore(rejected)
        let session = try fixture.session(store)
        _ = try await session.restoreState()
        let client = try await fixture.devices(session)
        await #expect(throws: V2ClientDeviceSessionError.authorizationDenied) { try await client.list(cursor: nil, pageSize: 10) }
        let record = try #require(await store.load())
        let rotated = record.credentials.refreshCredential != rejected.refreshCredential
        #expect(rotated)
        #expect(record.pendingRefreshOperationID == nil)
        let page = try await client.list(cursor: nil, pageSize: 10)
        #expect(page.sessions.count == 1)
        #expect(page.sessions.first?.isCurrentDevice == true)
        #expect(await session.currentState() != .unauthenticated)
    }

    @Test("another real device revokes this device and HTTP requests end its session")
    func remoteRevocationEndsSession() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let account = try await fixture.register()
        let other = try await fixture.login(account.handle)
        let store = LiveAccountCredentialStore(account.credentials)
        let session = try fixture.session(store)
        _ = try await session.restoreState()
        let updates = await session.sessionUpdates(for: await session.currentEpoch())
        let terminal = Task<V2AuthSessionSnapshot.EndReason?, Never> {
            for await update in updates {
                if case .ended(let reason) = update.status { return reason }
            }
            return nil as V2AuthSessionSnapshot.EndReason?
        }
        defer { terminal.cancel() }
        let client = try await fixture.devices(session)
        let otherSession = try fixture.session(LiveAccountCredentialStore(other))
        _ = try await otherSession.restoreState()
        let otherClient = try await fixture.devices(otherSession)
        try await otherClient.revoke(deviceID: account.credentials.deviceID, operationID: UUID())
        await #expect(throws: (any Error).self) { try await client.list(cursor: nil, pageSize: 10) }
        #expect(await terminal.value == .authenticationRequired)
        #expect(await store.load() == nil)
        #expect(await session.currentState() == .unauthenticated)
        await #expect(throws: V2AuthSessionError.unauthenticated) { try await session.refresh() }
        let remaining = try await otherClient.list(cursor: nil, pageSize: 10)
        #expect(remaining.sessions.count == 1)
        #expect(remaining.sessions.first?.isCurrentDevice == true)
    }

    @Test("expired local access plus rejected real refresh clears the credential")
    func rejectedRefreshDuringCredentialAcquisition() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let account = try await fixture.register()
        let invalid = try V2AuthCredentials(userID: account.credentials.userID, deviceID: account.credentials.deviceID,
            accessToken: account.credentials.accessToken, accessTokenExpiresAt: .distantPast,
            refreshCredential: "invalid-live-test-refresh", revocationCredential: account.credentials.revocationCredential, revocationCredentialExpiresAt: account.credentials.revocationCredentialExpiresAt)
        let store = LiveAccountCredentialStore(invalid)
        let session = try fixture.session(store)
        _ = try await session.restoreState()
        let client = try await fixture.devices(session)
        await #expect(throws: V2ClientDeviceSessionError.authorizationUnavailable) { try await client.list(cursor: nil, pageSize: 10) }
        #expect(await store.load() == nil)
        #expect(await session.currentState() == .unauthenticated)
    }

    @Test("an untrusted real TLS certificate is not account revocation")
    func untrustedTLSKeepsCredentials() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let account = try await fixture.register()
        let store = LiveAccountCredentialStore(account.credentials)
        let session = try fixture.session(store)
        _ = try await session.restoreState()
        let untrusted = V2SecureURLSession.make()
        defer { untrusted.invalidateAndCancel() }
        let boundary = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(),
            transport: V2URLSessionAuthHTTPTransport(session: untrusted))
        let client = try V2HTTPDeviceSessionClient(endpoint: fixture.url("v2/devices"), credentials: boundary, transport: boundary)
        await #expect(throws: V2ClientDeviceSessionError.networkFailure) { try await client.list(cursor: nil, pageSize: 10) }
        let unchanged = await store.load()?.credentials == account.credentials
        #expect(unchanged)
        #expect(await session.currentState() != .unauthenticated)
    }
}

@Suite("Live current-device logout", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_CURRENT_LOGOUT"] == "1"))
struct V2LiveCurrentDeviceLogoutTests {
    @Test("current logout revokes all rotations, preserves another device and tolerates concurrent delivery")
    func revokesOnlyCurrentDevice() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let cancellationClient = try V2HTTPDeviceRegistrationCancellationClient(
            endpoint: fixture.url("v2/device-credentials/cancel-registration"), transport: fixture.transport)
        let cutoff = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
        let preIssue = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(),
            proof: .generate(), issueBeforeMilliseconds: cutoff)
        let droppedCancellation = LoseFirstRegistrationCancellationResult(client: cancellationClient)
        await #expect(throws: V2DeviceRegistrationCancellationClientError.networkFailure) { try await droppedCancellation.cancel(preIssue) }
        #expect(try await droppedCancellation.cancel(preIssue) == .cancelled)
        let expired = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(),
            proof: .generate(), issueBeforeMilliseconds: cutoff - 120_000)
        #expect(try await cancellationClient.cancel(expired) == .expired)
        let tooFar = try V2DeviceRegistrationCancellation(deviceID: preIssue.deviceID, operationID: preIssue.operationID,
            proof: preIssue.proof, issueBeforeMilliseconds: cutoff + 86_400_000)
        await #expect(throws: V2DeviceRegistrationCancellationClientError.serverStatus(400)) { try await cancellationClient.cancel(tooFar) }
        let account = try await fixture.register()
        let other = try await fixture.login(account.handle)
        // The issuer receives no response bytes or returned authority. A new
        // owner can still cancel using the proof saved before HTTP issuance.
        let interrupted = try await fixture.loseIssuedResponse(account.handle)
        let lostProof = try #require(try await interrupted.pendingCancellations().first)
        let lostCancellation = LoseFirstRegistrationCancellationResult(client: cancellationClient)
        let retryStart = Date()
        try await V2DeviceRegistrationCancellationRunner(store: interrupted, client: lostCancellation,
            now: { retryStart }).flushOnce()
        let retryJob = try #require(try await interrupted.cancellationJobs().first)
        #expect(retryJob.cancellation == lostProof && retryJob.attempts == 1)
        try await V2DeviceRegistrationCancellationRunner(store: interrupted, client: lostCancellation,
            now: { retryStart.addingTimeInterval(2) }).flushOnce()
        #expect(try await interrupted.pendingCancellations().isEmpty)
        let session = try fixture.session(LiveAccountCredentialStore(account.credentials))
        let rotated = try await session.refresh()
        func request(_ path: String, credentials: V2AuthCredentials, body: [String: String]? = nil) throws -> URLRequest {
            var request = URLRequest(url: fixture.url(path))
            request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue(credentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
            if let body {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
            }
            return request
        }
        func status(_ request: URLRequest) async throws -> Int {
            let (_, response) = try await fixture.http.data(for: request)
            return try #require(response as? HTTPURLResponse).statusCode
        }
        #expect(try await status(request("v2/devices/revoke-current", credentials: rotated,
            body: ["deviceID": other.deviceID.rawValue, "operationID": UUID().uuidString])) == 400)
        // The harness injects a PostgreSQL AFTER INSERT journal failure
        // only for this operation, after the revocation updates executed.
        #expect(try await status(request("v2/devices/revoke-current", credentials: rotated,
            body: ["operationID": "00000000-0000-4000-8000-00000000b008"])) == 503)
        #expect(try await status(request("v2/devices", credentials: account.credentials)) == 200)
        #expect(try await status(request("v2/devices", credentials: rotated)) == 200)
        #expect(try await status(request("v2/devices", credentials: other)) == 200)
        let logoutOperation = UUID()
        let logout = try request("v2/devices/revoke-current", credentials: rotated, body: ["operationID": logoutOperation.uuidString])
        let http = fixture.http
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let (_, response) = try await http.data(for: logout)
                    return try #require(response as? HTTPURLResponse).statusCode
                }
            }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(statuses.contains(204))
        #expect(statuses.allSatisfy { $0 == 204 || $0 == 401 })
        #expect(try await status(logout) == 401)
        #expect(try await status(request("v2/devices", credentials: account.credentials)) == 401)
        #expect(try await status(request("v2/devices", credentials: rotated)) == 401)
        #expect(try await status(request("v2/devices", credentials: other)) == 200)
        // Exercise the new purpose-only client over the real TLS edge using
        // credentials that the real registration transaction returned.
        #expect(rotated.revocationCredential == account.credentials.revocationCredential)
        #expect(rotated.revocationCredentialExpiresAt == account.credentials.revocationCredentialExpiresAt)
        let revocation = try V2HTTPDeviceRevocationClient(endpoint: fixture.url("v2/device-credentials/revoke"), transport: fixture.transport)
        #expect(try await revocation.revoke(credential: account.credentials.revocationCredential, operationID: logoutOperation) == .revoked)
        #expect(try await revocation.revoke(credential: other.revocationCredential, operationID: logoutOperation) == .operationConflict)
        #expect(try await status(request("v2/devices", credentials: other)) == 200)
        #expect(try await revocation.revoke(credential: .generate(), operationID: UUID()) == .invalidCredential)
        let otherLogoutOperation = UUID()
        let persistence = RevocationTestPersistence()
        let outbox = V2DeviceRevocationStore(persistence: persistence)
        try await outbox.enqueue(.init(credentials: other, operationID: otherLogoutOperation))
        let lostResponse = LoseFirstRevocationResult(client: revocation)
        let started = Date()
        try await V2DeviceRevocationRunner(store: outbox, client: lostResponse, now: { started }).flushOnce()
        let pending = try #require(try await outbox.jobs().first)
        #expect(pending.intent.operationID == otherLogoutOperation)
        #expect(pending.attempts == 1)
        #expect(try await status(request("v2/devices", credentials: other)) == 401)
        let reopened = V2DeviceRevocationStore(persistence: persistence)
        try await V2DeviceRevocationRunner(store: reopened, client: lostResponse,
            now: { started.addingTimeInterval(2) }).flushOnce()
        #expect(try await reopened.jobs().isEmpty)
        #expect(try await revocation.revoke(credential: other.revocationCredential, operationID: otherLogoutOperation) == .revoked)
        #expect(try await status(request("v2/devices", credentials: other)) == 401)
        await #expect(throws: V2AuthSessionError.unauthenticated) { try await session.refresh() }
    }
}

// Drop a successful decoded result after the real server committed. This
// injects client-side result loss, not a simulated PostgreSQL response.
private actor LoseFirstRevocationResult: V2DeviceRevocationClient {
    let client: V2HTTPDeviceRevocationClient
    private var dropped = false
    init(client: V2HTTPDeviceRevocationClient) { self.client = client }
    func revoke(credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationResult {
        let result = try await client.revoke(credential: credential, operationID: operationID)
        if !dropped { dropped = true; throw V2DeviceRevocationClientError.networkFailure }
        return result
    }
}

private actor LoseFirstRegistrationCancellationResult: V2DeviceRegistrationCancellationClient {
    let client: V2HTTPDeviceRegistrationCancellationClient
    private var dropped = false
    init(client: V2HTTPDeviceRegistrationCancellationClient) { self.client = client }
    func cancel(_ request: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationResult {
        let result = try await client.cancel(request)
        if !dropped { dropped = true; throw V2DeviceRegistrationCancellationClientError.networkFailure }
        return result
    }
}

private actor LoseIssuedResponse: V2AuthHTTPTransport {
    let underlying: V2URLSessionAuthHTTPTransport
    private(set) var dropped = false
    init(underlying: V2URLSessionAuthHTTPTransport) { self.underlying = underlying }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await underlying.data(for: request)
        guard result.1.statusCode == 200 else { return result }
        dropped = true
        throw URLError(.networkConnectionLost)
    }
}

struct LiveAccountFixture {
    let base: URL
    let http: URLSession
    let transport: V2URLSessionAuthHTTPTransport
    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let rawBase = try #require(environment["IMV2_LIVE_ACCOUNT_HTTPS_URL"])
        base = try #require(URL(string: rawBase))
        try #require(base.scheme == "https" && base.host == "localhost")
        let ca = try Data(contentsOf: URL(fileURLWithPath: try #require(environment["IMV2_LIVE_ACCOUNT_CA_DER"])))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        http = URLSession(configuration: configuration, delegate: LiveAccountTrust(anchor: ca), delegateQueue: nil)
        transport = V2URLSessionAuthHTTPTransport(session: http)
    }
    func close() { http.invalidateAndCancel() }
    func url(_ path: String) -> URL { base.appendingPathComponent(path) }
    func session(_ store: LiveAccountCredentialStore) throws -> V2AuthSession {
        V2AuthSession(credentialStore: store, transport: try V2HTTPDeviceCredentialAuthTransport(
            refreshEndpoint: url("v2/device-credentials/refresh"), transport: transport),
            revocationScheduler: FixtureRevocationScheduler())
    }
    func devices(_ session: V2AuthSession) async throws -> V2HTTPDeviceSessionClient {
        let boundary = V2SessionHTTPAuthorization(session: session, epoch: await session.currentEpoch(), transport: transport)
        return try .init(endpoint: url("v2/devices"), credentials: boundary, transport: boundary)
    }
    func authenticator() throws -> V2HTTPPasswordAccountAuthenticator {
        try .init(registrationEndpoint: url("v2/account-auth/password/register"),
                  assertionEndpoint: url("v2/account-auth/password/assertion"), transport: transport)
    }
    func register() async throws -> (handle: String, credentials: V2AuthCredentials) {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20))
        let device = try DeviceID(UUID().uuidString.lowercased())
        let handle = "live_" + suffix
        let assertion = try await authenticator().register(accountHandle: handle, password: "local-live-test-password",
            publicHandle: "live" + suffix, displayName: "Local HTTPS verification", deviceID: device)
        return (handle, try await issue(assertion, device: device))
    }
    func login(_ handle: String) async throws -> V2AuthCredentials {
        let device = try DeviceID(UUID().uuidString.lowercased())
        let assertion = try await authenticator().authenticate(accountHandle: handle, password: "local-live-test-password", deviceID: device)
        return try await issue(assertion, device: device)
    }
    func loseIssuedResponse(_ handle: String) async throws -> V2DeviceRegistrationStore {
        let persistence = DeviceRegistrationTestPersistence()
        let registrations = V2DeviceRegistrationStore(persistence: persistence)
        let prepared = try await registrations.prepare(accountHandle: handle)
        let original = try #require(try await prepared.load())
        let device = try await prepared.deviceID()
        let assertion = try await authenticator().authenticate(accountHandle: handle, password: "local-live-test-password", deviceID: device)
        let received = IssuedRecoveryTestPersistence()
        let recovery = V2IssuedCredentialRecoveryStore(persistence: received,
            revocations: V2DeviceRevocationStore(persistence: RevocationTestPersistence()))
        let dropped = LoseIssuedResponse(underlying: transport)
        let issuer = try V2HTTPAccountAssertionDeviceCredentialProvider(issueEndpoint: url("v2/device-credentials"),
            assertionProvider: LiveAccountIdentity(assertion: assertion.value, device: device),
            deviceIdentityProvider: prepared, operationStore: prepared, recovery: recovery, transport: dropped)
        await #expect(throws: V2HTTPAuthTransportError.networkFailure) { try await issuer.issueDeviceCredentials() }
        #expect(await dropped.dropped)
        #expect(try received.load() == nil)
        #expect(try await prepared.load() == original)
        let reopened = V2DeviceRegistrationStore(persistence: persistence)
        try await reopened.recoverUnclaimed(ownedBy: nil)
        return reopened
    }
    private func issue(_ assertion: V2AccountAssertion, device: DeviceID) async throws -> V2AuthCredentials {
        let identity = LiveAccountIdentity(assertion: assertion.value, device: device)
        let received = IssuedRecoveryTestPersistence()
        let revocations = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let recovery = V2IssuedCredentialRecoveryStore(persistence: received, revocations: revocations)
        let issuer = try V2HTTPAccountAssertionDeviceCredentialProvider(issueEndpoint: url("v2/device-credentials"),
            assertionProvider: identity, deviceIdentityProvider: identity, operationStore: LiveAccountRegistrationStore(),
            recovery: recovery, transport: transport)
        let credentials = try await issuer.issueDeviceCredentials()
        #expect(try received.load() != nil)
        try await issuer.finalizeIssuedDeviceCredentials(credentials)
        #expect(try received.load() == nil)
        #expect(try await revocations.jobs().isEmpty)
        return credentials
    }
}

private final class LiveAccountTrust: NSObject, URLSessionDelegate {
    let anchor: Data
    init(anchor: Data) { self.anchor = anchor }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "localhost", let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecCertificateCreateWithData(nil, anchor as CFData),
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "localhost" as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil)
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct LiveAccountIdentity: V2DeviceBoundAccountAssertionProvider, V2DeviceIdentityProvider {
    let assertion: String
    let device: DeviceID
    func accountAssertion(for deviceID: DeviceID) throws -> String {
        guard deviceID == device else { throw V2AuthSessionError.deviceMismatch }
        return assertion
    }
    func deviceID() -> DeviceID { device }
}
private actor LiveAccountRegistrationStore: V2DeviceCredentialRegistrationOperationStore {
    var pending: V2PendingDeviceCredentialRegistration?
    func load() -> V2PendingDeviceCredentialRegistration? { pending }
    func save(_ value: V2PendingDeviceCredentialRegistration) { pending = value }
    func delete() { pending = nil }
}
actor LiveAccountCredentialStore: V2CredentialStore {
    var record: V2AuthCredentialRecord?
    init(_ credentials: V2AuthCredentials) { record = .init(credentials: credentials) }
    func load() -> V2AuthCredentialRecord? { record }
    func save(_ value: V2AuthCredentialRecord) { record = value }
    func delete() { record = nil }
}
#endif
