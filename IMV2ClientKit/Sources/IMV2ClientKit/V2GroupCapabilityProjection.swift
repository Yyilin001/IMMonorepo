import Foundation
import IMV2Core

/// 群公告的只读本地投影。
///
/// 它与命令与结果类型分开，使界面层无需解码事件 JSON。
public struct V2ClientGroupAnnouncement: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 公告正文。
    public let body: String
    /// 公告修订。
    public let revision: UInt64
    /// 公告更新时刻。
    public let updatedAt: Date

    /// 保存公告投影。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - body: 公告正文。
    ///   - revision: 公告修订。
    ///   - updatedAt: 更新时刻。
    public init(roomID: RoomID, body: String, revision: UInt64, updatedAt: Date) {
        self.roomID = roomID
        self.body = body
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

/// 群角色策略的只读本地投影。
public struct V2ClientGroupRolePolicy: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 目标角色。
    public let role: V2RoomMembershipRole
    /// 该角色当前拥有的权限集合。
    public let permissions: Set<V2GroupPermission>
    /// 策略修订。
    public let revision: UInt64

    /// 保存角色策略投影。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - role: 目标角色。
    ///   - permissions: 权限集合。
    ///   - revision: 策略修订。
    public init(roomID: RoomID, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, revision: UInt64) {
        self.roomID = roomID
        self.role = role
        self.permissions = permissions
        self.revision = revision
    }
}

/// 群控制类事件载荷的解析器。
///
/// 与界面模型分开可以保证标准扇出、混合房间日志拉取与前台预览三条路径
/// 使用完全相同的校验逻辑。
enum V2ClientGroupCapabilityProjection {
    /// 仅解读事件类型的事件头。
    struct Header: Decodable { let eventType: String; enum CodingKeys: String, CodingKey { case eventType = "event_type" } }
    /// 成员角色变更事件的关键字段。
    struct MemberRole: Decodable { let roomID: String; let targetUserID: String; let role: String; let membershipRevision: UInt64; enum CodingKeys: String, CodingKey { case roomID = "room_id", targetUserID = "target_user_id", role, membershipRevision = "membership_revision" } }

    /// 解析事件头。
    ///
    /// - Parameter data: 事件载荷。
    /// - Returns: 解析出的事件头。
    /// - Throws: 载荷无法解码时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    static func header(_ data: Data) throws -> Header { do { return try JSONDecoder().decode(Header.self, from: data) } catch { throw V2ClientProjectionError.invalidMessagePayload } }
}
