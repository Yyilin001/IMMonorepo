import Crypto
import Foundation

/// 用于访问令牌索引的 HMAC 密钥材料。
///
/// 由组装层从密钥管理或环境配置注入；数据库查找使用摘要，不把原始访问令牌作为持久化查询键。
/// 内部保存不可变字节，仅在同步摘要计算时创建 Crypto 密钥值。
public struct V2AccessTokenHMACKey: Sendable {
    // Crypto 的 SymmetricKey 不符合 Sendable。保留符合 Sendable 的不可变字节，
    // 只在同步摘要计算边界创建短期 Crypto 值。
    /// 不可变密钥字节，不应输出到日志或诊断响应。
    private let rawBytes: Data

    /// 从 Base64 配置创建令牌摘要密钥。
    ///
    /// - Parameter value: 编码后的密钥，解码后至少 32 字节。
    /// - Throws: 无法解码或长度不足时抛出无效密钥材料错误。
    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2GatewayAuthenticationError.invalidKeyMaterial
        }
        rawBytes = bytes
    }

    /// 从原始字节创建令牌摘要密钥。
    ///
    /// - Parameter rawBytes: 至少 32 字节的密钥材料。
    /// - Throws: 长度不足时抛出无效密钥材料错误。
    ///
    /// 长度检查不能证明随机性，安全生成与存储由配置提供方负责。
    public init(rawBytes: Data) throws {
        guard rawBytes.count >= 32 else { throw V2GatewayAuthenticationError.invalidKeyMaterial }
        self.rawBytes = rawBytes
    }

    /// 通过 Crypto 的认证码比较方法验证已存储的十六进制摘要。
    package func matches(_ digest: String, value: String) -> Bool {
        guard digest.utf8.count == 64 else { return false }
        let chars = Array(digest)
        var bytes = Data()
        for index in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return false }
            bytes.append(byte)
        }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data(value.utf8), using: SymmetricKey(data: rawBytes))
    }

    /// 计算访问令牌的 HMAC-SHA256 查询摘要。
    ///
    /// - Parameter accessToken: 按原样 UTF-8 编码的令牌，不执行空白清理或格式校验。
    /// - Returns: 64 个小写十六进制字符，可用于数据库精确匹配。
    ///
    /// 同一密钥与令牌产生相同摘要；更换密钥会改变查询结果，需要外部协调令牌生命周期。
    public func digest(_ accessToken: String) -> String {
        let key = SymmetricKey(data: rawBytes)
        let code = HMAC<SHA256>.authenticationCode(for: Data(accessToken.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
