import Foundation

/// 可跨客户端传输的消息格式片段，位置和长度均以 UTF-16 代码单元计数。
///
/// 初始化只校验片段形状；必须通过 ``V2RichMessageContent/validate(text:entities:)`` 核对正文中的范围。
/// 合成的 `Codable` 解码不会调用此初始化器，校验入口会重新检查所有字段。
public struct V2MessageEntity: Hashable, Codable, Sendable {
    /// 消息格式类型；具体视觉样式由呈现层决定。
    public enum Kind: String, Codable, Sendable {
        /// 粗体。
        case bold
        /// 斜体。
        case italic
        /// 下划线。
        case underline
        /// 删除线。
        case strikethrough
        /// 剧透内容，具体隐藏与展开行为由呈现层实现。
        case spoiler
        /// 行内代码。
        case code
        /// 预格式化文本。
        case preformatted
        /// 带 HTTP 或 HTTPS 目标地址的链接。
        case link
    }

    /// 片段起点，按正文 UTF-16 代码单元计数，从零开始。
    public let offsetUTF16: Int
    /// 片段覆盖的 UTF-16 代码单元数量，初始化时要求大于零。
    public let lengthUTF16: Int
    /// 片段的格式类型。
    public let kind: Kind
    /// 仅链接片段携带的目标地址；要求 HTTP(S) 协议且存在 host，不在此执行网络访问或目标可达性校验。
    public let linkURL: URL?

    /// 创建片段并检查偏移、长度与链接字段的组合。
    ///
    /// - Parameters:
    ///   - offsetUTF16: 非负 UTF-16 起点。
    ///   - lengthUTF16: 正的 UTF-16 长度。
    ///   - kind: 格式类型。
    ///   - linkURL: 链接类型必须提供 HTTP(S) 且具有 host 的地址，其他类型必须为 `nil`。
    /// - Throws: 字段形状不合法时抛出 ``V2RichMessageContentError/invalidEntity``。
    /// - Note: 此处尚无正文，不能判断范围是否越界，也不计算起点与长度之和。
    public init(offsetUTF16: Int, lengthUTF16: Int, kind: Kind, linkURL: URL? = nil) throws {
        guard offsetUTF16 >= 0, lengthUTF16 > 0 else { throw V2RichMessageContentError.invalidEntity }
        switch kind {
        case .link:
            guard let linkURL,
                  let scheme = linkURL.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  linkURL.host != nil
            else { throw V2RichMessageContentError.invalidEntity }
        default:
            guard linkURL == nil else { throw V2RichMessageContentError.invalidEntity }
        }
        self.offsetUTF16 = offsetUTF16
        self.lengthUTF16 = lengthUTF16
        self.kind = kind
        self.linkURL = linkURL
    }
}

/// 回复所引用的消息标识；引用是否存在、可见以及是否属于当前会话由业务层检查。
public struct V2MessageReplyReference: Hashable, Codable, Sendable {
    /// 被回复消息的稳定标识。
    public let messageID: MessageID

    /// 创建回复引用。
    ///
    /// - Parameter messageID: 被回复消息标识；此处不查询消息存储。
    public init(messageID: MessageID) {
        self.messageID = messageID
    }
}

/// 消息正文与格式片段的纯校验入口，不执行正文长度策略、权限检查或持久化。
public enum V2RichMessageContent {
    /// 每条消息最多允许 100 个格式片段。
    public static let maxEntities = 100

    /// 检查片段数量、唯一性、字段形状与正文范围。
    ///
    /// 空数组直接通过；非空数组最多 100 项，不允许完全相同的片段重复出现。
    /// 重新调用片段初始化器后，以溢出检测计算范围终点，再检查范围能转换为正文中的 Swift 索引，且往返 UTF-16 计数一致。
    /// 允许不同片段重叠，不要求按位置排序，也不在此限制正文为空或正文总长度。
    ///
    /// - Parameters:
    ///   - text: 片段所引用的原始正文；校验过程不会规范化或修改文本。
    ///   - entities: 格式片段列表。
    /// - Throws: 任一片段、范围或列表约束不合法时抛出 ``V2RichMessageContentError/invalidEntity``。
    public static func validate(text: String, entities: [V2MessageEntity]) throws {
        // Plain text is the overwhelmingly common case. No entity can point
        // outside the string when there is no entity, so constructing a Set
        // and traversing UTF-16 would prove nothing further.
        guard !entities.isEmpty else { return }
        guard entities.count <= maxEntities, Set(entities).count == entities.count else {
            throw V2RichMessageContentError.invalidEntity
        }
        let length = text.utf16.count
        for entity in entities {
            // Codable can populate stored properties without using the public
            // initializer. Validate them again before arithmetic or NSRange.
            _ = try V2MessageEntity(
                offsetUTF16: entity.offsetUTF16, lengthUTF16: entity.lengthUTF16,
                kind: entity.kind, linkURL: entity.linkURL
            )
            let (end, overflow) = entity.offsetUTF16.addingReportingOverflow(entity.lengthUTF16)
            guard !overflow, end <= length else { throw V2RichMessageContentError.invalidEntity }
            guard let range = Range(NSRange(location: entity.offsetUTF16, length: entity.lengthUTF16), in: text),
                  text[..<range.lowerBound].utf16.count == entity.offsetUTF16,
                  text[range].utf16.count == entity.lengthUTF16
            else { throw V2RichMessageContentError.invalidEntity }
        }
    }
}

/// 富文本片段校验错误。
public enum V2RichMessageContentError: Error, Equatable, Sendable {
    /// 片段形状、数量、唯一性或正文范围不满足合同。
    case invalidEntity
}
