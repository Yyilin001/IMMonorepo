import Crypto
import Foundation
import IMV2Core
import NIOCore

/// 仅由已认证 HTTPS 边缘提供的客户端网络地址。
///
/// 该值在转换为不透明数据库键之前会被刻意校验；账号处理层既不会收到其明文形式，
/// 也不会把它写入日志。
public struct V2AccountEdgeClientAddress: Equatable, Sendable {
    private let rawValue: String

    /// 校验并保存网络地址。
    ///
    /// - Parameter value: 文本形式的 IP 地址，长度需在 1 至 45 字节之间且可解析为套接字地址。
    /// - Throws: 长度或格式不合法时抛出
    ///   ``V2AccountEdgeClientRateLimitError/invalidAddress``。
    public init(_ value: String) throws {
        guard (1 ... 45).contains(value.utf8.count),
              (try? SocketAddress(ipAddress: value, port: 0)) != nil
        else { throw V2AccountEdgeClientRateLimitError.invalidAddress }
        rawValue = value
    }

    /// 供键派生使用原始文本，不对外暴露。
    fileprivate var valueForKeyDerivation: String { rawValue }
}

/// 已通过认证 HTTPS 账号边缘的请求所使用的固定窗口预算，由部署方提供。
///
/// 代码刻意不提供默认值：生产部署必须依据其已批准的滥用防控与恢复策略选择预算。
public struct V2AccountEdgeClientRateLimitPolicy: Equatable, Sendable {
    /// 单窗口内允许的最大请求数。
    public let maximumRequests: Int
    /// 计数窗口长度。
    public let window: TimeInterval

    /// 校验并保存限流预算。
    ///
    /// - Parameters:
    ///   - maximumRequests: 窗口内最大请求数，需大于零且严格小于 `Int32.max`。
    ///   - window: 计数窗口长度，需可表示为整秒且能编码为 PostgreSQL 时间戳。
    /// - Throws: 任一取值越界时抛出
    ///   ``V2AccountEdgeClientRateLimitError/invalidPolicy``。
    ///
    /// 上限刻意留出一个哨兵值：库中请求数按有符号 32 位整数存储，
    /// 这样可在不溢出、不额外查询的前提下表示一次超预算尝试。
    public init(maximumRequests: Int, window: TimeInterval) throws {
        // PostgreSQL 以有符号 32 位整数存储 request_count。
        // 在配置的预算之上保留一个哨兵值，使超额请求无需溢出或二次查询即可表示。
        guard maximumRequests > 0,
              maximumRequests < Int(Int32.max),
              v2RateLimitDurationIsRepresentable(window)
        else {
            throw V2AccountEdgeClientRateLimitError.invalidPolicy
        }
        self.maximumRequests = maximumRequests
        self.window = window
    }
}

/// 账号边缘客户端限流错误。
public enum V2AccountEdgeClientRateLimitError: Error, Equatable, Sendable {
    /// 客户端地址长度或格式非法。
    case invalidAddress
    /// 限流密钥材料无法解码或长度不足。
    case invalidKeyMaterial
    /// 限流预算或作用域参数非法。
    case invalidPolicy
    /// 限流存储当前不可用。
    case unavailable
}

/// 在限流存储接触数据之前对地址与身份做假名化处理。
///
/// 数据库只保存 HMAC 摘要，永远不会保存 IP 地址或明文的用户、设备标识。
public struct V2AccountEdgeClientRateLimitKey: Sendable {
    private let rawBytes: Data

    /// 从 Base64 编码的密钥材料构造假名化密钥。
    ///
    /// - Parameter value: Base64 编码的密钥，至少 32 字节。
    /// - Throws: 无法解码或字节数不足时抛出
    ///   ``V2AccountEdgeClientRateLimitError/invalidKeyMaterial``。
    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2AccountEdgeClientRateLimitError.invalidKeyMaterial
        }
        rawBytes = bytes
    }

    /// 计算某个客户端地址的假名摘要。
    ///
    /// - Parameter address: 已通过边缘校验的客户端地址。
    /// - Returns: 十六进制表示的 HMAC 摘要。
    public func digest(_ address: V2AccountEdgeClientAddress) -> String {
        digest("ip|" + address.valueForKeyDerivation)
    }

    /// 计算某个已认证连接在指定作用域下的假名摘要。
    ///
    /// 复用同一部署密钥，但通过前缀把已认证预算与 IP 预算放在不同命名空间；
    /// 明文的用户与设备标识不会进入限流表。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接的用户与设备标识。
    ///   - scope: 作用域标识，需非空、不超过 64 字节且不含控制字符。
    /// - Returns: 十六进制表示的 HMAC 摘要。
    /// - Throws: 作用域为空、超长或含控制字符时抛出
    ///   ``V2AccountEdgeClientRateLimitError/invalidPolicy``。
    public func digest(
        identity: V2AuthenticatedConnection,
        scope: String
    ) throws -> String {
        guard !scope.isEmpty, scope.utf8.count <= 64,
              !scope.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw V2AccountEdgeClientRateLimitError.invalidPolicy }
        return digest(
            "auth|\(scope)|\(identity.userID.rawValue)|\(identity.deviceID.rawValue)"
        )
    }

    /// 以部署密钥计算给定前缀串的 HMAC-SHA256 摘要。
    ///
    /// - Parameter value: 待摘要的规范化前缀串。
    /// - Returns: 十六进制表示的摘要。
    private func digest(_ value: String) -> String {
        let key = SymmetricKey(data: rawBytes)
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: key
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
