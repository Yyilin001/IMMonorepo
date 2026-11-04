import Foundation

/// 联系人展示名和账号名索引使用的字符分词器。
///
/// 搜索语义在此显式定义，而不依赖 SQLite 分词器的偶然特性；
/// 字节编码让每个扩展字形簇（含标点与表情）都成为安全的全文本检索词元。
struct V2ContactSearchTokenizer: Sendable {
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
        let unigrams = characters.map { v2SearchToken(prefix: "u1", text: String($0)) }
        let bigrams = zip(characters, characters.dropFirst()).map {
            v2SearchToken(prefix: "u2", text: String($0.0) + String($0.1))
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
}

/// 将任意 UTF-8 文本编码成单个安全的 SQLite FTS ASCII 词元。
func v2SearchToken(prefix: String, text: String) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var encoded = Array(prefix.utf8)
    encoded.reserveCapacity(encoded.count + text.utf8.count * 2)
    for byte in text.utf8 {
        encoded.append(digits[Int(byte >> 4)])
        encoded.append(digits[Int(byte & 15)])
    }
    return String(decoding: encoded, as: UTF8.self)
}
