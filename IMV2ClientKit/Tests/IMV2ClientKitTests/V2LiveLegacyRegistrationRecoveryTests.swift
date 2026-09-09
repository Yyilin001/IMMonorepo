#if os(macOS)
import Foundation
import Crypto
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Live legacy registration recovery", .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_LEGACY_RECOVERY"] == "1"), .timeLimit(.minutes(2)))
struct V2LiveLegacyRegistrationRecoveryTests {
    @Test("Real cleanup acknowledgement loss replays archived identity before new credential issuance")
    func recoverLegacy() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let old = try await fixture.register()
        let scope = SHA256.hash(data: Data(("password-account-v1\0" + old.handle).utf8)).map { String(format: "%02x", $0) }.joined()
        let persistence = DeviceRegistrationTestPersistence()
        try persistence.save(JSONSerialization.data(withJSONObject: ["version": 1, "pending": [scope:
            ["deviceID": ["rawValue": old.credentials.deviceID.rawValue], "operationID": UUID().uuidString]]]))
        let registrations = V2DeviceRegistrationStore(persistence: persistence)
        let dropped = LoseFirstLegacyAcknowledgement(underlying: fixture.transport)
        let cleanup = try V2HTTPLegacyRegistrationCancellationClient(endpoint: fixture.url("v2/device-credentials/cancel-legacy-registration"), transport: dropped)
        let received = IssuedRecoveryTestPersistence()
        let recovery = V2IssuedCredentialRecoveryStore(persistence: received, revocations: V2DeviceRevocationStore(persistence: RevocationTestPersistence()))
        func issuer(_ lease: V2PreparedDeviceRegistration) throws -> V2HTTPAccountAssertionDeviceCredentialProvider {
            let factor = V2OneTimePasswordAccountAssertionProvider(accountHandle: old.handle, password: "local-live-test-password", authenticator: try fixture.authenticator())
            return try .init(issueEndpoint: fixture.url("v2/device-credentials"),
                assertionProvider: lease.recoveringLegacyRegistration(using: factor, client: cleanup),
                deviceIdentityProvider: lease, operationStore: lease, recovery: recovery, transport: fixture.transport)
        }
        let first = try await registrations.prepare(accountHandle: old.handle)
        let firstIssuer = try issuer(first)
        await #expect(throws: V2LegacyRegistrationCancellationError.networkFailure) { try await firstIssuer.issueDeviceCredentials() }
        #expect(try await registrations.legacyRecoveryCount() == 1)
        #expect(try received.load() == nil)
        let reopened = V2DeviceRegistrationStore(persistence: persistence)
        let retry = try await reopened.prepare(accountHandle: old.handle)
        #expect(try await retry.deviceID() == first.deviceID())
        let retryIssuer = try issuer(retry)
        let credentials = try await retryIssuer.issueDeviceCredentials()
        #expect(credentials.deviceID != old.credentials.deviceID)
        #expect(try await reopened.legacyRecoveryCount() == 0)
        try await retryIssuer.finalizeIssuedDeviceCredentials(credentials)
        #expect(try persistence.load() == nil)
        #expect(await dropped.calls == 2)
        let session = try fixture.session(LiveAccountCredentialStore(credentials))
        _ = try await session.restoreState()
        let devices = try await fixture.devices(session)
        let page = try await devices.list(cursor: nil, pageSize: 10)
        #expect(page.sessions.count == 1)
        #expect(page.sessions.first?.isCurrentDevice == true)
        var request = URLRequest(url: fixture.url("v2/devices"))
        request.setValue("Bearer " + old.credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(old.credentials.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        let (_, response) = try await fixture.transport.data(for: request)
        #expect(response.statusCode == 401)
    }
}

private actor LoseFirstLegacyAcknowledgement: V2AuthHTTPTransport {
    let underlying: any V2AuthHTTPTransport
    private(set) var calls = 0
    init(underlying: any V2AuthHTTPTransport) { self.underlying = underlying }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await underlying.data(for: request)
        #expect(result.1.statusCode == 204)
        calls += 1
        if calls == 1 { throw URLError(.networkConnectionLost) }
        return result
    }
}

#endif
