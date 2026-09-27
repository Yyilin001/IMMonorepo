import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 可变的群控制项与消息共享同一条有序事件流。
///
/// 尤其是策略或角色变更，绝不会在没有房间事件与投递计划的情况下提交。
/// 消费方必须使用来源房间序号而不是接收者的个人同步游标来排列这些效果。
public struct PostgresV2GroupCapabilitiesStore: V2GroupCapabilitiesStore, V2OwnerValidatedGroupCapabilitiesStore {
    private let database: any Database
    private let activationScope: V2RoomActivationWriteScope?
    /// 组合数据库。
    ///
    /// - Parameter database: 存放房间、成员、置顶与策略状态的数据库。
    public init(database: any Database) {
        self.database = database
        activationScope = nil
    }

    public init(database: any Database, activationScope: V2RoomActivationWriteScope) {
        self.database = database
        self.activationScope = activationScope
    }

    /// Group avatars belong to the room. Only its structural owner may bind one;
    /// upload authorization alone never grants this mutation. All effects are atomic.
    /// The authenticated control boundary validates account/device state; this owner
    /// database does not require a replica of control-domain profiles or devices.
    public func setAvatar(actorUserID: UserID, command: V2GroupAvatarCommand,
                          capacityProfile: V2CapacityProfile, eventID: EventID,
                          now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAvatarChange> {
        guard let activationScope else { throw V2RoomActivationLeaseError.activationChanged }
        return try await groupTransaction(database, classifyCommitFailure: true) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID)
            let requested = command.mutation.mediaID?.uuidValue
            try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            try await activationScope.require([ids.room], sql: sql)
            if let prior = try await sql.raw("""
                SELECT room_id,requested_media_id,expected_revision,resulting_revision,room_sequence,created_at
                FROM im_v2.resource_group_avatar_operations WHERE actor_user_id=\(bind:ids.actor) AND operation_id=\(bind:ids.operation)
                """).first(decoding: GroupAvatarOperationRow.self) {
                guard prior.roomID == ids.room, prior.mediaID == requested,
                      try groupUnsigned(prior.expectedRevision) == command.expectedRevision else { return .idempotencyConflict }
                return .idempotent(try prior.value())
            }
            if let closed = try await sql.raw("""
                SELECT room_id,requested_media_id,expected_revision FROM im_v2.resource_group_avatar_closures
                WHERE actor_user_id=\(bind:ids.actor) AND operation_id=\(bind:ids.operation)
                """).first(decoding: GroupAvatarClosureRow.self) {
                guard closed.matches(command) else { return .idempotencyConflict }
                throw V2GroupCapabilitiesStoreError.operationClosed
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .owner,
                capacityProfile: capacityProfile, now: now, sql: sql)
            guard try await sql.raw("""
                SELECT 1 FROM im_v2.group_rooms g JOIN im_v2.rooms r USING(room_id)
                WHERE g.room_id=\(bind:ids.room) AND g.owner_user_id=\(bind:ids.actor) AND r.frozen_at IS NULL
                """).first() != nil else { throw V2GroupCapabilitiesStoreError.actorNotAuthorized }
            let current = try await sql.raw("SELECT media_id,revision FROM im_v2.resource_group_avatars WHERE room_id=\(bind:ids.room) FOR UPDATE")
                .first(decoding: GroupAvatarBindingRow.self)
            let revision = current?.revision ?? 0
            guard try groupUnsigned(revision) == command.expectedRevision else { return .revisionConflict }
            guard revision < Int64.max else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            // Binding and GC share exact media locks, always in canonical order.
            for id in Set([current?.mediaID, requested].compactMap { $0 }).sorted(by: { $0.uuidString < $1.uuidString }) {
                guard try await sql.raw("SELECT 1 FROM im_v2.media_objects WHERE media_id=\(bind:id) FOR UPDATE").first() != nil
                else { throw V2GroupCapabilitiesStoreError.resourceUnavailable }
            }
            // Queueing and media-lock waits can outlive an upload's bind window.
            // The same fresh observation protects byte capabilities issued before
            // the room lock from an early GC after replacement/removal.
            let bindingObservedAt = max(now, try await v2RoomActivationDatabaseClock(sql: sql))
            guard let retireAfter = v2PostgresFutureTimestamp(now: bindingObservedAt, interval: 120)
            else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            if let requested {
                guard try await sql.raw("""
                    SELECT 1 FROM im_v2.media_objects m JOIN im_v2.resource_catalog c USING(media_id)
                    JOIN im_v2.resource_blob_placements p ON p.media_id=c.media_id AND p.generation=c.generation AND p.state='active'
                    WHERE m.media_id=\(bind:requested) AND m.state='available' AND m.content_type LIKE 'image/%'
                      AND c.home_kind='room' AND c.home_id=\(bind:ids.room) AND c.usage_kind='group_avatar'
                      AND ((m.owner_user_id=\(bind:ids.actor) AND m.expires_at>\(bind:bindingObservedAt)) OR m.media_id=\(bind:current?.mediaID))
                      AND (SELECT count(*) FROM im_v2.resource_variants v WHERE v.media_id=c.media_id
                        AND v.generation=c.generation AND v.recipe='avatar' AND v.recipe_version=1
                        AND v.size IN (128,256) AND v.state='ready')=2
                    """).first() != nil else { throw V2GroupCapabilitiesStoreError.resourceUnavailable }
            }
            let next = revision + 1
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID,
                eventType: "group.avatar_changed", payload: groupPayload([
                    "event_type": "group.avatar_changed", "room_id": ids.room.uuidString, "revision": next
                ]), now: now, sql: sql)
            try await sql.raw("""
                INSERT INTO im_v2.resource_group_avatars(room_id,media_id,revision,updated_by_user_id,updated_at)
                VALUES(\(bind:ids.room),\(bind:requested),\(bind:next),\(bind:ids.actor),\(bind:now))
                ON CONFLICT(room_id) DO UPDATE SET media_id=EXCLUDED.media_id,revision=EXCLUDED.revision,
                    updated_by_user_id=EXCLUDED.updated_by_user_id,updated_at=EXCLUDED.updated_at
                """).run()
            if let previous = current?.mediaID, previous != requested {
                // Existing byte capabilities live at most 120 seconds. Release the
                // binding now, but keep the old object through that bounded interval.
                try await sql.raw("UPDATE im_v2.media_objects SET expires_at=GREATEST(expires_at,\(bind:retireAfter)) WHERE media_id=\(bind:previous)").run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.resource_group_avatar_operations(actor_user_id,operation_id,room_id,requested_media_id,
                    expected_revision,resulting_revision,room_sequence,event_id,created_at)
                VALUES(\(bind:ids.actor),\(bind:ids.operation),\(bind:ids.room),\(bind:requested),\(bind:revision),\(bind:next),
                    \(bind:committed.sequence),\(bind:committed.eventID),\(bind:now))
                """).run()
            return .applied(try .init(state: .init(roomID: command.roomID, mediaID: command.mutation.mediaID,
                revision: groupUnsigned(next)), roomSequence: groupUnsigned(committed.sequence), updatedAt: committed.createdAt))
        }
    }

    /// Recovery is scoped to the authenticated actor's command and needs no
    /// current membership. It neither reads nor mutates another actor's avatar.
    public func recoverAvatar(actorUserID: UserID, request: V2GroupAvatarRecoveryRequest) async throws -> V2GroupAvatarRecoveryResult {
        guard let activationScope else { throw V2RoomActivationLeaseError.activationChanged }
        return try await v2WithRoomScopedTransaction(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let command = request.command, ids = try groupIDs(actorUserID, request.command.operationID, request.command.roomID)
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            try await activationScope.require([ids.room], sql: sql)
            if let prior = try await sql.raw("""
                SELECT room_id,requested_media_id,expected_revision,resulting_revision,room_sequence,created_at
                FROM im_v2.resource_group_avatar_operations WHERE actor_user_id=\(bind:ids.actor) AND operation_id=\(bind:ids.operation)
                """).first(decoding: GroupAvatarOperationRow.self) {
                guard prior.roomID == ids.room, prior.mediaID == command.mutation.mediaID?.uuidValue,
                      try groupUnsigned(prior.expectedRevision) == command.expectedRevision else { return .idempotencyConflict }
                return .committed(try prior.value())
            }
            if let closed = try await sql.raw("""
                SELECT room_id,requested_media_id,expected_revision FROM im_v2.resource_group_avatar_closures
                WHERE actor_user_id=\(bind:ids.actor) AND operation_id=\(bind:ids.operation)
                """).first(decoding: GroupAvatarClosureRow.self) {
                return closed.matches(command) ? .closed : .idempotencyConflict
            }
            guard request.action == .closeIfAbsent else { return .unresolved }
            try await sql.raw("""
                INSERT INTO im_v2.resource_group_avatar_closures(actor_user_id,operation_id,room_id,requested_media_id,expected_revision,closed_at)
                VALUES(\(bind:ids.actor),\(bind:ids.operation),\(bind:ids.room),\(bind:command.mutation.mediaID?.uuidValue),
                    \(bind:try groupSigned(command.expectedRevision)),clock_timestamp())
                """).run()
            return .closed
        }
    }

    /// 设置置顶消息（不校验房间归属）。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 置顶消息命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 置顶结果。
    /// - Throws: 无权限、状态冲突或持久化失败时抛出。
    public func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        try await setPinnedMessage(actorUserID: actorUserID, command: command, ownerRoute: nil, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    /// 按房间归属设置置顶消息。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 置顶消息命令。
    ///   - ownerRoute: 已选定的房间归属，事务内据此校验归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 置顶结果。
    /// - Throws: 归属已变更、无权限、状态冲突或持久化失败时抛出。
    public func setPinnedMessageOwnerValidated(actorUserID: UserID, command: V2PinnedMessageCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        try await setPinnedMessage(actorUserID: actorUserID, command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    private func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        return try await groupTransaction(database, classifyCommitFailure: activationScope != nil) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID, command.messageID)
            guard let messageID = ids.target else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            if let activationScope { try await activationScope.require([ids.room], sql: sql) }
            if activationScope == nil, let ownerRoute { try await v2RequireRoomOwner(roomID: ids.room, route: ownerRoute, sql: sql) }
            if let prior = try await sql.raw("SELECT room_id, message_id, is_pinned, room_sequence, created_at FROM im_v2.room_pinned_message_operations WHERE actor_user_id = \(bind: ids.actor) AND operation_id = \(bind: ids.operation)").first(decoding: GroupPinOperationRow.self) {
                guard prior.roomID == ids.room, prior.messageID == messageID, prior.isPinned == command.isPinned else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(prior.createdAt) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
                return .idempotent(try prior.value(roomID: command.roomID, messageID: command.messageID))
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .permission(.pinMessages), capacityProfile: capacityProfile, now: now, sql: sql)
            guard let message = try await sql.raw("""
                SELECT message.room_id, message.withdrawn_at
                FROM im_v2.messages AS message
                JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                WHERE message.message_id = \(bind: messageID)
                  AND message.room_id = \(bind: ids.room)
                  AND (\(v2ForwardSourceVisibility(actorID: ids.actor)))
                FOR UPDATE OF message
                """).first(decoding: GroupMessageRow.self), message.roomID == ids.room else { throw V2GroupCapabilitiesStoreError.messageNotFound }
            guard message.withdrawnAt == nil else { throw V2GroupCapabilitiesStoreError.messageWithdrawn }
            let exists = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_pinned_messages WHERE room_id = \(bind: ids.room) AND message_id = \(bind: messageID)) AS value").first(decoding: GroupBoolRow.self)?.value ?? false
            guard exists != command.isPinned else { return .alreadyInDesiredState }
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID, eventType: "message.pinned_changed", payload: try groupPayload(["event_type": "message.pinned_changed", "room_id": ids.room.uuidString, "message_id": messageID.uuidString, "is_pinned": command.isPinned, "actor_user_id": ids.actor.uuidString]), now: now, sql: sql)
            if command.isPinned { try await sql.raw("INSERT INTO im_v2.room_pinned_messages (room_id, message_id, pinned_by_user_id, pinned_at) VALUES (\(bind: ids.room), \(bind: messageID), \(bind: ids.actor), \(bind: now))").run() }
            else { try await sql.raw("DELETE FROM im_v2.room_pinned_messages WHERE room_id = \(bind: ids.room) AND message_id = \(bind: messageID)").run() }
            try await sql.raw("INSERT INTO im_v2.room_pinned_message_operations (actor_user_id, operation_id, room_id, message_id, is_pinned, room_sequence, event_id, created_at) VALUES (\(bind: ids.actor), \(bind: ids.operation), \(bind: ids.room), \(bind: messageID), \(bind: command.isPinned), \(bind: committed.sequence), \(bind: committed.eventID), \(bind: now))").run()
            return .applied(try .init(roomID: command.roomID, messageID: command.messageID, isPinned: command.isPinned, roomSequence: groupUnsigned(committed.sequence), updatedAt: committed.createdAt))
        }
    }

    /// 设置群公告（不校验房间归属）。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 群公告命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 公告结果。
    /// - Throws: 无权限、状态冲突或持久化失败时抛出。
    public func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        try await setAnnouncement(actorUserID: actorUserID, command: command, ownerRoute: nil, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    /// 按房间归属设置群公告。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 群公告命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 公告结果。
    /// - Throws: 归属已变更、无权限、状态冲突或持久化失败时抛出。
    public func setAnnouncementOwnerValidated(actorUserID: UserID, command: V2GroupAnnouncementCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        try await setAnnouncement(actorUserID: actorUserID, command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    private func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        return try await groupTransaction(database, classifyCommitFailure: activationScope != nil) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID)
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            if let activationScope { try await activationScope.require([ids.room], sql: sql) }
            if activationScope == nil, let ownerRoute { try await v2RequireRoomOwner(roomID: ids.room, route: ownerRoute, sql: sql) }
            let expectedRevision = try groupSigned(command.expectedRevision)
            if let prior = try await sql.raw("SELECT room_id, body, expected_revision, resulting_revision, room_sequence, created_at FROM im_v2.group_announcement_operations WHERE actor_user_id = \(bind: ids.actor) AND operation_id = \(bind: ids.operation)").first(decoding: GroupAnnouncementOperationRow.self) {
                guard prior.roomID == ids.room, prior.body == command.body, prior.expectedRevision == expectedRevision else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(prior.createdAt) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
                return .idempotent(try prior.value(roomID: command.roomID))
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .permission(.manageAnnouncements), capacityProfile: capacityProfile, now: now, sql: sql)
            let current = try await sql.raw("SELECT revision FROM im_v2.group_announcements WHERE room_id = \(bind: ids.room) FOR UPDATE").first(decoding: GroupRevisionRow.self)?.revision ?? 0
            guard try groupUnsigned(current) == command.expectedRevision else { return .revisionConflict }
            guard current < Int64.max else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let revision = current + 1
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID, eventType: "group.announcement_changed", payload: try groupPayload(["event_type": "group.announcement_changed", "room_id": ids.room.uuidString, "body": command.body, "revision": revision, "actor_user_id": ids.actor.uuidString]), now: now, sql: sql)
            try await sql.raw("INSERT INTO im_v2.group_announcements (room_id, body, revision, updated_by_user_id, updated_at) VALUES (\(bind: ids.room), \(bind: command.body), \(bind: revision), \(bind: ids.actor), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET body = EXCLUDED.body, revision = EXCLUDED.revision, updated_by_user_id = EXCLUDED.updated_by_user_id, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("INSERT INTO im_v2.group_announcement_operations (actor_user_id, operation_id, room_id, body, expected_revision, resulting_revision, room_sequence, event_id, created_at) VALUES (\(bind: ids.actor), \(bind: ids.operation), \(bind: ids.room), \(bind: command.body), \(bind: groupSigned(command.expectedRevision)), \(bind: revision), \(bind: committed.sequence), \(bind: committed.eventID), \(bind: now))").run()
            return .applied(try .init(roomID: command.roomID, body: command.body, revision: groupUnsigned(revision), roomSequence: groupUnsigned(committed.sequence), updatedAt: committed.createdAt))
        }
    }

    /// 设置角色权限（不校验房间归属）。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 角色权限命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 权限变更结果。
    /// - Throws: 无权限、修订冲突或持久化失败时抛出。
    public func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> {
        try await setRolePermissions(actorUserID: actorUserID, command: command, ownerRoute: nil, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    /// 按房间归属设置角色权限。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 角色权限命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 权限变更结果。
    /// - Throws: 归属已变更、无权限、修订冲突或持久化失败时抛出。
    public func setRolePermissionsOwnerValidated(actorUserID: UserID, command: V2GroupRolePermissionsCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> {
        try await setRolePermissions(actorUserID: actorUserID, command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    private func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange> {
        return try await groupTransaction(database, classifyCommitFailure: activationScope != nil) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID)
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            if let activationScope { try await activationScope.require([ids.room], sql: sql) }
            if activationScope == nil, let ownerRoute { try await v2RequireRoomOwner(roomID: ids.room, route: ownerRoute, sql: sql) }
            let permissionJSON = try groupPermissionsJSON(command.permissions)
            let expectedRevision = try groupSigned(command.expectedRevision)
            if let prior = try await sql.raw("SELECT room_id, expected_revision, resulting_revision, role, permissions::text AS permissions_json, room_sequence FROM im_v2.group_permission_operations WHERE actor_user_id = \(bind: ids.actor) AND operation_id = \(bind: ids.operation)").first(decoding: GroupPermissionOperationRow.self) {
                let value = try prior.value(roomID: command.roomID)
                // PostgreSQL 的 jsonb::text 会添加格式，且不保留请求编码器的原始写法。
                // 幂等性绑定的是集合本身。
                guard prior.roomID == ids.room, prior.expectedRevision == expectedRevision, prior.role == command.role.rawValue, value.permissions == command.permissions else { return .idempotencyConflict }
                return .idempotent(value)
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .permission(.changeMemberRoles), capacityProfile: capacityProfile, now: now, sql: sql)
            guard try groupUnsigned(context.room.groupPermissionRevision) == command.expectedRevision else { return .revisionConflict }
            guard context.room.groupPermissionRevision < Int64.max else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let revision = context.room.groupPermissionRevision + 1
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID, eventType: "group.role_permissions_changed", payload: try groupPayload(["event_type": "group.role_permissions_changed", "room_id": ids.room.uuidString, "role": command.role.rawValue, "permissions": command.permissions.map(\.rawValue).sorted(), "revision": revision, "actor_user_id": ids.actor.uuidString]), now: now, sql: sql)
            // 当前策略身份的存续期超过操作重放窗口，
            // 即使权限集合没有物化记录也是如此。
            try await sql.raw("INSERT INTO im_v2.group_role_policies (room_id, role) VALUES (\(bind: ids.room), \(bind: command.role.rawValue)) ON CONFLICT (room_id, role) DO NOTHING").run()
            try await sql.raw("DELETE FROM im_v2.group_role_permissions WHERE room_id = \(bind: ids.room) AND role = \(bind: command.role.rawValue)").run()
            for permission in command.permissions { try await sql.raw("INSERT INTO im_v2.group_role_permissions (room_id, role, permission) VALUES (\(bind: ids.room), \(bind: command.role.rawValue), \(bind: permission.rawValue))").run() }
            try await sql.raw("UPDATE im_v2.rooms SET group_permission_revision = \(bind: revision) WHERE room_id = \(bind: ids.room)").run()
            try await sql.raw("INSERT INTO im_v2.group_permission_operations (actor_user_id, operation_id, room_id, expected_revision, resulting_revision, role, permissions, room_sequence, event_id, created_at) VALUES (\(bind: ids.actor), \(bind: ids.operation), \(bind: ids.room), \(bind: groupSigned(command.expectedRevision)), \(bind: revision), \(bind: command.role.rawValue), \(bind: permissionJSON)::jsonb, \(bind: committed.sequence), \(bind: committed.eventID), \(bind: now))").run()
            return .applied(try .init(roomID: command.roomID, role: command.role, permissions: command.permissions, revision: groupUnsigned(revision), roomSequence: groupUnsigned(committed.sequence)))
        }
    }

    /// 调整成员角色（不校验房间归属）。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 成员角色命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 角色变更结果。
    /// - Throws: 目标非成员、无权限或持久化失败时抛出。
    public func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        try await changeMemberRole(actorUserID: actorUserID, command: command, ownerRoute: nil, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    /// 按房间归属调整成员角色。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 成员角色命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 角色变更结果。
    /// - Throws: 归属已变更、目标非成员、无权限或持久化失败时抛出。
    public func changeMemberRoleOwnerValidated(actorUserID: UserID, command: V2GroupMemberRoleCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        try await changeMemberRole(actorUserID: actorUserID, command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    private func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        return try await groupTransaction(database, classifyCommitFailure: activationScope != nil) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let ids = try groupIDs(actorUserID, command.operationID, command.roomID, command.targetUserID)
            guard let targetID = ids.target else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await groupLock(actor: ids.actor, operation: ids.operation, sql: sql)
            if let activationScope { try await activationScope.require([ids.room], sql: sql) }
            if activationScope == nil, let ownerRoute { try await v2RequireRoomOwner(roomID: ids.room, route: ownerRoute, sql: sql) }
            guard ids.actor != targetID else { return .alreadyInDesiredState }
            let expectedMembershipRevision = try groupSigned(command.expectedMembershipRevision)
            if let prior = try await sql.raw("SELECT room_id, target_user_id, role, expected_membership_revision, resulting_membership_revision, room_sequence FROM im_v2.group_role_operations WHERE actor_user_id = \(bind: ids.actor) AND operation_id = \(bind: ids.operation)").first(decoding: GroupRoleOperationRow.self) {
                guard prior.roomID == ids.room, prior.targetUserID == targetID, prior.role == command.role.rawValue, prior.expectedMembershipRevision == expectedMembershipRevision else { return .idempotencyConflict }
                return .idempotent(try prior.value(roomID: command.roomID, targetUserID: command.targetUserID))
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let context = try await prepare(room: ids.room, actor: ids.actor, required: .permission(.changeMemberRoles), capacityProfile: capacityProfile, now: now, sql: sql)
            guard try groupUnsigned(context.room.membershipRevision) == command.expectedMembershipRevision else { return .revisionConflict }
            guard let target = try await sql.raw("SELECT role, joined_revision FROM im_v2.room_memberships WHERE room_id = \(bind: ids.room) AND user_id = \(bind: targetID) AND joined_revision <= \(bind: context.room.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: context.room.membershipRevision)) ORDER BY joined_revision DESC LIMIT 1 FOR UPDATE").first(decoding: GroupMemberRow.self) else { throw V2GroupCapabilitiesStoreError.targetNotMember }
            guard target.role != .owner else { throw V2GroupCapabilitiesStoreError.actorNotAuthorized }
            guard target.role != command.role else { return .alreadyInDesiredState }
            guard context.room.membershipRevision < Int64.max else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            let membershipRevision = context.room.membershipRevision + 1
            let committed = try await commit(room: ids.room, context: context, actor: ids.actor, eventID: eventID, eventType: "group.member_role_changed", payload: try groupPayload(["event_type": "group.member_role_changed", "room_id": ids.room.uuidString, "target_user_id": targetID.uuidString, "role": command.role.rawValue, "membership_revision": membershipRevision, "actor_user_id": ids.actor.uuidString]), now: now, sql: sql)
            // 成员关系历史按修订记录。关闭当前有效记录并加入新的有效区间，
            // 以保持历史房间事件的可见性正确。
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = \(bind: membershipRevision) WHERE room_id = \(bind: ids.room) AND user_id = \(bind: targetID) AND joined_revision = \(bind: target.joinedRevision)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision, left_revision) VALUES (\(bind: ids.room), \(bind: targetID), \(bind: command.role.rawValue), \(bind: membershipRevision), NULL)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = \(bind: membershipRevision) WHERE room_id = \(bind: ids.room)").run()
            try await sql.raw("INSERT INTO im_v2.group_role_operations (actor_user_id, operation_id, room_id, target_user_id, role, expected_membership_revision, resulting_membership_revision, room_sequence, event_id, created_at) VALUES (\(bind: ids.actor), \(bind: ids.operation), \(bind: ids.room), \(bind: targetID), \(bind: command.role.rawValue), \(bind: groupSigned(command.expectedMembershipRevision)), \(bind: membershipRevision), \(bind: committed.sequence), \(bind: committed.eventID), \(bind: now))").run()
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
private func groupTransaction<Value: Equatable & Sendable>(
    _ database: any Database,
    classifyCommitFailure: Bool,
    _ body: @escaping @Sendable (any Database) async throws -> V2GroupCapabilitiesOutcome<Value>
) async throws -> V2GroupCapabilitiesOutcome<Value> {
    do {
        return try await v2WithPostgresTransactionRetry(
            database: database, maximumRetryCount: 0,
            classifyCommitFailure: classifyCommitFailure,
            useRoomDeadline: classifyCommitFailure, body
        )
    }
    catch let signal as GroupAdmissionSignal { switch signal { case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds); case .unavailable(let reason): return .unavailable(reason) } }
}

private struct GroupRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let groupPermissionRevision: Int64; let capacityProfileID: String; let roomKind: String; let capacityClass: V2GroupCapacityClass; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", groupPermissionRevision = "group_permission_revision", capacityProfileID = "capacity_profile_id", roomKind = "room_kind", capacityClass = "capacity_class" } }
private struct GroupMemberRow: Decodable { let role: V2RoomMembershipRole; let joinedRevision: Int64; enum CodingKeys: String, CodingKey { case role, joinedRevision = "joined_revision" } }
private struct GroupMessageRow: Decodable { let roomID: UUID; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", withdrawnAt = "withdrawn_at" } }
private struct GroupBoolRow: Decodable { let value: Bool }
private struct GroupRevisionRow: Decodable { let revision: Int64 }
private struct GroupAdmissionRow: Decodable { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64; enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)) } }
private struct GroupShardRow: Decodable { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: try groupUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))) } }
private struct GroupContext { let room: GroupRoomRow; let admission: GroupAdmissionRow; let nextRoom: RoomAdmissionState; let nextShard: ShardAdmissionState }
private struct GroupCommitted { let sequence: Int64; let eventID: UUID; let createdAt: Date }
private struct GroupCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}

private enum GroupAuthorizationRequirement { case permission(V2GroupPermission), owner, member }
private func prepare(room: UUID, actor: UUID, required: GroupAuthorizationRequirement, capacityProfile: V2CapacityProfile, now: Date, sql: any SQLDatabase) async throws -> GroupContext {
    guard let state = try await sql.raw("SELECT room_shard_id, room_sequence, membership_revision, group_permission_revision, capacity_profile_id, room_kind, capacity_class FROM im_v2.rooms WHERE room_id = \(bind: room) FOR NO KEY UPDATE").first(decoding: GroupRoomRow.self) else { throw V2GroupCapabilitiesStoreError.roomNotFound }
    guard state.roomKind == "group", state.capacityProfileID == capacityProfile.id else { throw state.roomKind == "group" ? V2GroupCapabilitiesStoreError.corruptPersistenceState : V2GroupCapabilitiesStoreError.notGroupRoom }
    guard let member = try await sql.raw("SELECT role, joined_revision FROM im_v2.room_memberships WHERE room_id = \(bind: room) AND user_id = \(bind: actor) AND joined_revision <= \(bind: state.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: state.membershipRevision)) ORDER BY joined_revision DESC LIMIT 1 FOR UPDATE").first(decoding: GroupMemberRow.self) else { throw V2GroupCapabilitiesStoreError.actorNotMember }
    switch required {
    case .member: break
    case .owner:
        guard member.role == .owner else { throw V2GroupCapabilitiesStoreError.actorNotAuthorized }
    case .permission(let permission):
        let configuredPermissions = try await v2ResolvedGroupPermissions(roomID: room, role: member.role, sql: sql)
        guard V2GroupPermissionDefaults.allows(role: member.role, permission: permission, configured: configuredPermissions) else { throw V2GroupCapabilitiesStoreError.actorNotAuthorized }
    }
    guard let admission = try await sql.raw("SELECT eligible_member_count, command_window_limit, command_window_used, shard_lease_id, shard_lease_generation FROM im_v2.room_admission WHERE room_id = \(bind: room) FOR UPDATE").first(decoding: GroupAdmissionRow.self), let shard = try await sql.raw("SELECT lease_id, generation, valid_until, command_window_limit, command_window_used FROM im_v2.shard_admission_pools WHERE room_shard_id = \(bind: state.roomShardID) AND capacity_profile_id = \(bind: state.capacityProfileID) FOR UPDATE").first(decoding: GroupShardRow.self), admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    switch try V2CommandAdmissionEvaluator.reserve(profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now) { case .accepted(_, let nextRoom, let nextShard): return .init(room: state, admission: admission, nextRoom: nextRoom, nextShard: nextShard); case .rateLimited(let seconds): throw GroupAdmissionSignal.rateLimited(seconds); case .unavailable(let reason): throw GroupAdmissionSignal.unavailable(reason) }
}

/// Runs in the nickname writer's owner-fenced transaction, sharing room command
/// admission and sequence allocation. The event deliberately contains no nickname text.
func v2AppendGroupNicknameInvalidation(room: UUID, actor: UUID, revision: Int64,
    capacityProfile: V2CapacityProfile, eventID: EventID, now: Date, sql: any SQLDatabase) async throws {
    do {
        let context = try await prepare(room: room, actor: actor, required: .member,
            capacityProfile: capacityProfile, now: now, sql: sql)
        let committed = try await commit(room: room, context: context, actor: actor, eventID: eventID,
            eventType: "group.nickname_changed", payload: groupPayload([
                "event_type": "group.nickname_changed", "room_id": room.uuidString,
                "target_user_id": actor.uuidString, "revision": revision
            ]), now: now, sql: sql)
        if context.room.capacityClass == .standard {
            // Large rooms already enqueue through the room-event trigger. Account
            // HTTP writes also need a durable wake for a quiet standard room.
            try await sql.raw("""
                INSERT INTO im_v2.group_event_wake_outbox
                    (room_id,target_room_sequence,revision,state,next_attempt_at,updated_at)
                VALUES(\(bind: room),\(bind: committed.sequence),1,'pending',\(bind: now),\(bind: now))
                ON CONFLICT(room_id) DO UPDATE SET
                    target_room_sequence=GREATEST(im_v2.group_event_wake_outbox.target_room_sequence,EXCLUDED.target_room_sequence),
                    revision=im_v2.group_event_wake_outbox.revision+1,state='pending',
                    lease_token=NULL,lease_expires_at=NULL,
                    next_attempt_at=LEAST(im_v2.group_event_wake_outbox.next_attempt_at,EXCLUDED.next_attempt_at),
                    updated_at=GREATEST(im_v2.group_event_wake_outbox.updated_at,EXCLUDED.updated_at)
                WHERE im_v2.group_event_wake_outbox.state='leased'
                """).run()
        }
    } catch let failure as GroupAdmissionSignal {
        switch failure {
        case .rateLimited: throw V2RoomCallFailure.rolledBack(.overloaded)
        case .unavailable: throw V2RoomCallFailure.rolledBack(.unavailable)
        }
    }
}
private enum GroupAdmissionSignal: Error { case rateLimited(Int); case unavailable(V2CommandAdmissionUnavailableReason) }
private func commit(room: UUID, context: GroupContext, actor: UUID, eventID: EventID, eventType: String, payload: String, now: Date, sql: any SQLDatabase) async throws -> GroupCommitted {
    guard let lease = context.nextShard.lease, context.room.roomSequence < Int64.max, let event = UUID(uuidString: eventID.rawValue) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    let sequence = context.room.roomSequence + 1
    guard let leaseID = UUID(uuidString: lease.id.rawValue) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    // 在既有序号更新期间通过 PostgreSQL 解码原始时钟值。
    // 响应和载荷使用该规范值；存储仍保留原始 Date，
    // 避免再次编码损失额外一微秒。
    guard let timestamp = try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: sequence) WHERE room_id = \(bind: room) RETURNING \(bind: now)::timestamptz AS created_at").first(decoding: GroupCommittedTimestampRow.self) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
    let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
    try await sql.raw("UPDATE im_v2.room_admission SET command_window_used = \(bind: context.nextRoom.commandWindow.used), shard_lease_id = \(bind: leaseID), shard_lease_generation = \(bind: try groupSigned(lease.generation)) WHERE room_id = \(bind: room)").run()
    try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used) WHERE room_shard_id = \(bind: context.room.roomShardID) AND capacity_profile_id = \(bind: context.room.capacityProfileID) AND lease_id = \(bind: leaseID) AND generation = \(bind: try groupSigned(lease.generation))").run()
    // 在追加操作使用的同一房间锁下分配源版本。
    // 个人状态投影保留此载荷，但自行分配游标。
    try await sql.raw("INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at) VALUES (\(bind: event), \(bind: room), \(bind: sequence), \(bind: eventType), \(bind: actor), \(bind: payload)::jsonb || jsonb_build_object('room_sequence', \(bind: sequence), 'server_created_at_ms', \(bind: createdAtMilliseconds)), \(bind: context.room.membershipRevision), \(bind: now))").run()
    return .init(sequence: sequence, eventID: event, createdAt: timestamp.createdAt)
}
private struct GroupPinOperationRow: Decodable { let roomID: UUID; let messageID: UUID; let isPinned: Bool; let roomSequence: Int64; let createdAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", isPinned = "is_pinned", roomSequence = "room_sequence", createdAt = "created_at" }; func value(roomID: RoomID, messageID: MessageID) throws -> V2PinnedMessage { try .init(roomID: roomID, messageID: messageID, isPinned: isPinned, roomSequence: groupUnsigned(roomSequence), updatedAt: createdAt) } }
private struct GroupAnnouncementOperationRow: Decodable { let roomID: UUID; let body: String; let expectedRevision: Int64; let resultingRevision: Int64; let roomSequence: Int64; let createdAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", body, expectedRevision = "expected_revision", resultingRevision = "resulting_revision", roomSequence = "room_sequence", createdAt = "created_at" }; func value(roomID: RoomID) throws -> V2GroupAnnouncement { try .init(roomID: roomID, body: body, revision: groupUnsigned(resultingRevision), roomSequence: groupUnsigned(roomSequence), updatedAt: createdAt) } }
private struct GroupPermissionOperationRow: Decodable { let roomID: UUID; let expectedRevision: Int64; let resultingRevision: Int64; let role: String; let permissionsJSON: String; let roomSequence: Int64; enum CodingKeys: String, CodingKey { case roomID = "room_id", expectedRevision = "expected_revision", resultingRevision = "resulting_revision", role, permissionsJSON = "permissions_json", roomSequence = "room_sequence" }; func value(roomID: RoomID) throws -> V2GroupRolePermissionsChange { guard let role = V2RoomMembershipRole(rawValue: role) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }; let values = try JSONDecoder().decode([String].self, from: Data(permissionsJSON.utf8)); let permissions = try Set(values.map { guard let value = V2GroupPermission(rawValue: $0) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }; return value }); return try .init(roomID: roomID, role: role, permissions: permissions, revision: groupUnsigned(resultingRevision), roomSequence: groupUnsigned(roomSequence)) } }
private struct GroupRoleOperationRow: Decodable { let roomID: UUID; let targetUserID: UUID; let role: String; let expectedMembershipRevision: Int64; let resultingMembershipRevision: Int64; let roomSequence: Int64; enum CodingKeys: String, CodingKey { case roomID = "room_id", targetUserID = "target_user_id", role, expectedMembershipRevision = "expected_membership_revision", resultingMembershipRevision = "resulting_membership_revision", roomSequence = "room_sequence" }; func value(roomID: RoomID, targetUserID: UserID) throws -> V2GroupMemberRoleChange { guard let role = V2RoomMembershipRole(rawValue: role) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }; return try .init(roomID: roomID, targetUserID: targetUserID, role: role, membershipRevision: groupUnsigned(resultingMembershipRevision), roomSequence: groupUnsigned(roomSequence)) } }

private struct GroupAvatarBindingRow: Decodable {
    let mediaID: UUID?; let revision: Int64
    enum CodingKeys: String, CodingKey { case mediaID = "media_id", revision }
}
private struct GroupAvatarOperationRow: Decodable {
    let roomID: UUID; let mediaID: UUID?; let expectedRevision: Int64
    let resultingRevision: Int64; let roomSequence: Int64; let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", mediaID = "requested_media_id", expectedRevision = "expected_revision"
        case resultingRevision = "resulting_revision", roomSequence = "room_sequence", createdAt = "created_at"
    }
    func value() throws -> V2GroupAvatarChange {
        try .init(state: .init(roomID: .init(uuid: roomID), mediaID: mediaID.map { .init(uuid: $0) }, revision: groupUnsigned(resultingRevision)),
                  roomSequence: groupUnsigned(roomSequence), updatedAt: createdAt)
    }
}
private struct GroupAvatarClosureRow: Decodable {
    let roomID: UUID; let mediaID: UUID?; let expectedRevision: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", mediaID = "requested_media_id", expectedRevision = "expected_revision"
    }
    func matches(_ command: V2GroupAvatarCommand) -> Bool {
        roomID == command.roomID.uuidValue && mediaID == command.mutation.mediaID?.uuidValue
            && expectedRevision >= 0 && UInt64(expectedRevision) == command.expectedRevision
    }
}
