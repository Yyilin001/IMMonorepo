import Foundation

/// 仅由 HTTPS 边缘与回环账号进程共享的密钥。
///
/// 它用于阻止本地调用方绕过已批准的边缘，直接把自造的转发上下文头交给账号路由。
public struct V2AccountEdgeAuthorizationSecret: Sendable {
    private let bytes: Data

    /// 从 Base64 编码的密钥材料构造。
    ///
    /// - Parameter value: Base64 编码的密钥，至少 32 字节。
    /// - Throws: 无法解码或字节数不足时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64")
        }
        self.bytes = bytes
    }

    /// 以恒定时间比较候选密钥。
    ///
    /// - Parameter value: 候选密钥的 Base64 编码。
    /// - Returns: 长度与内容都一致时为 `true`。
    public func matches(base64EncodedCandidate value: String) -> Bool {
        guard let candidate = Data(base64Encoded: value), candidate.count == bytes.count else { return false }
        var difference: UInt8 = 0
        for (candidateByte, expectedByte) in zip(candidate, bytes) {
            difference |= candidateByte ^ expectedByte
        }
        return difference == 0
    }
}
