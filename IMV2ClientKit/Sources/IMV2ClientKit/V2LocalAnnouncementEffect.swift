import Crypto
import Foundation
import IMV2Core

/// 本地公告变更效果。
///
/// 公告修订负责为自身取值排序；历史载荷可能合理地缺少来源房间序号，
/// 接收端游标无法补上该字段。
struct V2LocalAnnouncementEffect {
    /// 来源事件标识。
    let sourceEventID: EventID
    /// 目标房间。
    let roomID: RoomID
    /// 公告修订。
    let revision: Int64
    /// 公告正文。
    let body: String
    /// 服务端事件时间戳（毫秒）。
    let updatedAtMilliseconds: Int64
    /// 来源房间序号；历史载荷可能缺失。
    let roomSequence: Int64?
    /// 由房间、修订、正文、更新时间与发起者计算的规范摘要。
    let digest: Data

    /// 从同步记录解码公告效果。
    ///
    /// - Parameters:
    ///   - record: 公告变更类型的同步记录。
    ///   - expectedRoomSequence: 期望的房间序号；给出且载荷含序号时必须一致。
    ///   - expectedRoomID: 期望的房间；给出时必须与载荷一致。
    /// - Throws: 载荷无法解码、事件类型不符、修订或时间戳越界、正文超长，
    ///   或与期望值不一致时抛出 ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord, expectedRoomSequence: UInt64? = nil, expectedRoomID: RoomID? = nil) throws {
        struct Wire: Decodable {
            let event_type: String; let room_id: String; let revision: Int64
            let body: String; let server_created_at_ms: Int64
            let actor_user_id: String?; let room_sequence: Int64?
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
            guard record.projectionKind == "group_capability",
                  wire.event_type == "group.announcement_changed", wire.revision > 0,
                  UUID(uuidString: wire.room_id) != nil,
                  wire.actor_user_id.map({ UUID(uuidString: $0) != nil }) ?? true,
                  wire.server_created_at_ms >= 0,
                  wire.body.utf8.count <= V2GroupAnnouncementCommand.maximumUTF8Bytes,
                  wire.room_sequence.map({ $0 > 0 }) ?? true
            else { throw V2ClientProjectionError.invalidMessagePayload }
            if let expectedRoomSequence, let sequence = wire.room_sequence {
                guard UInt64(sequence) == expectedRoomSequence else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            sourceEventID = record.sourceEventID
            roomID = try .init(wire.room_id)
            guard expectedRoomID == nil || expectedRoomID == roomID else { throw V2ClientProjectionError.invalidMessagePayload }
            revision = wire.revision
            body = wire.body
            updatedAtMilliseconds = wire.server_created_at_ms
            roomSequence = wire.room_sequence
            struct Canonical: Encodable {
                let version = 1
                let room: String; let revision: Int64; let body: String
                let updatedAt: Int64; let actor: String?
            }
            let actor = try wire.actor_user_id.map(UserID.init)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            digest = Data(SHA256.hash(data: try encoder.encode(Canonical(
                room: roomID.rawValue, revision: revision, body: body,
                updatedAt: updatedAtMilliseconds, actor: actor?.rawValue
            ))))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
