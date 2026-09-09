import Foundation

/// 仅用于撤销服务端绑定会话的目的受限凭证，不可用作访问令牌或刷新凭证。
///
/// 格式校验只确认编码合法，不证明服务端已签发、绑定或仍接受该值。文本描述与反射隐藏内容，rawValue 和 Codable 仍包含敏感原文。
public struct V2DeviceRevocationCredential: Equatable, Sendable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// 含用途前缀的敏感凭证原文，只应交给必要的持久化和传输边界。
    public let rawValue: String
    /// 区分设备会话撤销用途的固定版本前缀 imv2-revoke-v1.。
    private static let prefix = "imv2-revoke-v1."

    /// 校验并保存带用途前缀的规范 256 位凭证编码。
    ///
    /// - Parameter rawValue: 前缀后恰好 43 个 ASCII Base64URL 字符，不包含填充符。
    /// - Throws: 前缀、长度、字符集、32 字节解码结果或重新编码一致性不满足时抛出 invalidCredential。
    ///
    /// 重新编码比较确保只接受规范表示，不进行服务端授权检查。
    public init(rawValue: String) throws {
        guard rawValue.utf8.count == Self.prefix.utf8.count + 43,
              rawValue.hasPrefix(Self.prefix) else { throw ValidationError.invalidCredential }
        let suffix = String(rawValue.dropFirst(Self.prefix.count))
        guard suffix.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), let bytes = Data(base64Encoded: suffix.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32, Self.encode(bytes) == suffix
        else { throw ValidationError.invalidCredential }
        self.rawValue = rawValue
    }

    /// 使用 SystemRandomNumberGenerator 生成 32 个随机字节并添加用途前缀。
    ///
    /// - Returns: 格式合法的新撤销凭证；是否绑定会话由服务端持久化流程决定。
    public static func generate() -> Self {
        var random = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        return Self(generatedValue: prefix + encode(bytes))
    }

    /// 内部接纳由本类型生成的规范值，避免重复解码校验。
    private init(generatedValue: String) { rawValue = generatedValue }

    /// 将字节转换为无填充 Base64URL，替换加号与斜线并移除等号。
    private static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// 从单值字符串解码并复用公开构造校验，非法编码不能绕过验证。
    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    /// 将完整敏感原文编码为单个字符串，不使用展示用脱敏描述。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// 返回固定脱敏描述，不展示原始凭证。
    public var description: String { "V2DeviceRevocationCredential(<redacted>)" }
    /// 调试描述复用脱敏文本。
    public var debugDescription: String { description }
    /// 提供无子字段的反射视图，避免常规反射展开 rawValue；不改变其公开可访问性。
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// 凭证格式校验错误；invalidCredential 表示输入不满足规范编码。
    public enum ValidationError: Error, Equatable, Sendable { case invalidCredential }
}
