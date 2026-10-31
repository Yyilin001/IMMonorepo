import Crypto
import Foundation
import IMV2Core

/// 本地置顶消息变更效果。
///
/// 置顶顺序来自房间日志外层；正文携带序号时必须与外层一致。
struct V2LocalPinnedMessageEffect {
    /// 来源事件标识。
    let sourceEventID: EventID
    /// 目标房间。
    let roomID: RoomID
    /// 被置顶或取消置顶的消息。
    let messageID: MessageID
    /// 变更后的置顶状态。
    let isPinned: Bool
    /// 服务端事件时间戳（毫秒）。
    let updatedAtMilliseconds: Int64
    /// 已验证的来源房间序号。
    let roomSequence: Int64
    /// 由房间、消息、置顶状态、更新时间与发起者计算的规范摘要。
    let digest: Data

    /// 从同步记录解码置顶效果。
    ///
    /// 给出期望房间序号时，该序号会覆盖载荷中缺失的序号；
    /// 载荷自带序号时必须与期望值一致。
    ///
    /// - Parameters:
    ///   - record: 置顶变更类型的同步记录。
    ///   - expectedRoomSequence: 期望的房间序号。
    ///   - expectedRoomID: 期望的房间。
    /// - Throws: 载荷无法解码、事件类型不符、字段越界，或与期望值不一致时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord, expectedRoomSequence: UInt64? = nil, expectedRoomID: RoomID? = nil) throws {
        struct Wire: Decodable {
            let event_type: String; let room_id: String; let message_id: String
            let is_pinned: Bool; let server_created_at_ms: Int64
            let actor_user_id: String?; let room_sequence: Int64?
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
            guard record.projectionKind == "group_capability",
                  wire.event_type == "message.pinned_changed",
                  UUID(uuidString: wire.message_id) != nil,
                  UUID(uuidString: wire.room_id) != nil,
                  wire.actor_user_id.map({ UUID(uuidString: $0) != nil }) ?? true,
                  wire.server_created_at_ms >= 0,
                  wire.room_sequence.map({ $0 > 0 }) ?? true
            else { throw V2ClientProjectionError.invalidMessagePayload }
            if let expectedRoomSequence, let sequence = wire.room_sequence {
                guard UInt64(sequence) == expectedRoomSequence else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            sourceEventID = record.sourceEventID
            roomID = try .init(wire.room_id)
            guard expectedRoomID == nil || expectedRoomID == roomID else { throw V2ClientProjectionError.invalidMessagePayload }
            messageID = try .init(wire.message_id)
            isPinned = wire.is_pinned
            updatedAtMilliseconds = wire.server_created_at_ms
            if let expectedRoomSequence {
                guard expectedRoomSequence > 0, let source = Int64(exactly: expectedRoomSequence) else { throw V2ClientProjectionError.invalidMessagePayload }
                roomSequence = source
            } else {
                guard let sequence = wire.room_sequence else { throw V2ClientProjectionError.invalidMessagePayload }
                roomSequence = sequence
            }
            struct Canonical: Encodable {
                let version = 1
                let room: String; let message: String; let isPinned: Bool
                let updatedAt: Int64; let actor: String?
            }
            let actor = try wire.actor_user_id.map(UserID.init)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            digest = Data(SHA256.hash(data: try encoder.encode(Canonical(
                room: roomID.rawValue, message: messageID.rawValue, isPinned: isPinned,
                updatedAt: updatedAtMilliseconds, actor: actor?.rawValue
            ))))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
