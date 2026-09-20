import Foundation
import IMV2Core

/// 精简的群身份信息与本设备观察到的最新成员修订。
///
/// 个人发现事件只保存房间身份，不把完整成员名册复制进个人同步历史。
public struct V2ClientRoomProfileProjection: Equatable, Sendable {
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 目标房间。
    public let roomID: RoomID
    /// 房间标题，已去除首尾空白。
    public let title: String
    /// 群主用户。
    public let ownerUserID: UserID
    /// 房间容量等级。
    public let capacityClass: V2GroupCapacityClass

    /// 成员修订。
    public let membershipRevision: UInt64
    /// 房间创建时刻。
    public let createdAt: Date

    /// 保存房间资料投影。
    ///
    /// - Parameters:
    ///   - sourceEventID: 来源事件标识。
    ///   - roomID: 目标房间。
    ///   - title: 房间标题。
    ///   - ownerUserID: 群主用户。
    ///   - capacityClass: 群容量等级。
    ///   - membershipRevision: 成员修订。
    ///   - createdAt: 房间创建时刻。
    init(
        sourceEventID: EventID, roomID: RoomID, title: String,
        ownerUserID: UserID, capacityClass: V2GroupCapacityClass,

        membershipRevision: UInt64, createdAt: Date
    ) {
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.title = title
        self.ownerUserID = ownerUserID
        self.capacityClass = capacityClass
        self.membershipRevision = membershipRevision
        self.createdAt = createdAt
    }

    /// 从同步记录解码房间资料投影。
    ///
    /// 仅接受房间创建或成员变更事件，并要求标题非空、不含控制字符且不超过命令上限，
    /// 成员修订大于零、创建时刻不早于 Unix 纪元。
    ///
    /// - Parameter record: 房间或成员类同步记录。
    /// - Throws: 载荷无法解码、事件类型不符或字段越界时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let title: String
            let ownerUserID: String
            let membershipRevision: UInt64
            let capacityClass: String
            // 权威副本形态是服务端宣告的必需字段：项目未上线，不保留"缺字段就按投递模式
            // 推断"的静默回退，缺失或未知值一律按不可解码处理。

            let createdAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"; case roomID = "room_id"; case title
                case ownerUserID = "owner_user_id"; case membershipRevision = "membership_revision"; case capacityClass = "capacity_class"; case createdAtMilliseconds = "created_at_ms"
            }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        let normalizedTitle = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (record.projectionKind == "room" && payload.eventType == "room.created")
                || (record.projectionKind == "membership" && payload.eventType == "membership_changed"),
              !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              payload.membershipRevision > 0,
              payload.createdAtMilliseconds >= 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            sourceEventID = record.sourceEventID
            roomID = try .init(payload.roomID)
            title = normalizedTitle
            ownerUserID = try .init(payload.ownerUserID)
            guard let mode = V2GroupCapacityClass(rawValue: payload.capacityClass) else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
            capacityClass = mode
            membershipRevision = payload.membershipRevision
            createdAt = Date(timeIntervalSince1970: TimeInterval(payload.createdAtMilliseconds) / 1_000)
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
