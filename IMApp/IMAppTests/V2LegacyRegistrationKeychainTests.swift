import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core
import Security
import Testing
@testable import IMApp

@Suite("Legacy registration Keychain recovery", .timeLimit(.minutes(1)))
struct V2LegacyRegistrationKeychainTests {
    @MainActor
    @Test("Cold App preserves legacy identity and confirmed cleanup removes only its archive")
    func coldRecovery() async throws {
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: UUID().uuidString))
        let service = scope.keychainService(basedOn: try V2AppConfiguration().keychainService)
        let old = DeviceID(uuid: UUID()), operation = UUID()
        let account = "legacy_account"
        let key = SHA256.hash(data: Data(("password-account-v1\0" + account).utf8)).map { String(format: "%02x", $0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "pending": [key: ["deviceID": ["rawValue": old.rawValue], "operationID": operation.uuidString]]])
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "device-registration-ledger-v1"]
        defer { SecItemDelete(query as CFDictionary) }
        var insert = query
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecValueData as String] = data
        try #require(SecItemAdd(insert as CFDictionary, nil) == errSecSuccess)
        let app = V2AppStore(startupMode: .uiTestingLiveLocalAccount, liveLocalAccountE2ETestScope: scope)
        await app.restore()
        #expect(app.route == .signedOut)
        let store = V2DeviceRegistrationStore(service: service)
        #expect(try await store.legacyRecoveryCount() == 1)
        let lease = try await store.prepare(accountHandle: account)
        let device = try await lease.deviceID()
        #expect(device != old)
        let failed = lease.recoveringLegacyRegistration(using: KeychainLegacyFactor(), client: KeychainLegacyCleanup(fail: true, expected: old, operation: operation))
        await #expect(throws: V2LegacyRegistrationCancellationError.networkFailure) { try await failed.accountAssertion(for: device) }
        let reopened = V2DeviceRegistrationStore(service: service)
        #expect(try await reopened.legacyRecoveryCount() == 1)
        let retry = try await reopened.prepare(accountHandle: account)
        #expect(try await retry.deviceID() == device)
        let provider = retry.recoveringLegacyRegistration(using: KeychainLegacyFactor(), client: KeychainLegacyCleanup(fail: false, expected: old, operation: operation))
        #expect(try await provider.accountAssertion(for: device) == "fresh-factor")
        #expect(try await reopened.legacyRecoveryCount() == 0)
        #expect(try await retry.deviceID() == device)
        var attributes: CFTypeRef?
        try #require(SecItemCopyMatching(query.merging([kSecReturnAttributes as String: true]) { _, new in new } as CFDictionary, &attributes) == errSecSuccess)
        let item = try #require(attributes as? [String: Any])
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        try await retry.delete()
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
        let cleanup = V2AppStore(startupMode: .uiTestingLiveLocalAccountCleanup, liveLocalAccountE2ETestScope: scope)
        await cleanup.restore()
        #expect(cleanup.route == .uiTestingLiveLocalAccountCleanupCompleted)
    }
}

private struct KeychainLegacyFactor: V2DeviceBoundAccountAssertionProvider {
    func accountAssertion(for deviceID: DeviceID) async throws -> String { "fresh-factor" }
}

private struct KeychainLegacyCleanup: V2LegacyRegistrationCancellationClient {
    let fail: Bool
    let expected: DeviceID
    let operation: UUID
    func cancel(_ registration: V2LegacyDeviceRegistration, accountAssertion: String, assertionDeviceID: DeviceID) async throws {
        #expect(registration.deviceID == expected)
        #expect(registration.operationID == operation)
        #expect(accountAssertion == "fresh-factor")
        #expect(assertionDeviceID != expected)
        if fail { throw V2LegacyRegistrationCancellationError.networkFailure }
    }
}
