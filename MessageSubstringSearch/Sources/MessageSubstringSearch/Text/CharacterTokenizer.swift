import Foundation

struct TokenizedText {
    let tokens: [String]
    let ranges: [TextRange]
    let sourceBytes: [Range<Int>]
    func encoded(_ bounds: Range<Int>) -> String { tokens[bounds].joined(separator: " ") }
}

enum CharacterTokenizer {
    static let version = "grapheme-nfc-ascii-v1"
    private static let hex = Array("0123456789abcdef".utf8)

    private struct SourceBoundary {
        let normalizedEnd: Int
        let utf8End: Int
        let utf16End: Int
    }

    private static func normalized(_ character: Character, mode: SearchTextMode) -> String {
        if let ascii = character.asciiValue, character != "\r\n" {
            let lowercase = mode != .literal && (65...90).contains(ascii)
            return String(UnicodeScalar(lowercase ? ascii + 32 : ascii))
        }
        let original = String(character)
        if mode == .compatibilityCaseInsensitive {
            return original.precomposedStringWithCompatibilityMapping.lowercased()
        }
        return original.precomposedStringWithCanonicalMapping
    }

    private static func token(_ character: Character, mode: SearchTextMode) -> String {
        // 跨原字符合成的字素也必须与查询得到相同的字节编码。
        let canonical = String(character).precomposedStringWithCanonicalMapping
        var encoded: [UInt8] = [120]
        for raw in canonical.utf8 {
            let byte = mode == .asciiCaseInsensitive && (65...90).contains(raw) ? raw + 32 : raw
            encoded.append(hex[Int(byte >> 4)])
            encoded.append(hex[Int(byte & 15)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func tokenize(_ text: String, mode: SearchTextMode, byteLimit: Int, graphemeByteLimit: Int = 256,
                         check: () throws -> Void = { try Task.checkCancellation() }) throws -> TokenizedText {
        guard text.utf8.count <= byteLimit else { throw SearchIndexError.invalidArgument("text byte limit exceeded") }
        // 先记录原文边界，再按完整规范化字符串划分字素。同时覆盖一个字符展开与多个字符合成。
        var normalizedText = ""
        var boundaries = [SourceBoundary(normalizedEnd: 0, utf8End: 0, utf16End: 0)]
        var byteOffset = 0, utf16Offset = 0, normalizedEnd = 0
        for (position, character) in text.enumerated() {
            if position.isMultiple(of: 128) { try check() }
            let original = String(character)
            guard original.utf8.count <= graphemeByteLimit else { throw SearchIndexError.invalidArgument("grapheme byte limit exceeded") }
            let piece = normalized(character, mode: mode)
            normalizedText += piece
            byteOffset += original.utf8.count
            utf16Offset += original.utf16.count
            normalizedEnd += piece.utf8.count
            boundaries.append(.init(normalizedEnd: normalizedEnd, utf8End: byteOffset, utf16End: utf16Offset))
        }

        var tokens: [String] = [], ranges: [TextRange] = [], sourceBytes: [Range<Int>] = []
        var source = 0, offset = 0
        for (position, character) in normalizedText.enumerated() {
            if position.isMultiple(of: 128) { try check() }
            let count = String(character).utf8.count
            guard count <= graphemeByteLimit else { throw SearchIndexError.invalidArgument("grapheme byte limit exceeded") }
            while boundaries[source + 1].normalizedEnd <= offset { source += 1 }
            let first = boundaries[source]
            offset += count
            while boundaries[source + 1].normalizedEnd < offset { source += 1 }
            let last = boundaries[source + 1]
            tokens.append(token(character, mode: mode))
            ranges.append(TextRange(location: first.utf16End, length: last.utf16End - first.utf16End))
            sourceBytes.append(first.utf8End..<last.utf8End)
        }
        return TokenizedText(tokens: tokens, ranges: ranges, sourceBytes: sourceBytes)
    }

}

/// KMP 的失败表只取决于查询。整页文档共用此值，每个字段单独保存匹配进度。
struct TokenPattern: Sendable {
    let tokens: [String]
    private let failure: [Int]

    init(_ tokens: [String]) {
        self.tokens = tokens
        var table = Array(repeating: 0, count: tokens.count)
        var matched = 0
        for index in tokens.indices.dropFirst() {
            while matched > 0 && tokens[index] != tokens[matched] { matched = table[matched - 1] }
            if tokens[index] == tokens[matched] { matched += 1 }
            table[index] = matched
        }
        failure = table
    }

    func consume(_ token: String, matched: inout Int) -> Bool {
        while matched > 0 && token != tokens[matched] { matched = failure[matched - 1] }
        if token == tokens[matched] { matched += 1 }
        guard matched == tokens.count else { return false }
        matched = failure[matched - 1]
        return true
    }

    func ranges(in text: TokenizedText, check: () throws -> Void) throws -> [TextRange] {
        guard !tokens.isEmpty, text.tokens.count >= tokens.count else { return [] }
        var matched = 0, results: [TextRange] = []
        for i in text.tokens.indices {
            if i.isMultiple(of: 128) { try check() }
            if consume(text.tokens[i], matched: &matched) {
                let first = text.ranges[i - tokens.count + 1], last = text.ranges[i]
                let match = TextRange(location: first.location, length: last.location + last.length - first.location)
                if results.last != match { results.append(match) }
                if results.count == 100 { break }
            }
        }
        return results
    }
}
