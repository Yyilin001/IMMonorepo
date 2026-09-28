import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 逻辑 home 与物理 owner 分离；房间准入通过 RoomRef，SQL 事务内只复核该决定的事实/fence。
public struct V2ResourceHomeRouter: Sendable {
    private let controlDatabase: any Database
    private let rooms: any V2RoomShardRouting
    private let ownerDatabases: [String: any Database]
    private let authorization: V2ActorRoomMediaAuthorizationPort
    private let callTimeout: Duration

    public init(controlDatabase: any Database, rooms: any V2RoomShardRouting,
                ownerDatabases: [String: any Database], authorization: V2ActorRoomMediaAuthorizationPort,
                callTimeout: Duration = .seconds(10)) {
        self.controlDatabase = controlDatabase; self.rooms = rooms; self.ownerDatabases = ownerDatabases
        self.authorization = authorization; self.callTimeout = callTimeout
    }

    public func resolve(home: V2ResourceHome, usage: V2ResourceUsage?, actorUserID: UserID,
                        deviceID: DeviceID) async throws -> PostgresV2ResourceLifecycleStore {
        try Task.checkCancellation()
        guard callTimeout > .zero, let actor = actorUserID.uuidValue, let device = deviceID.uuidValue,
              usage.map({ $0.home(actorUserID: actorUserID) == home }) ?? true
        else { throw V2MediaStoreError.uploadNotAuthorized }
        let deadline = ContinuousClock.now + callTimeout
        let deviceExpiry = try await Self.requireDevice(actor: actor, device: device, database: controlDatabase)
        switch home {
        case .account(let owner):
            guard owner == actorUserID, usage == nil || usage == .userAvatar else { throw V2MediaStoreError.uploadNotAuthorized }
            return PostgresV2ResourceLifecycleStore(database: controlDatabase, authorizationExpiresAt: deviceExpiry) { transaction in
                try Self.checkBudget(deadline)
                _ = try await Self.requireDevice(actor: actor, device: device, database: transaction)
            }
        case .room(let roomID):
            guard let room = roomID.uuidValue else { throw V2MediaStoreError.uploadNotAuthorized }
            let route = try await rooms.route(for: roomID)
            guard let owner = ownerDatabases[route.shardID] else { throw V2ResourceProviderError.configurationInvalid }
            let request = V2ActorResourceUploadAuthorizationWire(roomID: roomID, actorUserID: actorUserID,
                usage: usage ?? .messageAttachment(roomID))
            guard let proof = try await authorization.captureUpload(request, deadline: deadline),
                  proof.activation.owner.shardID == route.shardID, proof.activation.owner.epoch == route.epoch
            else { throw V2MediaStoreError.uploadNotAuthorized }
            try Self.checkBudget(deadline)
            let control = controlDatabase
            let router = rooms
            let requiresGroupOwner: Bool
            if case .groupAvatar = usage { requiresGroupOwner = true } else { requiresGroupOwner = false }
            return PostgresV2ResourceLifecycleStore(database: owner, authorizationExpiresAt: min(deviceExpiry, proof.activationExpiresAt), backgroundDelegationExpiresAt: deviceExpiry) { transaction in
                try Self.checkBudget(deadline)
                // No owner locks are held while the independent control authority is queried.
                _ = try await Self.requireDevice(actor: actor, device: device, database: control)
                guard try await router.route(for: roomID) == route else { throw V2RoomOwnerFenceError.ownerChanged }
                guard let sql = transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
                try await v2RequireRoomActivation(token: proof.activation, sql: sql)
                // Same room lock serializes membership, role, permission, freeze and mute changes.
                guard try await sql.raw("""
                    SELECT 1 FROM im_v2.rooms room JOIN im_v2.room_memberships member ON member.room_id = room.room_id
                    WHERE room.room_id = \(bind: room) AND room.membership_revision = \(bind: proof.membershipRevision)
                      AND room.group_permission_revision = \(bind: proof.permissionRevision) AND room.frozen_at IS NULL
                      AND member.user_id = \(bind: actor) AND member.role = \(bind: proof.role)
                      AND (\(bind: requiresGroupOwner) = FALSE OR (room.room_kind='group' AND member.role='owner'
                          AND EXISTS (SELECT 1 FROM im_v2.group_rooms g WHERE g.room_id=room.room_id
                              AND g.owner_user_id=\(bind: actor))))
                      AND member.joined_revision <= room.membership_revision
                      AND (member.left_revision IS NULL OR member.left_revision > room.membership_revision)
                      AND NOT EXISTS (SELECT 1 FROM im_v2.room_member_mutes mute WHERE mute.room_id = room.room_id
                          AND mute.user_id = \(bind: actor) AND mute.mute_until > clock_timestamp())
                    """).first() != nil else { throw V2MediaStoreError.uploadNotAuthorized }
                try Self.checkBudget(deadline)
            }
        }
    }

    private static func requireDevice(actor: UUID, device: UUID, database: any Database) async throws -> Date {
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        guard let row = try await sql.raw("""
            SELECT device.session_expires_at FROM im_v2.auth_devices device
            JOIN im_v2.public_user_profiles profile ON profile.user_id = device.user_id AND profile.state = 'active'
            WHERE device.user_id = \(bind: actor) AND device.device_id = \(bind: device)
              AND device.revoked_at IS NULL AND device.session_expires_at > clock_timestamp()
              AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables WHERE user_id = device.user_id)
            """).first(decoding: V2ResourceDeviceExpiryRow.self)
        else { throw V2MediaStoreError.uploadNotAuthorized }
        return row.expiresAt
    }

    private static func checkBudget(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
    }
}

private struct V2ResourceDeviceExpiryRow: Decodable {
    let expiresAt: Date
    enum CodingKeys: String, CodingKey { case expiresAt = "session_expires_at" }
}
