import Foundation
import Fluent
import FluentPostgresDriver
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing
import Vapor

struct PostgresV2ForwardTerminalReplayTests {
    @Test(arguments: [0, 1, 31, 33])
    func receiptRejectsMalformedDigest(length: Int) {
        #expect(throws: V2ForwardInboxError.corruptPersistenceState) {
            _ = try V2ForwardTerminalReceipt(exportID: UUID(), payloadDigest: Data(repeating: 0, count: length),
                outcome: .rejected(code: "FORBIDDEN"))
        }
    }

    @Test func terminalPairReplayChecksIdentityAndDigest() async throws {
        guard let url = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let app = try await Application.make(.testing)
        var ownsSchema = false
        do {
            app.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(app.db(.psql) as? any SQLDatabase)
            struct Exists: Decodable { let exists: Bool }
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: Exists.self)?.exists == false else { throw CancellationError() }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let sourceSQL = try String(contentsOf: root.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
            let executable = sourceSQL.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
            ownsSchema = true
            for statement in postgresStatements(in: executable) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            let receipts = PostgresV2ForwardReceiptStore(database: app.db(.psql))
            let service = try V2CrossOwnerForwardService(sources: ["source": .init(
                exports: .init(database: app.db(.psql)), receipts: receipts, jobs: .init(database: app.db(.psql)))])
            for scenario in 0..<3 {
                let rejected = scenario == 1
                let actor = UserID(uuid: UUID()), operation = MessageForwardOperationID(uuid: UUID())
                let room = RoomID(uuid: UUID()), target = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
                let reference = try V2ForwardMessageReference(roomID: room, messageID: message, revision: .init(1))
                let export = try V2ForwardExport(intent: .init(version: 1, exportID: UUID(), actorUserID: actor.uuidValue!,
                    operationID: operation.uuidValue!, sourceRoomID: room.uuidValue!, sourceMessageID: message.uuidValue!, sourceRevision: 1,
                    sourceSenderUserID: actor.uuidValue!, sourceShardID: "source", sourceEpoch: 0,
                    targetRoomID: target.uuidValue!, targetClientMessageID: UUID(), targetShardID: "target", targetEpoch: 0,
                    text: "original", entities: [], media: []))
                let id = export.intent.exportID, resultID = UUID(), now = Date(timeIntervalSince1970: 1_750_000_000)
                try await sql.raw("""
                    INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id)
                    VALUES (\(bind: room.uuidValue!), 'source', 'terminal-test'), (\(bind: target.uuidValue!), 'target', 'terminal-test')
                    """).run()
                func verifyMigrationFence(roomID: RoomID, shard: String, source: Bool, at: Date) async throws {
                    @Sendable func compact(_ database: any Database) async throws -> Int {
                        if source { return try await PostgresV2ForwardExportCompactor(database: database).runOnce(now: at, limit: 1) }
                        return try await PostgresV2ForwardInboxCompactor(database: database).runOnce(now: at, limit: 1)
                    }
                    try await app.db(.psql).transaction { transaction in
                        let scoped = try #require(transaction as? any SQLDatabase)
                        try await scoped.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: roomID.uuidValue!) FOR UPDATE").run()
                        #expect(try await compact(app.db(.psql)) == 0)
                    }
                    // Roll back this isolated fence fixture, then continue
                    // ordinary compaction verification on the same envelope.
                    await #expect(throws: CancellationError.self) {
                        try await app.db(.psql).transaction { transaction in
                            let scoped = try #require(transaction as? any SQLDatabase)
                            try await scoped.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: roomID.uuidValue!), \(bind: shard), 0, \(bind: now), \(bind: now))").run()
                            let control = PostgresV2RoomOwnerMigrationPreparationStore(database: transaction, registeredShardIDs: [shard, "next"])
                            let request = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: roomID,
                                source: .init(shardID: shard, epoch: 0), targetShardID: "next")
                            _ = try await control.prepare(request, now: now)
                            let freezing = try await control.beginFreezing(request, now: now)
                            try await PostgresV2RoomMigrationWriteFence(database: transaction).install(for: freezing)
                            #expect(try await compact(transaction) == 0)
                            throw CancellationError()
                        }
                    }
                }
                try await sql.raw("""
                    INSERT INTO im_v2.message_forward_exports VALUES
                    (\(bind: id), \(bind: actor.uuidValue!), \(bind: operation.uuidValue!), \(bind: room.uuidValue!),
                     \(bind: message.uuidValue!), 1, 'source', 0, \(bind: target.uuidValue!), \(bind: export.intent.targetClientMessageID),
                     'target', 0, \(bind: export.payload), \(bind: export.digest), '{}', \(bind: now), NULL, NULL)
                    """).run()
                #expect(try await receipts.terminalStatus(actor: actor, operation: operation, source: reference, target: target) == nil)
                let exports = PostgresV2ForwardExportStore(database: app.db(.psql))
                func prepare(_ source: V2ForwardMessageReference) async throws -> V2ForwardExportPreparation {
                    try await exports.prepareForDelivery(actorUserID: actor, operationID: operation, source: source,
                        sourceRoute: .init(shardID: "source", epoch: 9), targetRoomID: target,
                        targetRoute: .init(shardID: "target", epoch: 9), now: now)
                }
                guard case .export(let unfinished) = try await prepare(reference) else {
                    Issue.record("Expected original envelope before receipt"); throw CancellationError()
                }
                #expect(unfinished == export)
                let result: UUID? = rejected ? nil : resultID
                let sequence: Int64? = rejected ? nil : 7
                let code: String? = rejected ? "FORBIDDEN" : nil
                let receiptDigest = scenario == 2 ? Data(repeating: 0, count: 32) : export.digest
                try await sql.raw("""
                    INSERT INTO im_v2.message_forward_export_receipts VALUES
                    (\(bind: id), \(bind: receiptDigest), \(bind: rejected ? "rejected" : "completed"),
                     \(bind: result), \(bind: sequence), \(bind: code), \(bind: now))
                    """).run()
                let sourceCompactor = PostgresV2ForwardExportCompactor(database: app.db(.psql))
                let sourceCompactAt = now.addingTimeInterval(PostgresV2ForwardExportCompactor.retentionSeconds)
                #expect(try await sourceCompactor.runOnce(now: sourceCompactAt, limit: 1) == 0)
                // A receipt alone cannot authorize compaction or manufacture completion.
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.message_forward_exports SET delivery_completed_at = \(bind: now) WHERE export_id = \(bind: id)").run()
                }
                if scenario == 2 {
                    await #expect(throws: (any Error).self) {
                        try await sql.raw("""
                            INSERT INTO im_v2.message_forward_delivery_jobs (export_id, state, created_at, completed_at)
                            VALUES (\(bind: id), 'completed', \(bind: now), \(bind: now))
                            """).run()
                    }
                    await #expect(throws: V2ForwardExportError.corruptPersistenceState) {
                        _ = try await prepare(reference)
                    }
                    await #expect(throws: V2ForwardExportError.corruptPersistenceState) {
                        _ = try await service.forward(actor: actor, operation: operation, source: reference,
                            sourceRoute: .init(shardID: "source", epoch: 0), target: target, targetRoute: .init(shardID: "target", epoch: 0))
                    }
                    continue
                }
                try await sql.raw("""
                    INSERT INTO im_v2.message_forward_delivery_jobs (export_id, state, created_at)
                    VALUES (\(bind: id), 'paused', \(bind: now))
                    """).run()
                #expect(try await sourceCompactor.runOnce(now: sourceCompactAt, limit: 1) == 0)
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.message_forward_exports SET payload = NULL, payload_compacted_at = \(bind: sourceCompactAt) WHERE export_id = \(bind: id)").run()
                }
                try await sql.raw("""
                    UPDATE im_v2.message_forward_delivery_jobs SET state = 'pending', next_attempt_at = \(bind: now)
                    WHERE export_id = \(bind: id)
                    """).run()
                #expect(try await sourceCompactor.runOnce(now: sourceCompactAt, limit: 1) == 0)
                let token = UUID()
                try await sql.raw("""
                    UPDATE im_v2.message_forward_delivery_jobs SET state = 'claimed', next_attempt_at = NULL, claim_token = \(bind: token),
                        lease_expires_at = \(bind: now.addingTimeInterval(30)) WHERE export_id = \(bind: id)
                    """).run()
                #expect(try await sourceCompactor.runOnce(now: sourceCompactAt, limit: 1) == 0)
                let delivery = PostgresV2ForwardDeliveryStore(database: app.db(.psql))
                let lease = V2ForwardDeliveryLease(export: export, claimToken: token, attempt: 1, expiresAt: now.addingTimeInterval(30))
                // Completion and cleanup eligibility roll back together.
                await #expect(throws: CancellationError.self) {
                    try await app.db(.psql).transaction { transaction in
                        #expect(try await PostgresV2ForwardDeliveryStore(database: transaction).complete(lease, now: now))
                        throw CancellationError()
                    }
                }
                #expect(try await sourceCompactor.runOnce(now: sourceCompactAt, limit: 1) == 0)
                #expect(try await delivery.complete(lease, now: now))
                try await verifyMigrationFence(roomID: room, shard: "source", source: true, at: sourceCompactAt)
                #expect(try await sourceCompactor.runOnce(now: sourceCompactAt.addingTimeInterval(-1), limit: 1) == 0)
                await #expect(throws: CancellationError.self) {
                    try await app.db(.psql).transaction { transaction in
                        #expect(try await PostgresV2ForwardExportCompactor(database: transaction).runOnce(now: sourceCompactAt, limit: 1) == 1)
                        throw CancellationError()
                    }
                }
                let sourceCount = try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<4 { group.addTask { try await sourceCompactor.runOnce(now: sourceCompactAt, limit: 1) } }
                    var total = 0
                    for try await value in group { total += value }
                    return total
                }
                #expect(sourceCount == 1)
                #expect(try await sourceCompactor.runOnce(now: sourceCompactAt, limit: 1) == 0)
                struct SourceCompaction: Decodable { let compacted: Bool }
                #expect(try await sql.raw("SELECT payload IS NULL AND payload_compacted_at IS NOT NULL AS compacted FROM im_v2.message_forward_exports WHERE export_id = \(bind: id)").first(decoding: SourceCompaction.self)?.compacted == true)
                await #expect(throws: V2ForwardExportError.payloadCompacted) {
                    _ = try await exports.prepare(actorUserID: actor, operationID: operation, source: reference,
                        sourceRoute: .init(shardID: "source", epoch: 9), targetRoomID: target,
                        targetRoute: .init(shardID: "target", epoch: 9), now: now)
                }
                #expect(try await delivery.complete(lease, now: now) == false)
                #expect(try await delivery.reschedule(lease, disposition: .pause, now: now) == false)
                #expect(try await delivery.claim(sourceShardID: "source", now: sourceCompactAt, leaseDuration: 30, limit: 1).isEmpty)
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.message_forward_exports SET payload = \(bind: export.payload), payload_compacted_at = NULL WHERE export_id = \(bind: id)").run()
                }
                try await sql.raw("""
                    INSERT INTO im_v2.message_forward_inbox
                        (export_id, actor_user_id, operation_id, source_message_id, target_room_id, target_client_message_id, target_shard_id, target_epoch,
                         payload, payload_digest, state, result_message_id, result_room_sequence, error_code,
                         created_at, accepted_at, completed_at)
                    VALUES (\(bind: id), \(bind: actor.uuidValue!), \(bind: operation.uuidValue!), \(bind: message.uuidValue!),
                            \(bind: target.uuidValue!), \(bind: export.intent.targetClientMessageID), \(bind: export.intent.targetShardID), \(bind: export.intent.targetEpoch), \(bind: export.payload),
                            \(bind: export.digest), 'pending', NULL, NULL, NULL, \(bind: now), NULL, NULL)
                    """).run()
                let compactAt = now.addingTimeInterval(PostgresV2ForwardInboxCompactor.retentionSeconds)
                let compactor = PostgresV2ForwardInboxCompactor(database: app.db(.psql))
                #expect(try await compactor.runOnce(now: compactAt, limit: 1) == 0)
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.message_forward_inbox SET payload = NULL, payload_compacted_at = \(bind: compactAt) WHERE export_id = \(bind: id)").run()
                }
                if !rejected {
                    try await sql.raw("""
                        UPDATE im_v2.message_forward_inbox SET state = 'accepted', result_message_id = \(bind: result),
                            result_room_sequence = \(bind: sequence), accepted_at = \(bind: now) WHERE export_id = \(bind: id)
                        """).run()
                    #expect(try await compactor.runOnce(now: compactAt, limit: 1) == 0)
                }
                try await sql.raw("""
                    UPDATE im_v2.message_forward_inbox SET state = \(bind: rejected ? "rejected" : "completed"),
                        error_code = \(bind: code), completed_at = \(bind: now) WHERE export_id = \(bind: id)
                    """).run()
                try await verifyMigrationFence(roomID: target, shard: "target", source: false, at: compactAt)
                #expect(try await compactor.runOnce(now: compactAt.addingTimeInterval(-1), limit: 1) == 0)
                await #expect(throws: CancellationError.self) {
                    try await app.db(.psql).transaction { transaction in
                        #expect(try await PostgresV2ForwardInboxCompactor(database: transaction).runOnce(now: compactAt, limit: 1) == 1)
                        throw CancellationError()
                    }
                }
                let compacted = try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<4 { group.addTask { try await compactor.runOnce(now: compactAt, limit: 1) } }
                    var total = 0
                    for try await count in group { total += count }
                    return total
                }
                #expect(compacted == 1)
                #expect(try await compactor.runOnce(now: compactAt, limit: 1) == 0)
                struct Compacted: Decodable { let compacted: Bool }
                #expect(try await sql.raw("SELECT payload IS NULL AND payload_compacted_at IS NOT NULL AS compacted FROM im_v2.message_forward_inbox WHERE export_id = \(bind: id)").first(decoding: Compacted.self)?.compacted == true)
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.message_forward_inbox SET payload = \(bind: export.payload), payload_compacted_at = NULL WHERE export_id = \(bind: id)").run()
                }
                await #expect(throws: (any Error).self) {
                    try await sql.raw("DELETE FROM im_v2.message_forward_inbox WHERE export_id = \(bind: id)").run()
                }
                // Remove fixture rooms after cleanup: terminal replay must
                // remain independent of live source/target room rows.
                try await sql.raw("DELETE FROM im_v2.rooms WHERE room_id IN (\(bind: room.uuidValue!), \(bind: target.uuidValue!))").run()
                // Receipt was inserted after the absent preflight above. Preparation
                // now returns the terminal result even with no source room/content.
                guard case .terminal(let preparedTerminal) = try await prepare(reference) else {
                    Issue.record("Expected terminal after preflight miss"); throw CancellationError()
                }
                let inbox = PostgresV2ForwardInboxStore(database: app.db(.psql))
                try await inbox.receive(export, now: now)
                let terminal = try #require(try await inbox.terminalReceipt(exportID: id))
                #expect(terminal.matches(export))
                try await receipts.record(terminal, now: now)
                #expect(preparedTerminal == terminal.outcome)
                #expect(try await inbox.status(exportID: id) == terminal.outcome)
                let locked = try await app.db(.psql).transaction { transaction in
                    try await v2LockForwardInbox(exportID: id, sql: try #require(transaction as? any SQLDatabase))
                }
                #expect(locked.payload == nil)
                #expect(try locked.outcome == terminal.outcome)
                let profile = try V2CapacityProfile(id: "terminal-replay", limits: .init(maxEligibleMembers: 10,
                    maxCommandsPerWindow: 10, retryAfterSeconds: 1))
                #expect(try await PostgresV2RoomWriteStore(database: app.db(.psql)).importForwardExport(export,
                    capacityProfile: profile, limits: .init(maxUTF8Bytes: 64),
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())), now: now) == terminal.outcome)
                var changed = try #require(JSONSerialization.jsonObject(with: export.payload) as? [String: Any])
                changed["text"] = "conflicting payload"
                let changedExport = try V2ForwardExport(intent: JSONDecoder().decode(V2ForwardExportIntent.self,
                    from: JSONSerialization.data(withJSONObject: changed)))
                await #expect(throws: V2ForwardInboxError.idempotencyConflict) { try await inbox.receive(changedExport, now: now) }
                // No source content, room or target database exists; both bodies are compacted.
                // Terminal replay must use the immutable source receipt alone.
                let outcome = try await service.forward(actor: actor, operation: operation, source: reference,
                    sourceRoute: .init(shardID: "source", epoch: 9), target: target, targetRoute: .init(shardID: "target", epoch: 9))
                guard case .completed(let saved) = outcome else { Issue.record("Expected terminal replay"); throw CancellationError() }
                #expect(saved.messageID?.uuidValue == result && saved.roomSequence == sequence.map(UInt64.init) && saved.errorCode == code)
                for changed in [try V2ForwardMessageReference(roomID: .init(uuid: UUID()), messageID: message, revision: .init(1)),
                                try V2ForwardMessageReference(roomID: room, messageID: message, revision: .init(2))] {
                    await #expect(throws: V2ForwardExportError.idempotencyConflict) {
                        _ = try await prepare(changed)
                    }
                    let conflict = try await service.forward(actor: actor, operation: operation, source: changed,
                        sourceRoute: .init(shardID: "source", epoch: 0), target: target, targetRoute: .init(shardID: "target", epoch: 0))
                    guard case .completed(let value) = conflict else { throw CancellationError() }
                    #expect(value.errorCode == "IDEMPOTENCY_CONFLICT")
                }
                #expect(try await receipts.terminalStatus(actor: .init(uuid: UUID()), operation: operation, source: reference, target: target) == nil)
                #expect(try await receipts.terminalStatus(actor: actor, operation: .init(uuid: UUID()), source: reference, target: target) == nil)
                #expect(try await receipts.terminalStatus(actor: actor, operation: operation, source: reference, target: .init(uuid: UUID())) == nil)
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            ownsSchema = false
            try await app.asyncShutdown()
        } catch {
            if ownsSchema, let sql = app.db(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA im_v2 CASCADE").run() }
            try? await app.asyncShutdown()
            throw error
        }
    }
}
