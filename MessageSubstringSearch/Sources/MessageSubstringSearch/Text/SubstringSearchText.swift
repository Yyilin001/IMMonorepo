import Foundation

/// 用于嵌入已有事务与 FTS5 表的规范化查询。
public struct SubstringSearchText: Sendable {
    private let pattern: TokenPattern

    public init(_ text: String) throws {
        pattern = try TokenPattern(Self.tokenize(text).tokens)
    }

    private static func tokenize(_ text: some StringProtocol) throws -> TokenizedText {
        try CharacterTokenizer.tokenize(text, mode: .compatibilityCaseInsensitive, byteLimit: .max, graphemeByteLimit: .max)
    }

    public var isEmpty: Bool { pattern.tokens.isEmpty }
    public var encodedPhrase: String { pattern.tokens.joined(separator: " ") }

    /// 写入索引时无需编译查询。
    public static func encodeForIndex(_ text: String) throws -> String {
        try CharacterTokenizer.encodeForIndex(text)
    }

    /// 返回至多 100 个原文 UTF-16 范围，支持重叠命中。
    public func matchingRanges(in text: String) throws -> [NSRange] {
        try pattern.ranges(in: Self.tokenize(text), check: Task.checkCancellation)
            .map { NSRange(location: $0.location, length: $0.length) }
    }

    /// 只收集起点位于首个命中后指定原文字素窗口内的命中，包括跨出窗口的完整匹配。
    public func previewRanges(in text: String, characterCount: Int) throws -> [NSRange] {
        let width = pattern.tokens.count
        guard width > 0, characterCount > 0 else { return [] }
        if text.utf8.count <= characterCount { return try matchingRanges(in: text) }
        var recent = Array(repeating: 0, count: width)
        var matched = 0, position = 0, base = 0
        var results: [NSRange] = [], windowEnd: Int?
        var start = text.startIndex, batch = 160
        while start < text.endIndex {
            try Task.checkCancellation()
            let end = text.index(start, offsetBy: batch, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = try Self.tokenize(text[start..<end])
            var stable = chunk.tokens.count
            if end != text.endIndex {
                // 后文可能与最后一个规范化字素合成。保留它及共享原字符的所有词元。
                stable -= 1
                while stable > 0 && chunk.sourceBytes[stable - 1].upperBound > chunk.sourceBytes[stable].lowerBound {
                    stable -= 1
                }
                if stable == 0 { batch = min(batch, Int.max / 2) * 2; continue }
            }
            for i in 0..<stable {
                let source = chunk.ranges[i]
                recent[position % width] = base + source.location
                position += 1
                let first = recent[position % width]
                if let windowEnd, position >= width, first >= windowEnd { return results }
                if pattern.consume(chunk.tokens[i], matched: &matched) {
                    let range = NSRange(location: first, length: base + source.location + source.length - first)
                    if results.last != range { results.append(range) }
                    if results.count == 100 { return results }
                    if windowEnd == nil {
                        let origin = String.Index(utf16Offset: first, in: text)
                        let limit = text.index(origin, offsetBy: characterCount, limitedBy: text.endIndex) ?? text.endIndex
                        windowEnd = limit.utf16Offset(in: text)
                    }
                }
            }
            if end == text.endIndex { break }
            start = text.utf8.index(start, offsetBy: chunk.sourceBytes[stable].lowerBound)
            base += chunk.ranges[stable].location
            batch = 160
        }
        return results
    }
}
