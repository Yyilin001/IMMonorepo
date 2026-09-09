import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Legacy registration recovery")
struct V2LegacyRegistrationRecoveryTests {
    private let endpoint = URL(string: "https://account.example/v2/device-credentials/cancel-legacy-registration")!

    @Test("Only empty 204 completes recovery", arguments: [204, 200, 400, 401, 403, 404, 409, 410, 429, 503, 507])
    func statuses(_ status: Int) async throws {
        let transport = LegacyHTTPTransport(status: status)
        let client = try V2HTTPLegacyRegistrationCancellationClient(endpoint: endpoint, transport: transport)
        let legacy = try V2LegacyDeviceRegistration(deviceID: .init(uuid: UUID()), operationID: UUID())
        let device = DeviceID(uuid: UUID())
        if status == 204 {
            try await client.cancel(legacy, accountAssertion: "fresh-factor", assertionDeviceID: device)
        } else {
            let expected: V2LegacyRegistrationCancellationError
            switch status {
            case 400: expected = .invalidRequest
            case 401: expected = .authenticationRequired
            case 403: expected = .accountUnavailable
            case 404: expected = .targetUnavailable
            case 409: expected = .conflict
            case 429: expected = .rateLimited(retryAfterSeconds: 19)
            case 507: expected = .capacityExceeded
            default: expected = .serverStatus(status)
            }
            await #expect(throws: expected) { try await client.cancel(legacy, accountAssertion: "fresh-factor", assertionDeviceID: device) }
        }
        let requests = await transport.requests
        let request = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.timeoutInterval == 15)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["accountAssertion": "fresh-factor", "assertionDeviceID": device.rawValue,
            "targetDeviceID": legacy.deviceID.rawValue, "operationID": legacy.operationID.uuidString])
    }

    @Test("Unsafe endpoint and invalid completion are rejected")
    func transportBoundaries() async throws {
        for value in ["http://account.example/cancel", "https://user:pass@account.example/cancel", "https://account.example/cancel?x=y", "https://account.example/cancel#x"] {
            let url = try #require(URL(string: value))
            #expect(throws: V2LegacyRegistrationCancellationError.invalidEndpoint) { try V2HTTPLegacyRegistrationCancellationClient(endpoint: url) }
        }
        let legacy = try V2LegacyDeviceRegistration(deviceID: .init(uuid: UUID()), operationID: UUID())
        let client = try V2HTTPLegacyRegistrationCancellationClient(endpoint: endpoint, transport: LegacyHTTPTransport(status: 204, body: Data("unexpected".utf8)))
        await #expect(throws: V2LegacyRegistrationCancellationError.invalidResponse) { try await client.cancel(legacy, accountAssertion: "factor", assertionDeviceID: .init(uuid: UUID())) }
        await #expect(throws: V2LegacyRegistrationCancellationError.invalidRequest) { try await client.cancel(legacy, accountAssertion: "factor", assertionDeviceID: legacy.deviceID) }
        for mode in ["cancel-url", "late-success", "network"] {
            let client = try V2HTTPLegacyRegistrationCancellationClient(endpoint: endpoint, transport: LegacyHTTPTransport(status: 204, mode: mode))
            let task = Task { try await client.cancel(legacy, accountAssertion: "factor", assertionDeviceID: .init(uuid: UUID())) }
            if mode == "network" {
                await #expect(throws: V2LegacyRegistrationCancellationError.networkFailure) { try await task.value }
            } else { await #expect(throws: CancellationError.self) { try await task.value } }
        }
    }

    @Test("One factor cleans only its account archive before returning; retries omit completed work")
    func successfulRecovery() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        try seed(persistence, accounts: ["account_a", "account_b"])
        let store = V2DeviceRegistrationStore(persistence: persistence)
        let lease = try await store.prepare(accountHandle: "ACCOUNT_A")
        let factor = LegacyFactor()
        let client = LegacyCleanup()
        let provider = lease.recoveringLegacyRegistration(using: factor, client: client)
        let device = try await lease.deviceID()
        #expect(try await provider.accountAssertion(for: device) == "fresh-factor")
        #expect(try await store.legacyRecoveryCount() == 1)
        #expect(await client.count == 1)
        #expect(await factor.count == 1)
        #expect(try await lease.deviceID() == device)
        #expect(try await provider.accountAssertion(for: device) == "fresh-factor")
        #expect(await client.count == 1)
        let other = try await store.prepare(accountHandle: "account_b")
        #expect(try await other.deviceID() != device)
        #expect(try await store.legacyRecoveryCount() == 1)
    }

    @Test("HTTP failures preserve the exact archive and escape issuer without credential HTTP", arguments: [404, 401, 507, 503])
    func failedRecovery(status: Int) async throws {
        let persistence = DeviceRegistrationTestPersistence()
        try seed(persistence, accounts: ["account_a"])
        let store = V2DeviceRegistrationStore(persistence: persistence)
        let lease = try await store.prepare(accountHandle: "account_a")
        let before = try persistence.load()
        let cleanup = try V2HTTPLegacyRegistrationCancellationClient(endpoint: endpoint, transport: LegacyHTTPTransport(status: status))
        let issueTransport = LegacyHTTPTransport(status: 200)
        let issuer = try V2HTTPAccountAssertionDeviceCredentialProvider(issueEndpoint: endpoint,
            assertionProvider: lease.recoveringLegacyRegistration(using: LegacyFactor(), client: cleanup),
            deviceIdentityProvider: lease, operationStore: lease,
            recovery: V2IssuedCredentialRecoveryStore(persistence: IssuedRecoveryTestPersistence(), revocations: V2DeviceRevocationStore(persistence: RevocationTestPersistence())),
            transport: issueTransport)
        await #expect(throws: V2LegacyRegistrationCancellationError.self) { try await issuer.issueDeviceCredentials() }
        #expect(await issueTransport.requests.isEmpty)
        #expect(try persistence.load() == before)
    }

    @Test("Local commit failure replays the same archive after recreation")
    func failedPersistence() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        try seed(persistence, accounts: ["account_a"])
        let store = V2DeviceRegistrationStore(persistence: persistence)
        let lease = try await store.prepare(accountHandle: "account_a")
        let client = LegacyCleanup(action: { persistence.setFailure(.save) })
        let provider = lease.recoveringLegacyRegistration(using: LegacyFactor(), client: client)
        let device = try await lease.deviceID()
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.unavailable) { try await provider.accountAssertion(for: device) }
        persistence.setFailure(nil)
        let reopened = V2DeviceRegistrationStore(persistence: persistence)
        #expect(try await reopened.legacyRecoveryCount() == 1)
        let retryLease = try await reopened.prepare(accountHandle: "account_a")
        let retry = LegacyCleanup()
        _ = try await retryLease.recoveringLegacyRegistration(using: LegacyFactor(), client: retry).accountAssertion(for: device)
        #expect(await client.target == retry.target)
        #expect(try await reopened.legacyRecoveryCount() == 0)
    }

    @Test("Cancellation, logout and replaced archive fence late completion", arguments: ["cancel", "logout", "replaced"])
    func staleCompletion(mode: String) async throws {
        let persistence = DeviceRegistrationTestPersistence()
        try seed(persistence, accounts: ["account_a"])
        let store = V2DeviceRegistrationStore(persistence: persistence)
        let lease = try await store.prepare(accountHandle: "account_a")
        let device = try await lease.deviceID()
        let cleanup = LegacyCleanup(action: {
            if mode == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
            if mode == "logout" {
                try await store.discardPendingRegistrations()
                _ = try await store.prepare(accountHandle: "account_a")
            }
            if mode == "replaced" {
                let bytes = try #require(try persistence.load())
                var ledger = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var legacy = try #require(ledger["legacy"] as? [String: [String: Any]])
                for key in legacy.keys { legacy[key]?["operationID"] = UUID().uuidString }
                ledger["legacy"] = legacy
                try persistence.save(JSONSerialization.data(withJSONObject: ledger))
            }
        })
        let provider = lease.recoveringLegacyRegistration(using: LegacyFactor(), client: cleanup)
        let task = Task { try await provider.accountAssertion(for: device) }
        if mode == "cancel" { await #expect(throws: CancellationError.self) { try await task.value } }
        else { await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.malformedRecord) { try await task.value } }
        #expect(try await store.legacyRecoveryCount() == 1)
        if mode == "logout" { #expect(try await store.prepare(accountHandle: "account_a").deviceID() != device) }
    }

    @Test("A full migrated archive has exactly one reserved recovery slot")
    func fullArchive() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        try seed(persistence, accounts: (0..<256).map { "account_\($0)" })
        let store = V2DeviceRegistrationStore(persistence: persistence)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.capacityExceeded) { try await store.prepare(accountHandle: "unrelated_account") }
        let lease = try await store.prepare(accountHandle: "account_0")
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.capacityExceeded) { try await store.prepare(accountHandle: "account_1") }
        let device = try await lease.deviceID()
        _ = try await lease.recoveringLegacyRegistration(using: LegacyFactor(), client: LegacyCleanup()).accountAssertion(for: device)
        #expect(try await store.legacyRecoveryCount() == 255)
        try await lease.delete()
        _ = try await store.prepare(accountHandle: "unrelated_account")
    }

    private func seed(_ persistence: DeviceRegistrationTestPersistence, accounts: [String]) throws {
        var values: [String: Any] = [:]
        for account in accounts {
            let scope = SHA256.hash(data: Data(("password-account-v1\0" + account).utf8)).map { String(format: "%02x", $0) }.joined()
            values[scope] = ["deviceID": ["rawValue": UUID().uuidString], "operationID": UUID().uuidString]
        }
        try persistence.save(JSONSerialization.data(withJSONObject: ["version": 1, "pending": values]))
    }
}

private actor LegacyHTTPTransport: V2AuthHTTPTransport {
    let status: Int
    let body: Data
    let mode: String?
    private(set) var requests: [URLRequest] = []
    init(status: Int, body: Data = Data(), mode: String? = nil) { self.status = status; self.body = body; self.mode = mode }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if mode == "network" { throw URLError(.networkConnectionLost) }
        if mode == "cancel-url" { throw URLError(.cancelled) }
        if mode == "late-success" { withUnsafeCurrentTask { $0?.cancel() } }
        return (body, try #require(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "19"])))
    }
}

private actor LegacyFactor: V2DeviceBoundAccountAssertionProvider {
    private(set) var count = 0
    func accountAssertion(for deviceID: DeviceID) -> String { count += 1; return "fresh-factor" }
}

private actor LegacyCleanup: V2LegacyRegistrationCancellationClient {
    private(set) var count = 0
    private(set) var target: V2LegacyDeviceRegistration?
    let action: @Sendable () async throws -> Void
    init(action: @escaping @Sendable () async throws -> Void = {}) { self.action = action }
    func cancel(_ registration: V2LegacyDeviceRegistration, accountAssertion: String, assertionDeviceID: DeviceID) async throws {
        #expect(accountAssertion == "fresh-factor")
        #expect(registration.deviceID != assertionDeviceID)
        count += 1; target = registration
        try await action()
    }
}
