import Foundation
import IMV2Core

/// 可搜索范围。
///
/// 刻意使用领域标识表达，使调用方无法在存储边界上把房间标识与用户标识混用。
public enum V2MessageSearchScope: Equatable, Sendable {
    /// 限定在单个房间内。
    case room(RoomID)
    /// 覆盖全部消息。
    case allMessages
    /// 限定在单个发送者。
    case sender(UserID)
}

/// 已建立索引的本地内容筛选条件。
///
/// 它描述的是接受消息时记录的展示类型，而不是发送方提供的文件名或 MIME 字符串。
public enum V2MessageSearchContentFilter: String, CaseIterable, Equatable, Sendable {
    /// 不筛选内容类型。
    case all
    /// 含附件的消息。
    case media
    /// 图片消息。
    case image
    /// 视频消息。
    case video
    /// 文件消息。
    case file
    /// 语音消息。
    case audio
}

/// 消息搜索游标。
public struct V2MessageSearchCursor: Equatable, Sendable {
    /// 游标在存储层的具体形态。
    enum Storage: Equatable, Sendable {
        /// 房间内按房间序号与消息标识续页。
        case room(roomID: RoomID, roomSequence: UInt64, messageID: MessageID)
        /// 全局按创建时刻与消息标识续页。
        case global(createdAt: Date, messageID: MessageID)
    }

    /// 存储层游标。
    let storage: Storage
    /// 筛选条件指纹。
    ///
    /// 续页只在筛选集合完全一致时有效，否则用户切换成员或媒体类别后，
    /// 客户端可能静默跳过或重复记录。
    let filterFingerprint: String
}

/// 消息搜索请求。
public struct V2MessageSearchRequest: Equatable, Sendable {
    /// 查询文本。
    public let query: String
    /// 搜索范围。
    public let scope: V2MessageSearchScope
    /// 内容类型筛选。
    public let contentFilter: V2MessageSearchContentFilter
    /// 可选的发送者筛选；可与房间范围叠加使用。
    public let senderUserID: UserID?
    /// 本页最多返回的条数。
    public let limit: Int
    /// 上一页游标。
    public let cursor: V2MessageSearchCursor?

    /// 保存搜索请求。
    ///
    /// - Parameters:
    ///   - query: 查询文本。
    ///   - scope: 搜索范围，默认全部消息。
    ///   - contentFilter: 内容类型筛选，默认不筛选。
    ///   - senderUserID: 发送者筛选。
    ///   - limit: 本页条数，默认 50。
    ///   - cursor: 上一页游标。
    public init(
        query: String,
        scope: V2MessageSearchScope = .allMessages,
        contentFilter: V2MessageSearchContentFilter = .all,
        senderUserID: UserID? = nil,
        limit: Int = 50,
        cursor: V2MessageSearchCursor? = nil
    ) {
        self.query = query
        self.scope = scope
        self.contentFilter = contentFilter
        self.senderUserID = senderUserID
        self.limit = limit
        self.cursor = cursor
    }
}

/// 单条搜索命中。
public struct V2MessageSearchHit: Equatable, Sendable, Identifiable {
    /// 消息标识。
    public let messageID: MessageID
    /// 所属房间。
    public let roomID: RoomID
    /// 房间日志序号。
    public let roomSequence: UInt64
    /// 发送者。
    public let senderUserID: UserID
    /// 命中正文。
    public let text: String
    /// 消息创建时刻。
    public let createdAt: Date

    /// 用于列表标识。
    public var id: MessageID { messageID }

    /// 保存搜索命中。
    ///
    /// - Parameters:
    ///   - messageID: 消息标识。
    ///   - roomID: 所属房间。
    ///   - roomSequence: 房间日志序号。
    ///   - senderUserID: 发送者。
    ///   - text: 命中正文。
    ///   - createdAt: 消息创建时刻。
    public init(
        messageID: MessageID,
        roomID: RoomID,
        roomSequence: UInt64,
        senderUserID: UserID,
        text: String,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.senderUserID = senderUserID
        self.text = text
        self.createdAt = createdAt
    }
}

/// 搜索结果分页。
public struct V2MessageSearchPage: Equatable, Sendable {
    /// 本页命中。
    public let hits: [V2MessageSearchHit]
    /// 下一页游标；为空表示已到末尾。
    public let nextCursor: V2MessageSearchCursor?

    /// 保存搜索结果分页。
    ///
    /// - Parameters:
    ///   - hits: 本页命中。
    ///   - nextCursor: 下一页游标。
    public init(hits: [V2MessageSearchHit], nextCursor: V2MessageSearchCursor?) {
        self.hits = hits
        self.nextCursor = nextCursor
    }
}

/// 搜索索引的构建状态。
public enum V2MessageSearchIndexState: Equatable, Sendable {
    /// 正在构建，尚无可用的完整代次。
    case building
    /// 已就绪。
    case ready
    /// 构建失败。
    case failed

    /// 由持久化取值解析状态。
    ///
    /// - Parameter storageValue: 持久化字符串。
    init?(storageValue: String) {
        switch storageValue {
        case "building": self = .building
        case "ready": self = .ready
        case "failed": self = .failed
        default: return nil
        }
    }
}

/// 搜索索引的观测快照。
///
/// 该观测区域刻意不含消息正文或积压计数；新一代次会使既有分页游标失效。
public struct V2MessageSearchIndexSnapshot: Equatable, Sendable {
    /// 当前状态。
    public let state: V2MessageSearchIndexState
    /// 索引代次。
    public let generation: UInt64
    /// 索引结构版本。
    public let indexVersion: Int

    /// 保存观测快照。
    ///
    /// - Parameters:
    ///   - state: 当前状态。
    ///   - generation: 索引代次。
    ///   - indexVersion: 索引结构版本。
    public init(state: V2MessageSearchIndexState, generation: UInt64, indexVersion: Int) {
        self.state = state
        self.generation = generation
        self.indexVersion = indexVersion
    }
}

/// 搜索索引的构建进度。
///
/// 在报告存在积压时，界面仍可继续展示已校验的历史命中。
/// `building` 表示尚无完整代次可用；`isCatchingUp` 仅表示最近接受或编辑的消息
/// 可能尚未进入索引。
public struct V2MessageSearchIndexProgress: Equatable, Sendable {
    /// 当前状态。
    public let state: V2MessageSearchIndexState
    /// 待处理任务数。
    public let pendingJobCount: Int

    /// 保存构建进度。
    ///
    /// - Parameters:
    ///   - state: 当前状态。
    ///   - pendingJobCount: 待处理任务数。
    public init(state: V2MessageSearchIndexState, pendingJobCount: Int) {
        self.state = state
        self.pendingJobCount = pendingJobCount
    }

    /// 是否处于追赶状态。
    public var isCatchingUp: Bool { state == .ready && pendingJobCount > 0 }
}

/// 消息搜索错误。
public enum V2MessageSearchError: Error, Equatable, Sendable {
    /// 查询文本为空。
    case emptyQuery
    /// 分页条数越界。
    case invalidPageSize
    /// 索引当前不可用，附带其状态。
    case indexUnavailable(V2MessageSearchIndexState)
    /// 游标与本次搜索范围或筛选不匹配。
    case cursorDoesNotMatchScope
}

/// 字符级分词器。
///
/// 搜索语义在此显式定义，而不依赖 SQLite 分词器的偶然特性；
/// 字节编码让每个扩展字形簇（含标点与表情）都成为安全的全文本检索词元。
struct V2CharacterGramTokenizer: Sendable {
    /// 分词方案版本，索引结构变更时同步递增。
    static let version = 1

    /// 一次分词的结果。
    struct Tokens: Equatable, Sendable {
        /// 规范化后的文本。
        let normalized: String
        /// 单字符词元。
        let unigrams: [String]
        /// 相邻双字符词元。
        let bigrams: [String]

        /// 字符数，等于单字符词元数量。
        var characterCount: Int { unigrams.count }
    }

    /// 对输入文本分词。
    ///
    /// - Parameter input: 原始文本。
    /// - Returns: 规范化文本、单字符与双字符词元。
    func tokenize(_ input: String) -> Tokens {
        let normalized = Self.normalize(input)
        let characters = Array(normalized)
        let unigrams = characters.map { Self.token(prefix: "u1", text: String($0)) }
        let bigrams = zip(characters, characters.dropFirst()).map {
            Self.token(prefix: "u2", text: String($0.0) + String($0.1))
        }
        return .init(normalized: normalized, unigrams: unigrams, bigrams: bigrams)
    }

    /// 规范化输入：兼容分解后重新组合并转为小写。
    ///
    /// - Parameter input: 原始文本。
    /// - Returns: 规范化文本。
    static func normalize(_ input: String) -> String {
        input.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// 生成范围或标识对应的词元。
    ///
    /// - Parameters:
    ///   - prefix: 词元前缀，用于区分作用域。
    ///   - identifier: 标识内容。
    /// - Returns: 编码后的词元。
    static func scopeToken(prefix: String, identifier: String) -> String {
        token(prefix: prefix, text: identifier)
    }

    /// 以前缀与十六进制编码生成词元。
    ///
    /// - Parameters:
    ///   - prefix: 词元前缀。
    ///   - text: 词元原文。
    /// - Returns: 编码后的词元。
    private static func token(prefix: String, text: String) -> String {
        prefix + hex(text.utf8)
    }

    /// 把字节序列编码为小写十六进制字符串。
    ///
    /// - Parameter bytes: 待编码字节。
    /// - Returns: 十六进制字符串。
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
