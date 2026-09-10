import Foundation
import IMV2Core

/// 群控制类投影事件。
///
/// 群控制修订为自己的对象（包括每个成员的角色）排序，
/// 不会把接收端的同步游标当作对象版本使用。
struct V2GroupPolicySnapshotEffect: Equatable {
    /// 本次事件携带的变更内容。
    enum Value: Equatable {
        /// 公告正文及其更新时间。
        case announcement(body: String, updatedAtMilliseconds: Int64)
        /// 某角色的权限集合。
        case permissions(role: V2RoomMembershipRole, values: Set<V2GroupPermission>)
        /// 某成员的角色变更。
        case memberRole(target: UUID, role: V2RoomMembershipRole, updatedAtMilliseconds: Int64?)
    }

    /// 目标房间。
    let roomID: UUID
    /// 该对象自身的修订号。
    let revision: Int64
    /// 本次变更内容。
    let value: Value
    /// 发起变更的用户；历史载荷可能缺失。
    let actorID: UUID?
    /// 来源房间日志序号；历史载荷可能缺失。
    let roomSequence: Int64?

    /// 投影实体键，按变更类型分别由房间、角色或目标成员唯一确定。
    var entityKey: String {
        switch value {
        case .announcement: "announcement:\(roomID.uuidString)"
        case .permissions(let role, _): "permissions:\(roomID.uuidString):\(role.rawValue)"
        case .memberRole(let target, _, _): "member-role:\(roomID.uuidString):\(target.uuidString)"
        }
    }

    /// 从事件载荷解码群控制变更。
    ///
    /// 成员角色事件使用成员修订，其余事件使用对象修订；公告正文长度、角色取值、
    /// 权限去重与未知权限过滤都会逐一校验，任一不符即视为载荷损坏。
    ///
    /// - Parameter payload: 事件载荷 JSON。
    /// - Throws: 载荷无法解码、事件类型不受支持或字段越界时抛出
    ///   ``V2UserProjectionWorkerError/invalidPayload``。
    init(payload: Data) throws {
        struct Wire: Decodable {
            let eventType: String; let roomID: UUID; let revision: Int64?
            let membershipRevision: Int64?; let targetUserID: UUID?
            let body: String?; let role: String?; let permissions: [String]?
            let updatedAt: Int64?; let actorID: UUID?; let roomSequence: Int64?
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type", roomID = "room_id", revision, body, role, permissions
                case updatedAt = "server_created_at_ms", actorID = "actor_user_id", roomSequence = "room_sequence"
                case membershipRevision = "membership_revision", targetUserID = "target_user_id"
            }
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: payload)
            let objectRevision = wire.eventType == "group.member_role_changed" ? wire.membershipRevision : wire.revision
            guard let objectRevision, objectRevision > 0, wire.roomSequence.map({ $0 > 0 }) ?? true,
                  wire.updatedAt.map({ $0 >= 0 }) ?? true
            else { throw V2UserProjectionWorkerError.invalidPayload }
            roomID = wire.roomID
            revision = objectRevision
            actorID = wire.actorID
            roomSequence = wire.roomSequence
            switch wire.eventType {
            case "group.announcement_changed":
                guard let body = wire.body, body.utf8.count <= V2GroupAnnouncementCommand.maximumUTF8Bytes,
                      let updatedAt = wire.updatedAt
                else { throw V2UserProjectionWorkerError.invalidPayload }
                // Empty legacy/replacement facts also carry a revision. Their
                // absence cannot fence an older nonempty announcement.
                value = .announcement(body: body, updatedAtMilliseconds: updatedAt)
            case "group.role_permissions_changed":
                guard let rawRole = wire.role, let role = V2RoomMembershipRole(rawValue: rawRole), role != .owner,
                      let rawPermissions = wire.permissions,
                      Set(rawPermissions).count == rawPermissions.count
                else { throw V2UserProjectionWorkerError.invalidPayload }
                let permissions = Set(rawPermissions.compactMap(V2GroupPermission.init(rawValue:)))
                guard permissions.count == rawPermissions.count else { throw V2UserProjectionWorkerError.invalidPayload }
                value = .permissions(role: role, values: permissions)
            case "group.member_role_changed":
                guard let target = wire.targetUserID, let rawRole = wire.role,
                      let role = V2RoomMembershipRole(rawValue: rawRole), role != .owner
                else { throw V2UserProjectionWorkerError.invalidPayload }
                value = .memberRole(target: target, role: role, updatedAtMilliseconds: wire.updatedAt)
            default: throw V2UserProjectionWorkerError.invalidPayload
            }
        } catch {
            throw V2UserProjectionWorkerError.invalidPayload
        }
    }

    /// 判断两个观测是否代表同一事实。
    ///
    /// 来源房间序号是后加的元数据：同一历史事实缺少序号时视为兼容，
    /// 但两个都给出了明确且不同的序号时不视为同一事实。
    ///
    /// - Parameter other: 另一个观测。
    /// - Returns: 房间、对象修订、变更内容与发起者一致，且来源序号不冲突时为 `true`。
    func representsSameFact(as other: Self) -> Bool {
        roomID == other.roomID && revision == other.revision && value == other.value && actorID == other.actorID
            && (roomSequence == nil || other.roomSequence == nil || roomSequence == other.roomSequence)
    }
}
