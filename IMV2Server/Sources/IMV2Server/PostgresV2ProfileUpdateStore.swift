import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 本人资料写入实现。
///
/// 头像必须在同一事务内同时满足「属于发起者」与「扫描已通过」，
/// 且与该次资料修订、持久化的私聊对端失效源记录一起提交。
public struct PostgresV2ProfileUpdateStore: V2ProfileUpdateStore, V2OwnProfileReading {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    /// 组合数据库与标识、授时来源。
    ///
    /// - Parameters:
    ///   - database: 存放公开资料、资料操作与失效源记录的数据库。
    ///   - makeUUID: 传播源记录标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        database: any Database,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 应用一次本人资料变更。
    ///
    /// 事务先读取并锁定当前资料行，使并发重试能看到其等待期间提交的操作，再检查修订与时钟。
    /// 已有同一操作记录时校验载荷一致并返回当前权威视图；否则更新资料修订、写入传播源记录
    /// 并登记操作结果。
    ///
    /// - Parameter command: 资料变更命令。
    /// - Returns: 变更结果。
    /// - Throws: 标识无法解析或持久化状态异常时抛出
    ///   ``V2ProfileUpdateError/corruptPersistenceState``；同一操作标识载荷不一致时抛出
    ///   ``V2ProfileUpdateError/operationPayloadMismatch``；修订冲突时抛出
    ///   ``V2ProfileUpdateError/revisionConflict(current:)``；头像不可用时抛出
    ///   ``V2ProfileUpdateError/avatarUnavailable``。
    public func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateOutcome {
        guard let actorID = UUID(uuidString: command.actorUserID.rawValue),
              let operationID = UUID(uuidString: command.operationID.rawValue)
        else { throw V2ProfileUpdateError.corruptPersistenceState }
        let requestedAvatarID = try command.avatar.map { avatar -> UUID in
            guard let value = UUID(uuidString: avatar.mediaID.rawValue) else {
                throw V2ProfileUpdateError.corruptPersistenceState
            }
            return value
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ProfileUpdateError.corruptPersistenceState
            }
            // 在此记录上串行化台账读取与修改。并发重试在检查修订号或时钟前，
            // 必须看到它等待的写入方已提交的操作。
            let current = try await activeProfile(userID: actorID, sql: sql)
            if let operation = try await operation(actorID: actorID, operationID: operationID, sql: sql) {
                guard operation.matches(command: command) else {
                    throw V2ProfileUpdateError.operationPayloadMismatch
                }
                guard operation.resultRevision > 0 else {
                    throw V2ProfileUpdateError.corruptPersistenceState
                }
                // 后续操作可能已经推进此资料。返回当前权威视图
                // 比重放旧状态更安全；操作台账仍保证此次重试
                // 不会创建第二个源事件。
                return .idempotent(current)
            }

            guard current.revision == command.expectedRevision else {
                throw V2ProfileUpdateError.revisionConflict(current: current.revision)
            }
            if let requestedAvatarID,
               try await sql.raw("""
                    SELECT 1 FROM im_v2.media_objects
                    WHERE media_id = \(bind: requestedAvatarID)
                      AND owner_user_id = \(bind: actorID)
                      AND state = 'available'
                    """).first() == nil {
                throw V2ProfileUpdateError.avatarUnavailable
            }

            let changedAt = now()
            guard v2PostgresTimestampCanEncode(changedAt) else { throw V2ProfileUpdateError.corruptPersistenceState }
            let changed = current.publicIdentity?.displayName != command.displayName || current.avatar != command.avatar
            let result: V2ProfileView
            if changed {
                guard current.revision.rawValue < UInt64(Int64.max),
                      current.visibilityRevision.rawValue < UInt64(Int64.max)
                else { throw V2ProfileUpdateError.corruptPersistenceState }
                guard let updated = try await sql.raw("""
                    UPDATE im_v2.public_user_profiles
                    SET display_name = \(bind: command.displayName),
                        avatar_media_id = \(bind: requestedAvatarID),
                        revision = revision + 1,
                        visibility_revision = visibility_revision + 1,
                        updated_at = \(bind: changedAt)
                    WHERE user_id = \(bind: actorID) AND state = 'active'
                    RETURNING user_id, public_handle, display_name, avatar_media_id,
                              account_kind, state, revision, visibility_revision
                    """).first(decoding: UpdatedProfileRow.self) else {
                    throw V2ProfileUpdateError.unavailable
                }
                result = try updated.profileView()
                guard let identity = result.publicIdentity else {
                    throw V2ProfileUpdateError.corruptPersistenceState
                }
                try await sql.raw("""
                    INSERT INTO im_v2.public_profile_update_outbox
                    (source_event_id, source_user_id, public_handle, display_name, account_kind, profile_state, revision, profile_updated_at, created_at)
                    VALUES (\(bind: makeUUID()), \(bind: actorID), \(bind: identity.handle.rawValue),
                            \(bind: identity.displayName), \(bind: identity.accountKind.rawValue), 'active', \(bind: result.revision.signedValue), \(bind: changedAt), \(bind: changedAt))
                    """).run()
            } else {
                result = current
            }
            try await sql.raw("""
                INSERT INTO im_v2.public_profile_update_operations
                    (actor_user_id, operation_id, expected_revision, requested_display_name,
                     requested_avatar_media_id, result_revision, created_at)
                VALUES (\(bind: actorID), \(bind: operationID), \(bind: command.expectedRevision.signedValue),
                        \(bind: command.displayName), \(bind: requestedAvatarID),
                        \(bind: result.revision.signedValue), \(bind: changedAt))
                """).run()
            return .updated(result)
        }
    }

    /// 读取发起者当前的本人资料。
    ///
    /// - Parameter actorUserID: 目标用户。
    /// - Returns: 当前资料视图。
    /// - Throws: 标识无法解析、资料不存在或持久化失败时抛出
    ///   ``V2ProfileUpdateError/corruptPersistenceState``。
    public func currentProfile(for actorUserID: UserID) async throws -> V2ProfileView {
        guard let actorID = UUID(uuidString: actorUserID.rawValue) else {
            throw V2ProfileUpdateError.corruptPersistenceState
        }
        guard let sql = database as? any SQLDatabase else {
            throw V2ProfileUpdateError.corruptPersistenceState
        }
        return try await readActiveProfile(userID: actorID, sql: sql)
    }

    private func operation(actorID: UUID, operationID: UUID, sql: any SQLDatabase) async throws -> ProfileOperationRow? {
        try await sql.raw("""
            SELECT expected_revision, requested_display_name, requested_avatar_media_id, result_revision
            FROM im_v2.public_profile_update_operations
            WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
            """).first(decoding: ProfileOperationRow.self)
    }

    private func activeProfile(userID: UUID, sql: any SQLDatabase) async throws -> V2ProfileView {
        guard let row = try await sql.raw("""
            SELECT p.user_id, p.public_handle, p.display_name, p.account_kind,
                   CASE WHEN avatar.owner_user_id = p.user_id AND avatar.state = 'available'
                        THEN avatar.media_id ELSE NULL END AS avatar_media_id,
                   p.state, p.revision, p.visibility_revision
            FROM im_v2.public_user_profiles AS p
            LEFT JOIN im_v2.media_objects AS avatar ON avatar.media_id = p.avatar_media_id
            WHERE p.user_id = \(bind: userID)
            FOR UPDATE OF p
            """).first(decoding: UpdatedProfileRow.self) else {
            throw V2ProfileUpdateError.unavailable
        }
        let view = try row.profileView()
        guard view.state == .active else { throw V2ProfileUpdateError.unavailable }
        return view
    }

    private func readActiveProfile(userID: UUID, sql: any SQLDatabase) async throws -> V2ProfileView {
        guard let row = try await sql.raw("""
            SELECT p.user_id, p.public_handle, p.display_name, p.account_kind,
                   CASE WHEN avatar.owner_user_id = p.user_id AND avatar.state = 'available'
                        THEN avatar.media_id ELSE NULL END AS avatar_media_id,
                   p.state, p.revision, p.visibility_revision
            FROM im_v2.public_user_profiles AS p
            LEFT JOIN im_v2.media_objects AS avatar ON avatar.media_id = p.avatar_media_id
            WHERE p.user_id = \(bind: userID)
            """).first(decoding: UpdatedProfileRow.self) else {
            throw V2ProfileUpdateError.unavailable
        }
        let view = try row.profileView()
        guard view.state == .active else { throw V2ProfileUpdateError.unavailable }
        return view
    }
}

private struct ProfileOperationRow: Decodable {
    let expectedRevision: Int64
    let requestedDisplayName: String
    let requestedAvatarMediaID: UUID?
    let resultRevision: Int64

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case requestedDisplayName = "requested_display_name"
        case requestedAvatarMediaID = "requested_avatar_media_id"
        case resultRevision = "result_revision"
    }

    func matches(command: V2ProfileUpdateCommand) -> Bool {
        // 旧写入方校验规范化名称，但记录原始输入。
        // 保持这些操作在相同名称语义下可重放。
        let normalizedName = requestedDisplayName.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return expectedRevision > 0 && UInt64(expectedRevision) == command.expectedRevision.rawValue &&
            normalizedName == command.displayName &&
            requestedAvatarMediaID?.uuidString == command.avatar?.mediaID.rawValue
    }
}

private struct UpdatedProfileRow: Decodable {
    let userID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let avatarMediaID: UUID?
    let state: String
    let revision: Int64
    let visibilityRevision: Int64

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case avatarMediaID = "avatar_media_id"
        case state
        case revision
        case visibilityRevision = "visibility_revision"
    }

    func profileView() throws -> V2ProfileView {
        guard let userID = try? UserID(userID.uuidString),
              let state = V2ProfileState(rawValue: state),
              let accountKind = V2AccountKind(rawValue: accountKind),
              let revision = V2ProfileRevision(rawValue: UInt64(revision)),
              let visibilityRevision = V2ProfileRevision(rawValue: UInt64(visibilityRevision))
        else { throw V2ProfileUpdateError.corruptPersistenceState }
        guard state == .active else { throw V2ProfileUpdateError.unavailable }
        return try .init(
            userID: userID,
            publicIdentity: .init(userID: userID, handle: .init(publicHandle), displayName: displayName, accountKind: accountKind),
            avatar: try avatarMediaID.map { try .init(mediaID: .init($0.uuidString)) },
            state: state,
            revision: revision,
            visibilityRevision: visibilityRevision
        )
    }
}
