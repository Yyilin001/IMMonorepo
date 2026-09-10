import Foundation
import IMV2Core

/// 客户端可见的当前房间控制状态。
///
/// 安全服务的审计原因刻意不会跨越该边界。
public struct V2ClientRoomControlProjection: Equatable, Sendable {
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 目标房间。
    public let roomID: RoomID
    /// 事件在房间日志中的序号。
    public let roomSequence: UInt64
    /// 发起控制的用户。
    public let actorUserID: UserID
    /// 房间当前是否被冻结。
    public let isFrozen: Bool
    /// 事件创建时刻。
    public let createdAt: Date

    /// 校验并保存房间控制投影。
    ///
    /// - Parameters:
    ///   - sourceEventID: 来源事件标识。
    ///   - roomID: 目标房间。
    ///   - roomSequence: 房间序号，需大于零。
    ///   - actorUserID: 发起控制的用户。
    ///   - isFrozen: 是否被冻结。
    ///   - createdAt: 事件创建时刻，需不早于 Unix 纪元。
    /// - Throws: 序号为零或时刻早于纪元时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(sourceEventID: EventID, roomID: RoomID, roomSequence: UInt64, actorUserID: UserID, isFrozen: Bool, createdAt: Date) throws {
        guard roomSequence > 0, createdAt.timeIntervalSince1970 >= 0 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.actorUserID = actorUserID
        self.isFrozen = isFrozen
        self.createdAt = createdAt
    }

    /// 从同步记录解码房间控制投影。
    ///
    /// - Parameter record: 投影类型为审核的同步记录。
    /// - Throws: 载荷无法解码、事件类型不受支持或字段越界时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let roomSequence: UInt64
            let actorUserID: String
            let serverCreatedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
                case roomID = "room_id"
                case roomSequence = "room_sequence"
                case actorUserID = "actor_user_id"
                case serverCreatedAtMilliseconds = "server_created_at_ms"
            }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard record.projectionKind == "moderation",
              payload.eventType == "room.frozen" || payload.eventType == "room.unfrozen",
              payload.roomSequence > 0, payload.serverCreatedAtMilliseconds >= 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            try self.init(sourceEventID: record.sourceEventID, roomID: .init(payload.roomID), roomSequence: payload.roomSequence, actorUserID: .init(payload.actorUserID), isFrozen: payload.eventType == "room.frozen", createdAt: Date(timeIntervalSince1970: TimeInterval(payload.serverCreatedAtMilliseconds) / 1_000))
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}
