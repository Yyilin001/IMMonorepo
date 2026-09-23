import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 转发媒体导入的持久化实现。
///
/// 在执行 I/O 之前先预留稳定的目标对象，并用持久化租约栅栏复制与扫描结果；
/// 这些锁下不会进行任何字节传输或扫描。
public struct PostgresV2ForwardMediaImportStore: Sendable {
    private let database: any Database
    private let temporaryLifetime: TimeInterval
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库与临时对象存活时长。
    ///
    /// - Parameters:
    ///   - database: 存放转发收件箱与导入任务的数据库。
    ///   - temporaryLifetime: 临时对象存活秒数，需为正的有限值，默认 24 小时。
    ///   - makeUUID: 导入任务标识生成方式。
    /// - Throws: 存活时长非正或非有限时抛出
    ///   ``V2ForwardMediaCopyError/invalidReceipt``。
    public init(database: any Database, temporaryLifetime: TimeInterval = 86_400,
                makeUUID: @escaping @Sendable () -> UUID = UUID.init) throws {
        guard temporaryLifetime.isFinite, temporaryLifetime > 0 else { throw V2ForwardMediaCopyError.invalidReceipt }
        self.database = database; self.temporaryLifetime = temporaryLifetime; self.makeUUID = makeUUID
    }

    /// 判断该导出是否存在暂停的媒体导入任务。
    ///
    /// 用于让源端投递在上一进程暂停后不再无限等待为「空闲」。
    ///
    /// - Parameter exportID: 目标导出标识。
    /// - Returns: 存在暂停任务且收件箱仍待处理时为 `true`。
    /// - Throws: 连接不支持 SQL 时抛出 ``V2ForwardInboxError/corruptPersistenceState``。
    func hasPausedImport(exportID: UUID) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
        return try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM im_v2.message_forward_media_imports AS job
                JOIN im_v2.message_forward_inbox AS inbox ON inbox.export_id = job.export_id
                WHERE job.export_id = \(bind: exportID) AND job.state = 'paused' AND inbox.state = 'pending'
            ) AS value
            """).first(decoding: ImportPausedRow.self)?.value == true
    }

    /// 认领一次媒体导入任务。
    ///
    /// 事务先锁定目标收件箱，仅在其处于待处理状态时继续；随后在付出对象 I/O 之前
    /// 复核目标房间存在性与当前权限，因此权限变化会让本次认领直接失败。
    ///
    /// - Parameters:
    ///   - exportID: 目标导出标识。
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数，需大于零且不超过 3600。
    /// - Returns: 本次导入租约；收件箱不在待处理状态时返回 `nil`。
    /// - Throws: 租约时长越界时抛出 ``V2ForwardMediaCopyError/invalidReceipt``；
    ///   目标房间不存在时抛出 ``V2ForwardInboxError/targetNotFound``；
    ///   时刻不可编码或归属校验失败时抛出
    ///   ``V2ForwardInboxError/corruptPersistenceState``。
    public func claim(exportID: UUID, now: Date, leaseDuration: TimeInterval) async throws -> V2ForwardMediaImportLease? {
        guard leaseDuration.isFinite, leaseDuration > 0, leaseDuration <= 3_600 else { throw V2ForwardMediaCopyError.invalidReceipt }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
            let inbox = try await v2LockForwardInbox(exportID: exportID, sql: sql)
            guard inbox.state == "pending" else { return nil }
            guard let leaseExpiresAt = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            let currentTime = try V2PostgresTimestamp(date: now)
            let export = try inbox.export
            // Check current target permissions before spending object I/O.
            // Acceptance repeats this check after all files become ready.
            guard try await sql.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: export.intent.targetRoomID) FOR UPDATE").first() != nil else { throw V2ForwardInboxError.targetNotFound }
            try await v2AssertForwardInboxOwner(.init(export: export, mediaIDs: []), sql: sql)
            guard let actor = try await sql.raw("""
                SELECT room.room_kind, room.frozen_at, membership.role,
                       COALESCE(profile.state = 'active', FALSE) AND NOT EXISTS (
                           SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: export.intent.actorUserID)
                       ) AS active,
                       EXISTS (SELECT 1 FROM im_v2.room_member_mutes AS mute
                               WHERE mute.room_id = room.room_id AND mute.user_id = \(bind: export.intent.actorUserID)
                                 AND mute.mute_until > \(bind: now)) AS muted
                FROM im_v2.rooms AS room
                LEFT JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id AND membership.user_id = \(bind: export.intent.actorUserID)
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision)
                LEFT JOIN im_v2.public_user_profiles AS profile ON profile.user_id = \(bind: export.intent.actorUserID)
                WHERE room.room_id = \(bind: export.intent.targetRoomID)
                """).first(decoding: ImportActorRow.self) else { throw V2ForwardInboxError.targetNotFound }
            do {
                try await v2AuthorizeContentWrite(roomID: export.intent.targetRoomID, isGroup: actor.kind == "group",
                    frozenAt: actor.frozenAt, actorIsActive: actor.active, actorRole: actor.role, isMuted: actor.muted, sql: sql)
            } catch let error as V2RoomWriteStoreError {
                let code: String
                switch error {
                case .roomFrozen: code = "ROOM_FROZEN"
                case .actorMuted: code = "ACTOR_MUTED"
                case .actorNotEligible: code = "FORBIDDEN"
                default: throw error
                }
                _ = try await v2RejectForwardInbox(inbox, code: code, now: now, sql: sql)
                return nil
            }
            guard let pending = try await sql.raw("""
                SELECT ordinal, source_media_id FROM im_v2.message_forward_inbox_media
                WHERE export_id = \(bind: exportID) AND state = 'pending' ORDER BY ordinal LIMIT 1 FOR UPDATE
                """).first(decoding: ImportPendingRow.self) else { return nil }
            guard pending.ordinal >= 0, pending.ordinal < export.intent.media.count,
                  export.intent.media[pending.ordinal].mediaID == pending.sourceID
            else { throw V2ForwardInboxError.corruptPersistenceState }
            let manifest = export.intent.media[pending.ordinal]
            if try await readJob(exportID: exportID, ordinal: pending.ordinal, sql: sql) == nil {
                guard let mediaExpiresAt = v2PostgresFutureTimestamp(now: now, interval: temporaryLifetime) else {
                    throw V2ForwardInboxError.corruptPersistenceState
                }
                let targetID = makeUUID(), uploadID = makeUUID()
                guard targetID != manifest.mediaID else { throw V2ForwardMediaCopyError.contentConflict }
                try await sql.raw("""
                    INSERT INTO im_v2.media_objects
                        (media_id, owner_user_id, content_type, byte_count, state, upload_session_id, expires_at, state_updated_at, created_at)
                    VALUES (\(bind: targetID), \(bind: export.intent.actorUserID), \(bind: manifest.contentType), \(bind: manifest.byteCount),
                            'pending_upload', \(bind: uploadID), \(bind: mediaExpiresAt), \(bind: now), \(bind: now))
                    """).run()
                try await sql.raw("""
                    INSERT INTO im_v2.message_forward_media_imports
                        (export_id, ordinal, target_media_id, target_upload_session_id, state, created_at)
                    VALUES (\(bind: exportID), \(bind: pending.ordinal), \(bind: targetID), \(bind: uploadID), 'pending', \(bind: now))
                    """).run()
            }
            guard let job = try await readJob(exportID: exportID, ordinal: pending.ordinal, sql: sql) else { throw V2ForwardInboxError.corruptPersistenceState }
            if job.state == "paused" { return nil }
            guard job.state == "pending" || job.state == "claimed" else { throw V2ForwardInboxError.corruptPersistenceState }
            if let deadline = job.retryAt, deadline.microseconds > currentTime.microseconds { return nil }
            if job.state == "claimed", let deadline = job.expiresAt, deadline.microseconds > currentTime.microseconds { return nil }
            guard job.attempt >= 0, job.attempt < Int64.max, job.attempt < Int64(Int.max) else { throw V2ForwardInboxError.corruptPersistenceState }
            let token = makeUUID(), expires = leaseExpiresAt
            try await sql.raw("""
                UPDATE im_v2.message_forward_media_imports SET state = 'claimed', claim_token = \(bind: token),
                    lease_expires_at = \(bind: expires), next_attempt_at = NULL, retry_count = retry_count + 1
                WHERE export_id = \(bind: exportID) AND ordinal = \(bind: pending.ordinal)
                """).run()
            return .init(export: export, ordinal: pending.ordinal, targetMediaID: .init(uuid: job.targetID),
                         targetUploadSessionID: job.uploadID, copiedDigest: job.digest, claimToken: token,
                         attempt: Int(job.attempt) + 1, expiresAt: expires)
        }
    }

    /// 记录已完成的字节复制，并按租约栅栏判断是否仍然有效。
    ///
    /// - Parameters:
    ///   - lease: 本次导入租约。
    ///   - receipt: 复制回执。
    ///   - now: 记录时刻。
    /// - Returns: 记录生效时为 `true`；租约已被取代时为 `false`。
    /// - Throws: 持久化失败时抛出。
    public func recordCopied(_ lease: V2ForwardMediaImportLease, receipt: V2ForwardMediaCopyReceipt, now: Date) async throws -> Bool {
        guard receipt.byteCount == lease.source.byteCount else { throw V2ForwardMediaCopyError.byteCountMismatch }
        return try await mutate(lease, now: now) { sql, job, _ in
            guard job.digest == nil || job.digest == receipt.digest else { throw V2ForwardMediaCopyError.contentConflict }
            try await sql.raw("""
                UPDATE im_v2.message_forward_media_imports SET copied_digest = \(bind: receipt.digest), copied_at = COALESCE(copied_at, \(bind: now))
                WHERE export_id = \(bind: lease.export.intent.exportID) AND ordinal = \(bind: lease.ordinal)
                """).run()
            guard try await sql.raw("""
                UPDATE im_v2.media_objects SET state = 'scanning', state_updated_at = \(bind: now)
                WHERE media_id = \(bind: job.targetID) AND upload_session_id = \(bind: job.uploadID)
                  AND state IN ('pending_upload', 'scanning') RETURNING media_id
                """).first() != nil else { throw V2ForwardInboxError.corruptPersistenceState }
        }
    }

    /// 记录复制与扫描均完成的结果。
    ///
    /// - Parameters:
    ///   - lease: 本次导入租约。
    ///   - receipt: 复制回执。
    ///   - result: 扫描结论。
    ///   - now: 完成时刻。
    /// - Returns: 记录生效时为 `true`；租约已被取代时为 `false`。
    /// - Throws: 持久化失败时抛出。
    public func complete(_ lease: V2ForwardMediaImportLease, receipt: V2ForwardMediaCopyReceipt, result: V2MediaScanResult, now: Date) async throws -> Bool {
        try await mutate(lease, now: now) { sql, job, inbox in
            guard job.digest == receipt.digest, receipt.byteCount == lease.source.byteCount else { throw V2ForwardMediaCopyError.contentConflict }
            guard result == .passed else { try await reject(job: job, lease: lease, inbox: inbox, now: now, sql: sql); return }
            guard let mediaExpiresAt = v2PostgresFutureTimestamp(now: now, interval: temporaryLifetime) else {
                throw V2ForwardInboxError.corruptPersistenceState
            }
            let updated = try await sql.raw("""
                UPDATE im_v2.media_objects SET state = 'available', state_updated_at = \(bind: now), expires_at = GREATEST(expires_at, \(bind: mediaExpiresAt))
                WHERE media_id = \(bind: job.targetID) AND upload_session_id = \(bind: job.uploadID)
                  AND owner_user_id = \(bind: lease.export.intent.actorUserID) AND state = 'scanning'
                  AND content_type = \(bind: lease.source.contentType) AND byte_count = \(bind: lease.source.byteCount)
                RETURNING media_id
                """).first()
            guard updated != nil else { throw V2ForwardInboxError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.message_forward_inbox_media SET state = 'ready', target_media_id = \(bind: job.targetID), object_digest = \(bind: receipt.digest)
                WHERE export_id = \(bind: lease.export.intent.exportID) AND ordinal = \(bind: lease.ordinal) AND state = 'pending'
                """).run()
            try await sql.raw("""
                UPDATE im_v2.message_forward_media_imports SET state = 'ready', claim_token = NULL, lease_expires_at = NULL, completed_at = \(bind: now)
                WHERE export_id = \(bind: lease.export.intent.exportID) AND ordinal = \(bind: lease.ordinal)
                """).run()
        }
    }

    /// 把导入标记为确定拒绝。
    ///
    /// - Parameters:
    ///   - lease: 本次导入租约。
    ///   - now: 记录时刻。
    /// - Returns: 记录生效时为 `true`；租约已被取代时为 `false`。
    /// - Throws: 持久化失败时抛出。
    public func reject(_ lease: V2ForwardMediaImportLease, now: Date) async throws -> Bool {
        try await mutate(lease, now: now) { sql, job, inbox in
            try await reject(job: job, lease: lease, inbox: inbox, now: now, sql: sql)
        }
    }

    /// 按处置结果安排重试或暂停。
    ///
    /// - Parameters:
    ///   - lease: 本次导入租约。
    ///   - disposition: 下一步处置。
    ///   - now: 记录时刻。
    /// - Returns: 记录生效时为 `true`；租约已被取代时为 `false`。
    /// - Throws: 持久化失败时抛出。
    public func retry(_ lease: V2ForwardMediaImportLease, disposition: V2DurableRetryDisposition, now: Date) async throws -> Bool {
        try await mutate(lease, now: now) { sql, _, _ in
            let state: String, deadline: Date?
            switch disposition {
            case .retry(let date):
                guard v2PostgresTimestampCanEncode(date) else { throw V2ForwardInboxError.corruptPersistenceState }
                state = "pending"; deadline = date
            case .pause: state = "paused"; deadline = nil
            }
            try await sql.raw("""
                UPDATE im_v2.message_forward_media_imports SET state = \(bind: state), claim_token = NULL, lease_expires_at = NULL, next_attempt_at = \(bind: deadline)
                WHERE export_id = \(bind: lease.export.intent.exportID) AND ordinal = \(bind: lease.ordinal)
                """).run()
        }
    }

    private func reject(job: ImportJobRow, lease: V2ForwardMediaImportLease, inbox: ForwardInboxRow, now: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("""
            UPDATE im_v2.media_objects SET state = 'failed', state_updated_at = \(bind: now), expires_at = \(bind: now)
            WHERE media_id = \(bind: job.targetID) AND upload_session_id = \(bind: job.uploadID) AND state IN ('pending_upload', 'scanning')
            """).run()
        try await sql.raw("""
            UPDATE im_v2.message_forward_media_imports SET state = 'failed', claim_token = NULL, lease_expires_at = NULL, completed_at = \(bind: now)
            WHERE export_id = \(bind: lease.export.intent.exportID) AND ordinal = \(bind: lease.ordinal)
            """).run()
        _ = try await v2RejectForwardInbox(inbox, code: "MEDIA_UNAVAILABLE", now: now, sql: sql)
    }

    private func mutate(_ lease: V2ForwardMediaImportLease, now: Date,
                        _ action: @escaping @Sendable (any SQLDatabase, ImportJobRow, ForwardInboxRow) async throws -> Void) async throws -> Bool {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
            let inbox = try await v2LockForwardInbox(exportID: lease.export.intent.exportID, sql: sql)
            guard inbox.state == "pending", inbox.payload == lease.export.payload, inbox.digest == lease.export.digest else { return false }
            guard try await sql.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: lease.export.intent.targetRoomID) FOR UPDATE").first() != nil else { throw V2ForwardInboxError.targetNotFound }
            try await v2AssertForwardInboxOwner(.init(export: lease.export, mediaIDs: []), sql: sql)
            guard let job = try await readJob(exportID: lease.export.intent.exportID, ordinal: lease.ordinal, sql: sql),
                  job.state == "claimed", job.token == lease.claimToken, job.targetID == lease.targetMediaID.uuidValue,
                  job.uploadID == lease.targetUploadSessionID, let deadline = job.expiresAt
            else { return false }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
            let currentTime = try V2PostgresTimestamp(date: now)
            guard deadline.microseconds > currentTime.microseconds else { return false }
            try await action(sql, job, inbox)
            return true
        }
    }

    private func readJob(exportID: UUID, ordinal: Int, sql: any SQLDatabase) async throws -> ImportJobRow? {
        try await sql.raw("""
            SELECT target_media_id, target_upload_session_id, state, copied_digest, claim_token, lease_expires_at, next_attempt_at, retry_count
            FROM im_v2.message_forward_media_imports WHERE export_id = \(bind: exportID) AND ordinal = \(bind: ordinal) FOR UPDATE
            """).first(decoding: ImportJobRow.self)
    }
}

private struct ImportJobRow: Decodable, Sendable {
    let targetID: UUID; let uploadID: UUID; let state: String; let digest: Data?
    let token: UUID?; let expiresAt: V2PostgresTimestamp?; let retryAt: V2PostgresTimestamp?; let attempt: Int64
    enum CodingKeys: String, CodingKey {
        case state; case targetID = "target_media_id", uploadID = "target_upload_session_id", digest = "copied_digest"
        case token = "claim_token", expiresAt = "lease_expires_at", retryAt = "next_attempt_at", attempt = "retry_count"
    }
}
private struct ImportPausedRow: Decodable { let value: Bool }
private struct ImportPendingRow: Decodable {
    let ordinal: Int; let sourceID: UUID
    enum CodingKeys: String, CodingKey { case ordinal; case sourceID = "source_media_id" }
}
private struct ImportActorRow: Decodable {
    let kind: String; let frozenAt: Date?; let role: String?; let active: Bool; let muted: Bool
    enum CodingKeys: String, CodingKey { case role, active, muted; case kind = "room_kind", frozenAt = "frozen_at" }
}
