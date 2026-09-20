import Foundation
import IMV2Core

/// 持久化且仅对该查看者可见的时间线条目。
///
/// 它刻意不是消息：无法被回复、发送已读回执、编辑、加表情或转发。
/// 服务端在此只保存产品层面安全的展示原因码。
public struct V2ClientTimelineActivityProjection: Equatable, Sendable, Identifiable {
    /// 条目种类。
    public enum Kind: String, Equatable, Sendable {
        /// 私聊消息受限。
        case directMessageRestricted = "direct_message_restricted"
        /// 系统账号只读。
        case systemAccountReadOnly = "system_account_read_only"
    }

    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 目标房间。
    public let roomID: RoomID
    /// 时间线序号。
    public let timelineSequence: UInt64
    /// 条目种类。
    public let kind: Kind
    /// 事件创建时刻。
    public let createdAt: Date

    /// 用于列表标识。
    public var id: String { sourceEventID.rawValue }

    /// 保存时间线条目。
    ///
    /// - Parameters:
    ///   - sourceEventID: 来源事件标识。
    ///   - roomID: 目标房间。
    ///   - timelineSequence: 时间线序号，需大于零。
    ///   - kind: 条目种类。
    ///   - createdAt: 事件创建时刻。
    ///
    /// 序号非正时直接失败，避免产生无效的时间线位置。
    public init(sourceEventID: EventID, roomID: RoomID, timelineSequence: UInt64, kind: Kind, createdAt: Date) {
        precondition(timelineSequence > 0)
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.timelineSequence = timelineSequence
        self.kind = kind
        self.createdAt = createdAt
    }

    /// 从同步记录解码时间线条目。
    ///
    /// - Parameter record: 投影类型为时间线活动的同步记录。
    /// - Throws: 载荷无法解码、序号为零、时间戳为负或种类未知时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let timelineSequence: UInt64
            let serverCreatedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
                case roomID = "room_id"
                case timelineSequence = "timeline_sequence"
                case serverCreatedAtMilliseconds = "server_created_at_ms"
            }
        }
        guard record.projectionKind == "timeline_activity",
              let wire = try? JSONDecoder().decode(Wire.self, from: record.payload),
              wire.timelineSequence > 0,
              wire.serverCreatedAtMilliseconds >= 0,
              let kind = Kind(rawValue: wire.eventType)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            self.init(
                sourceEventID: record.sourceEventID,
                roomID: try .init(wire.roomID),
                timelineSequence: wire.timelineSequence,
                kind: kind,
                createdAt: Date(timeIntervalSince1970: TimeInterval(wire.serverCreatedAtMilliseconds) / 1_000)
            )
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}

/// 由服务端裁决的发送能力。
///
/// 它是私有投影，因此不会泄漏对端是否拉黑或对端的隐私配置。
public struct V2ClientDirectSendingCapability: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 当前是否允许发送。
    public let canSend: Bool
    /// 产生本状态的房间时间线序号，用于异步乱序收敛。
    public let stateVersion: UInt64
    /// 最近更新时刻。
    public let updatedAt: Date

    /// 保存发送能力。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - canSend: 是否允许发送。
    ///   - stateVersion: 产生此状态的正整数房间时间线序号。
    ///   - updatedAt: 最近更新时刻。
    public init(roomID: RoomID, canSend: Bool, stateVersion: UInt64, updatedAt: Date) {
        self.roomID = roomID
        self.canSend = canSend
        self.stateVersion = stateVersion
        self.updatedAt = updatedAt
    }

    /// 从同步记录解码发送能力。
    ///
    /// - Parameter record: 投影类型为私聊发送能力的同步记录。
    /// - Throws: 载荷无法解码、时间戳为负或房间标识非法时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let roomID: String
            let canSend: Bool
            let stateVersion: UInt64
            let updatedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id"
                case canSend = "can_send"
                case stateVersion = "state_version"
                case updatedAtMilliseconds = "updated_at_ms"
            }
        }
        guard record.projectionKind == "direct_sending_capability",
              let wire = try? JSONDecoder().decode(Wire.self, from: record.payload),
              wire.stateVersion > 0, wire.stateVersion <= UInt64(Int64.max),
              wire.updatedAtMilliseconds >= 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            self.init(roomID: try .init(wire.roomID), canSend: wire.canSend, stateVersion: wire.stateVersion, updatedAt: Date(timeIntervalSince1970: TimeInterval(wire.updatedAtMilliseconds) / 1_000))
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}
