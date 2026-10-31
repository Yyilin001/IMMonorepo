import Foundation
import IMV2Core

/// 通过房间日志收到的不可变、隐私安全的审核事实。
///
/// 它只携带标识与一个有界动作：举报文本与审计原因保留在受保护的服务端审计存储中。
public struct V2ClientModerationProjection: Equatable, Sendable {
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 目标房间。
    public let roomID: RoomID
    /// 事件在房间日志中的序号。
    public let roomSequence: UInt64
    /// 发起审核的用户。
    public let actorUserID: UserID
    /// 被禁言的成员。
    public let targetUserID: UserID
    /// 禁言到期时刻。
    public let muteUntil: Date
    /// 事件创建时刻。
    public let createdAt: Date

    /// 校验并保存审核投影。
    ///
    /// SQLite 已经保存了投影后的时刻，这里不再构造合成线路载荷：
    /// 再次转换会对较大时间戳引入二次舍入，并可能把合法的最大 `Int64` 时间戳变成溢出的 `Double`。
    ///
    /// - Parameters:
    ///   - sourceEventID: 来源事件标识。
    ///   - roomID: 目标房间。
    ///   - roomSequence: 房间序号，需大于零。
    ///   - actorUserID: 发起审核的用户。
    ///   - targetUserID: 被禁言的成员。
    ///   - muteUntil: 禁言到期时刻，需晚于创建时刻且不超过可表示的毫秒上界。
    ///   - createdAt: 事件创建时刻，需不早于 Unix 纪元。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(sourceEventID: EventID, roomID: RoomID, roomSequence: UInt64,
         actorUserID: UserID, targetUserID: UserID, muteUntil: Date, createdAt: Date) throws {
        let upperBound = Double(Int64.max) / 1_000
        guard roomSequence > 0,
              muteUntil.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970 >= 0,
              muteUntil.timeIntervalSince1970 <= upperBound,
              muteUntil > createdAt
        else { throw V2ClientProjectionError.invalidMessagePayload }
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.muteUntil = muteUntil
        self.createdAt = createdAt
    }

    /// 从同步记录解码成员禁言投影。
    ///
    /// - Parameter record: 投影类型为审核的同步记录。
    /// - Throws: 载荷无法解码、事件类型不符或时间戳关系异常时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let roomSequence: UInt64
            let actorUserID: String
            let targetUserID: String
            let muteUntilMilliseconds: Int64
            let serverCreatedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
                case roomID = "room_id"
                case roomSequence = "room_sequence"
                case actorUserID = "actor_user_id"
                case targetUserID = "target_user_id"
                case muteUntilMilliseconds = "mute_until_ms"
                case serverCreatedAtMilliseconds = "server_created_at_ms"
            }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard record.projectionKind == "moderation", payload.eventType == "member.muted",
              payload.roomSequence > 0, payload.muteUntilMilliseconds > payload.serverCreatedAtMilliseconds,
              payload.serverCreatedAtMilliseconds >= 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            sourceEventID = record.sourceEventID
            roomID = try .init(payload.roomID)
            roomSequence = payload.roomSequence
            actorUserID = try .init(payload.actorUserID)
            targetUserID = try .init(payload.targetUserID)
            muteUntil = Date(timeIntervalSince1970: TimeInterval(payload.muteUntilMilliseconds) / 1_000)
            createdAt = Date(timeIntervalSince1970: TimeInterval(payload.serverCreatedAtMilliseconds) / 1_000)
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}
