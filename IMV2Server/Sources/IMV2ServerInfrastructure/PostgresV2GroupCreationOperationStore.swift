import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// The control owner persists the exact audience and fixed placement before any
/// room-owner I/O. Finalizing is irreversible; closure cannot race creation.
public struct PostgresV2GroupCreationOperationStore: Sendable {
    private let database: any Database
    private let selector: V2GroupRoomShardSelector
    private let bootstrap: V2ActorCreationBootstrapPort
    private let capacityProfile: V2CapacityProfile
    public init(database: any Database, selector: V2GroupRoomShardSelector, bootstrap: V2ActorCreationBootstrapPort, capacityProfile: V2CapacityProfile) {
        self.database = database; self.selector = selector; self.bootstrap = bootstrap; self.capacityProfile = capacityProfile
    }
    public func begin(_ intent: V2GroupCreationIntent, now: Date = Date()) async throws -> V2GroupCreationOperationResult {
        try await database.transaction { tx in
            let sql = try sqlDatabase(tx); try await lock(intent, sql: sql)
            if let row = try await read(intent, sql: sql) { return try await result(row, intent: intent, sql: sql) }
            let ms = try milliseconds(now)
            if ms >= intent.firstSubmissionDeadlineMilliseconds { return try await insertTerminal(intent, outcome: .rejected(.submissionExpired), now: now, sql: sql) }
            guard intent.firstSubmissionDeadlineMilliseconds - ms <= 600_000 else { throw V2GroupCreationValidationError.invalidIntent }
            guard intent.initialMemberCount + 1 <= capacityProfile.limits.maxEligibleMembers else { return try await insertTerminal(intent, outcome: .rejected(.creationDenied), now: now, sql: sql) }
            guard try await active(intent.identity.accountID, sql: sql) else { return try await insertTerminal(intent, outcome: .rejected(.creationDenied), now: now, sql: sql) }
            let actor = intent.identity.accountID.uuidValue!
            try await expireStaging(actor, now: now, sql: sql)
            let count = try await sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.group_creation_operations WHERE actor_user_id = \(bind: actor) AND phase IN ('staging','finalizing')").first(decoding: Count.self)?.value ?? 3
            guard count < 3 else { return .deferred(try hint(intent, seconds: 30)) }
            try await insert(intent, phase: "staging", receipt: nil, now: now, sql: sql)
            guard let row = try await read(intent, sql: sql) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            return try await result(row, intent: intent, sql: sql)
        }
    }
    public func append(_ request: V2GroupCreationAppendRequest, now: Date = Date()) async throws -> V2GroupCreationOperationResult {
        try await database.transaction { tx in
            let sql = try sqlDatabase(tx); let intent = request.intent; try await lock(intent, sql: sql)
            guard let row = try await read(intent, sql: sql) else { return .unresolved }
            guard try matches(row, intent: intent) else { return .fingerprintConflict }
            if row.phase != "staging" { return try await result(row, intent: intent, sql: sql) }
            // A replay of an already accepted exact page remains reachable after expiry.
            let pages = try await pages(intent, sql: sql)
            if let old = pages.first(where: { $0.offset == request.offset }) {
                guard old.fingerprint == request.pageFingerprint, old.members == request.memberUserIDs else { return .fingerprintConflict }
                return try await result(row, intent: intent, sql: sql)
            }
            guard try milliseconds(now) < intent.firstSubmissionDeadlineMilliseconds else { return try await finish(row, intent: intent, outcome: .rejected(.submissionExpired), now: now, sql: sql) }
            guard try await active(intent.identity.accountID, sql: sql) else { return try await finish(row, intent: intent, outcome: .rejected(.creationDenied), now: now, sql: sql) }
            let members = pages.flatMap(\.members)
            guard request.offset == members.count else { return try await result(row, intent: intent, sql: sql) }
            let all = members + request.memberUserIDs
            guard (try? V2GroupCreationAudience.digest(all)) != nil else { return .fingerprintConflict }
            let encodedMembers = try json(request.memberUserIDs)
            let count = try await sql.raw("""
                SELECT COUNT(*)::bigint AS value FROM jsonb_array_elements(\(bind: encodedMembers)::jsonb) AS value
                JOIN im_v2.public_user_profiles p ON p.user_id = (value->>'rawValue')::uuid AND p.state = 'active'
                LEFT JOIN im_v2.account_disables d ON d.user_id = p.user_id WHERE d.user_id IS NULL
                """).first(decoding: Count.self)?.value ?? -1
            guard count == Int64(request.memberUserIDs.count) else { return try await finish(row, intent: intent, outcome: .rejected(.invalidAudience), now: now, sql: sql) }
            try await sql.raw("INSERT INTO im_v2.group_creation_pages(actor_user_id,operation_id,page_offset,page_fingerprint,members) VALUES (\(bind: intent.identity.accountID.uuidValue!),\(bind: operationUUID(intent)),\(bind: request.offset),\(bind: try json(request.pageFingerprint))::jsonb,\(bind: encodedMembers)::jsonb)").run()
            try await sql.raw("UPDATE im_v2.group_creation_operations SET accepted_member_count = \(bind: all.count),updated_at = \(bind: now) WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationUUID(intent))").run()
            guard let updated = try await read(intent, sql: sql) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            return try await result(updated, intent: intent, sql: sql)
        }
    }
    public func finalize(_ intent: V2GroupCreationIntent, now: Date = Date(), deadline: ContinuousClock.Instant) async throws -> V2GroupCreationOperationResult {
        let preparation: Preparation = try await database.transaction { tx in
            let sql = try sqlDatabase(tx); try await lock(intent, sql: sql)
            guard let row = try await read(intent, sql: sql) else { return .result(.unresolved) }
            guard try matches(row, intent: intent) else { return .result(.fingerprintConflict) }
            guard row.phase == "staging" || row.phase == "finalizing" else { return .result(try await result(row, intent: intent, sql: sql)) }
            let audience = try await pages(intent, sql: sql).flatMap(\.members)
            guard audience.count == intent.initialMemberCount else { return .result(try await result(row, intent: intent, sql: sql)) }
            guard try V2GroupCreationAudience.digest(audience) == intent.audienceDigest else {
                guard row.phase == "staging" else { throw V2GroupMessagingStoreError.corruptPersistenceState }
                return .result(try await finish(row, intent: intent, outcome: .rejected(.invalidAudience), now: now, sql: sql))
            }
            if row.phase == "staging" {
                guard try milliseconds(now) < intent.firstSubmissionDeadlineMilliseconds else { return .result(try await finish(row, intent: intent, outcome: .rejected(.submissionExpired), now: now, sql: sql)) }
                guard try await active(intent.identity.accountID, sql: sql) else { return .result(try await finish(row, intent: intent, outcome: .rejected(.creationDenied), now: now, sql: sql)) }
                let encoded = try json(audience.map { $0.uuidValue!.uuidString })
                let valid = try await sql.raw("SELECT COUNT(*)::bigint AS value FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value JOIN im_v2.public_user_profiles p ON p.user_id = value::uuid AND p.state = 'active' LEFT JOIN im_v2.account_disables d ON d.user_id = p.user_id WHERE d.user_id IS NULL").first(decoding: Count.self)?.value ?? -1
                guard valid == Int64(audience.count) else { return .result(try await finish(row, intent: intent, outcome: .rejected(.invalidAudience), now: now, sql: sql)) }
                try await sql.raw("UPDATE im_v2.group_creation_operations SET phase = 'finalizing',updated_at = \(bind: now) WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationUUID(intent))").run()
            }
            return .create(try placement(row, intent: intent), audience, row.copied)
        }
        switch preparation {
        case .result(let result): return result
        case .create(let placement, let audience, let copied):
            let all = ([intent.identity.accountID] + audience).sorted()
            if copied < all.count {
                let offset = copied
                try Task.checkCancellation()
                let end = min(all.count, offset + V2GroupRoomCreationManifestPage.maximumMemberCount)
                let page = try V2GroupRoomCreationManifestPage(pageNumber: offset / V2GroupRoomCreationManifestPage.maximumMemberCount, memberUserIDs: Array(all[offset..<end]), isFinal: end == all.count)
                try await bootstrap.stage(.init(domain: placement), .init(domain: page), deadline)
                let mirrored: V2GroupCreationOperationResult = try await database.transaction { tx in
                    let sql = try sqlDatabase(tx); try await lock(intent, sql: sql)
                    guard let row = try await read(intent, sql: sql), try matches(row, intent: intent) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
                    if row.phase == "committed" { return try await result(row, intent: intent, sql: sql) }
                    guard row.phase == "finalizing" else { throw V2GroupMessagingStoreError.corruptPersistenceState }
                    try await sql.raw("UPDATE im_v2.group_creation_operations SET copied_member_count = GREATEST(copied_member_count, \(bind: end)),updated_at = \(bind: now) WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationUUID(intent))").run()
                    guard let updated = try await read(intent, sql: sql) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
                    return try await result(updated, intent: intent, sql: sql)
                }
                if end < all.count { return mirrored }
            }
            guard case .provenGroup(let ownerResult) = try await bootstrap.execute(.provenGroup(.init(intent: intent, placement: .init(domain: placement))), deadline) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            guard case .receipt(let receipt) = ownerResult else { return ownerResult }
            guard receipt.validates(intent: intent), case .created(let room,_,_,_) = receipt.outcome, room == placement.roomID else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            return try await database.transaction { tx in
                let sql = try sqlDatabase(tx); try await lock(intent, sql: sql)
                guard let row = try await read(intent, sql: sql), try matches(row, intent: intent), row.phase == "finalizing" || row.phase == "committed" else { throw V2GroupMessagingStoreError.corruptPersistenceState }
                try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: row.roomID),\(bind: row.shard),0,\(bind: now),\(bind: now)) ON CONFLICT (room_id) DO NOTHING").run()
                guard let route = try await sql.raw("SELECT room_shard_id AS shard,route_epoch AS epoch FROM im_v2.room_owner_routes WHERE room_id = \(bind: row.roomID)").first(decoding: Route.self), route.shard == row.shard, route.epoch == 0 else { throw V2GroupRoomCreationIntentStoreError.routeConflict }
                if row.phase == "committed" { return try await result(row, intent: intent, sql: sql) }
                try await sql.raw("UPDATE im_v2.group_creation_operations SET phase = 'committed',receipt = \(bind: try json(receipt))::jsonb,updated_at = \(bind: now) WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationUUID(intent))").run()
                try await deleteTerminalPages(intent, sql: sql)
                return .receipt(receipt)
            }
        }
    }
    public func recover(_ request: V2GroupCreationRecoveryRequest, now: Date = Date()) async throws -> V2GroupCreationOperationResult {
        let observation = try await database.transaction { tx -> V2GroupCreationOperationResult in
            let sql = try sqlDatabase(tx); let intent = request.intent; try await lock(intent, sql: sql)
            guard let row = try await read(intent, sql: sql) else {
                return request.action == .closeIfAbsent ? try await insertTerminal(intent, outcome: .closed, now: now, sql: sql) : .unresolved
            }
            guard try matches(row, intent: intent) else { return .fingerprintConflict }
            if request.action == .closeIfAbsent && row.phase == "staging" { return try await finish(row, intent: intent, outcome: .closed, now: now, sql: sql) }
            return try await result(row, intent: intent, sql: sql)
        }
        if case .progress(let progress) = observation, progress.phase == .finalizing {
            // Resume the already frozen identity, even past the original admission window.
            return try await finalize(request.intent, now: now, deadline: ContinuousClock.now.advanced(by: .seconds(12)))
        }
        return observation
    }
    private enum Preparation: Sendable { case result(V2GroupCreationOperationResult), create(V2GroupRoomCreationIntent, [UserID], Int) }
    private struct Count: Decodable { let value: Int64 }
    private struct Route: Decodable { let shard: String; let epoch: Int64 }
    private struct Row: Decodable { let intent: String; let roomID: UUID; let eventID: UUID; let shard: String; let phase: String; let count: Int; let copied: Int; let receipt: String?
        enum CodingKeys: String, CodingKey { case intent,roomID = "room_id",eventID = "event_id",shard,phase,count,copied,receipt } }
    private struct PageRow: Decodable { let offset: Int; let fingerprint: String; let members: String }
    private struct Page: Sendable { let offset: Int; let fingerprint: V2OperationFingerprint; let members: [UserID] }
    private func sqlDatabase(_ database: any Database) throws -> any SQLDatabase { guard let sql = database as? any SQLDatabase else { throw V2GroupMessagingStoreError.corruptPersistenceState }; return sql }
    private func operationUUID(_ intent: V2GroupCreationIntent) -> UUID { UUID(uuidString: intent.identity.operation.rawOperationID)! }
    private func milliseconds(_ now: Date) throws -> UInt64 { guard v2PostgresTimestampCanEncode(now) else { throw V2GroupMessagingStoreError.corruptPersistenceState }; guard let value=UInt64(exactly:try v2GatewayMilliseconds(now)) else { throw V2GroupMessagingStoreError.corruptPersistenceState }; return value }
    private func json<T: Encodable>(_ value: T) throws -> String { guard let result = String(data: try JSONEncoder().encode(value), encoding: .utf8) else { throw V2GroupMessagingStoreError.corruptPersistenceState }; return result }
    private func lock(_ intent: V2GroupCreationIntent, sql: any SQLDatabase) async throws {
        // Actor lock bounds concurrent draft admission; operation lock is shared by every transition.
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "group-creation/" + intent.identity.accountID.rawValue),0))").run()
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: intent.identity.storageKey),0))").run()
    }
    private func active(_ user: UserID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT COUNT(*)::bigint AS value FROM im_v2.public_user_profiles p LEFT JOIN im_v2.account_disables d ON d.user_id = p.user_id WHERE p.user_id = \(bind: user.uuidValue!) AND p.state = 'active' AND d.user_id IS NULL").first(decoding: Count.self)?.value == 1
    }
    private func read(_ intent: V2GroupCreationIntent, sql: any SQLDatabase) async throws -> Row? {
        try await sql.raw("SELECT intent::text AS intent,room_id,event_id,room_shard_id AS shard,phase,accepted_member_count AS count,copied_member_count AS copied,receipt::text AS receipt FROM im_v2.group_creation_operations WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationUUID(intent)) FOR UPDATE").first(decoding: Row.self)
    }
    private func matches(_ row: Row, intent: V2GroupCreationIntent) throws -> Bool { try v2DecodePersistenceJSON(V2GroupCreationIntent.self, from: row.intent) == intent }
    private func pages(_ intent: V2GroupCreationIntent, sql: any SQLDatabase) async throws -> [Page] {
        let rows = try await sql.raw("SELECT page_offset AS offset,page_fingerprint::text AS fingerprint,members::text AS members FROM im_v2.group_creation_pages WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationUUID(intent)) ORDER BY page_offset LIMIT 196").all(decoding: PageRow.self)
        var expected = 0
        return try rows.map { row in
            let members = try JSONDecoder().decode([UserID].self, from: Data(row.members.utf8))
            guard row.offset == expected, !members.isEmpty, members.count <= 512, expected + members.count <= intent.initialMemberCount else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            let fingerprint = try v2DecodePersistenceJSON(V2OperationFingerprint.self, from: row.fingerprint)
            let page = try V2GroupCreationAppendRequest(intent: intent, offset: expected, memberUserIDs: members)
            guard page.pageFingerprint == fingerprint else { throw V2GroupMessagingStoreError.corruptPersistenceState }
            expected += members.count
            return .init(offset: row.offset, fingerprint: fingerprint, members: members)
        }
    }
    private func placement(_ row: Row, intent: V2GroupCreationIntent) throws -> V2GroupRoomCreationIntent {
        try .init(actorUserID: intent.identity.accountID, operationID: .init(intent.identity.operation.rawOperationID), roomID: .init(uuid: row.roomID), eventID: .init(uuid: row.eventID), roomShardID: row.shard, routeEpoch: 0, requestFingerprint: intent.fingerprint.digest, audienceMemberCount: intent.initialMemberCount + 1)
    }
    private func result(_ row: Row, intent: V2GroupCreationIntent, sql: any SQLDatabase) async throws -> V2GroupCreationOperationResult {
        guard try matches(row, intent: intent) else { return .fingerprintConflict }
        if let encoded = row.receipt {
            let receipt = try JSONDecoder().decode(V2GroupCreationReceipt.self, from: Data(encoded.utf8)); guard receipt.validates(intent: intent) else { throw V2GroupMessagingStoreError.corruptPersistenceState }; return .receipt(receipt)
        }
        let members = try await pages(intent, sql: sql).flatMap(\.members)
        guard members.count == row.count, let phase = V2GroupCreationPhase(rawValue: row.phase) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
        return .progress(try .init(intent: intent, roomID: .init(uuid: row.roomID), phase: phase, acceptedMemberCount: members.count, acceptedPrefixDigest: V2GroupCreationAudience.digest(members), copiedMemberCount: row.copied))
    }
    private func insert(_ intent: V2GroupCreationIntent, phase: String, receipt: V2GroupCreationReceipt?, now: Date, sql: any SQLDatabase) async throws {
        let operation = try GroupRoomOperationID(intent.identity.operation.rawOperationID)
        let encodedReceipt = try receipt.map { try json($0) }
        try await sql.raw("INSERT INTO im_v2.group_creation_operations(actor_user_id,operation_id,intent,room_id,event_id,room_shard_id,phase,accepted_member_count,receipt,created_at,updated_at) VALUES (\(bind: intent.identity.accountID.uuidValue!),\(bind: operationUUID(intent)),\(bind: try json(intent))::jsonb,\(bind: UUID()),\(bind: UUID()),\(bind: selector.shardID(actorUserID: intent.identity.accountID, operationID: operation)),\(bind: phase),0,\(bind: encodedReceipt)::jsonb,\(bind: now),\(bind: now))").run()
    }
    private func insertTerminal(_ intent: V2GroupCreationIntent, outcome: V2GroupCreationTerminalOutcome, now: Date, sql: any SQLDatabase) async throws -> V2GroupCreationOperationResult {
        let receipt = try V2GroupCreationReceipt(intent: intent, outcome: outcome, resolvedAtMilliseconds: milliseconds(now))
        try await insert(intent, phase: outcome == .closed ? "closed" : "rejected", receipt: receipt, now: now, sql: sql)
        return .receipt(receipt)
    }
    private func finish(_ row: Row, intent: V2GroupCreationIntent, outcome: V2GroupCreationTerminalOutcome, now: Date, sql: any SQLDatabase) async throws -> V2GroupCreationOperationResult {
        guard row.phase == "staging" else { throw V2GroupMessagingStoreError.corruptPersistenceState }
        let receipt = try V2GroupCreationReceipt(intent: intent, outcome: outcome, resolvedAtMilliseconds: milliseconds(now))
        try await sql.raw("UPDATE im_v2.group_creation_operations SET phase = \(bind: outcome == .closed ? "closed" : "rejected"),receipt = \(bind: try json(receipt))::jsonb,updated_at = \(bind: now) WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationUUID(intent))").run()
        try await deleteTerminalPages(intent, sql: sql)
        return .receipt(receipt)
    }
    private func deleteTerminalPages(_ intent: V2GroupCreationIntent, sql: any SQLDatabase) async throws {
        try await sql.raw("DELETE FROM im_v2.group_creation_pages WHERE actor_user_id = \(bind: intent.identity.accountID.uuidValue!) AND operation_id = \(bind: operationUUID(intent))").run()
    }
    private func expireStaging(_ actor: UUID, now: Date, sql: any SQLDatabase) async throws {
        let rows = try await sql.raw("SELECT intent::text AS intent,room_id,event_id,room_shard_id AS shard,phase,accepted_member_count AS count,copied_member_count AS copied,receipt::text AS receipt FROM im_v2.group_creation_operations WHERE actor_user_id = \(bind: actor) AND phase = 'staging' ORDER BY created_at LIMIT 3 FOR UPDATE").all(decoding: Row.self)
        let ms = try milliseconds(now)
        for row in rows {
            let intent = try v2DecodePersistenceJSON(V2GroupCreationIntent.self, from: row.intent)
            if ms >= intent.firstSubmissionDeadlineMilliseconds {
                _ = try await finish(row, intent: intent, outcome: .rejected(.submissionExpired), now: now, sql: sql)
            }
        }
    }
    private func hint(_ intent: V2GroupCreationIntent, seconds: Int) throws -> V2MessageOperationRetryHint { try .init(identity: intent.identity, fingerprint: intent.fingerprint, reason: .admissionUnavailable, retryAfterMilliseconds: UInt64(seconds) * 1_000) }
}
