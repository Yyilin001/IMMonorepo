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
  private let nicknameCapacityProfile: V2CapacityProfile?
  private let makeEventID: @Sendable () throws -> EventID

  /// 创建资料展示存储。
  ///
  /// - Parameters:
  ///   - database: 控制面数据库连接。
  ///   - now: 服务端时钟，默认取当前时间。
  public init(
    database: any Database, nicknameCapacityProfile: V2CapacityProfile? = nil,
    makeEventID: @escaping @Sendable () throws -> EventID = { .init(uuid: UUID()) },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.now = now
    self.nicknameScope = nil
    self.activationScope = nil
    self.nicknameCapacityProfile = nicknameCapacityProfile
    self.makeEventID = makeEventID
  }

  /// 仅用于固定的房间 Actor 轮次；所有昵称读写都会重新校验完整令牌。
  public init(
    database: any Database, activationScope: V2RoomActivationWriteScope,
    nicknameCapacityProfile: V2CapacityProfile,
    makeEventID: @escaping @Sendable () throws -> EventID = { .init(uuid: UUID()) },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.now = now
    self.nicknameScope = nil
    self.activationScope = activationScope
    self.nicknameCapacityProfile = nicknameCapacityProfile
    self.makeEventID = makeEventID
  }

  init(
    database: any Database, roomID: RoomID, ownerRoute: V2RoomShardRoute,
    nicknameCapacityProfile: V2CapacityProfile, now: @escaping @Sendable () -> Date
  ) {
    self.database = database
    self.now = now
    self.nicknameScope = (roomID, ownerRoute)
    self.activationScope = nil
    self.nicknameCapacityProfile = nicknameCapacityProfile
    self.makeEventID = { .init(uuid: UUID()) }
  }

  /// 按目标用户游标分页读取联系人备注。
  ///
  /// - Parameters:
  ///   - ownerUserID: 拥有这批备注的用户。
  ///   - afterTargetUserID: 分页起点之后的目标用户，首页传 `nil`。
  ///   - limit: 本次返回条数，必须落在 1…500 之间。
  /// - Returns: 备注分页，含下一页游标。
  /// - Throws: 条数越界、标识符非法或持久化状态损坏时抛出。
  public func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int)
    async throws -> V2ContactAliasPage
  {
    guard (1...500).contains(limit) else { throw V2ProfilePresentationError.invalidPresentation }
    let owner = try uuid(ownerUserID)
    let afterTarget = try afterTargetUserID.map(uuid)
    guard let sql = database as? any SQLDatabase else {
      throw V2ProfilePresentationError.corruptPersistenceState
    }
    let rows = try await sql.raw(
      """
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
      """
    ).all(decoding: AliasRow.self)
    let values = try rows.prefix(limit).map { try $0.alias(owner: ownerUserID) }
    return .init(values: values, nextCursor: rows.count > limit ? values.last?.targetUserID : nil)
  }

  /// 写入或清除某个联系人的备注名。
  ///
  /// - Parameters:
  ///   - ownerUserID: 拥有该备注的用户。
  ///   - targetUserID: 被备注的目标用户。
  ///   - operationID: 该次操作的稳定标识，用于幂等重试。
  ///   - expectedRevision: 期望的当前修订，`nil` 表示此前不存在该记录。
  ///   - remarkName: 新的备注名；传 `nil` 表示清除。
  /// - Returns: 写入后的备注记录。
  /// - Throws: 修订冲突、载荷不匹配、内容非法或持久化失败时抛出。

  /// 按成员游标分页读取群昵称展示。
  ///
  /// - Parameters:
  ///   - actorUserID: 发起读取的成员。
  ///   - roomID: 目标群组房间。
  ///   - afterUserID: 分页起点之后的成员，首页传 `nil`。
  ///   - limit: 本次返回条数，必须落在允许区间内。
  /// - Returns: 群昵称分页，含下一页游标。
  /// - Throws: 无权限、条数越界或持久化状态损坏时抛出。
  public func groupNicknames(actorUserID: UserID, roomID: RoomID, afterUserID: UserID?, limit: Int)
    async throws -> V2GroupNicknamePage
  {
    if activationScope != nil || nicknameScope != nil {
      return try await v2WithPostgresTransactionRetry(
        database: database, maximumRetryCount: 0,
        classifyCommitFailure: false, useRoomDeadline: activationScope != nil
      ) { transaction in
        guard let sql = transaction as? any SQLDatabase else {
          throw V2ProfilePresentationError.corruptPersistenceState
        }
        let room = try uuid(roomID)
        if let activationScope {
          try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
          try await activationScope.require([room], sql: sql)
        } else if let scope = nicknameScope {
          guard scope.roomID == roomID else { throw V2RoomOwnerFenceError.ownerChanged }
          try await v2RequireRoomOwner(roomID: room, route: scope.route, sql: sql)
        }
        return try await readGroupNicknames(
          actorUserID: actorUserID, roomID: roomID,
          afterUserID: afterUserID, limit: limit, sql: sql)
      }
    }
    guard let sql = database as? any SQLDatabase else {
      throw V2ProfilePresentationError.corruptPersistenceState
    }
    return try await readGroupNicknames(
      actorUserID: actorUserID, roomID: roomID, afterUserID: afterUserID, limit: limit, sql: sql)
  }

  private func readGroupNicknames(
    actorUserID: UserID, roomID: RoomID, afterUserID: UserID?, limit: Int, sql: any SQLDatabase
  ) async throws -> V2GroupNicknamePage {
    guard (1...500).contains(limit) else { throw V2ProfilePresentationError.invalidPresentation }
    let actor = try uuid(actorUserID)
    let room = try uuid(roomID)
    let afterUser = try afterUserID.map(uuid)
    let rows = try await sql.raw(
      """
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
      """
    ).all(decoding: AuthorizedNicknameRow.self)
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
  ///   - expectedRevision: 期望的当前修订，`nil` 表示此前不存在该记录。
  ///   - nickname: 新的群昵称；传 `nil` 表示清除。
  /// - Returns: 更新后的群成员展示。
  /// - Throws: 修订冲突、载荷不匹配、内容非法或持久化失败时抛出。

  private func relationshipExists(owner: UUID, target: UUID, sql: any SQLDatabase) async throws
    -> Bool
  {
    try await sql.raw(
      "SELECT 1 FROM im_v2.user_relationships WHERE state IN ('pending', 'accepted') AND ((lower_user_id = \(bind: owner) AND higher_user_id = \(bind: target)) OR (higher_user_id = \(bind: owner) AND lower_user_id = \(bind: target)))"
    ).first() != nil
  }
  private func activeMember(userID: UUID, roomID: UUID, sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw(
      "SELECT 1 FROM im_v2.rooms AS room JOIN im_v2.room_memberships AS membership ON membership.room_id = room.room_id AND membership.user_id = \(bind: userID) AND membership.joined_revision <= room.membership_revision AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision) WHERE room.room_id = \(bind: roomID) AND room.room_kind = 'group'"
    ).first() != nil
  }
  private func aliasRow(owner: UUID, target: UUID, sql: any SQLDatabase) async throws -> AliasRow? {
    try await sql.raw(
      "SELECT target_user_id, remark_name, revision FROM im_v2.user_contact_aliases WHERE owner_user_id = \(bind: owner) AND target_user_id = \(bind: target) FOR UPDATE"
    ).first(decoding: AliasRow.self)
  }
  private func nicknameRow(room: UUID, user: UUID, sql: any SQLDatabase) async throws
    -> NicknameRow?
  {
    try await sql.raw(
      "SELECT user_id, nickname, revision FROM im_v2.room_member_nicknames WHERE room_id = \(bind: room) AND user_id = \(bind: user) FOR UPDATE"
    ).first(decoding: NicknameRow.self)
  }
  public func contactAliasSnapshot(ownerUserID: UserID, targetUserID: UserID) async throws
    -> V2ContactAliasSnapshot
  {
    let owner = try uuid(ownerUserID)
    let target = try uuid(targetUserID)
    return try await database.transaction { tx in
      guard let sql = tx as? any SQLDatabase else {
        throw V2ProfilePresentationError.corruptPersistenceState
      }
      guard try await relationshipExists(owner: owner, target: target, sql: sql) else {
        throw V2ProfilePresentationError.forbidden
      }
      let value = try await aliasRow(owner: owner, target: target, sql: sql)?.alias(
        owner: ownerUserID)
      return try .init(ownerUserID: ownerUserID, targetUserID: targetUserID, value: value)
    }
  }
  public func ownGroupNicknameSnapshot(actorUserID: UserID, roomID: RoomID) async throws
    -> V2GroupNicknameSnapshot
  {
    let actor = try uuid(actorUserID)
    let room = try uuid(roomID)
    guard let sql = database as? any SQLDatabase else {
      throw V2ProfilePresentationError.corruptPersistenceState
    }
    guard try await activeMember(userID: actor, roomID: room, sql: sql) else {
      throw V2ProfilePresentationError.forbidden
    }
    let value = try await nicknameRow(room: room, user: actor, sql: sql)?.presentation(
      roomID: roomID)
    return try .init(actorUserID: actorUserID, roomID: roomID, value: value)
  }
  public func updateContactAlias(_ command: V2ContactAliasUpdateCommand) async throws
    -> V2ContactAliasUpdateReceipt
  {
    let owner = try uuid(command.ownerUserID)
    let target = try uuid(command.targetUserID)
    return try await database.transaction { tx in
      guard let sql = tx as? any SQLDatabase else {
        throw V2ProfilePresentationError.corruptPersistenceState
      }
      try await presentationLock(scope: presentationOperationLockKey(command.identity), sql: sql)
      if let row = try await readReceipt(.alias, identity: command.identity, sql: sql) {
        let receipt = try JSONDecoder().decode(
          V2ContactAliasUpdateReceipt.self, from: Data(row.payload.utf8))
        try validatePresentationReceipt(
          identity: receipt.identity, fingerprint: receipt.fingerprint, row: row)
        guard receipt.validates(command), receipt.fingerprint == (try row.fingerprint) else {
          throw V2ProfilePresentationError.operationPayloadMismatch
        }
        return receipt
      }
      try await presentationLock(scope: owner.uuidString + ":alias:" + target.uuidString, sql: sql)
      let time = try validatedPresentationClock(now())
      let milliseconds = try presentationMilliseconds(time)
      var reason: V2ContactAliasOperationRejection?
      if !(try await relationshipExists(owner: owner, target: target, sql: sql)) {
        reason = .permissionDenied
      }
      if reason == nil, milliseconds > command.firstSubmissionDeadlineMilliseconds {
        reason = .expiredUnsubmitted
      }
      let current = try await aliasRow(owner: owner, target: target, sql: sql)
      if reason == nil, current?.revision != (try signed(command.expectedRevision)) {
        reason = .revisionConflict(current: current?.profileRevision)
      }
      if reason == nil, current?.revision == Int64.max {
        reason = .revisionConflict(current: current?.profileRevision)
      }
      let outcome: V2ContactAliasOperationTerminalOutcome
      if let reason {
        outcome = .rejected(reason)
      } else {
        let revision = try nextPresentationRevision(current: current?.revision)
        try await sql.raw(
          "INSERT INTO im_v2.user_contact_aliases(owner_user_id,target_user_id,remark_name,revision,updated_at) VALUES(\(bind:owner),\(bind:target),\(bind:command.remarkName),\(bind:revision),\(bind:time)) ON CONFLICT(owner_user_id,target_user_id) DO UPDATE SET remark_name=EXCLUDED.remark_name,revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at"
        ).run()
        try await sql.raw("""
          INSERT INTO im_v2.user_state_event_outbox(user_id,source_event_id,projection_kind,payload,created_at,next_attempt_at)
          VALUES(\(bind:owner),\(bind:uuid(makeEventID())),'contact_alias',
            jsonb_build_object('target_user_id',\(bind:command.targetUserID.rawValue),'revision',\(bind:revision)),
            \(bind:time),\(bind:time))
          """).run()
        outcome = .committed(
          try .init(
            ownerUserID: command.ownerUserID, targetUserID: command.targetUserID,
            remarkName: command.remarkName, revision: .init(rawValue: UInt64(revision))!))
      }
      let receipt = try V2ContactAliasUpdateReceipt(
        identity: command.identity, fingerprint: command.fingerprint, outcome: outcome,
        resolvedAtMilliseconds: milliseconds)
      try await persistReceipt(
        .alias, identity: command.identity, fingerprint: command.fingerprint, receipt: receipt,
        time: time, sql: sql)
      return receipt
    }
  }
  public func recoverContactAlias(_ request: V2ContactAliasRecoveryRequest) async throws
    -> V2ContactAliasRecoveryResult
  {
    try await database.transaction { tx in
      guard let sql = tx as? any SQLDatabase else {
        throw V2ProfilePresentationError.corruptPersistenceState
      }
      try await presentationLock(scope: presentationOperationLockKey(request.identity), sql: sql)
      if let row = try await readReceipt(.alias, identity: request.identity, sql: sql) {
        let receipt = try JSONDecoder().decode(
          V2ContactAliasUpdateReceipt.self, from: Data(row.payload.utf8))
        try validatePresentationReceipt(
          identity: receipt.identity, fingerprint: receipt.fingerprint, row: row)
        guard receipt.fingerprint == (try row.fingerprint) else {
          throw V2ProfilePresentationError.corruptPersistenceState
        }
        return receipt.identity == request.identity && receipt.fingerprint == request.fingerprint
          ? .receipt(receipt) : .fingerprintConflict
      }
      guard request.action == .closeIfAbsent else { return .unresolved }
      let time = try validatedPresentationClock(now())
      let receipt = try V2ContactAliasUpdateReceipt(
        identity: request.identity, fingerprint: request.fingerprint, outcome: .closed,
        resolvedAtMilliseconds: presentationMilliseconds(time))
      try await persistReceipt(
        .alias, identity: request.identity, fingerprint: request.fingerprint, receipt: receipt,
        time: time, sql: sql)
      return .receipt(receipt)
    }
  }
  public func updateOwnGroupNickname(_ command: V2GroupNicknameUpdateCommand) async throws
    -> V2GroupNicknameUpdateReceipt
  {
    let actor = try uuid(command.actorUserID)
    let room = try uuid(command.roomID)
    return try await v2WithPostgresTransactionRetry(
      database: database, maximumRetryCount: 0, classifyCommitFailure: activationScope != nil,
      useRoomDeadline: activationScope != nil
    ) { tx in
      guard let sql = tx as? any SQLDatabase else {
        throw V2ProfilePresentationError.corruptPersistenceState
      }
      try await prepareNickname(identity: command.identity, roomID: command.roomID, sql: sql)
      if let row = try await readReceipt(.nickname, identity: command.identity, sql: sql) {
        let receipt = try JSONDecoder().decode(
          V2GroupNicknameUpdateReceipt.self, from: Data(row.payload.utf8))
        try validatePresentationReceipt(
          identity: receipt.identity, fingerprint: receipt.fingerprint, row: row)
        guard receipt.validates(command), receipt.fingerprint == (try row.fingerprint) else {
          throw V2ProfilePresentationError.operationPayloadMismatch
        }
        return receipt
      }
      try await presentationLock(scope: room.uuidString + ":nickname:" + actor.uuidString, sql: sql)
      let exists =
        try await sql.raw(
          "SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind:room) FOR NO KEY UPDATE"
        ).first(decoding: NicknameRoomFenceRow.self) != nil
      let time = try validatedPresentationClock(now())
      let milliseconds = try presentationMilliseconds(time)
      var reason: V2GroupNicknameOperationRejection?
      if !exists {
        reason = .notFound
      } else if !(try await activeMember(userID: actor, roomID: room, sql: sql)) {
        reason = .permissionDenied
      }
      if reason == nil, milliseconds > command.firstSubmissionDeadlineMilliseconds {
        reason = .expiredUnsubmitted
      }
      let current = try await nicknameRow(room: room, user: actor, sql: sql)
      if reason == nil, current?.revision != (try signed(command.expectedRevision)) {
        reason = .revisionConflict(current: current?.profileRevision)
      }
      if reason == nil, current?.revision == Int64.max {
        reason = .revisionConflict(current: current?.profileRevision)
      }
      let outcome: V2GroupNicknameOperationTerminalOutcome
      if let reason {
        outcome = .rejected(reason)
      } else {
        let revision = try nextPresentationRevision(current: current?.revision)
        if current?.revision != revision {
          guard let nicknameCapacityProfile else {
            throw V2ProfilePresentationError.corruptPersistenceState
          }
          try await v2AppendGroupNicknameInvalidation(
            room: room, actor: actor, revision: revision, capacityProfile: nicknameCapacityProfile,
            eventID: makeEventID(), now: time, sql: sql)
        }
        try await sql.raw(
          "INSERT INTO im_v2.room_member_nicknames(room_id,user_id,nickname,revision,updated_at) VALUES(\(bind:room),\(bind:actor),\(bind:command.nickname),\(bind:revision),\(bind:time)) ON CONFLICT(room_id,user_id) DO UPDATE SET nickname=EXCLUDED.nickname,revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at"
        ).run()
        outcome = .committed(
          try .init(
            roomID: command.roomID, userID: command.actorUserID, groupNickname: command.nickname,
            revision: .init(rawValue: UInt64(revision))!))
      }
      let receipt = try V2GroupNicknameUpdateReceipt(
        identity: command.identity, fingerprint: command.fingerprint, outcome: outcome,
        resolvedAtMilliseconds: milliseconds)
      try await persistReceipt(
        .nickname, identity: command.identity, fingerprint: command.fingerprint, receipt: receipt,
        time: time, sql: sql)
      return receipt
    }
  }
  public func recoverGroupNickname(_ request: V2GroupNicknameRecoveryRequest) async throws
    -> V2GroupNicknameRecoveryResult
  {
    guard case .room(let roomID) = request.identity.scope else {
      throw V2ProfilePresentationError.invalidPresentation
    }
    return try await v2WithPostgresTransactionRetry(
      database: database, maximumRetryCount: 0, classifyCommitFailure: activationScope != nil,
      useRoomDeadline: activationScope != nil
    ) { tx in
      guard let sql = tx as? any SQLDatabase else {
        throw V2ProfilePresentationError.corruptPersistenceState
      }
      try await prepareNickname(identity: request.identity, roomID: roomID, sql: sql)
      if let row = try await readReceipt(.nickname, identity: request.identity, sql: sql) {
        let receipt = try JSONDecoder().decode(
          V2GroupNicknameUpdateReceipt.self, from: Data(row.payload.utf8))
        try validatePresentationReceipt(
          identity: receipt.identity, fingerprint: receipt.fingerprint, row: row)
        guard receipt.fingerprint == (try row.fingerprint) else {
          throw V2ProfilePresentationError.corruptPersistenceState
        }
        return receipt.identity == request.identity && receipt.fingerprint == request.fingerprint
          ? .receipt(receipt) : .fingerprintConflict
      }
      guard request.action == .closeIfAbsent else { return .unresolved }
      let time = try validatedPresentationClock(now())
      let receipt = try V2GroupNicknameUpdateReceipt(
        identity: request.identity, fingerprint: request.fingerprint, outcome: .closed,
        resolvedAtMilliseconds: presentationMilliseconds(time))
      try await persistReceipt(
        .nickname, identity: request.identity, fingerprint: request.fingerprint, receipt: receipt,
        time: time, sql: sql)
      return .receipt(receipt)
    }
  }
  private func prepareNickname(identity: V2OperationIdentity, roomID: RoomID, sql: any SQLDatabase)
    async throws
  {
    if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
    try await presentationLock(scope: presentationOperationLockKey(identity), sql: sql)
    let room = try uuid(roomID)
    if let activationScope { try await activationScope.require([room], sql: sql) }
    if let nicknameScope {
      guard nicknameScope.roomID == roomID else { throw V2RoomOwnerFenceError.ownerChanged }
      try await v2RequireRoomOwner(roomID: room, route: nicknameScope.route, sql: sql)
    }
  }
  private func readReceipt(
    _ table: PresentationReceiptTable, identity: V2OperationIdentity, sql: any SQLDatabase
  ) async throws -> PresentationReceiptRow? {
    guard UUID(uuidString: identity.operation.rawOperationID) != nil else {
      throw V2ProfilePresentationError.corruptPersistenceState
    }
    guard
      let row = try await sql.raw(
        "SELECT receipt::text AS payload,fingerprint_version,request_fingerprint,actor_user_id,operation_id,\(unsafeRaw:table.entityColumn) AS entity_id FROM im_v2.\(unsafeRaw:table.rawValue) WHERE actor_user_id=\(bind:uuid(identity.accountID)) AND operation_id=\(bind:UUID(uuidString:identity.operation.rawOperationID)!)"
      ).first(decoding: PresentationReceiptRow.self)
    else { return nil }
    _ = try row.fingerprint
    return row
  }
  private func persistReceipt<Receipt: Encodable>(
    _ table: PresentationReceiptTable, identity: V2OperationIdentity,
    fingerprint: V2OperationFingerprint, receipt: Receipt, time: Date, sql: any SQLDatabase
  ) async throws {
    guard let operation = UUID(uuidString: identity.operation.rawOperationID) else {
      throw V2ProfilePresentationError.corruptPersistenceState
    }
    let payload = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    try await sql.raw(
      "INSERT INTO im_v2.\(unsafeRaw:table.rawValue)(identity_key,actor_user_id,operation_id,fingerprint_version,request_fingerprint,receipt,created_at,\(unsafeRaw:table.entityColumn)) VALUES(\(bind:identity.storageKey),\(bind:uuid(identity.accountID)),\(bind:operation),\(bind:Int16(fingerprint.version)),\(bind:fingerprint.digest),\(bind:payload)::jsonb,\(bind:time),\(bind:presentationEntityUUID(identity)))"
    ).run()
  }

}

private struct AliasRow: Decodable {
  let target: UUID
  let remarkName: String?
  let revision: Int64
  enum CodingKeys: String, CodingKey {
    case target = "target_user_id"
    case remarkName = "remark_name"
    case revision
  }
  var profileRevision: V2ProfileRevision? { revision > 0 ? .init(rawValue: UInt64(revision)) : nil }
  func alias(owner: UserID) throws -> V2ContactAlias {
    guard let rev = profileRevision else {
      throw V2ProfilePresentationError.corruptPersistenceState
    }
    return try .init(
      ownerUserID: owner, targetUserID: .init(target.uuidString), remarkName: remarkName,
      revision: rev)
  }
}
private struct NicknameRow: Decodable {
  let user: UUID
  let nickname: String?
  let revision: Int64
  enum CodingKeys: String, CodingKey {
    case user = "user_id"
    case nickname
    case revision
  }
  var profileRevision: V2ProfileRevision? { revision > 0 ? .init(rawValue: UInt64(revision)) : nil }
  func presentation(roomID: RoomID) throws -> V2GroupMemberPresentation {
    guard let rev = profileRevision else {
      throw V2ProfilePresentationError.corruptPersistenceState
    }
    return try .init(
      roomID: roomID, userID: .init(user.uuidString), groupNickname: nickname, revision: rev)
  }
}
private struct AuthorizedNicknameRow: Decodable {
  let authorized: Bool
  let user: UUID?
  let nickname: String?
  let revision: Int64?
  enum CodingKeys: String, CodingKey {
    case authorized
    case user = "user_id"
    case nickname
    case revision
  }
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
private func uuid<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
  guard let result = UUID(uuidString: value.rawValue) else {
    throw V2ProfilePresentationError.corruptPersistenceState
  }
  return result
}
private func signed(_ value: V2ProfileRevision?) throws -> Int64? {
  guard let value else { return nil }
  guard let signed = Int64(exactly: value.rawValue), signed > 0 else {
    throw V2ProfilePresentationError.invalidPresentation
  }
  return signed
}
private func nextPresentationRevision(current: Int64?) throws -> Int64 {
  guard let current else { return 1 }
  guard current > 0 else { throw V2ProfilePresentationError.corruptPersistenceState }

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

private enum PresentationReceiptTable: String {
  case alias = "contact_alias_operation_receipts"
  case nickname = "group_nickname_operation_receipts"
  var entityColumn: String { self == .alias ? "target_user_id" : "room_id" }
}
private struct PresentationReceiptRow: Decodable {
  let payload: String
  let fingerprintVersion: Int16
  let requestFingerprint: Data
  let actorUserID: UUID
  let operationID: UUID
  let entityID: UUID
  enum CodingKeys: String, CodingKey {
    case payload
    case fingerprintVersion = "fingerprint_version"
    case requestFingerprint = "request_fingerprint"
    case actorUserID = "actor_user_id"
    case operationID = "operation_id"
    case entityID = "entity_id"
  }
  var fingerprint: V2OperationFingerprint {
    get throws {
      guard fingerprintVersion > 0 else { throw V2ProfilePresentationError.corruptPersistenceState }
      return try .init(version: UInt16(fingerprintVersion), digest: requestFingerprint)
    }
  }
}
private struct PresentationClockRow: Decodable { let value: Date }
private func presentationClock(_ sql: any SQLDatabase) async throws -> Date {
  guard
    let time = try await sql.raw("SELECT clock_timestamp() AS value").first(
      decoding: PresentationClockRow.self)?.value
  else { throw V2ProfilePresentationError.corruptPersistenceState }
  return time
}
private func presentationMilliseconds(_ time: Date) throws -> UInt64 {
  guard let value = UInt64(exactly: (time.timeIntervalSince1970 * 1000).rounded(.towardZero)),
    value <= UInt64(Int64.max)
  else { throw V2ProfilePresentationError.corruptPersistenceState }
  return value
}

private func validatedPresentationClock(_ time: Date) throws -> Date {
  guard v2PostgresTimestampCanEncode(time) else {
    throw V2ProfilePresentationError.corruptPersistenceState
  }
  return time
}

private func presentationOperationLockKey(_ identity: V2OperationIdentity) throws -> String {
  guard let operation = UUID(uuidString: identity.operation.rawOperationID) else {
    throw V2ProfilePresentationError.corruptPersistenceState
  }
  return try uuid(identity.accountID).uuidString + ":presentation-operation:"
    + identity.kind.rawValue + ":" + operation.uuidString
}

private func presentationEntityUUID(_ identity: V2OperationIdentity) throws -> UUID {
  switch identity.scope {
  case .room(let room): return try uuid(room)
  case .userPair(_, let target): return try uuid(target)
  default: throw V2ProfilePresentationError.corruptPersistenceState
  }
}
private func validatePresentationReceipt(
  identity: V2OperationIdentity, fingerprint: V2OperationFingerprint, row: PresentationReceiptRow
) throws {
  guard try uuid(identity.accountID) == row.actorUserID,
    UUID(uuidString: identity.operation.rawOperationID) == row.operationID,
    (try presentationEntityUUID(identity)) == row.entityID, fingerprint == (try row.fingerprint)
  else { throw V2ProfilePresentationError.corruptPersistenceState }
}
