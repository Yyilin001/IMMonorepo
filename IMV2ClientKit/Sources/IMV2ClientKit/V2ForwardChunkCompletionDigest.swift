import Crypto
import Foundation
import IMV2Core

/// 转发分片完成摘要。
///
/// 只保留不可变的结果元数据；线路上的结果顺序无关紧要，
/// 编码时统一按持久化命令中的来源顺序进行。
enum V2ForwardChunkCompletionDigest {
    /// 由命令与结果计算确认摘要。
    ///
    /// - Parameters:
    ///   - command: 原始转发命令。
    ///   - results: 各来源消息的转发结果。
    /// - Returns: 带版本前缀的十六进制摘要。
    /// - Throws: 结果与命令不匹配或字段组合非法时抛出
    ///   ``V2ClientCommandError/commandConflict``。
    static func acknowledged(command: V2ForwardMessagesCommand, results: [V2ForwardMessageResult]) throws -> String {
        try acknowledged(sourceMessageIDs: command.sourceMessageIDs, targetRoomIDs: command.targetRoomIDs, results: results)
    }

    /// 由来源消息、目标房间与结果计算确认摘要。
    ///
    /// 要求目标房间唯一、结果数量与来源一致、来源集合完全匹配，
    /// 且每条结果要么是「成功且序号可写入 `Int64`」，要么是「仅含非空错误码」。
    ///
    /// - Parameters:
    ///   - sourceMessageIDs: 来源消息标识列表，决定编码顺序。
    ///   - targetRoomIDs: 目标房间列表，必须恰好一个。
    ///   - results: 各来源消息的转发结果。
    /// - Returns: 带版本前缀的十六进制摘要。
    /// - Throws: 任一约束不满足时抛出 ``V2ClientCommandError/commandConflict``。
    static func acknowledged(sourceMessageIDs: [MessageID], targetRoomIDs: [RoomID], results: [V2ForwardMessageResult]) throws -> String {
        guard targetRoomIDs.count == 1,
              results.count == sourceMessageIDs.count,
              Set(results.map(\.sourceMessageID)) == Set(sourceMessageIDs),
              results.allSatisfy({ $0.targetRoomID == targetRoomIDs[0] })
        else { throw V2ClientCommandError.commandConflict }
        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceMessageID, $0) })
        var encoder = Encoder(kind: 0)
        for source in sourceMessageIDs {
            guard let result = bySource[source] else { throw V2ClientCommandError.commandConflict }
            encoder.string(source.rawValue)
            encoder.string(result.targetRoomID.rawValue)
            if let messageID = result.messageID, let sequence = result.roomSequence, result.errorCode == nil {
                guard sequence > 0, sequence <= UInt64(Int64.max) else { throw V2ClientCommandError.commandConflict }
                encoder.data.append(0)
                encoder.string(messageID.rawValue)
                encoder.integer(sequence)
            } else if let code = result.errorCode, result.messageID == nil, result.roomSequence == nil {
                guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
                encoder.data.append(1)
                encoder.string(code)
            } else {
                throw V2ClientCommandError.commandConflict
            }
        }
        return encoder.digest
    }

    /// 计算「整体被拒绝」的摘要。
    ///
    /// - Parameter code: 稳定错误码。
    /// - Returns: 带版本前缀的十六进制摘要。
    static func rejected(code: String) -> String {
        var encoder = Encoder(kind: 1)
        encoder.string(code)
        return encoder.digest
    }

    /// 长度前缀编码器，用于生成稳定的规范摘要输入。
    private struct Encoder {
        /// 累积的规范字节。
        var data = Data("im-v2-forward-chunk-completion-v1".utf8)

        /// 以摘要类别初始化编码器。
        ///
        /// - Parameter kind: 摘要类别（确认或拒绝）。
        init(kind: UInt8) { data.append(kind) }

        /// 以大端无符号整数追加编码。
        ///
        /// - Parameter value: 待编码整数。
        mutating func integer(_ value: UInt64) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        /// 以长度前缀追加字符串。
        ///
        /// - Parameter value: 待编码字符串。
        mutating func string(_ value: String) {
            let bytes = Data(value.utf8)
            integer(UInt64(bytes.count))
            data.append(bytes)
        }
        /// 当前内容对应的带版本摘要。
        var digest: String { "v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
}
