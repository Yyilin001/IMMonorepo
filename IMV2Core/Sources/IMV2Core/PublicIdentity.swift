import Foundation

/// 服务端控制的账户展示类别，不是授权凭证。
///
/// 客户端可以据此展示身份，特殊发送权限仍由服务端专用账户注册表决定，不能仅凭客户端传入的类别授予。
public enum V2AccountKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// 普通账户。
    case regular
    /// 系统账户展示类别。
    case system
    /// 客服账户，协议原始值为 customer_support。
    case customerSupport = "customer_support"
}

/// 用户选择的公开账号标识，与登录账户名及认证凭证分离。
///
/// 普通构造入口允许一个前导 @ 并转为小写；持久化与协议应使用规范 rawValue。
/// Codable 为自动合成实现，解码不会调用普通构造器进行规范化校验，调用边界需区分来源。
public struct V2PublicHandle: Hashable, Codable, Sendable, CustomStringConvertible {
    /// 不含展示用 @ 前缀的公开标识；普通构造器保证为规范小写形式。
    public let rawValue: String

    /// 移除至多一个开头的 @，转小写后校验公开标识。
    ///
    /// - Parameter value: 用户输入的公开账号标识，不自动裁剪首尾空白。
    /// - Throws: 规范化后不为 3 到 32 个 ASCII 小写字母、数字或下划线时抛出 invalidHandle。
    ///
    /// 不允许连字符、空格或额外 @；此格式与密码登录账户名的格式不同。
    public init(_ value: String) throws {
        let withoutPrefix = value.first == "@" ? String(value.dropFirst()) : value
        let canonical = withoutPrefix.lowercased()
        let scalars = canonical.unicodeScalars
        guard (3 ... 32).contains(scalars.count), scalars.allSatisfy({ scalar in
            (48 ... 57).contains(scalar.value) ||
            (97 ... 122).contains(scalar.value) ||
            scalar == "_"
        }) else {
            throw V2PublicIdentityValidationError.invalidHandle
        }
        rawValue = canonical
    }

    /// 在保存的 rawValue 前加 @，用于公开展示。
    public var description: String { "@\(rawValue)" }
}

/// 允许离开认证边界的公开身份事实，只包含用户标识、公开标识、显示名与账户类别。
///
/// 不携带登录账户名、密码、Passkey、手机号或邮箱。该值不证明当前调用者有权限执行账户操作。
public struct V2PublicIdentity: Codable, Equatable, Sendable {
    /// 领域用户标识，区别于可展示的公开账号标识。
    public let userID: UserID
    /// 公开账号标识，构造本身份时直接使用传入值，不再次校验其 rawValue。
    public let handle: V2PublicHandle
    /// 经规范组合与首尾空白处理后的显示名，最多 80 个 UTF-8 字节。
    public let displayName: String
    /// 服务端提供的账户展示类别。
    public let accountKind: V2AccountKind

    /// 构造公开身份并规范化显示名。
    ///
    /// - Parameters:
    ///   - userID: 目标用户身份。
    ///   - handle: 已准备好的公开标识，本构造器不重复验证其内部字符串。
    ///   - displayName: 原始显示名，先做 Unicode 规范组合，再移除首尾空白与换行。
    ///   - accountKind: 账户展示类别，不在此授予权限。
    /// - Throws: 处理后为空、超过 80 个 UTF-8 字节、包含控制字符，或包含普通空格以外的空白字符时抛出 invalidDisplayName。
    ///
    /// 长度按字节而非显示字符计数；内部普通空格保留。
    public init(
        userID: UserID,
        handle: V2PublicHandle,
        displayName: String,
        accountKind: V2AccountKind
    ) throws {
        let normalizedName = displayName.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= 80,
              normalizedName.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && (!$0.properties.isWhitespace || $0 == " ")
              })
        else { throw V2PublicIdentityValidationError.invalidDisplayName }
        self.userID = userID
        self.handle = handle
        self.displayName = normalizedName
        self.accountKind = accountKind
    }

    /// 公开身份编码键，使用 userID、handle、displayName 和 accountKind。
    private enum CodingKeys: String, CodingKey {
        case userID
        case handle
        case displayName
        case accountKind
    }

    /// 解码四个必需字段并调用公开身份构造器，重新校验和规范化显示名。
    ///
    /// - Throws: 字段解码错误或显示名校验错误。
    ///
    /// handle 使用 V2PublicHandle 的合成解码，不在此重新执行其字符串构造校验。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            userID: container.decode(UserID.self, forKey: .userID),
            handle: container.decode(V2PublicHandle.self, forKey: .handle),
            displayName: container.decode(String.self, forKey: .displayName),
            accountKind: try container.decode(V2AccountKind.self, forKey: .accountKind)
        )
    }

    /// 按固定键编码公开身份，handle 使用其自身 Codable 表示，不替换为带 @ 的展示文本。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userID, forKey: .userID)
        try container.encode(handle, forKey: .handle)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(accountKind, forKey: .accountKind)
    }
}

/// 公开身份输入的领域校验错误。
public enum V2PublicIdentityValidationError: Error, Equatable, Sendable {
    /// 公开标识规范化后的长度或字符集不符合要求。
    case invalidHandle
    /// 显示名规范化后的字节长度、控制字符或空白字符不符合要求。
    case invalidDisplayName
}
