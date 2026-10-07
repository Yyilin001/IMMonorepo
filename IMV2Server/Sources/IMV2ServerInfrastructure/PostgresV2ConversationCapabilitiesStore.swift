import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Room-owner facts, revision tombstones and immutable operation receipts share one transaction.
public struct PostgresV2ConversationCapabilitiesStore: V2ConversationCapabilitiesStore {
    private let database: any Database
    private let activationScope: V2RoomActivationWriteScope?
    public init(database: any Database, activationScope: V2RoomActivationWriteScope? = nil) {
        self.database = database
        self.activationScope = activationScope
    }
    public func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) async throws
        -> V2PersonalPreferenceReceipt
    {
        if let muteUntil = command.muteUntil, !v2PostgresTimestampCanEncode(muteUntil) {
            throw V2ConversationCapabilitiesStoreError.invalidTimestamp
        }
        let identity = try command.identity(actorUserID: actorUserID)
        let fingerprint = try command.fingerprint(actorUserID: actorUserID)
        let receipt = try await submit(
            identity: identity, fingerprint: fingerprint, deadline: command.firstSubmissionDeadlineMilliseconds,
            expected: command.expectedRevision, now: now
        ) { sql, actor, room, current, time in
            guard current < Int64.max else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let revision = current + 1
            let pinned = command.isPinned ? time : nil
            let archived = command.isArchived ? time : nil
            try await sql.raw(
                "INSERT INTO im_v2.user_room_preferences(user_id,room_id,pinned_at,archived_at,mute_until,updated_at,revision) VALUES(\(bind:actor),\(bind:room),\(bind:pinned),\(bind:archived),\(bind:command.muteUntil),\(bind:time),\(bind:revision)) ON CONFLICT(user_id,room_id) DO UPDATE SET pinned_at=EXCLUDED.pinned_at,archived_at=EXCLUDED.archived_at,mute_until=EXCLUDED.mute_until,updated_at=EXCLUDED.updated_at,revision=EXCLUDED.revision"
            ).run()
            let value = V2ConversationState(
                roomID: command.roomID, isPinned: command.isPinned, isArchived: command.isArchived,
                muteUntil: command.muteUntil, updatedAt: time, revision: .init(rawValue: UInt64(revision))!)
            try await appendStateProjection(
                actor: actor, source: capabilityUUID(command.operationID), value: value, now: time, sql: sql)
            return .conversationState(value)
        }
        return receipt
    }
    public func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) async throws
        -> V2PersonalPreferenceReceipt
    {
        let identity = try command.identity(actorUserID: actorUserID)
        let fingerprint = try command.fingerprint(actorUserID: actorUserID)
        let receipt = try await submit(
            identity: identity, fingerprint: fingerprint, deadline: command.firstSubmissionDeadlineMilliseconds,
            expected: command.expectedRevision, now: now
        ) { sql, actor, room, current, time in
            guard current < Int64.max else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let message = try capabilityUUID(command.messageID)
            let revision = current + 1
            try await sql.raw(
                "INSERT INTO im_v2.user_message_favorites(user_id,message_id,room_id,is_favorited,created_at,revision) VALUES(\(bind:actor),\(bind:message),\(bind:room),\(bind:command.isFavorited),\(bind:time),\(bind:revision)) ON CONFLICT(user_id,message_id) DO UPDATE SET is_favorited=EXCLUDED.is_favorited,created_at=EXCLUDED.created_at,revision=EXCLUDED.revision"
            ).run()
            let value = V2MessageFavorite(
                roomID: command.roomID, messageID: command.messageID, isFavorited: command.isFavorited, updatedAt: time,
                revision: .init(rawValue: UInt64(revision))!)
            try await appendFavoriteProjection(
                actor: actor, source: capabilityUUID(command.operationID), value: value, now: time, sql: sql)
            return .messageFavorite(value)
        }
        return receipt
    }
    private func submit(
        identity: V2OperationIdentity, fingerprint: V2OperationFingerprint, deadline: UInt64,
        expected: V2PersonalPreferenceRevision, now: Date,
        apply: @escaping @Sendable (any SQLDatabase, UUID, UUID, Int64, Date) async throws -> V2PersonalPreferenceValue
    ) async throws -> V2PersonalPreferenceReceipt {
        try await v2WithPostgresTransactionRetry(
            database: database, maximumRetryCount: 0, classifyCommitFailure: activationScope != nil,
            useRoomDeadline: activationScope != nil
        ) { tx in
            guard let sql = tx as? any SQLDatabase else {
                throw V2ConversationCapabilitiesStoreError.corruptPersistenceState
            }
            let actor = try capabilityUUID(identity.accountID)
            let room = try roomUUID(identity)
            try await prepare(identity: identity, room: room, sql: sql)
            if let old = try await read(identity: identity, sql: sql) {
                guard old.fingerprint == fingerprint else {
                    throw V2ConversationCapabilitiesStoreError.operationPayloadMismatch
                }
                return old
            }
            // Lock the room before testing membership and the revision fence. Absent facts also serialize.
            var rejection: V2PersonalPreferenceRejection?
            do {
                try await assertActiveMember(actor: actor, room: room, sql: sql)
            } catch V2ConversationCapabilitiesStoreError.roomNotFound {
                rejection = .notFound
            } catch V2ConversationCapabilitiesStoreError.actorNotMember { rejection = .permissionDenied }
            if rejection == nil, case .message(_, let messageID) = identity.scope {
                let exists =
                    try await sql.raw(
                        "SELECT EXISTS(SELECT 1 FROM im_v2.messages WHERE room_id=\(bind:room) AND message_id=\(bind:capabilityUUID(messageID))) AS value"
                    ).first(decoding: CapabilityBooleanRow.self)?.value ?? false
                if !exists { rejection = .notFound }
            }
            guard
                let time = try await sql.raw("SELECT clock_timestamp() AS value").first(
                    decoding: PreferenceClockRow.self)?.value,
                let millis = Int64(exactly: (time.timeIntervalSince1970 * 1000).rounded(.towardZero)), millis >= 0
            else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            if rejection == nil, UInt64(millis) > deadline { rejection = .expiredUnsubmitted }
            var current: Int64 = 0
            if rejection == nil {
                switch identity.scope {
                case .room:
                    current =
                        try await sql.raw(
                            "SELECT revision AS value FROM im_v2.user_room_preferences WHERE user_id=\(bind:actor) AND room_id=\(bind:room) FOR UPDATE"
                        ).first(decoding: PreferenceRevisionRow.self)?.value ?? 0
                case .message(_, let message):
                    current =
                        try await sql.raw(
                            "SELECT revision AS value FROM im_v2.user_message_favorites WHERE user_id=\(bind:actor) AND message_id=\(bind:capabilityUUID(message)) FOR UPDATE"
                        ).first(decoding: PreferenceRevisionRow.self)?.value ?? 0
                default: throw V2ConversationCapabilitiesStoreError.corruptPersistenceState
                }
                if current != expected.signedValue || current == Int64.max {
                    rejection = .revisionConflict(current: .init(rawValue: UInt64(current))!)
                }
            }
            let outcome: V2PersonalPreferenceTerminalOutcome
            if let rejection {
                outcome = .rejected(rejection)
            } else {
                outcome = .committed(try await apply(sql, actor, room, current, time))
            }
            return try await record(
                identity: identity, fingerprint: fingerprint, outcome: outcome, time: time, sql: sql)
        }
    }
    public func recover(actorUserID: UserID, request: V2PersonalPreferenceRecoveryRequest, now: Date) async throws
        -> V2PersonalPreferenceRecoveryResult
    {
        guard request.identity.accountID == actorUserID else {
            throw V2ConversationCapabilitiesStoreError.actorNotMember
        }
        return try await v2WithPostgresTransactionRetry(
            database: database, maximumRetryCount: 0, classifyCommitFailure: activationScope != nil,
            useRoomDeadline: activationScope != nil
        ) { tx in
            guard let sql = tx as? any SQLDatabase else {
                throw V2ConversationCapabilitiesStoreError.corruptPersistenceState
            }
            try await prepare(identity: request.identity, room: capabilityUUID(request.roomID), sql: sql)
            if let receipt = try await read(identity: request.identity, sql: sql) {
                return receipt.fingerprint == request.fingerprint ? .receipt(receipt) : .fingerprintConflict
            }
            guard request.action == .closeIfAbsent else { return .unresolved }
            guard
                let time = try await sql.raw("SELECT clock_timestamp() AS value").first(
                    decoding: PreferenceClockRow.self)?.value
            else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            return .receipt(
                try await record(
                    identity: request.identity, fingerprint: request.fingerprint, outcome: .closed, time: time, sql: sql
                ))
        }
    }
    private func prepare(identity: V2OperationIdentity, room: UUID, sql: any SQLDatabase) async throws {
        if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:identity.storageKey),0))").run()
        if let activationScope { try await activationScope.require([room], sql: sql) }
    }
    private func read(identity: V2OperationIdentity, sql: any SQLDatabase) async throws -> V2PersonalPreferenceReceipt?
    {
        guard
            let row = try await sql.raw(
                "SELECT receipt::text AS value,fingerprint_version,request_fingerprint,kind,actor_user_id,operation_id,room_id,outcome_kind FROM im_v2.personal_preference_operation_receipts WHERE identity_key=\(bind:identity.storageKey)"
            ).first(decoding: PreferenceReceiptRow.self)
        else { return nil }
        let receipt = try JSONDecoder().decode(V2PersonalPreferenceReceipt.self, from: Data(row.value.utf8))
        let expectedOutcome: String
        switch receipt.outcome {
        case .committed: expectedOutcome = "committed"
        case .rejected: expectedOutcome = "rejected"
        case .closed: expectedOutcome = "closed"
        }
        guard row.outcomeKind == expectedOutcome, receipt.identity == identity,
            Int16(exactly: receipt.fingerprint.version) == row.fingerprintVersion,
            receipt.fingerprint.digest == row.requestFingerprint,
            row.kind == identity.kind.rawValue, row.actorUserID == identity.accountID.uuidValue,
            row.operationID.uuidString.lowercased() == identity.operation.rawOperationID.lowercased(),
            row.roomID == (try roomUUID(identity))
        else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
        return receipt
    }
    private func record(
        identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
        outcome: V2PersonalPreferenceTerminalOutcome, time: Date, sql: any SQLDatabase
    ) async throws -> V2PersonalPreferenceReceipt {
        guard let operationUUID = UUID(uuidString: identity.operation.rawOperationID),
            let millis = UInt64(exactly: (time.timeIntervalSince1970 * 1000).rounded(.towardZero))
        else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
        let receipt = try V2PersonalPreferenceReceipt(
            identity: identity, fingerprint: fingerprint, outcome: outcome, resolvedAtMilliseconds: millis)
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        let outcomeKind: String
        switch outcome {
        case .committed: outcomeKind = "committed"
        case .rejected: outcomeKind = "rejected"
        case .closed: outcomeKind = "closed"
        }
        try await sql.raw(
            "INSERT INTO im_v2.personal_preference_operation_receipts(identity_key,actor_user_id,operation_id,room_id,kind,fingerprint_version,request_fingerprint,outcome_kind,receipt,created_at) VALUES(\(bind:identity.storageKey),\(bind:capabilityUUID(identity.accountID)),\(bind:operationUUID),\(bind:roomUUID(identity)),\(bind:identity.kind.rawValue),\(bind:Int16(fingerprint.version)),\(bind:fingerprint.digest),\(bind:outcomeKind),\(bind:json)::jsonb,\(bind:time))"
        ).run()
        return receipt
    }
    private func roomUUID(_ identity: V2OperationIdentity) throws -> UUID {
        switch identity.scope {
        case .room(let room), .message(let room, _): return try capabilityUUID(room)
        default: throw V2ConversationCapabilitiesStoreError.corruptPersistenceState
        }
    }
    private func assertActiveMember(actor: UUID, room: UUID, sql: any SQLDatabase) async throws {
        guard
            let revision = try await sql.raw(
                "SELECT membership_revision FROM im_v2.rooms WHERE room_id = \(bind: room) FOR UPDATE"
            ).first(decoding: CapabilityRoomRow.self)?.membershipRevision
        else { throw V2ConversationCapabilitiesStoreError.roomNotFound }
        let member =
            try await sql.raw(
                "SELECT EXISTS (SELECT 1 FROM im_v2.room_memberships WHERE room_id = \(bind: room) AND user_id = \(bind: actor) AND joined_revision <= \(bind: revision) AND (left_revision IS NULL OR left_revision > \(bind: revision))) AS value"
            ).first(decoding: CapabilityBooleanRow.self)?.value ?? false
        guard member else { throw V2ConversationCapabilitiesStoreError.actorNotMember }
    }
    // 向存储绑定原始时钟值；响应日期解码后若重新编码，可能再损失一微秒。
    // 载荷时间戳使用已提交值。
    private func appendStateProjection(
        actor: UUID, source: UUID, value: V2ConversationState, now: Date, sql: any SQLDatabase
    ) async throws {
        try await sql.raw(
            "INSERT INTO im_v2.user_state_event_outbox (user_id, source_event_id, projection_kind, payload, created_at, next_attempt_at, source_room_id) VALUES (\(bind: actor), \(bind: source), 'conversation_state', jsonb_build_object('room_id', \(bind: value.roomID.rawValue), 'is_pinned', \(bind: value.isPinned), 'is_archived', \(bind: value.isArchived), 'mute_until_ms', \(bind: value.muteUntil.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0), 'revision', \(bind: value.revision.signedValue), 'updated_at_ms', \(bind: Int64(value.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: now), \(bind: now), \(bind: capabilityUUID(value.roomID)))"
        ).run()
    }
    private func appendFavoriteProjection(
        actor: UUID, source: UUID, value: V2MessageFavorite, now: Date, sql: any SQLDatabase
    ) async throws {
        try await sql.raw(
            "INSERT INTO im_v2.user_state_event_outbox (user_id, source_event_id, projection_kind, payload, created_at, next_attempt_at, source_room_id) VALUES (\(bind: actor), \(bind: source), 'message_favorite', jsonb_build_object('room_id', \(bind: value.roomID.rawValue), 'message_id', \(bind: value.messageID.rawValue), 'is_favorited', \(bind: value.isFavorited), 'revision', \(bind: value.revision.signedValue), 'updated_at_ms', \(bind: Int64(value.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: now), \(bind: now), \(bind: capabilityUUID(value.roomID)))"
        ).run()
    }

}
private struct PreferenceReceiptRow: Decodable {
    let value: String
    let fingerprintVersion: Int16
    let requestFingerprint: Data
    let kind: String
    let actorUserID: UUID
    let operationID: UUID
    let roomID: UUID
    let outcomeKind: String
    enum CodingKeys: String, CodingKey {
        case value, kind
        case fingerprintVersion = "fingerprint_version"
        case requestFingerprint = "request_fingerprint"
        case actorUserID = "actor_user_id"
        case operationID = "operation_id"
        case roomID = "room_id"
        case outcomeKind = "outcome_kind"
    }
}
private struct PreferenceClockRow: Decodable { let value: Date }
private struct PreferenceRevisionRow: Decodable { let value: Int64 }
private struct CapabilityRoomRow: Decodable {
    let membershipRevision: Int64
    enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision" }
}
private struct CapabilityBooleanRow: Decodable { let value: Bool }
private func capabilityUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let uuid = UUID(uuidString: id.rawValue) else {
        throw V2ConversationCapabilitiesStoreError.corruptPersistenceState
    }
    return uuid
}
