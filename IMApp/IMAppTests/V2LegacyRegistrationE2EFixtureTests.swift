#if DEBUG
import Foundation
import Security
import Testing
@testable import IMApp

@MainActor
@Suite("Legacy fixture namespace protection")
struct V2LegacyRegistrationE2EFixtureTests {
    @Test("Opt-in scope is required and existing records cannot be overwritten")
    func boundaries() throws {
        let base = "legacy-fixture-test." + UUID().uuidString
        let scope = try #require(V2LiveLocalAccountE2ETestScope(rawValue: UUID().uuidString))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope.keychainService(basedOn: base),
            kSecAttrAccount as String: "device-registration-ledger-v1"]
        let unscoped: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: base, kSecAttrAccount as String: "device-registration-ledger-v1"]
        defer { SecItemDelete(query as CFDictionary); SecItemDelete(unscoped as CFDictionary) }
        let arguments = ["-v2-ui-testing-legacy-registration", "-v2-ui-testing-account-handle", "legacyapp_" + String(repeating: "a", count: 20),
            "-v2-ui-testing-legacy-device", UUID().uuidString, "-v2-ui-testing-legacy-operation", UUID().uuidString]
        try V2LegacyRegistrationE2EFixture.installIfRequested(baseService: base, scope: nil, arguments: [])
        #expect(throws: (any Error).self) { try V2LegacyRegistrationE2EFixture.installIfRequested(baseService: base, scope: nil, arguments: arguments) }
        var invalid = arguments
        invalid[2] = "ordinary_account"
        #expect(throws: (any Error).self) { try V2LegacyRegistrationE2EFixture.installIfRequested(baseService: base, scope: scope, arguments: invalid) }
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
        var marker = unscoped
        marker[kSecValueData as String] = Data("untouched-base-service".utf8)
        try #require(SecItemAdd(marker as CFDictionary, nil) == errSecSuccess)
        try V2LegacyRegistrationE2EFixture.installIfRequested(baseService: base, scope: scope, arguments: arguments)
        let before = try read(query)
        var changed = arguments
        changed[4] = UUID().uuidString
        #expect(throws: (any Error).self) { try V2LegacyRegistrationE2EFixture.installIfRequested(baseService: base, scope: scope, arguments: changed) }
        #expect(try read(query) == before)
        try V2LegacyRegistrationE2EFixture.remove(baseService: base, scope: scope)
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
        #expect(try read(unscoped) == Data("untouched-base-service".utf8))
    }

    private func read(_ query: [String: Any]) throws -> Data {
        var result: CFTypeRef?
        try #require(SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &result) == errSecSuccess)
        return try #require(result as? Data)
    }
}
#endif
