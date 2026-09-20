import Crypto
import Foundation
import IMV2Core

/// 账号断言错误。
public enum V2AccountAssertionError: Error, Equatable, Sendable {
    /// 密钥材料无法解码或长度不足。
    case invalidKeyMaterial
    /// 断言寿命非正、非有限或超过上限。
    case invalidLifetime
    /// 断言格式、签名、时效或绑定设备不合法。
    case invalidAssertion
    /// 当前服务器时钟无法表示为毫秒时间戳。
    case invalidClock
}

/// 基于 HMAC 的短时账号断言签发与校验实现。
///
/// 这是有效期内可重复验证的 bearer 凭据，不提供一次性消费保证或设备私钥持有证明。
/// 注册与旧注册清理共用它完成同一次登录交接；幂等和取消边界由各操作账本负责。
/// 设备 ID 绑定只限制目标标识，持有断言的调用方仍可在有效期内提交该标识。
///
/// 断言绑定到即将注册的具体 V2 设备。由于载荷只包含不透明 UUID 与时间戳，
/// 这里选择签名而非加密；移动客户端在把它交给设备凭据边界之后既不会记录也不会保留它。
public struct V2HMACAccountAssertionIssuer: V2DeviceBoundAccountAssertionVerifier, Sendable {
    private let rawKey: Data
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date

    /// 以 Base64 密钥构造签发器。
    ///
    /// - Parameters:
    ///   - base64EncodedKey: Base64 编码的 HMAC 密钥，至少 32 字节。
    ///   - lifetime: 断言寿命秒数，默认 90 秒。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 密钥无法解码或长度不足时抛出
    ///   ``V2AccountAssertionError/invalidKeyMaterial``；寿命越界时抛出
    ///   ``V2AccountAssertionError/invalidLifetime``。
    public init(
        base64EncodedKey: String,
        lifetime: TimeInterval = 90,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard let key = Data(base64Encoded: base64EncodedKey), key.count >= 32 else {
            throw V2AccountAssertionError.invalidKeyMaterial
        }
        try self.init(rawKey: key, lifetime: lifetime, now: now)
    }

    /// 以原始密钥构造签发器。
    ///
    /// - Parameters:
    ///   - rawKey: HMAC 密钥字节，至少 32 字节。
    ///   - lifetime: 断言寿命秒数，需大于零且不超过 5 分钟。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 密钥长度不足时抛出
    ///   ``V2AccountAssertionError/invalidKeyMaterial``；寿命越界时抛出
    ///   ``V2AccountAssertionError/invalidLifetime``。
    public init(
        rawKey: Data,
        lifetime: TimeInterval = 90,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard rawKey.count >= 32 else { throw V2AccountAssertionError.invalidKeyMaterial }
        guard lifetime > 0, lifetime <= 5 * 60, lifetime.isFinite else { throw V2AccountAssertionError.invalidLifetime }
        self.rawKey = rawKey
        self.lifetime = lifetime
        self.now = now
    }

    /// 为指定用户与设备签发断言。
    ///
    /// 有效期按向下取整的毫秒计算，并要求到期毫秒严格大于签发毫秒；
    /// 服务器时钟早于 Unix 纪元时不会签发更长的有效期，而是直接报错。
    ///
    /// - Parameters:
    ///   - userID: 断言所属用户。
    ///   - deviceID: 断言绑定的设备。
    /// - Returns: 形如 `v2a1.<载荷>.<签名>` 的断言字符串。
    /// - Throws: 时刻无法表示为毫秒时间戳，或到期时间不晚于签发时间时抛出
    ///   ``V2AccountAssertionError/invalidClock``。
    public func issue(userID: UserID, deviceID: DeviceID, credentialRevision: Int64 = 1) throws -> String {
        let issuedAt = now()
        let issuedMilliseconds = issuedAt.timeIntervalSince1970 * 1_000
        let expiry = issuedAt.addingTimeInterval(lifetime).timeIntervalSince1970 * 1_000
        // A signed deadline must not extend the configured lifetime when
        // the server clock is before the Unix epoch.
        guard Int64(exactly: issuedMilliseconds.rounded(.towardZero)) != nil,
              let expiresAtMilliseconds = Int64(exactly: expiry.rounded(.down)),
              Double(expiresAtMilliseconds) > issuedMilliseconds
        else { throw V2AccountAssertionError.invalidClock }
        let claims = Claims(
            userID: userID.rawValue,
            deviceID: deviceID.rawValue,
            expiresAtMilliseconds: expiresAtMilliseconds,
            credentialRevision: credentialRevision
        )
        let payload = try JSONEncoder().encode(claims)
        let encodedPayload = base64URL(payload)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(encodedPayload.utf8), using: SymmetricKey(data: rawKey))
        return "v2a1.\(encodedPayload).\(base64URL(Data(signature)))"
    }

    /// 校验断言并返回其声明的用户，不校验绑定设备。
    ///
    /// - Parameter accountAssertion: 待校验的断言。
    /// - Returns: 断言确认的用户标识。
    /// - Throws: 断言非法、过期或时钟不可用时抛出。
    public func verifiedUserID(for accountAssertion: String) throws -> UserID {
        try verifiedClaims(for: accountAssertion, expectedDeviceID: nil).userID
    }

    /// 校验断言并确认其绑定到指定设备。
    ///
    /// - Parameters:
    ///   - accountAssertion: 待校验的断言。
    ///   - deviceID: 期望绑定的设备。
    /// - Returns: 断言确认的用户标识。
    /// - Throws: 断言非法、过期、绑定到其他设备或时钟不可用时抛出。
    public func verifiedUserID(for accountAssertion: String, deviceID: DeviceID) throws -> UserID {
        try verifiedClaims(for: accountAssertion, expectedDeviceID: deviceID).userID
    }

    public func credentialRevision(for accountAssertion: String, deviceID: DeviceID) throws -> Int64? {
        try verifiedClaims(for: accountAssertion, expectedDeviceID: deviceID).revision
    }

    /// 校验断言结构、签名、时效与可选设备绑定。
    ///
    /// - Parameters:
    ///   - assertion: 待校验的断言。
    ///   - expectedDeviceID: 期望绑定的设备；为 `nil` 时跳过设备校验。
    /// - Returns: 断言确认的用户标识。
    /// - Throws: 断言超长、段数或版本前缀不符、Base64 解码失败、签名无效、
    ///   载荷无法解码、标识非法、已过期、设备不匹配时抛出
    ///   ``V2AccountAssertionError/invalidAssertion``；
    ///   当前时钟无法表示时抛出 ``V2AccountAssertionError/invalidClock``。
    private func verifiedClaims(for assertion: String, expectedDeviceID: DeviceID?) throws -> (userID: UserID, revision: Int64) {
        guard assertion.utf8.count <= 4_096 else { throw V2AccountAssertionError.invalidAssertion }
        let parts = assertion.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v2a1",
              let payload = decodeBase64URL(String(parts[1])),
              let signature = decodeBase64URL(String(parts[2])),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(parts[1].utf8), using: SymmetricKey(data: rawKey)),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              claims.credentialRevision > 0,
              let userID = try? UserID(claims.userID),
              let assertionDeviceID = try? DeviceID(claims.deviceID)
        else { throw V2AccountAssertionError.invalidAssertion }
        let nowMilliseconds = now().timeIntervalSince1970 * 1_000
        guard Int64(exactly: nowMilliseconds.rounded(.towardZero)) != nil else { throw V2AccountAssertionError.invalidClock }
        guard Double(claims.expiresAtMilliseconds) > nowMilliseconds,
              expectedDeviceID.map({ $0 == assertionDeviceID }) ?? true
        else { throw V2AccountAssertionError.invalidAssertion }
        return (userID, claims.credentialRevision)
    }
}

/// 断言签名覆盖的载荷字段。
private struct Claims: Codable, Sendable {
    let userID: String
    let deviceID: String
    let expiresAtMilliseconds: Int64
    let credentialRevision: Int64
}

/// 编码为无填充的 URL 安全 Base64。
///
/// - Parameter data: 待编码数据。
/// - Returns: 把 `+`、`/` 替换为 `-`、`_` 并去掉 `=` 的字符串。
private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// 解码无填充的 URL 安全 Base64。
///
/// - Parameter value: 待解码字符串。
/// - Returns: 解码后的数据；格式非法时返回 `nil`。
private func decodeBase64URL(_ value: String) -> Data? {
    var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
    return Data(base64Encoded: padded)
}
