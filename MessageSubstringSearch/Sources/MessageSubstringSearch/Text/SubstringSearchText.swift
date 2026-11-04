import Foundation

/// 嵌入已有事务与 FTS5 表时使用的文本接口。索引和查询必须使用同一规范化规则。
public struct SubstringSearchText: Sendable {
    private let tokenized: TokenizedText

    public init(_ text: String) throws {
        tokenized = try CharacterTokenizer.tokenize(text, mode: .compatibilityCaseInsensitive,
                                                    byteLimit: .max, graphemeByteLimit: .max)
    }

    public var isEmpty: Bool { tokenized.tokens.isEmpty }

    /// 可直接写入 ASCII tokenizer 列，或放入 MATCH 的双引号短语。
    public var encodedPhrase: String { tokenized.encoded(tokenized.tokens.indices) }

    /// 返回至多 100 个原文 UTF-16 范围，支持重叠命中。
    public func matchingRanges(in text: String) throws -> [NSRange] {
        let document = try SubstringSearchText(text)
        return try CharacterTokenizer.matchingRanges(in: document.tokenized, query: tokenized.tokens,
                                                     check: Task.checkCancellation)
            .map { NSRange(location: $0.location, length: $0.length) }
    }
}
