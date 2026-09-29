import IMV2ServerContracts
import Foundation

/// 仅回环可达的运维服务的认证器。
///
/// 凭据是独立下发的高熵 Bearer 密钥，既不是用户或设备访问令牌，也不会进入公网网关进程。
public struct V2OperatorReplayBearerAuthenticator: Sendable {
    private let key: V2AccessTokenHMACKey
    private let expectedDigest: Data

    /// 从 Base64 编码的密钥材料构造认证器。
    ///
    /// - Parameter token: Base64 编码的密钥，至少 32 字节。
    /// - Throws: 无法解码或字节数不足时抛出
    ///   ``V2GatewayAuthenticationError/invalidKeyMaterial``。
    public init(base64EncodedBearerToken token: String) throws {
        guard let bytes = Data(base64Encoded: token), bytes.count >= 32 else {
            throw V2GatewayAuthenticationError.invalidKeyMaterial
        }
        key = try .init(rawBytes: bytes)
        expectedDigest = Data(key.digest(token).utf8)
    }

    /// 以恒定时间比较方式校验请求携带的 Bearer 令牌。
    ///
    /// - Parameter bearerToken: 请求中的令牌；为空或缺失一律拒绝。
    /// - Returns: 令牌摘要与预置摘要一致时为 `true`。
    public func isAuthorized(bearerToken: String?) -> Bool {
        guard let bearerToken, !bearerToken.isEmpty else { return false }
        return v2ConstantTimeEqual(Data(key.digest(bearerToken).utf8), expectedDigest)
    }
}

/// 以恒定时间比较两段字节，长度不同时同样走完整循环以避免泄漏长度信息。
///
/// - Parameters:
///   - lhs: 待比较的字节。
///   - rhs: 待比较的字节。
/// - Returns: 两段字节完全相同时为 `true`。
private func v2ConstantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    let maximumCount = max(lhs.count, rhs.count)
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    for index in 0..<maximumCount {
        let left = index < lhs.count ? lhs[lhs.index(lhs.startIndex, offsetBy: index)] : 0
        let right = index < rhs.count ? rhs[rhs.index(rhs.startIndex, offsetBy: index)] : 0
        difference |= left ^ right
    }
    return difference == 0
}
