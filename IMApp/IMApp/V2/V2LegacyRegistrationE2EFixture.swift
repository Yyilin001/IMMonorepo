#if DEBUG
import CryptoKit
import Foundation
import Security

/// Opt-in fixture restricted to a fresh, disposable local-E2E namespace.
/// Seeds only historical IDs; normal account verification still supplies all
/// authority. It never overwrites an existing registration ledger.
enum V2LegacyRegistrationE2EFixture {
    static func installIfRequested(baseService: String, scope: V2LiveLocalAccountE2ETestScope?, arguments: [String]) throws {
        guard arguments.contains("-v2-ui-testing-legacy-registration") else { return }
        guard let scope else { throw Failure.invalidScope }
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let account = value("-v2-ui-testing-account-handle"),
              account.range(of: "^legacyapp_[a-f0-9]{20}$", options: .regularExpression) != nil,
              let rawDevice = value("-v2-ui-testing-legacy-device"), let device = UUID(uuidString: rawDevice),
              let rawOperation = value("-v2-ui-testing-legacy-operation"), let operation = UUID(uuidString: rawOperation)
        else { throw Failure.invalidInput }
        let key = SHA256.hash(data: Data(("password-account-v1\0" + account).utf8)).map { String(format: "%02x", $0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "pending": [key:
            ["deviceID": ["rawValue": device.uuidString], "operationID": operation.uuidString]]])
        var item = query(baseService: baseService, scope: scope)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.persistence }
    }

    static func remove(baseService: String, scope: V2LiveLocalAccountE2ETestScope) throws {
        let status = SecItemDelete(query(baseService: baseService, scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.persistence }
    }

    private static func query(baseService: String, scope: V2LiveLocalAccountE2ETestScope) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: scope.keychainService(basedOn: baseService),
         kSecAttrAccount as String: "device-registration-ledger-v1"]
    }
    private enum Failure: Error { case invalidScope, invalidInput, persistence }
}
#endif
