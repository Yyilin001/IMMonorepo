import Fluent
import Foundation
import IMV2Core
import SQLKit

/// The mutable group controls share the same ordered event stream as messages.
/// In particular, a policy or role change is never committed without its room
/// event and delivery plan; clients therefore cannot observe a newer policy
/// while still applying an older membership projection.
public struct PostgresV2GroupCapabilitiesStore: V2GroupCapabilitiesStore {
    private let database: any Database
    public init(database: any Database) { self.database = database }

    public func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        try await groupTransaction(database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID, command.messageID)
            guard let messageID = ids.target else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            if let prior = try await sql.raw("SELECT room_id, message_id, is_pinned, room_sequence, created_at FROM im_v2.room_pinned_message_operations WHERE actor_user_id = \(bind: ids.actor) AND operation_id = \(bind: ids.operation)").first(decoding: GroupPinOperationRow.self) {
                guard prior.roomID == ids.room, prior.messageID == messageID, prior.isPinned == command.isPinned else { return .idempotencyConflict }
                return .idempotent(try prior.value(roomID: command.roomID, messageID: command.messageID))
            }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .pinMessages, capacityProfile: capacityProfile, now: now, sql: sql)
            guard let message = try await sql.raw("SELECT room_id, withdrawn_at FROM im_v2.messages WHERE message_id = \(bind: messageID) FOR UPDATE").first(decoding: GroupMessageRow.self), message.roomID == ids.room else { throw V2GroupCapabilitiesStoreError.messageNotFound }
            guard message.withdrawnAt == nil else { throw V2GroupCapabilitiesStoreError.messageWithdrawn }
            let exists = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_pinned_messages WHERE room_id = \(bind: ids.room) AND message_id = \(bind: messageID)) AS value").first(decoding: GroupBoolRow.self)?.value ?? false
            guard exists != command.isPinned else { return .alreadyInDesiredState }
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID, planID: planID, eventType: "message.pinned_changed", payload: try groupPayload(["event_type": "message.pinned_changed", "room_id": ids.room.uuidString, "message_id": messageID.uuidString, "is_pinned": command.isPinned, "actor_user_id": ids.actor.uuidString, "server_created_at_ms": Int64(now.timeIntervalSince1970 * 1_000)]), now: now, sql: sql)
            if command.isPinned { try await sql.raw("INSERT INTO im_v2.room_pinned_messages (room_id, message_id, pinned_by_user_id, pinned_at) VALUES (\(bind: ids.room), \(bind: messageID), \(bind: ids.actor), \(bind: now))").run() }
            else { try await sql.raw("DELETE FROM im_v2.room_pinned_messages WHERE room_id = \(bind: ids.room) AND message_id = \(bind: messageID)").run() }
            try await sql.raw("INSERT INTO im_v2.room_pinned_message_operations (actor_user_id, operation_id, room_id, message_id, is_pinned, room_sequence, event_id, plan_id, created_at) VALUES (\(bind: ids.actor), \(bind: ids.operation), \(bind: ids.room), \(bind: messageID), \(bind: command.isPinned), \(bind: committed.sequence), \(bind: committed.eventID), \(bind: committed.planID), \(bind: now))").run()
            return .applied(try .init(roomID: command.roomID, messageID: command.messageID, isPinned: command.isPinned, roomSequence: groupUnsigned(committed.sequence), updatedAt: now))
        }
    }

    public func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        try await groupTransaction(database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID)
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            let expectedRevision = try groupSigned(command.expectedRevision)
            if let prior = try await sql.raw("SELECT room_id, body, expected_revision, resulting_revision, room_sequence, created_at FROM im_v2.group_announcement_operations WHERE actor_user_id = \(bind: ids.actor) AND operation_id = \(bind: ids.operation)").first(decoding: GroupAnnouncementOperationRow.self) {
                guard prior.roomID == ids.room, prior.body == command.body, prior.expectedRevision == expectedRevision else { return .idempotencyConflict }
                return .idempotent(try prior.value(roomID: command.roomID))
            }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .manageAnnouncements, capacityProfile: capacityProfile, now: now, sql: sql)
            let current = try await sql.raw("SELECT revision FROM im_v2.group_announcements WHERE room_id = \(bind: ids.room) FOR UPDATE").first(decoding: GroupRevisionRow.self)?.revision ?? 0
            guard try groupUnsigned(current) == command.expectedRevision else { return .revisionConflict }
            guard current < Int64.max else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let revision = current + 1
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID, planID: planID, eventType: "group.announcement_changed", payload: try groupPayload(["event_type": "group.announcement_changed", "room_id": ids.room.uuidString, "body": command.body, "revision": revision, "actor_user_id": ids.actor.uuidString, "server_created_at_ms": Int64(now.timeIntervalSince1970 * 1_000)]), now: now, sql: sql)
            try await sql.raw("INSERT INTO im_v2.group_announcements (room_id, body, revision, updated_by_user_id, updated_at) VALUES (\(bind: ids.room), \(bind: command.body), \(bind: revision), \(bind: ids.actor), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET body = EXCLUDED.body, revision = EXCLUDED.revision, updated_by_user_id = EXCLUDED.updated_by_user_id, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("INSERT INTO im_v2.group_announcement_operations (actor_user_id, operation_id, room_id, body, expected_revision, resulting_revision, room_sequence, event_id, plan_id, created_at) VALUES (\(bind: ids.actor), \(bind: ids.operation), \(bind: ids.room), \(bind: command.body), \(bind: groupSigned(command.expectedRevision)), \(bind: revision), \(bind: committed.sequence), \(bind: committed.eventID), \(bind: committed.planID), \(bind: now))").run()
            return .applied(try .init(roomID: command.roomID, body: command.body, revision: groupUnsigned(revision), roomSequence: groupUnsigned(committed.sequence), updatedAt: now))
        }
    }

    public func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> {
        try await groupTransaction(database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID)
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            let permissionJSON = try groupPermissionsJSON(command.permissions)
            let expectedRevision = try groupSigned(command.expectedRevision)
            if let prior = try await sql.raw("SELECT room_id, expected_revision, resulting_revision, role, permissions::text AS permissions_json, room_sequence FROM im_v2.group_permission_operations WHERE actor_user_id = \(bind: ids.actor) AND operation_id = \(bind: ids.operation)").first(decoding: GroupPermissionOperationRow.self) {
                guard prior.roomID == ids.room, prior.expectedRevision == expectedRevision, prior.role == command.role.rawValue, prior.permissionsJSON == permissionJSON else { return .idempotencyConflict }
                return .idempotent(try prior.value(roomID: command.roomID))
            }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .changeMemberRoles, capacityProfile: capacityProfile, now: now, sql: sql)
            guard try groupUnsigned(context.room.groupPermissionRevision) == command.expectedRevision else { return .revisionConflict }
            guard context.room.groupPermissionRevision < Int64.max else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let revision = context.room.groupPermissionRevision + 1
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID, planID: planID, eventType: "group.role_permissions_changed", payload: try groupPayload(["event_type": "group.role_permissions_changed", "room_id": ids.room.uuidString, "role": command.role.rawValue, "permissions": command.permissions.map(\.rawValue).sorted(), "revision": revision, "actor_user_id": ids.actor.uuidString, "server_created_at_ms": Int64(now.timeIntervalSince1970 * 1_000)]), now: now, sql: sql)
            try await sql.raw("DELETE FROM im_v2.group_role_permissions WHERE room_id = \(bind: ids.room) AND role = \(bind: command.role.rawValue)").run()
            for permission in command.permissions { try await sql.raw("INSERT INTO im_v2.group_role_permissions (room_id, role, permission) VALUES (\(bind: ids.room), \(bind: command.role.rawValue), \(bind: permission.rawValue))").run() }
            try await sql.raw("UPDATE im_v2.rooms SET group_permission_revision = \(bind: revision) WHERE room_id = \(bind: ids.room)").run()
            try await sql.raw("INSERT INTO im_v2.group_permission_operations (actor_user_id, operation_id, room_id, expected_revision, resulting_revision, role, permissions, room_sequence, event_id, plan_id, created_at) VALUES (\(bind: ids.actor), \(bind: ids.operation), \(bind: ids.room), \(bind: groupSigned(command.expectedRevision)), \(bind: revision), \(bind: command.role.rawValue), \(bind: permissionJSON)::jsonb, \(bind: committed.sequence), \(bind: committed.eventID), \(bind: committed.planID), \(bind: now))").run()
            return .applied(try .init(roomID: command.roomID, role: command.role, permissions: command.permissions, revision: groupUnsigned(revision), roomSequence: groupUnsigned(committed.sequence)))
        }
    }

    public func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        try await groupTransaction(database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID, command.targetUserID)
            guard let targetID = ids.target else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            guard ids.actor != targetID else { return .alreadyInDesiredState }
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            let expectedMembershipRevision = try groupSigned(command.expectedMembershipRevision)
            if let prior = try await sql.raw("SELECT room_id, target_user_id, role, expected_membership_revision, resulting_membership_revision, room_sequence FROM im_v2.group_role_operations WHERE actor_user_id = \(bind: ids.actor) AND operation_id = \(bind: ids.operation)").first(decoding: GroupRoleOperationRow.self) {
                guard prior.roomID == ids.room, prior.targetUserID == targetID, prior.role == command.role.rawValue, prior.expectedMembershipRevision == expectedMembershipRevision else { return .idempotencyConflict }
                return .idempotent(try prior.value(roomID: command.roomID, targetUserID: command.targetUserID))
            }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .changeMemberRoles, capacityProfile: capacityProfile, now: now, sql: sql)
            guard try groupUnsigned(context.room.membershipRevision) == command.expectedMembershipRevision else { return .revisionConflict }
            guard let target = try await sql.raw("SELECT role, joined_revision FROM im_v2.room_memberships WHERE room_id = \(bind: ids.room) AND user_id = \(bind: targetID) AND joined_revision <= \(bind: context.room.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: context.room.membershipRevision)) ORDER BY joined_revision DESC LIMIT 1 FOR UPDATE").first(decoding: GroupMemberRow.self) else { throw V2GroupCapabilitiesStoreError.targetNotMember }
            guard target.role != .owner else { throw V2GroupCapabilitiesStoreError.actorNotAuthorized }
            guard target.role != command.role else { return .alreadyInDesiredState }
            guard context.room.membershipRevision < Int64.max else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let membershipRevision = context.room.membershipRevision + 1
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID, planID: planID, eventType: "group.member_role_changed", payload: try groupPayload(["event_type": "group.member_role_changed", "room_id": ids.room.uuidString, "target_user_id": targetID.uuidString, "role": command.role.rawValue, "membership_revision": membershipRevision, "actor_user_id": ids.actor.uuidString, "server_created_at_ms": Int64(now.timeIntervalSince1970 * 1_000)]), now: now, sql: sql)
            // Membership history is revisioned. Close the active row and add
            // a new active interval so historical fan-out remains correct.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = \(bind: membershipRevision) WHERE room_id = \(bind: ids.room) AND user_id = \(bind: targetID) AND joined_revision = \(bind: target.joinedRevision)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision, left_revision) VALUES (\(bind: ids.room), \(bind: targetID), \(bind: command.role.rawValue), \(bind: membershipRevision), NULL)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = \(bind: membershipRevision) WHERE room_id = \(bind: ids.room)").run()
            try await sql.raw("INSERT INTO im_v2.group_role_operations (actor_user_id, operation_id, room_id, target_user_id, role, expected_membership_revision, resulting_membership_revision, room_sequence, event_id, plan_id, created_at) VALUES (\(bind: ids.actor), \(bind: ids.operation), \(bind: ids.room), \(bind: targetID), \(bind: command.role.rawValue), \(bind: groupSigned(command.expectedMembershipRevision)), \(bind: membershipRevision), \(bind: committed.sequence), \(bind: committed.eventID), \(bind: committed.planID), \(bind: now))").run()
            return .applied(try .init(roomID: command.roomID, targetUserID: command.targetUserID, role: command.role, membershipRevision: groupUnsigned(membershipRevision), roomSequence: groupUnsigned(committed.sequence)))
        }
    }
}

private struct GroupIDs { let actor: UUID; let operation: UUID; let room: UUID; let target: UUID? }
private func groupIDs<Tag: V2IdentifierTag>(_ actor: UserID, _ operation: V2Identifier<Tag>, _ room: RoomID) throws -> GroupIDs {
    guard let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let room = UUID(uuidString: room.rawValue) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    return .init(actor: actor, operation: operation, room: room, target: nil)
}
private func groupIDs<Operation: V2IdentifierTag, Target: V2IdentifierTag>(_ actor: UserID, _ operation: V2Identifier<Operation>, _ room: RoomID, _ target: V2Identifier<Target>) throws -> GroupIDs {
    var ids = try groupIDs(actor, operation, room)
    guard let target = UUID(uuidString: target.rawValue) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    ids = .init(actor: ids.actor, operation: ids.operation, room: ids.room, target: target)
    return ids
}

private func groupLock(actor: UUID, operation: UUID, sql: any SQLDatabase) async throws {
    let key = actor.uuidString + ":" + operation.uuidString
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
}
private func groupUnsigned(_ value: Int64) throws -> UInt64 { guard value >= 0 else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }; return UInt64(value) }
private func groupSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }; return Int64(value) }
private func groupPermissionsJSON(_ permissions: Set<V2GroupPermission>) throws -> String { String(decoding: try JSONEncoder().encode(permissions.map(\.rawValue).sorted()), as: UTF8.self) }
private func groupPayload(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
private func groupTransaction<Value: Equatable & Sendable>(_ database: any Database, _ body: @escaping @Sendable (any Database) async throws -> V2GroupCapabilitiesOutcome<Value>) async throws -> V2GroupCapabilitiesOutcome<Value> {
    do { return try await database.transaction(body) }
    catch let signal as GroupAdmissionSignal { switch signal { case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds); case .unavailable(let reason): return .unavailable(reason) } }
}

private struct GroupRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let groupPermissionRevision: Int64; let capacityProfileID: String; let roomKind: String; let deliveryMode: V2GroupDeliveryMode; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", groupPermissionRevision = "group_permission_revision", capacityProfileID = "capacity_profile_id", roomKind = "room_kind", deliveryMode = "delivery_mode" } }
private struct GroupMemberRow: Decodable { let role: V2RoomMembershipRole; let joinedRevision: Int64; enum CodingKeys: String, CodingKey { case role, joinedRevision = "joined_revision" } }
private struct GroupMessageRow: Decodable { let roomID: UUID; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", withdrawnAt = "withdrawn_at" } }
private struct GroupBoolRow: Decodable { let value: Bool }
private struct GroupRevisionRow: Decodable { let revision: Int64 }
private struct GroupAdmissionRow: Decodable { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64; enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private struct GroupShardRow: Decodable { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int; enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: try groupUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private struct GroupContext { let room: GroupRoomRow; let admission: GroupAdmissionRow; let nextRoom: RoomAdmissionState; let nextShard: ShardAdmissionState }
private struct GroupCommitted { let sequence: Int64; let eventID: UUID; let planID: UUID }

private func prepare(room: UUID, actor: UUID, required: V2GroupPermission, capacityProfile: V2CapacityProfile, now: Date, sql: any SQLDatabase) async throws -> GroupContext {
    guard let state = try await sql.raw("SELECT room_shard_id, room_sequence, membership_revision, group_permission_revision, capacity_profile_id, room_kind, delivery_mode FROM im_v2.rooms WHERE room_id = \(bind: room) FOR UPDATE").first(decoding: GroupRoomRow.self) else { throw V2GroupCapabilitiesStoreError.roomNotFound }
    guard state.roomKind == "group", state.capacityProfileID == capacityProfile.id else { throw state.roomKind == "group" ? V2GroupCapabilitiesStoreError.corruptPersistenceState : V2GroupCapabilitiesStoreError.notGroupRoom }
    guard let member = try await sql.raw("SELECT role, joined_revision FROM im_v2.room_memberships WHERE room_id = \(bind: room) AND user_id = \(bind: actor) AND joined_revision <= \(bind: state.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: state.membershipRevision)) ORDER BY joined_revision DESC LIMIT 1 FOR UPDATE").first(decoding: GroupMemberRow.self) else { throw V2GroupCapabilitiesStoreError.actorNotMember }
    let configuredPermissions = try await v2ResolvedGroupPermissions(roomID: room, role: member.role, sql: sql)
    guard V2GroupPermissionDefaults.allows(role: member.role, permission: required, configured: configuredPermissions) else { throw V2GroupCapabilitiesStoreError.actorNotAuthorized }
    guard let admission = try await sql.raw("SELECT eligible_member_count, command_window_limit, command_window_used, fanout_window_limit, fanout_window_used, max_outstanding_fanout_units, outstanding_fanout_units, max_outstanding_plans, outstanding_plans, shard_lease_id, shard_lease_generation FROM im_v2.room_admission WHERE room_id = \(bind: room) FOR UPDATE").first(decoding: GroupAdmissionRow.self), let shard = try await sql.raw("SELECT lease_id, generation, valid_until, command_window_limit, command_window_used, fanout_window_limit, fanout_window_used, max_outstanding_fanout_units, outstanding_fanout_units, max_outstanding_plans, outstanding_plans FROM im_v2.shard_admission_pools WHERE room_shard_id = \(bind: state.roomShardID) AND capacity_profile_id = \(bind: state.capacityProfileID) FOR UPDATE").first(decoding: GroupShardRow.self), admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    switch try V2RoomEventDeliveryMode.reserve(deliveryMode: state.deliveryMode, targetRule: .eligibleMemberCount, profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now) { case .accepted(_, let nextRoom, let nextShard): return .init(room: state, admission: admission, nextRoom: nextRoom, nextShard: nextShard); case .rateLimited(let seconds): throw GroupAdmissionSignal.rateLimited(seconds); case .unavailable(let reason): throw GroupAdmissionSignal.unavailable(reason) }
}
private enum GroupAdmissionSignal: Error { case rateLimited(Int); case unavailable(FanoutAdmissionUnavailableReason) }
private func commit(room: UUID, context: GroupContext, actor: UUID, eventID: EventID, planID: FanoutPlanID, eventType: String, payload: String, now: Date, sql: any SQLDatabase) async throws -> GroupCommitted {
    guard let lease = context.nextShard.lease, context.room.roomSequence < Int64.max, let event = UUID(uuidString: eventID.rawValue), let plan = UUID(uuidString: planID.rawValue) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    let sequence = context.room.roomSequence + 1
    guard let leaseID = UUID(uuidString: lease.id.rawValue) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: sequence) WHERE room_id = \(bind: room)").run()
    try await sql.raw("UPDATE im_v2.room_admission SET command_window_used = \(bind: context.nextRoom.commandWindow.used), fanout_window_used = \(bind: context.nextRoom.fanoutWindow.used), outstanding_fanout_units = \(bind: context.nextRoom.outstandingFanoutUnits), outstanding_plans = \(bind: context.nextRoom.outstandingPlans), shard_lease_id = \(bind: leaseID), shard_lease_generation = \(bind: try groupSigned(lease.generation)) WHERE room_id = \(bind: room)").run()
    try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used), fanout_window_used = \(bind: lease.fanoutWindow.used), outstanding_fanout_units = \(bind: context.nextShard.outstandingFanoutUnits), outstanding_plans = \(bind: context.nextShard.outstandingPlans) WHERE room_shard_id = \(bind: context.room.roomShardID) AND capacity_profile_id = \(bind: context.room.capacityProfileID) AND lease_id = \(bind: leaseID) AND generation = \(bind: try groupSigned(lease.generation))").run()
    try await sql.raw("INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at) VALUES (\(bind: event), \(bind: room), \(bind: sequence), \(bind: eventType), \(bind: actor), \(bind: payload)::jsonb, \(bind: context.room.membershipRevision), \(bind: now))").run()
    try await V2RoomEventDeliveryMode.persistPlan(deliveryMode: context.room.deliveryMode, planID: plan, eventID: event, roomID: room, roomSequence: sequence, committedMembershipRevision: context.room.membershipRevision, standardTargetRuleJSON: "{\"kind\":\"eligible_member_count\"}", standardTargetCount: context.admission.eligibleMemberCount, now: now, sql: sql)
    return .init(sequence: sequence, eventID: event, planID: plan)
}
private struct GroupPinOperationRow: Decodable { let roomID: UUID; let messageID: UUID; let isPinned: Bool; let roomSequence: Int64; let createdAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", isPinned = "is_pinned", roomSequence = "room_sequence", createdAt = "created_at" }; func value(roomID: RoomID, messageID: MessageID) throws -> V2PinnedMessage { try .init(roomID: roomID, messageID: messageID, isPinned: isPinned, roomSequence: groupUnsigned(roomSequence), updatedAt: createdAt) } }
private struct GroupAnnouncementOperationRow: Decodable { let roomID: UUID; let body: String; let expectedRevision: Int64; let resultingRevision: Int64; let roomSequence: Int64; let createdAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", body, expectedRevision = "expected_revision", resultingRevision = "resulting_revision", roomSequence = "room_sequence", createdAt = "created_at" }; func value(roomID: RoomID) throws -> V2GroupAnnouncement { try .init(roomID: roomID, body: body, revision: groupUnsigned(resultingRevision), roomSequence: groupUnsigned(roomSequence), updatedAt: createdAt) } }
private struct GroupPermissionOperationRow: Decodable { let roomID: UUID; let expectedRevision: Int64; let resultingRevision: Int64; let role: String; let permissionsJSON: String; let roomSequence: Int64; enum CodingKeys: String, CodingKey { case roomID = "room_id", expectedRevision = "expected_revision", resultingRevision = "resulting_revision", role, permissionsJSON = "permissions_json", roomSequence = "room_sequence" }; func value(roomID: RoomID) throws -> V2GroupRolePermissionsChange { guard let role = V2RoomMembershipRole(rawValue: role) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }; let values = try JSONDecoder().decode([String].self, from: Data(permissionsJSON.utf8)); let permissions = try Set(values.map { guard let value = V2GroupPermission(rawValue: $0) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }; return value }); return try .init(roomID: roomID, role: role, permissions: permissions, revision: groupUnsigned(resultingRevision), roomSequence: groupUnsigned(roomSequence)) } }
private struct GroupRoleOperationRow: Decodable { let roomID: UUID; let targetUserID: UUID; let role: String; let expectedMembershipRevision: Int64; let resultingMembershipRevision: Int64; let roomSequence: Int64; enum CodingKeys: String, CodingKey { case roomID = "room_id", targetUserID = "target_user_id", role, expectedMembershipRevision = "expected_membership_revision", resultingMembershipRevision = "resulting_membership_revision", roomSequence = "room_sequence" }; func value(roomID: RoomID, targetUserID: UserID) throws -> V2GroupMemberRoleChange { guard let role = V2RoomMembershipRole(rawValue: role) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }; return try .init(roomID: roomID, targetUserID: targetUserID, role: role, membershipRevision: groupUnsigned(resultingMembershipRevision), roomSequence: groupUnsigned(roomSequence)) } }
