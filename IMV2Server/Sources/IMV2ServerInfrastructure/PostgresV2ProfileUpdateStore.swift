import IMV2ServerApplication
import IMV2ServerContracts
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
    /// 已有操作返回不可变原回执和独立当前快照；否则更新资料修订、写入传播源记录
    /// 并登记操作结果。
    ///
    /// - Parameter command: 资料变更命令。
    /// - Returns: 变更结果。
    /// - Throws: 标识无法解析或持久化状态异常时抛出
    ///   ``V2ProfileUpdateError/corruptPersistenceState``；同一操作标识载荷不一致时抛出
    ///   ``V2ProfileUpdateError/operationPayloadMismatch``；修订冲突时抛出
    ///   业务版本冲突、头像不可用及到期返回持久拒绝回执，不作为传输异常。
    public func update(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateResult {
        guard let actorID = UUID(uuidString: command.actorUserID.rawValue),
              let operationID = UUID(uuidString: command.operationID.rawValue)
        else { throw V2ProfileUpdateError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ProfileUpdateError.corruptPersistenceState }
            try await lockOperation(actorID: actorID, operationID: operationID, sql: sql)
            if let receipt = try await operation(actorID: actorID, operationID: operationID, sql: sql) {
                guard receipt.validates(actorUserID: command.actorUserID, operationID: command.operationID, fingerprint: command.fingerprint) else {
                    throw V2ProfileUpdateError.operationPayloadMismatch
                }
                return .init(receipt: receipt, currentSnapshot: try await optionalProfile(userID: actorID, sql: sql))
            }
            let current = try await activeProfile(userID: actorID, sql: sql)
            let changedAt = now()
            guard v2PostgresTimestampCanEncode(changedAt), changedAt.timeIntervalSince1970 >= 0 else { throw V2ProfileUpdateError.corruptPersistenceState }
            func reject(_ reason: V2ProfileOperationRejection) async throws -> V2ProfileUpdateResult {
                let receipt = try await record(actorID: actorID, operationID: operationID, fingerprint: command.fingerprint, outcome: .rejected(reason), resolvedAt: changedAt, sql: sql)
                return .init(receipt: receipt, currentSnapshot: current)
            }
            guard let observation = try await sql.raw("SELECT clock_timestamp() AS observed_at").first(decoding: ProfileResourceClock.self)
            else { throw V2ProfileUpdateError.corruptPersistenceState }
            let admissionObservedAt = max(changedAt, observation.observedAt)
            guard admissionObservedAt.timeIntervalSince1970 * 1000 <= Double(command.firstSubmissionDeadlineMilliseconds) else {
                return try await reject(.expiredUnsubmitted)
            }
            guard current.revision == command.expectedRevision else { return try await reject(.revisionConflict(current: current.revision)) }
            let requestedName: String
            switch command.patch.displayName {
            case .unchanged: guard let value = current.publicIdentity?.displayName else { throw V2ProfileUpdateError.corruptPersistenceState }; requestedName = value
            case .set(let value): requestedName = value
            }
            let requestedAvatar: V2AvatarReference?
            switch command.patch.avatar {
            case .unchanged: requestedAvatar = current.avatar
            case .remove: requestedAvatar = nil
            case .set(let value): requestedAvatar = value
            }
            let requestedAvatarID = try requestedAvatar.map { avatar -> UUID in
                guard let value = avatar.mediaID.uuidValue else { throw V2ProfileUpdateError.corruptPersistenceState }; return value
            }
            let previousAvatarID = current.avatar?.mediaID.uuidValue
            // Bind and retire under the same media-row locks used by GC. Lock
            // both identities in canonical order before observing expiration.
            for mediaID in Set([previousAvatarID, requestedAvatarID].compactMap { $0 }).sorted(by: { $0.uuidString < $1.uuidString }) {
                guard try await sql.raw("SELECT 1 FROM im_v2.media_objects WHERE media_id=\(bind:mediaID) FOR UPDATE").first() != nil
                else { return try await reject(.avatarUnavailable) }
            }
            guard let resourceClock = try await sql.raw("SELECT clock_timestamp() AS observed_at").first(decoding: ProfileResourceClock.self)
            else { throw V2ProfileUpdateError.corruptPersistenceState }
            let bindingObservedAt = max(changedAt, resourceClock.observedAt)
            guard bindingObservedAt.timeIntervalSince1970 * 1000 <= Double(command.firstSubmissionDeadlineMilliseconds) else {
                return try await reject(.expiredUnsubmitted)
            }
            if let requestedAvatarID,
               try await sql.raw("""
                    SELECT 1 FROM im_v2.media_objects media
                    WHERE media.media_id = \(bind: requestedAvatarID)
                      AND media.owner_user_id = \(bind: actorID) AND media.state = 'available'
                      AND EXISTS (
                          SELECT 1 FROM im_v2.resource_catalog resource
                          JOIN im_v2.resource_blob_placements placement ON placement.media_id=resource.media_id
                            AND placement.generation=resource.generation AND placement.state='active'
                          WHERE resource.media_id=media.media_id AND resource.home_kind='account'
                            AND resource.home_id=\(bind:actorID) AND resource.usage_kind='user_avatar'
                            AND media.content_type LIKE 'image/%'
                            AND (media.expires_at>\(bind:bindingObservedAt) OR media.media_id=\(bind:previousAvatarID))
                            AND (SELECT count(*) FROM im_v2.resource_variants variant WHERE variant.media_id=resource.media_id
                              AND variant.generation=resource.generation AND variant.recipe='avatar' AND variant.recipe_version=1
                              AND variant.size IN (128,256) AND variant.state='ready')=2
                      )
                    """).first() == nil {
                return try await reject(.avatarUnavailable)
            }

            let changed = current.publicIdentity?.displayName != requestedName || current.avatar != requestedAvatar
            let result: V2ProfileView
            if changed {
                guard current.revision.rawValue < UInt64(Int64.max),
                      current.visibilityRevision.rawValue < UInt64(Int64.max)
                else { throw V2ProfileUpdateError.corruptPersistenceState }
                guard let updated = try await sql.raw("""
                    UPDATE im_v2.public_user_profiles
                    SET display_name = \(bind: requestedName),
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
                if let previousAvatarID, previousAvatarID != requestedAvatarID {
                    guard let retireAfter = v2PostgresFutureTimestamp(now: bindingObservedAt, interval: 120)
                    else { throw V2ProfileUpdateError.corruptPersistenceState }
                    try await sql.raw("UPDATE im_v2.media_objects SET expires_at=GREATEST(expires_at,\(bind:retireAfter)) WHERE media_id=\(bind:previousAvatarID)").run()
                }
                try await sql.raw("""
                    INSERT INTO im_v2.public_profile_update_outbox
                        (source_event_id, source_user_id, revision, created_at)
                    VALUES (\(bind: makeUUID()), \(bind: actorID), \(bind: result.revision.signedValue), \(bind: changedAt))
                    """).run()
            } else {
                result = current
            }
            let receipt = try await record(actorID: actorID, operationID: operationID, fingerprint: command.fingerprint,
                outcome: .committed(revision: result.revision, visibilityRevision: result.visibilityRevision), resolvedAt: changedAt, sql: sql)
            return .init(receipt: receipt, currentSnapshot: result)
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

    public func recover(_ request: V2ProfileOperationRecoveryRequest) async throws -> V2ProfileOperationRecoveryResult {
        guard let actorID = request.actorUserID.uuidValue, let operationID = request.operationID.uuidValue else { throw V2ProfileUpdateError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ProfileUpdateError.corruptPersistenceState }
            try await lockOperation(actorID: actorID, operationID: operationID, sql: sql)
            if let receipt = try await operation(actorID: actorID, operationID: operationID, sql: sql) {
                guard receipt.validates(actorUserID: request.actorUserID, operationID: request.operationID, fingerprint: request.fingerprint) else { return .fingerprintConflict }
                return .receipt(receipt, currentSnapshot: try await optionalProfile(userID: actorID, sql: sql))
            }
            guard request.action == .closeIfAbsent else { return .unresolved }
            let receipt = try await record(actorID: actorID, operationID: operationID, fingerprint: request.fingerprint, outcome: .closed, resolvedAt: now(), sql: sql)
            return .receipt(receipt, currentSnapshot: try await optionalProfile(userID: actorID, sql: sql))
        }
    }

    private func lockOperation(actorID: UUID, operationID: UUID, sql: any SQLDatabase) async throws {
        let key = "profile-operation:" + actorID.uuidString + ":" + operationID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }
    private func optionalProfile(userID: UUID, sql: any SQLDatabase) async throws -> V2ProfileView? {
        do { return try await readActiveProfile(userID: userID, sql: sql) }
        catch V2ProfileUpdateError.unavailable { return nil }
    }
    private func operation(actorID: UUID, operationID: UUID, sql: any SQLDatabase) async throws -> V2ProfileOperationReceipt? {
        guard let row = try await sql.raw("SELECT receipt::text AS receipt, fingerprint_version, request_fingerprint, outcome_kind, result_revision FROM im_v2.public_profile_update_operations WHERE actor_user_id=\(bind:actorID) AND operation_id=\(bind:operationID)").first(decoding: ProfileOperationRow.self) else { return nil }
        let receipt = try JSONDecoder().decode(V2ProfileOperationReceipt.self, from: Data(row.receipt.utf8))
        guard receipt.actorUserID.uuidValue == actorID, receipt.operationID.uuidValue == operationID,
              row.fingerprintVersion > 0, Int16(receipt.fingerprint.version) == row.fingerprintVersion, receipt.fingerprint.digest == row.requestFingerprint else {
            throw V2ProfileUpdateError.corruptPersistenceState
        }
        switch receipt.outcome {
        case .committed(let revision, _):
            guard row.outcomeKind == "committed", row.resultRevision == revision.signedValue else { throw V2ProfileUpdateError.corruptPersistenceState }
        case .closed: guard row.outcomeKind == "closed", row.resultRevision == nil else { throw V2ProfileUpdateError.corruptPersistenceState }
        case .rejected: guard row.outcomeKind == "rejected", row.resultRevision == nil else { throw V2ProfileUpdateError.corruptPersistenceState }
        }
        return receipt
    }
    private func record(actorID: UUID, operationID: UUID, fingerprint: V2OperationFingerprint, outcome: V2ProfileOperationTerminalOutcome, resolvedAt: Date, sql: any SQLDatabase) async throws -> V2ProfileOperationReceipt {
        guard v2PostgresTimestampCanEncode(resolvedAt), resolvedAt.timeIntervalSince1970 >= 0 else { throw V2ProfileUpdateError.corruptPersistenceState }
        let milliseconds = resolvedAt.timeIntervalSince1970 * 1000
        guard milliseconds < Double(Int64.max) else { throw V2ProfileUpdateError.corruptPersistenceState }
        let receipt = try V2ProfileOperationReceipt(actorUserID: .init(uuid:actorID), operationID: .init(uuid:operationID), fingerprint: fingerprint, outcome: outcome, resolvedAtMilliseconds: UInt64(milliseconds))
        let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        let kind: String
        let revision: Int64?
        switch outcome {
        case .committed(let value, _): kind = "committed"; revision = value.signedValue
        case .rejected: kind = "rejected"; revision = nil
        case .closed: kind = "closed"; revision = nil
        }
        try await sql.raw("""
            INSERT INTO im_v2.public_profile_update_operations (actor_user_id,operation_id,fingerprint_version,request_fingerprint,outcome_kind,result_revision,receipt,created_at)
            VALUES (\(bind:actorID),\(bind:operationID),\(bind:Int16(fingerprint.version)),\(bind:fingerprint.digest),\(bind:kind),\(bind:revision),\(bind:encoded)::jsonb,\(bind:resolvedAt))
            """).run()
        return receipt
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

private struct ProfileResourceClock: Decodable {
    let observedAt: Date
    enum CodingKeys: String, CodingKey { case observedAt = "observed_at" }
}

private struct ProfileOperationRow: Decodable {
    let receipt: String
    let fingerprintVersion: Int16
    let requestFingerprint: Data
    let outcomeKind: String
    let resultRevision: Int64?
    enum CodingKeys: String, CodingKey {
        case receipt, fingerprintVersion = "fingerprint_version", requestFingerprint = "request_fingerprint"
        case outcomeKind = "outcome_kind", resultRevision = "result_revision"
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
