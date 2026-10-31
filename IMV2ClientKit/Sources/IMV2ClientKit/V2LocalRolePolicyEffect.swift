import Crypto
import Foundation
import IMV2Core

/// 本地角色策略变更效果。
///
/// 修订属于某个角色的来源事件，绝不能由房间级命令修订或接收者的个人游标推断得出。
struct V2LocalRolePolicyEffect {
    /// 来源事件标识。
    let sourceEventID: EventID
    /// 目标房间。
    let roomID: RoomID
    /// 目标角色。
    let role: V2RoomMembershipRole
    /// 策略修订。
    let revision: Int64
    /// 解析后的权限集合。
    let permissions: Set<V2GroupPermission>
    /// 权限集合的规范 JSON 编码。
    let encodedPermissions: Data
    /// 已验证的来源房间序号，正文省略时取房间日志外层。
    let roomSequence: Int64
    /// 由房间、角色、修订、权限、发起者与时间戳计算的规范摘要。
    let digest: Data

    /// 从同步记录解码角色策略效果。
    ///
    /// - Parameters:
    ///   - record: 角色权限变更类型的同步记录。
    ///   - expectedRoomSequence: 期望的房间序号；给出且载荷含序号时必须一致。
    ///   - expectedRoomID: 期望的房间；给出时必须与载荷一致。
    /// - Throws: 载荷无法解码、事件类型不符、角色为群主或未知、
    ///   权限存在重复或未知取值，或与期望值不一致时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord, expectedRoomSequence: UInt64? = nil, expectedRoomID: RoomID? = nil) throws {
        struct Wire: Decodable {
            let event_type: String; let room_id: String; let revision: Int64
            let role: String; let permissions: [String]
            let actor_user_id: String?; let server_created_at_ms: Int64?; let room_sequence: Int64?
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
            guard record.projectionKind == "group_capability", wire.event_type == "group.role_permissions_changed",
                  UUID(uuidString: wire.room_id) != nil, wire.revision > 0,
                  let parsedRole = V2RoomMembershipRole(rawValue: wire.role), parsedRole != .owner,
                  wire.actor_user_id.map({ UUID(uuidString: $0) != nil }) ?? true,
                  wire.server_created_at_ms.map({ $0 >= 0 }) ?? true,
                  wire.room_sequence.map({ $0 > 0 }) ?? true
            else { throw V2ClientProjectionError.invalidMessagePayload }
            let parsedPermissions = Set(wire.permissions.compactMap(V2GroupPermission.init(rawValue:)))
            guard parsedPermissions.count == wire.permissions.count else { throw V2ClientProjectionError.invalidMessagePayload }
            roomID = try .init(wire.room_id)
            guard expectedRoomID == nil || expectedRoomID == roomID else { throw V2ClientProjectionError.invalidMessagePayload }
            if let expectedRoomSequence, let sequence = wire.room_sequence {
                guard UInt64(sequence) == expectedRoomSequence else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            sourceEventID = record.sourceEventID
            role = parsedRole
            revision = wire.revision
            permissions = parsedPermissions
            guard let sequence = wire.room_sequence ?? expectedRoomSequence.flatMap(Int64.init(exactly:)), sequence > 0
            else { throw V2ClientProjectionError.invalidMessagePayload }
            roomSequence = sequence
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encodedPermissions = try encoder.encode(parsedPermissions.map(\.rawValue).sorted())
            struct Canonical: Encodable {
                let version = 1
                let room: String; let role: String; let revision: Int64; let permissions: [String]
                let actor: String?; let createdAt: Int64?
            }
            digest = Data(SHA256.hash(data: try encoder.encode(Canonical(
                room: roomID.rawValue, role: role.rawValue, revision: revision,
                permissions: parsedPermissions.map(\.rawValue).sorted(),
                actor: try wire.actor_user_id.map(UserID.init)?.rawValue, createdAt: wire.server_created_at_ms
            ))))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
