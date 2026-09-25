import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 会话能力变更的通用结果。
///
/// `Value` 为变更后的领域值；幂等重放会返回与此前一致的取值。
public enum V2ConversationCapabilitiesOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    /// 本次调用实际完成了变更。
    case applied(Value)
    /// 该操作此前已成功提交，本次为重放，返回相同结果。
    case idempotent(Value)
    /// 同一操作标识提交了与首次不同的载荷。
    case idempotencyConflict
}

/// 会话能力存储的错误分类。
public enum V2ConversationCapabilitiesStoreError: Error, Equatable, Sendable {
    /// 目标房间不存在。
    case roomNotFound
    /// 目标消息不存在或不属于该房间。
    case messageNotFound
    /// 发起者不是房间的活跃成员。
    case actorNotMember
    /// 时间戳无法被 PostgreSQL 时间类型编码。
    case invalidTimestamp
    /// 持久化状态与预期不一致。
    case corruptPersistenceState
}

/// 会话能力（会话状态与消息收藏）的持久化边界。
public protocol V2ConversationCapabilitiesStore: Sendable {
    /// 设置房间置顶、归档与免打扰等会话状态。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起变更的用户。
    ///   - command: 会话状态命令，携带操作标识以支持幂等重试。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 非成员、时间戳非法或持久化失败时抛出。
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState>
    /// 设置或取消某条消息的收藏。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起变更的用户。
    ///   - command: 收藏命令，携带操作标识以支持幂等重试。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 非成员、消息不存在或持久化失败时抛出。
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite>
}

/// 会话能力服务。
///
/// 它在调用存储前统一注入服务端时钟，保证同一次请求内的时间语义一致。
public struct V2ConversationCapabilitiesService: Sendable {
    private let store: any V2ConversationCapabilitiesStore
    private let now: @Sendable () -> Date
    /// 创建会话能力服务。
    ///
    /// - Parameters:
    ///   - store: 会话能力持久化边界。
    ///   - now: 服务端时钟，默认取当前时间。
    public init(store: any V2ConversationCapabilitiesStore, now: @escaping @Sendable () -> Date = Date.init) { self.store = store; self.now = now }
    /// 设置会话状态。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起变更的用户。
    ///   - command: 会话状态命令。
    /// - Returns: 变更结果。
    /// - Throws: 存储拒绝或持久化失败时抛出。
    public func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState> { try await store.setConversationState(actorUserID: actorUserID, command: command, now: now()) }
    /// 设置或取消消息收藏。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起变更的用户。
    ///   - command: 收藏命令。
    /// - Returns: 变更结果。
    /// - Throws: 存储拒绝或持久化失败时抛出。
    public func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite> { try await store.setMessageFavorite(actorUserID: actorUserID, command: command, now: now()) }
}

/// 会话能力的 PostgreSQL 持久化实现。
///
/// 每次变更都在单事务内完成操作台账写入、权威状态更新与用户同步投影，
/// 并在事务提交之后按需把控制面记录投递到用户的当前写入归属。
public struct PostgresV2ConversationCapabilitiesStore: V2ConversationCapabilitiesStore {
    private let database: any Database
    private let projectionDelivery: any V2UserShardProjectionDelivering
    /// 创建 PostgreSQL 会话能力存储。
    ///
    /// - Parameters:
    ///   - database: 控制面数据库连接。
    ///   - projectionDelivery: 提交后投递控制面投影到当前用户分片的实现。
    public init(database: any Database, projectionDelivery: any V2UserShardProjectionDelivering) { self.database = database; self.projectionDelivery = projectionDelivery }

    /// 设置会话状态，并把结果投影到发送者的用户同步日志。
    ///
    /// 先锁定操作台账身份再读取，使并发重试可以观察到刚提交的操作。
    /// 免打扰时间在 PostgreSQL 内比较，避免 Swift 侧二次量化引入的微秒差异被误判为载荷冲突。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起变更的用户。
    ///   - command: 会话状态命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 时间戳非法、非成员或持久化失败时抛出。
    public func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState> {
        if let muteUntil = command.muteUntil, !v2PostgresTimestampCanEncode(muteUntil) {
            throw V2ConversationCapabilitiesStoreError.invalidTimestamp
        }
        let result: V2ConversationCapabilitiesOutcome<V2ConversationState> = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let actor = try capabilityUUID(actorUserID), room = try capabilityUUID(command.roomID), operation = try capabilityUUID(command.operationID)
            try await lockOperation(actor: actor, operation: operation, kind: "conversation", sql: sql)
            if let prior = try await sql.raw("SELECT room_id, pinned_at, archived_at, mute_until, updated_at, mute_until IS NOT DISTINCT FROM \(bind: command.muteUntil) AS mute_matches FROM im_v2.user_room_preference_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)").first(decoding: ConversationStateRow.self) {
                guard prior.roomID == room, (prior.pinnedAt != nil) == command.isPinned, (prior.archivedAt != nil) == command.isArchived else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(prior.updatedAt), prior.muteUntil.map(v2PostgresTimestampCanEncode) ?? true else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
                // 在 PostgreSQL 中比较，使重试采用与原始绑定参数
                // 相同的微秒量化方式。
                guard prior.muteMatches else { return .idempotencyConflict }
                return .idempotent(try prior.value())
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            try await assertActiveMember(actor: actor, room: room, sql: sql)
            let pinnedAt = command.isPinned ? now : nil, archivedAt = command.isArchived ? now : nil
            try await sql.raw("INSERT INTO im_v2.user_room_preferences (user_id, room_id, pinned_at, archived_at, mute_until, updated_at) VALUES (\(bind: actor), \(bind: room), \(bind: pinnedAt), \(bind: archivedAt), \(bind: command.muteUntil), \(bind: now)) ON CONFLICT (user_id, room_id) DO UPDATE SET pinned_at = EXCLUDED.pinned_at, archived_at = EXCLUDED.archived_at, mute_until = EXCLUDED.mute_until, updated_at = EXCLUDED.updated_at").run()
            guard let persisted = try await sql.raw("INSERT INTO im_v2.user_room_preference_operations (actor_user_id, operation_id, room_id, pinned_at, archived_at, mute_until, updated_at) VALUES (\(bind: actor), \(bind: operation), \(bind: room), \(bind: pinnedAt), \(bind: archivedAt), \(bind: command.muteUntil), \(bind: now)) RETURNING room_id, pinned_at, archived_at, mute_until, updated_at, TRUE AS mute_matches").first(decoding: ConversationStateRow.self) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let value = try persisted.value()
            try await appendStateProjection(actor: actor, source: operation, value: value, now: now, sql: sql)
            return .applied(value)
        }
        switch result {
        case .applied, .idempotent:
            try await deliverProjection(actor: actorUserID, operation: command.operationID.rawValue, kinds: ["conversation_state"])
        case .idempotencyConflict:
            break
        }
        return result
    }

    /// 设置或取消消息收藏，并把结果投影到发送者的用户同步日志。
    ///
    /// 与设置会话状态相同，操作台账加锁先于读取；消息必须属于目标房间才会被接受。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起变更的用户。
    ///   - command: 收藏命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 非成员、消息不存在或持久化失败时抛出。
    public func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite> {
        let result: V2ConversationCapabilitiesOutcome<V2MessageFavorite> = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let actor = try capabilityUUID(actorUserID), room = try capabilityUUID(command.roomID), message = try capabilityUUID(command.messageID), operation = try capabilityUUID(command.operationID)
            try await lockOperation(actor: actor, operation: operation, kind: "favorite", sql: sql)
            if let prior = try await sql.raw("SELECT room_id, message_id, is_favorited, updated_at FROM im_v2.user_message_favorite_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)").first(decoding: FavoriteRow.self) {
                guard prior.roomID == room, prior.messageID == message, prior.isFavorited == command.isFavorited else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(prior.updatedAt) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
                return .idempotent(try prior.value())
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            try await assertActiveMember(actor: actor, room: room, sql: sql)
            let messageInRoom = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.messages WHERE message_id = \(bind: message) AND room_id = \(bind: room)) AS value").first(decoding: CapabilityBooleanRow.self)?.value ?? false
            guard messageInRoom else { throw V2ConversationCapabilitiesStoreError.messageNotFound }
            if command.isFavorited { try await sql.raw("INSERT INTO im_v2.user_message_favorites (user_id, message_id, room_id, created_at) VALUES (\(bind: actor), \(bind: message), \(bind: room), \(bind: now)) ON CONFLICT DO NOTHING").run() }
            else { try await sql.raw("DELETE FROM im_v2.user_message_favorites WHERE user_id = \(bind: actor) AND message_id = \(bind: message)").run() }
            guard let persisted = try await sql.raw("INSERT INTO im_v2.user_message_favorite_operations (actor_user_id, operation_id, message_id, room_id, is_favorited, updated_at) VALUES (\(bind: actor), \(bind: operation), \(bind: message), \(bind: room), \(bind: command.isFavorited), \(bind: now)) RETURNING room_id, message_id, is_favorited, updated_at").first(decoding: FavoriteRow.self) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let value = try persisted.value()
            try await appendFavoriteProjection(actor: actor, source: operation, value: value, now: now, sql: sql)
            return .applied(value)
        }
        switch result {
        case .applied, .idempotent:
            try await deliverProjection(actor: actorUserID, operation: command.operationID.rawValue, kinds: ["message_favorite"])
        case .idempotencyConflict:
            break
        }
        return result
    }

    private func lockOperation(actor: UUID, operation: UUID, kind: String, sql: any SQLDatabase) async throws {
        // 读取前先锁定台账身份。单靠房间锁或状态锁，
        // 不能保证并发重试看见新提交的操作。
        let key = "personal-preference:" + kind + ":" + actor.uuidString + ":" + operation.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    private func assertActiveMember(actor: UUID, room: UUID, sql: any SQLDatabase) async throws {
        guard let revision = try await sql.raw("SELECT membership_revision FROM im_v2.rooms WHERE room_id = \(bind: room) FOR UPDATE").first(decoding: CapabilityRoomRow.self)?.membershipRevision else { throw V2ConversationCapabilitiesStoreError.roomNotFound }
        let member = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_memberships WHERE room_id = \(bind: room) AND user_id = \(bind: actor) AND joined_revision <= \(bind: revision) AND (left_revision IS NULL OR left_revision > \(bind: revision))) AS value").first(decoding: CapabilityBooleanRow.self)?.value ?? false
        guard member else { throw V2ConversationCapabilitiesStoreError.actorNotMember }
    }
    // 向存储绑定原始时钟值；响应日期解码后若重新编码，可能再损失一微秒。
    // 载荷时间戳使用已提交值。
    private func appendStateProjection(actor: UUID, source: UUID, value: V2ConversationState, now: Date, sql: any SQLDatabase) async throws { let sequence = try await nextSequence(actor: actor, sql: sql); try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: actor), \(bind: sequence), \(bind: source), 'conversation_state', jsonb_build_object('room_id', \(bind: value.roomID.rawValue), 'is_pinned', \(bind: value.isPinned), 'is_archived', \(bind: value.isArchived), 'mute_until_ms', \(bind: value.muteUntil.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0), 'updated_at_ms', \(bind: Int64(value.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: now))").run() }
    private func appendFavoriteProjection(actor: UUID, source: UUID, value: V2MessageFavorite, now: Date, sql: any SQLDatabase) async throws { let sequence = try await nextSequence(actor: actor, sql: sql); try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: actor), \(bind: sequence), \(bind: source), 'message_favorite', jsonb_build_object('room_id', \(bind: value.roomID.rawValue), 'message_id', \(bind: value.messageID.rawValue), 'is_favorited', \(bind: value.isFavorited), 'updated_at_ms', \(bind: Int64(value.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: now))").run() }
    private func nextSequence(actor: UUID, sql: any SQLDatabase) async throws -> Int64 { guard let result = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: actor), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 WHERE im_v2.user_sync_sequences.next_sequence < \(bind: Int64.max) RETURNING next_sequence").first(decoding: CapabilitySyncRow.self)?.sequence else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }; return result }
    private func deliverProjection(actor: UserID, operation: String, kinds: Set<String>) async throws { _ = try await projectionDelivery.deliverToCurrentShard(userID: actor, sourceEventID: .init(operation), projectionKinds: kinds) }
}
private struct ConversationStateRow: Decodable { let muteMatches: Bool; let roomID: UUID; let pinnedAt: Date?; let archivedAt: Date?; let muteUntil: Date?; let updatedAt: Date; enum CodingKeys: String, CodingKey { case muteMatches = "mute_matches", roomID = "room_id", pinnedAt = "pinned_at", archivedAt = "archived_at", muteUntil = "mute_until", updatedAt = "updated_at" }; func value() throws -> V2ConversationState { try .init(roomID: .init(roomID.uuidString), isPinned: pinnedAt != nil, isArchived: archivedAt != nil, muteUntil: muteUntil, updatedAt: updatedAt) } }
private struct FavoriteRow: Decodable { let roomID: UUID; let messageID: UUID; let isFavorited: Bool; let updatedAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", isFavorited = "is_favorited", updatedAt = "updated_at" }; func value() throws -> V2MessageFavorite { try .init(roomID: .init(roomID.uuidString), messageID: .init(messageID.uuidString), isFavorited: isFavorited, updatedAt: updatedAt) } }
private struct CapabilityRoomRow: Decodable { let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision" } }
private struct CapabilityBooleanRow: Decodable { let value: Bool }
private struct CapabilitySyncRow: Decodable { let sequence: Int64; enum CodingKeys: String, CodingKey { case sequence = "next_sequence" } }
private func capabilityUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let uuid = UUID(uuidString: id.rawValue) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }; return uuid }
