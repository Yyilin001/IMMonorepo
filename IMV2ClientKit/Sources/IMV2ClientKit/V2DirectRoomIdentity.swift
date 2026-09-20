import Foundation
import IMV2Core

/// 设备本地的私聊房间与公开身份关联，来自当前用户明确发起的身份解析。
///
/// 这是已授权查询的缓存，不是联系人关系或可靠同步投影；应与服务端资料分开管理。
public struct V2ClientDirectRoomIdentity: Equatable, Sendable {
    /// 本地关联的私聊房间。
    public let roomID: RoomID
    /// 用户明确解析过的目标公开身份。
    public let publicIdentity: V2PublicIdentity
    /// 该本地关联记录的更新时间。
    public let updatedAt: Date
    public let roomCreatedAt: Date

    /// 保存本地关联字段，不检查时间范围、房间权限或目标是否仍为当前公开身份。
    public init(roomID: RoomID, publicIdentity: V2PublicIdentity, updatedAt: Date, roomCreatedAt: Date) {
        self.roomID = roomID
        self.publicIdentity = publicIdentity
        self.updatedAt = updatedAt
        self.roomCreatedAt = roomCreatedAt
    }
}

/// 从增量同步或快照基线取得的权威私聊资料投影。
///
/// 与设备本地的显式查询缓存分离，使同步重置可以只替换服务端拥有的状态。
public struct V2ClientDirectRoomProfileProjection: Equatable, Sendable {
    /// 该投影对应的源事件身份。
    public let sourceEventID: EventID
    /// 资料所属私聊房间。
    public let roomID: RoomID
    /// 服务端投影中的目标公开身份。
    public let publicIdentity: V2PublicIdentity
    /// 服务端资料修订号，同步解码入口要求大于零。
    public let revision: UInt64
    /// 服务端资料更新时间。
    public let updatedAt: Date
    public let roomCreatedAt: Date

    /// 直接保存已准备的投影字段，不执行修订号或日期校验；来自传输的数据应走同步记录解码入口。
    public init(
        sourceEventID: EventID, roomID: RoomID,
        publicIdentity: V2PublicIdentity, revision: UInt64, updatedAt: Date, roomCreatedAt: Date
    ) {
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.publicIdentity = publicIdentity
        self.revision = revision
        self.updatedAt = updatedAt
        self.roomCreatedAt = roomCreatedAt
    }

    /// 从 direct_room_profile 同步记录解码并校验资料投影。
    ///
    /// - Parameter record: 包含 JSON 资料负载的同步记录。
    /// - Throws: 投影类别、JSON、修订号或时间范围不符时抛出 invalidMessagePayload；标识及公开身份构造错误直接传播。
    ///
    /// 要求修订号大于零，Unix 毫秒时间非负；源事件身份来自记录，房间及目标身份来自负载。
    /// 不检查修订号是否连续、记录是否重复或时间是否晚于当前时钟，这些决策由应用投影层负责。
    public init(record: V2ClientSyncRecord) throws {
        guard record.projectionKind == "direct_room_profile" else { throw V2ClientProjectionError.invalidMessagePayload }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard payload.revision > 0, payload.updatedAtMilliseconds >= 0, payload.roomCreatedAtMilliseconds >= 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        sourceEventID = record.sourceEventID
        roomID = try .init(payload.roomID)
        publicIdentity = try .init(
            userID: .init(payload.targetUserID),
            handle: .init(payload.publicHandle),
            displayName: payload.displayName,
            accountKind: payload.accountKind
        )
        roomCreatedAt = Date(timeIntervalSince1970: TimeInterval(payload.roomCreatedAtMilliseconds) / 1_000)
        revision = payload.revision
        updatedAt = Date(timeIntervalSince1970: TimeInterval(payload.updatedAtMilliseconds) / 1_000)
    }

    /// 私聊资料负载的 JSON 格式，使用下划线字段名及 Unix 毫秒时间。
    private struct Wire: Decodable {
        /// 负载声明的房间标识。
        let roomID: String
        /// 目标用户标识。
        let targetUserID: String
        /// 目标公开账号标识。
        let publicHandle: String
        /// 目标显示名。
        let displayName: String
        /// 目标账户类别。
        let accountKind: V2AccountKind
        /// 必须为正数的资料修订号。
        let revision: UInt64
        /// 必须非负的 Unix 毫秒更新时间。
        let updatedAtMilliseconds: Int64
        let roomCreatedAtMilliseconds: Int64

        /// 将 Swift 字段映射为协议约定的下划线 JSON 键。
        enum CodingKeys: String, CodingKey {
            case roomID = "room_id"
            case targetUserID = "target_user_id"
            case publicHandle = "public_handle"
            case displayName = "display_name"
            case accountKind = "account_kind"
            case revision
            case updatedAtMilliseconds = "updated_at_ms"
            case roomCreatedAtMilliseconds = "room_created_at_ms"
        }
    }
}
