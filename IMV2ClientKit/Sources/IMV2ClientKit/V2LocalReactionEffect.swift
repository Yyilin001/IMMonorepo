import Crypto
import Foundation
import IMV2Core

/// 本地表情变更效果。
///
/// 房间序号是共享的排序权威；个人同步流的序号与之无关，
/// 绝不能在缺少版本时用个人序号替代。
struct V2LocalReactionEffect {
    /// 来源事件标识。
    let sourceEventID: EventID
    /// 解析出的客户端消息表情。
    let reaction: V2ClientMessageReaction
    /// 表情动作。
    let action: V2MessageReactionAction
    /// 房间日志序号。
    let roomSequence: Int64
    /// 由房间、消息、发起者、表情、动作与序号计算的规范摘要。
    let digest: Data

    /// 从同步记录解析本地表情效果。
    ///
    /// - Parameter record: 表情变更类型的同步记录。
    /// - Throws: 载荷无法解码、房间序号为零或超出 `Int64` 时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord) throws {
        struct Version: Decodable { let room_sequence: UInt64 }
        guard let version = try? JSONDecoder().decode(Version.self, from: record.payload),
              let sequence = Int64(exactly: version.room_sequence), sequence > 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        reaction = try .init(record: record)
        action = try reaction.action(record: record)
        sourceEventID = record.sourceEventID
        roomSequence = sequence
        struct Canonical: Encodable {
            let version = 1
            let room: String; let message: String; let actor: String
            let reaction: String; let action: String; let sequence: Int64
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        digest = Data(SHA256.hash(data: try encoder.encode(Canonical(room: reaction.roomID.rawValue, message: reaction.messageID.rawValue, actor: reaction.actorUserID.rawValue, reaction: reaction.reaction, action: action.rawValue, sequence: sequence))))
    }
}
