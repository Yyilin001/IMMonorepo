import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 资料展示（联系人备注与群昵称）的 PostgreSQL 持久化实现。
///
/// 所有写入都以操作台账保证幂等，并按修订做乐观并发校验。
public struct PostgresV2ProfilePresentationStore: V2ProfilePresentationManaging {
    private let database: any Database
    private let now: @Sendable () -> Date
    private let nicknameScope: (roomID: RoomID, route: V2RoomShardRoute)?
    private let activationScope: V2RoomActivationWriteScope?

    /// 创建资料展示存储。
    ///
    /// - Parameters:
    ///   - database: 控制面数据库连接。
    ///   - now: 服务端时钟，默认取当前时间。
    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
        self.nicknameScope = nil
        self.activationScope = nil
    }

    /// 仅用于固定的房间 Actor 轮次；所有昵称读写都会重新校验完整令牌。
    public init(database: any Database, activationScope: V2RoomActivationWriteScope,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
        self.nicknameScope = nil
        self.activationScope = activationScope
    }

    init(database: any Database, roomID: RoomID, ownerRoute: V2RoomShardRoute, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.now = now
        self.nicknameScope = (roomID, ownerRoute)
        self.activationScope = nil
    }

    /// 按目标用户游标分页读取联系人备注。
    ///
    /// - Parameters:
    ///   - ownerUserID: 拥有这批备注的用户。
    ///   - afterTargetUserID: 分页起点之后的目标用户，首页传 `nil`。
    ///   - limit: 本次返回条数，必须落在 1…500 之间。
    /// - Returns: 备注分页，含下一页游标。
    /// - Throws: 条数越界、标识符非法或持久化状态损坏时抛出。
    public func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int) async throws -> V2ContactAliasPage {
        guard (1...500).contains(limit) else { throw V2ProfilePresentationError.invalidPresentation }
        let owner = try uuid(ownerUserID)
        let afterTarget = try afterTargetUserID.map(uuid)
        guard let sql = database as? any SQLDatabase else { throw V2ProfilePresentationError.corruptPersistenceState }
        let rows = try await sql.raw("""
            SELECT alias.target_user_id, alias.remark_name, alias.revision
            FROM im_v2.user_contact_aliases AS alias
            WHERE alias.owner_user_id = \(bind: owner)
              AND (\(bind: afterTarget) IS NULL OR alias.target_user_id > \(bind: afterTarget))
              AND EXISTS (
                  SELECT 1 FROM im_v2.user_relationships AS relationship
                  WHERE relationship.state IN ('pending', 'accepted')
                    AND ((relationship.lower_user_id = alias.owner_user_id AND relationship.higher_user_id = alias.target_user_id)
                      OR (relationship.higher_user_id = alias.owner_user_id AND relationship.lower_user_id = alias.target_user_id))
              )
            ORDER BY alias.target_user_id
            LIMIT \(bind: limit + 1)
            """).all(decoding: AliasRow.self)
        let values = try rows.prefix(limit).map { try $0.alias(owner: ownerUserID) }
        return .init(values: values, nextCursor: rows.count > limit ? values.last?.targetUserID : nil)
    }

    /// 写入或清除某个联系人的备注名。
    ///
    /// - Parameters:
    ///   - ownerUserID: 拥有该备注的用户。
    ///   - targetUserID: 被备注的目标用户。
    ///   - operationID: 该次操作的稳定标识，用于幂等重试。
    ///   - expectedRevision: 期望的当前修订，`nil` 表示不校验。
    ///   - remarkName: 新的备注名；传 `nil` 表示清除。
    /// - Returns: 写入后的备注记录。
    /// - Throws: 修订冲突、载荷不匹配、内容非法或持久化失败时抛出。
    public func updateContactAlias(ownerUserID: UserID, targetUserID: UserID, operationID: ContactAliasOperationID, expectedRevision: V2ProfileRevision?, remarkName: String?) async throws -> V2ContactAlias {
        let validated = try V2ContactAlias(ownerUserID: ownerUserID, targetUserID: targetUserID, remarkName: remarkName, revision: .init(rawValue: 1)!)
        let normalizedRemarkName = validated.remarkName
        let expectedSignedRevision = try signed(expectedRevision)
        let owner = try uuid(ownerUserID), target = try uuid(targetUserID), operation = try uuid(operationID)
        return try await database.transaction { transaction -> V2ContactAlias in
            guard let sql = transaction as? any SQLDatabase else { throw V2ProfilePresentationError.corruptPersistenceState }
            try await presentationLock(scope: owner.uuidString + ":alias-operation:" + operation.uuidString, sql: sql)
            try await presentationLock(scope: owner.uuidString + ":alias:" + target.uuidString, sql: sql)
            if let saved = try await aliasOperation(owner: owner, operation: operation, sql: sql) {
                guard saved.target == target, saved.expectedRevision == expectedSignedRevision, saved.remarkName == normalizedRemarkName,
                      saved.resultRevision > 0,
                      let revision = V2ProfileRevision(rawValue: UInt64(saved.resultRevision))
                else { throw V2ProfilePresentationError.operationPayloadMismatch }
                return try .init(ownerUserID: ownerUserID, targetUserID: targetUserID, remarkName: saved.remarkName, revision: revision)
            }
            guard try await relationshipExists(owner: owner, target: target, sql: sql) else { throw V2ProfilePresentationError.forbidden }
            let current = try await aliasRow(owner: owner, target: target, sql: sql)
            guard current?.revision == expectedSignedRevision else { throw V2ProfilePresentationError.revisionConflict(current?.profileRevision) }
            let revision = try nextPresentationRevision(current: current?.revision, unchanged: current?.remarkName == normalizedRemarkName)
            let changedAt = now()
            guard v2PostgresTimestampCanEncode(changedAt) else { throw V2ProfilePresentationError.corruptPersistenceState }
            try await sql.raw("INSERT INTO im_v2.user_contact_aliases (owner_user_id, target_user_id, remark_name, revision, updated_at) VALUES (\(bind: owner), \(bind: target), \(bind: normalizedRemarkName), \(bind: revision), \(bind: changedAt)) ON CONFLICT (owner_user_id, target_user_id) DO UPDATE SET remark_name = EXCLUDED.remark_name, revision = EXCLUDED.revision, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("INSERT INTO im_v2.user_contact_alias_operations (owner_user_id, operation_id, target_user_id, expected_revision, requested_remark_name, result_revision, created_at) VALUES (\(bind: owner), \(bind: operation), \(bind: target), \(bind: expectedSignedRevision), \(bind: normalizedRemarkName), \(bind: revision), \(bind: changedAt))").run()
            return try V2ContactAlias(ownerUserID: ownerUserID, targetUserID: targetUserID, remarkName: normalizedRemarkName, revision: .init(rawValue: UInt64(revision))!)
        }
    }

    /// 按成员游标分页读取群昵称展示。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起读取的成员。
    ///   - roomID: 目标群组房间。
    ///   - afterUserID: 分页起点之后的成员，首页传 `nil`。
    ///   - limit: 本次返回条数，必须落在允许区间内。
    /// - Returns: 群昵称分页，含下一页游标。
    /// - Throws: 无权限、条数越界或持久化状态损坏时抛出。
    public func groupNicknames(actorUserID: UserID, roomID: RoomID, afterUserID: UserID?, limit: Int) async throws -> V2GroupNicknamePage {
        if activationScope != nil || nicknameScope != nil {
            return try await v2WithPostgresTransactionRetry(
                database: database, maximumRetryCount: 0,
                classifyCommitFailure: false, useRoomDeadline: activationScope != nil
            ) { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw V2ProfilePresentationError.corruptPersistenceState }
                let room = try uuid(roomID)
                if let activationScope {
                    try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
                    try await activationScope.require([room], sql: sql)
                } else if let scope = nicknameScope {
                    guard scope.roomID == roomID else { throw V2RoomOwnerFenceError.ownerChanged }
                    try await v2RequireRoomOwner(roomID: room, route: scope.route, sql: sql)
                }
                return try await readGroupNicknames(actorUserID: actorUserID, roomID: roomID,
                                                    afterUserID: afterUserID, limit: limit, sql: sql)
            }
        }
        guard let sql = database as? any SQLDatabase else { throw V2ProfilePresentationError.corruptPersistenceState }
        return try await readGroupNicknames(actorUserID: actorUserID, roomID: roomID, afterUserID: afterUserID, limit: limit, sql: sql)
    }

    private func readGroupNicknames(actorUserID: UserID, roomID: RoomID, afterUserID: UserID?, limit: Int, sql: any SQLDatabase) async throws -> V2GroupNicknamePage {
        guard (1...500).contains(limit) else { throw V2ProfilePresentationError.invalidPresentation }
        let actor = try uuid(actorUserID), room = try uuid(roomID)
        let afterUser = try afterUserID.map(uuid)
        let rows = try await sql.raw("""
            WITH nickname_authorization AS MATERIALIZED (
                SELECT EXISTS (
                    SELECT 1
                    FROM im_v2.rooms AS room
                    JOIN im_v2.room_memberships AS membership
                      ON membership.room_id = room.room_id
                     AND membership.user_id = \(bind: actor)
                     AND membership.joined_revision <= room.membership_revision
                     AND (membership.left_revision IS NULL
                          OR membership.left_revision > room.membership_revision)
                    WHERE room.room_id = \(bind: room)
                      AND room.room_kind = 'group'
                ) AS authorized
            ), page AS MATERIALIZED (
                SELECT nickname.user_id, nickname.nickname, nickname.revision
                FROM im_v2.room_member_nicknames AS nickname
                JOIN im_v2.rooms AS room ON room.room_id = nickname.room_id
                WHERE (SELECT authorized FROM nickname_authorization)
                  AND nickname.room_id = \(bind: room)
                  AND nickname.user_id > COALESCE(
                      \(bind: afterUser),
                      '00000000-0000-0000-0000-000000000000'::uuid
                  )
                  AND room.room_kind = 'group'
                  AND EXISTS (
                      SELECT 1
                      FROM im_v2.room_memberships AS membership
                      WHERE membership.room_id = room.room_id
                        AND membership.user_id = nickname.user_id
                        AND membership.joined_revision <= room.membership_revision
                        AND (membership.left_revision IS NULL
                             OR membership.left_revision > room.membership_revision)
                  )
                ORDER BY nickname.user_id
                LIMIT \(bind: limit + 1)
            )
            SELECT nickname_authorization.authorized,
                   page.user_id, page.nickname, page.revision
            FROM nickname_authorization
            LEFT JOIN page ON TRUE
            ORDER BY page.user_id NULLS LAST
            """).all(decoding: AuthorizedNicknameRow.self)
        guard rows.first?.authorized == true else { throw V2ProfilePresentationError.forbidden }
        let allValues = try rows.compactMap { try $0.presentation(roomID: roomID) }
        let values = Array(allValues.prefix(limit))
        return .init(values: values, nextCursor: allValues.count > limit ? values.last?.userID : nil)
    }

    /// 更新发起者本人在某群组内的昵称。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起更新的成员。
    ///   - roomID: 目标群组房间。
    ///   - operationID: 该次操作的稳定标识，用于幂等重试。
    ///   - expectedRevision: 期望的当前修订，`nil` 表示不校验。
    ///   - nickname: 新的群昵称；传 `nil` 表示清除。
    /// - Returns: 更新后的群成员展示。
    /// - Throws: 修订冲突、载荷不匹配、内容非法或持久化失败时抛出。
    public func updateOwnGroupNickname(actorUserID: UserID, roomID: RoomID, operationID: GroupNicknameOperationID, expectedRevision: V2ProfileRevision?, nickname: String?) async throws -> V2GroupMemberPresentation {
        let validated = try V2GroupMemberPresentation(roomID: roomID, userID: actorUserID, groupNickname: nickname, revision: .init(rawValue: 1)!)
        let normalizedNickname = validated.groupNickname
        let expectedSignedRevision = try signed(expectedRevision)
        let actor = try uuid(actorUserID), room = try uuid(roomID), operation = try uuid(operationID)
        return try await v2WithPostgresTransactionRetry(
            database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil
        ) { transaction -> V2GroupMemberPresentation in
            guard let sql = transaction as? any SQLDatabase else { throw V2ProfilePresentationError.corruptPersistenceState }
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await presentationLock(scope: actor.uuidString + ":nickname-operation:" + operation.uuidString, sql: sql)
            try await presentationLock(scope: room.uuidString + ":nickname:" + actor.uuidString, sql: sql)
            if let activationScope { try await activationScope.require([room], sql: sql) }
            if let scope = nicknameScope {
                guard scope.roomID == roomID else { throw V2RoomOwnerFenceError.ownerChanged }
                try await v2RequireRoomOwner(roomID: room, route: scope.route, sql: sql)
            }
            if let saved = try await nicknameOperation(actor: actor, operation: operation, sql: sql) {
                guard saved.room == room, saved.expectedRevision == expectedSignedRevision, saved.nickname == normalizedNickname,
                      saved.resultRevision > 0,
                      let revision = V2ProfileRevision(rawValue: UInt64(saved.resultRevision))
                else { throw V2ProfilePresentationError.operationPayloadMismatch }
                return try .init(roomID: roomID, userID: actorUserID, groupNickname: saved.nickname, revision: revision)
            }
            guard try await sql.raw("""
                SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: room) FOR SHARE
                """).first(decoding: NicknameRoomFenceRow.self) != nil else { throw V2ProfilePresentationError.forbidden }
            guard try await activeMember(userID: actor, roomID: room, sql: sql) else { throw V2ProfilePresentationError.forbidden }
            let current = try await nicknameRow(room: room, user: actor, sql: sql)
            guard current?.revision == expectedSignedRevision else { throw V2ProfilePresentationError.revisionConflict(current?.profileRevision) }
            let revision = try nextPresentationRevision(current: current?.revision, unchanged: current?.nickname == normalizedNickname)
            let changedAt = now()
            guard v2PostgresTimestampCanEncode(changedAt) else { throw V2ProfilePresentationError.corruptPersistenceState }
            try await sql.raw("INSERT INTO im_v2.room_member_nicknames (room_id, user_id, nickname, revision, updated_at) VALUES (\(bind: room), \(bind: actor), \(bind: normalizedNickname), \(bind: revision), \(bind: changedAt)) ON CONFLICT (room_id, user_id) DO UPDATE SET nickname = EXCLUDED.nickname, revision = EXCLUDED.revision, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("INSERT INTO im_v2.room_member_nickname_operations (actor_user_id, operation_id, room_id, expected_revision, requested_nickname, result_revision, created_at) VALUES (\(bind: actor), \(bind: operation), \(bind: room), \(bind: expectedSignedRevision), \(bind: normalizedNickname), \(bind: revision), \(bind: changedAt))").run()
            return try V2GroupMemberPresentation(roomID: roomID, userID: actorUserID, groupNickname: normalizedNickname, revision: .init(rawValue: UInt64(revision))!)
        }
    }

    private func relationshipExists(owner: UUID, target: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT 1 FROM im_v2.user_relationships WHERE state IN ('pending', 'accepted') AND ((lower_user_id = \(bind: owner) AND higher_user_id = \(bind: target)) OR (higher_user_id = \(bind: owner) AND lower_user_id = \(bind: target)))").first() != nil
    }
    private func activeMember(userID: UUID, roomID: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT 1 FROM im_v2.rooms AS room JOIN im_v2.room_memberships AS membership ON membership.room_id = room.room_id AND membership.user_id = \(bind: userID) AND membership.joined_revision <= room.membership_revision AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision) WHERE room.room_id = \(bind: roomID) AND room.room_kind = 'group'").first() != nil
    }
    private func aliasRow(owner: UUID, target: UUID, sql: any SQLDatabase) async throws -> AliasRow? { try await sql.raw("SELECT target_user_id, remark_name, revision FROM im_v2.user_contact_aliases WHERE owner_user_id = \(bind: owner) AND target_user_id = \(bind: target) FOR UPDATE").first(decoding: AliasRow.self) }
    private func nicknameRow(room: UUID, user: UUID, sql: any SQLDatabase) async throws -> NicknameRow? { try await sql.raw("SELECT user_id, nickname, revision FROM im_v2.room_member_nicknames WHERE room_id = \(bind: room) AND user_id = \(bind: user) FOR UPDATE").first(decoding: NicknameRow.self) }
    private func aliasOperation(owner: UUID, operation: UUID, sql: any SQLDatabase) async throws -> AliasOperationRow? { try await sql.raw("SELECT target_user_id, expected_revision, requested_remark_name, result_revision FROM im_v2.user_contact_alias_operations WHERE owner_user_id = \(bind: owner) AND operation_id = \(bind: operation)").first(decoding: AliasOperationRow.self) }
    private func nicknameOperation(actor: UUID, operation: UUID, sql: any SQLDatabase) async throws -> NicknameOperationRow? { try await sql.raw("SELECT room_id, expected_revision, requested_nickname, result_revision FROM im_v2.room_member_nickname_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)").first(decoding: NicknameOperationRow.self) }
}

private struct AliasRow: Decodable { let target: UUID; let remarkName: String?; let revision: Int64; enum CodingKeys: String, CodingKey { case target = "target_user_id"; case remarkName = "remark_name"; case revision }; var profileRevision: V2ProfileRevision? { revision > 0 ? .init(rawValue: UInt64(revision)) : nil }; func alias(owner: UserID) throws -> V2ContactAlias { guard let rev = profileRevision else { throw V2ProfilePresentationError.corruptPersistenceState }; return try .init(ownerUserID: owner, targetUserID: .init(target.uuidString), remarkName: remarkName, revision: rev) } }
private struct NicknameRow: Decodable { let user: UUID; let nickname: String?; let revision: Int64; enum CodingKeys: String, CodingKey { case user = "user_id"; case nickname; case revision }; var profileRevision: V2ProfileRevision? { revision > 0 ? .init(rawValue: UInt64(revision)) : nil }; func presentation(roomID: RoomID) throws -> V2GroupMemberPresentation { guard let rev = profileRevision else { throw V2ProfilePresentationError.corruptPersistenceState }; return try .init(roomID: roomID, userID: .init(user.uuidString), groupNickname: nickname, revision: rev) } }
private struct AuthorizedNicknameRow: Decodable {
    let authorized: Bool
    let user: UUID?
    let nickname: String?
    let revision: Int64?
    enum CodingKeys: String, CodingKey { case authorized; case user = "user_id"; case nickname; case revision }
    func presentation(roomID: RoomID) throws -> V2GroupMemberPresentation? {
        if user == nil, nickname == nil, revision == nil { return nil }
        guard let user, let revision, revision > 0,
              let profileRevision = V2ProfileRevision(rawValue: UInt64(revision))
        else { throw V2ProfilePresentationError.corruptPersistenceState }
        return try .init(
            roomID: roomID,
            userID: .init(user.uuidString),
            groupNickname: nickname,
            revision: profileRevision
        )
    }
}
private struct AliasOperationRow: Decodable { let target: UUID; let expectedRevision: Int64?; let remarkName: String?; let resultRevision: Int64; enum CodingKeys: String, CodingKey { case target = "target_user_id"; case expectedRevision = "expected_revision"; case remarkName = "requested_remark_name"; case resultRevision = "result_revision" } }
private struct NicknameOperationRow: Decodable { let room: UUID; let expectedRevision: Int64?; let nickname: String?; let resultRevision: Int64; enum CodingKeys: String, CodingKey { case room = "room_id"; case expectedRevision = "expected_revision"; case nickname = "requested_nickname"; case resultRevision = "result_revision" } }
private func uuid<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let result = UUID(uuidString: value.rawValue) else { throw V2ProfilePresentationError.corruptPersistenceState }; return result }
private func signed(_ value: V2ProfileRevision?) throws -> Int64? {
    guard let value else { return nil }
    guard let signed = Int64(exactly: value.rawValue), signed > 0 else { throw V2ProfilePresentationError.invalidPresentation }
    return signed
}
private func nextPresentationRevision(current: Int64?, unchanged: Bool) throws -> Int64 {
    guard let current else { return 1 }
    guard current > 0 else { throw V2ProfilePresentationError.corruptPersistenceState }
    if unchanged { return current }
    guard current < Int64.max else { throw V2ProfilePresentationError.corruptPersistenceState }
    return current + 1
}
private func presentationLock(scope: String, sql: any SQLDatabase) async throws {
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: scope), 0))").run()
}

private struct NicknameRoomFenceRow: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}
