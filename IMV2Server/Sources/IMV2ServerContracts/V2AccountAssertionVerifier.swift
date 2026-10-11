import IMV2Core

/// 内建账号认证因子的设备绑定扩展。
///
/// 校验结果与将要领取凭据的具体安装绑定，避免被窃取的短时断言被重放去注册第二台设备。
public protocol V2DeviceBoundAccountAssertionVerifier: Sendable {
    /// 密码因子的版本，供持有账号状态锁的签发事务复核；独立受信因子可返回 nil。
    func credentialRevision(for accountAssertion: String, deviceID: DeviceID) async throws -> Int64?

    /// 校验账号断言，并确认其绑定到指定安装。
    ///
    /// - Parameters:
    ///   - accountAssertion: 账号认证因子产生的不透明断言。
    ///   - deviceID: 本次凭据将要签发的安装标识。
    /// - Returns: 断言确认的用户标识。
    /// - Throws: 断言无效、过期、绑定到其他安装或校验设施不可用时抛出。
    func verifiedUserID(for accountAssertion: String, deviceID: DeviceID) async throws -> UserID
}

public extension V2DeviceBoundAccountAssertionVerifier {
    func credentialRevision(for accountAssertion: String, deviceID: DeviceID) async throws -> Int64? { nil }
}
