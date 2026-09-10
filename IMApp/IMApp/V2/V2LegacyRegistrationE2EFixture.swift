#if DEBUG
import CryptoKit
import Foundation
import Security

/// 需显式开启的测试夹具，只作用于全新的、用完即弃的本地端到端命名空间。
///
/// 它只写入历史标识；真正的授权仍由常规账号校验提供，并且绝不会覆盖已有的注册台账。
enum V2LegacyRegistrationE2EFixture {
    /// 在请求时写入历史注册台账。
    ///
    /// 仅在启动参数包含 `-v2-ui-testing-legacy-registration` 时生效，
    /// 并要求提供合法的端到端作用域、账号名、设备标识与操作标识。
    ///
    /// - Parameters:
    ///   - baseService: 钥匙串服务名前缀。
    ///   - scope: 端到端测试作用域。
    ///   - arguments: 启动参数。
    /// - Throws: 作用域缺失、参数非法或钥匙串写入失败时抛出。
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

    /// 删除该作用域下的历史注册台账。
    ///
    /// - Parameters:
    ///   - baseService: 钥匙串服务名前缀。
    ///   - scope: 端到端测试作用域。
    /// - Throws: 钥匙串删除失败（且不是「未找到」）时抛出。
    static func remove(baseService: String, scope: V2LiveLocalAccountE2ETestScope) throws {
        let status = SecItemDelete(query(baseService: baseService, scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.persistence }
    }

    /// 构造钥匙串查询条件。
    ///
    /// - Parameters:
    ///   - baseService: 钥匙串服务名前缀。
    ///   - scope: 端到端测试作用域。
    /// - Returns: 通用密码条目的查询字典。
    private static func query(baseService: String, scope: V2LiveLocalAccountE2ETestScope) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: scope.keychainService(basedOn: baseService),
         kSecAttrAccount as String: "device-registration-ledger-v1"]
    }
    private enum Failure: Error { case invalidScope, invalidInput, persistence }
}
#endif
