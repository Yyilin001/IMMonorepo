@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Durable direct authorization control obligation", .serialized, .timeLimit(.minutes(1)))
struct PostgresV2DirectAuthorizationIntentTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test(arguments: [false, true])
    func resolutionWithOccupiedSingleConnectionPools(separateOwner: Bool) async throws {
        try await fixture(separateOwner: separateOwner) { context in
            let controlURL = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"])
            let ownerURL = separateOwner
                ? try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"]) : controlURL
            let resources = makeV2DatabaseTestResources()
            do {
                func pool(_ role: String, _ url: String) throws -> any Database {
                    let id = DatabaseID(string: role)
                    resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 1), as: id)
                    return resources.database(id)
                }
                let writer = try pool("writer", controlURL)
                let reservation = try pool("reservation", controlURL)
                let foregroundOwner = try pool("foreground-owner", ownerURL)
                let controlResolution = try pool("resolution", controlURL)
                let ownerResolution = separateOwner ? try pool("owner-resolution", ownerURL) : controlResolution
                let intents = PostgresV2DirectAuthorizationIntentStore(database: reservation, schema: context.controlSchema)
                let grant = try #require(try await intents.reserve([context.request()], now: now).first)
                let coordinator = V2DirectAuthorizationCoordinator(
                    intents: .init(database: controlResolution, schema: context.controlSchema)
                ) { attempt, time in
                    try await context.receipts.abort(attempt, now: time, database: ownerResolution)
                }
                // Occupy the sole connection of every non-resolution role.
                // The writer also holds the real exclusive policy lock. Neither
                // owner abort nor control ACK may borrow these occupied pools.
                try await foregroundOwner.transaction { _ in
                    try await reservation.transaction { _ in
                        try await writer.transaction { transaction in
                            let sql = try #require(transaction as? any SQLDatabase)
                            let key = V2DirectSendControlPair(sender: context.sender, recipient: context.recipient).canonicalKey
                            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                            try await coordinator.drain(.pair(context.sender, context.recipient), transaction: transaction, now: now)
                            try await context.block(on: transaction, now: now)
                        }
                    }
                }
                let receipt = try await context.owner.transaction {
                    try await context.receipts.prepare(grant.attempt, transaction: $0)
                }
                #expect(receipt?.disposition == .aborted)
                let renewed = try #require(try await intents.reserve([context.request(client: grant.attempt.clientMessageID)], now: now).first)
                #expect(renewed.attempt.generation == 2)
                #expect(renewed.policy.blocked)
                #expect(try await coordinator.recover(limit: 8, now: now.addingTimeInterval(31)) == .init(claimed: 1, resolved: 1, deferred: 0))
                try await resources.shutdown()
            } catch {
                try? await resources.shutdown()
                throw error
            }
        }
    }

    @Test func reservationSurvivesControlBackendTermination() async throws {
        try await fixture { context in
            let request = context.request(), intents = context.intents
            let grant = try #require(try await intents.reserve([request], now: now).first)
            // Keep the selected control connection alive until termination.
            // A different connection on the same PostgreSQL server must issue
            // the signal; owner may live on a separate physical server.
            let killed = try await context.controlSQL.withSession { pinned in
                let backend = try #require(try await pinned.raw("SELECT pg_backend_pid()::bigint AS value")
                    .first(decoding: Count.self))
                return try #require(try await context.controlSQL.raw(
                    "SELECT pg_terminate_backend(\(bind: backend.value)::int4) AS value"
                ).first(decoding: Flag.self)).value
            }
            #expect(killed)
            // Pool reconnect is asynchronous. Retrying the same operation must
            // not allocate a new generation or discard the durable obligation.
            var replay: V2DirectAuthorizationGrant?
            for retry in 0..<20 {
                do { replay = try await intents.reserve([request], now: now.addingTimeInterval(1)).first; break }
                catch { if retry == 19 { throw error }; try await Task.sleep(for: .milliseconds(20)) }
            }
            #expect(try #require(replay).attempt == grant.attempt)
            #expect(replay?.createdAt == grant.createdAt)
            #expect(replay?.policy == grant.policy)
            try await context.withPairLock { transaction in
                try await context.coordinator.drain(.pair(context.sender, context.recipient), transaction: transaction, now: now.addingTimeInterval(1))
                try await context.block(on: transaction, now: now.addingTimeInterval(1))
            }
            let late = try await context.owner.transaction { transaction in
                try await context.receipts.prepare(grant.attempt, transaction: transaction)
            }
            #expect(late?.disposition == .aborted)
            let renewed = try #require(try await intents.reserve([request], now: now.addingTimeInterval(2)).first)
            #expect(renewed.attempt.generation == 2)
            #expect(renewed.policy.blocked)
            #expect(renewed.createdAt == grant.createdAt)
            #expect(try await intents.resolve(grant.attempt, receipt: .init(disposition: .aborted, eventID: nil), now: now.addingTimeInterval(2)) == false)
        }
    }

    @Test func boundedDrainProgressSurvivesRevocationRollback() async throws {
        try await fixture { context in
            let grants = try await context.intents.reserve([context.request(), context.request()], now: now)
            await #expect(throws: V2DirectAuthorizationCoordinationError.revocationIncomplete) {
                try await context.withPairLock { transaction in
                    try await context.coordinator.drain(.pair(context.sender, context.recipient), transaction: transaction, now: now, limit: 1)
                    try await context.block(on: transaction, now: now)
                }
            }
            let pending = try await context.control.transaction { transaction in
                try await context.intents.held(in: .user(context.sender), limit: 128, transaction: transaction)
            }
            #expect(pending.count == 1)
            let blocks = try #require(try await context.controlSQL.raw("SELECT count(*) AS value FROM \(unsafeRaw: context.controlSchema).user_blocks").first(decoding: Count.self))
            #expect(blocks.value == 0)
            try await context.withPairLock { transaction in
                try await context.coordinator.drain(.pair(context.sender, context.recipient), transaction: transaction, now: now, limit: 1)
                try await context.block(on: transaction, now: now)
            }
            for grant in grants {
                let late = try await context.owner.transaction { try await context.receipts.prepare(grant.attempt, transaction: $0) }
                #expect(late?.disposition == .aborted)
            }
            let fresh = try #require(try await context.intents.reserve([context.request()], now: now).first)
            #expect(fresh.policy.blocked)
        }
    }

    @Test func unavailableOwnerAndExpiredLeaseNeverReleaseGrant() async throws {
        try await fixture { context in
            let request = context.request(), intents = context.intents
            let grant = try #require(try await intents.reserve([request], now: now).first)
            let unavailable = V2DirectAuthorizationCoordinator(intents: intents) { _, _ in
                throw V2DirectAuthorizationCoordinationError.ownerUnavailable
            }
            await #expect(throws: V2DirectAuthorizationCoordinationError.ownerUnavailable) {
                try await context.withPairLock { transaction in
                    try await unavailable.drain(.user(context.sender), transaction: transaction, now: now)
                    try await context.block(on: transaction, now: now)
                }
            }
            #expect(try await unavailable.recover(limit: 1, now: now.addingTimeInterval(31)) == .init(claimed: 1, resolved: 0, deferred: 1))
            let replay = try #require(try await intents.reserve([request], now: now.addingTimeInterval(40)).first)
            #expect(replay.attempt == grant.attempt)
            let firstLease = try #require(try await intents.claim(limit: 1, now: now.addingTimeInterval(42)).first)
            #expect(try await intents.claim(limit: 1, now: now.addingTimeInterval(43)).isEmpty)
            let secondLease = try #require(try await intents.claim(limit: 1, now: now.addingTimeInterval(73)).first)
            #expect(secondLease.attempt == firstLease.attempt)
            #expect(secondLease.leaseToken != firstLease.leaseToken)
            try await intents.deferClaim(firstLease, now: now.addingTimeInterval(73))
            #expect(try await intents.claim(limit: 1, now: now.addingTimeInterval(74)).isEmpty)
            #expect(try await context.coordinator.recover(limit: 1, now: now.addingTimeInterval(104)) == .init(claimed: 1, resolved: 1, deferred: 0))
            let renewed = try #require(try await intents.reserve([request], now: now.addingTimeInterval(105)).first)
            #expect(renewed.attempt.generation == 2)
            #expect(renewed.createdAt == grant.createdAt)
            #expect(renewed.attemptCreatedAt == now.addingTimeInterval(105))
        }
    }

    @Test func concurrentReverseBatchesShareOneGenerationAndConflictRollsBack() async throws {
        try await fixture { context in
            let first = context.request(client: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
            let second = context.request(client: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
            try await withThrowingTaskGroup(of: [V2DirectAuthorizationGrant].self) { group in
                for index in 0..<8 {
                    group.addTask { try await context.intents.reserve(index.isMultiple(of: 2) ? [first, second] : [second, first], now: now) }
                }
                for try await grants in group { #expect(grants.count == 2); #expect(grants.allSatisfy { $0.attempt.generation == 1 }) }
            }
            let insertedBeforeConflict = context.request(client: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            let conflict = context.request(client: second.clientMessageID, digest: Data(repeating: 9, count: 32))
            await #expect(throws: V2DirectAuthorizationIntentError.identityConflict) {
                try await context.intents.reserve([insertedBeforeConflict, conflict], now: now)
            }
            let count = try #require(try await context.controlSQL.raw("SELECT count(*) AS value FROM \(unsafeRaw: context.controlSchema).direct_authorization_intents").first(decoding: Count.self))
            #expect(count.value == 2)
            for mutation in ["generation = generation + 1", "policy = '{}'::jsonb", "event_id = gen_random_uuid()"] {
                await #expect(throws: (any Error).self) {
                    try await context.controlSQL.raw("UPDATE \(unsafeRaw: context.controlSchema).direct_authorization_intents SET \(unsafeRaw: mutation)").run()
                }
            }
            await #expect(throws: (any Error).self) {
                try await context.controlSQL.raw("DELETE FROM \(unsafeRaw: context.controlSchema).direct_authorization_intents").run()
            }
        }
    }

    @Test(arguments: ["index", "constraint", "trigger", "function"])
    func readinessRejectsIntentDrift(drift: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            switch drift {
            case "index": try await sql.raw("DROP INDEX \(unsafeRaw: schema).direct_authorization_recovery_idx").run()
            case "constraint": try await sql.raw("ALTER TABLE \(unsafeRaw: schema).direct_authorization_intents DROP CONSTRAINT direct_authorization_intent_result_check").run()
            case "trigger": try await sql.raw("ALTER TABLE \(unsafeRaw: schema).direct_authorization_intents DISABLE TRIGGER direct_authorization_intents_guard").run()
            default: try await sql.raw("CREATE OR REPLACE FUNCTION \(unsafeRaw: schema).guard_direct_authorization_intent() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$").run()
            }
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".direct_authorization_intents[durable-obligation]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    private func fixture(separateOwner: Bool = true, _ operation: (Context) async throws -> Void) async throws {
        guard let secondary = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"] else { return }
        try await withUserEventDatabase { control, controlSQL, controlSchema in
            try await withUserEventDatabase(databaseURL: separateOwner ? secondary : nil) { owner, ownerSQL, ownerSchema in
                let users = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
                let room = UUID()
                for (index, user) in users.enumerated() {
                    try await controlSQL.raw("""
                        INSERT INTO \(unsafeRaw: controlSchema).public_user_profiles
                            (user_id, public_handle, display_name, created_at, updated_at)
                        VALUES (\(bind: user), \(bind: "authorization_" + String(index)), 'Authorization', \(bind: now), \(bind: now))
                        """).run()
                }
                try await ownerSQL.raw("""
                    INSERT INTO \(unsafeRaw: ownerSchema).rooms (room_id, room_kind, room_shard_id, capacity_profile_id)
                    VALUES (\(bind: room), 'direct', 'authorization-owner', 'standard')
                    """).run()
                try await ownerSQL.raw("""
                    INSERT INTO \(unsafeRaw: ownerSchema).direct_room_pairs (lower_user_id, higher_user_id, room_id, created_at)
                    VALUES (\(bind: users[0]), \(bind: users[1]), \(bind: room), \(bind: now))
                    """).run()
                try await operation(.init(control: control, owner: owner, controlSQL: controlSQL, ownerSQL: ownerSQL,
                    controlSchema: controlSchema, ownerSchema: ownerSchema, room: room, sender: users[0], recipient: users[1]))
            }
        }
    }

    private struct Context: Sendable {
        let control: any Database; let owner: any Database
        let controlSQL: any SQLDatabase; let ownerSQL: any SQLDatabase
        let controlSchema: String; let ownerSchema: String
        let room: UUID; let sender: UUID; let recipient: UUID
        var intents: PostgresV2DirectAuthorizationIntentStore { .init(database: control, schema: controlSchema) }
        var receipts: PostgresV2DirectAuthorizationReceiptStore { .init(schema: ownerSchema) }
        var coordinator: V2DirectAuthorizationCoordinator {
            .init(intents: intents) { attempt, now in try await receipts.abort(attempt, now: now, database: owner) }
        }
        func request(client: UUID = UUID(), digest: Data = Data(repeating: 7, count: 32)) -> V2DirectAuthorizationRequest {
            .init(roomID: room, senderID: sender, clientMessageID: client, recipientID: recipient,
                ownerShardID: "authorization-owner", ownerEpoch: 0, fingerprint: digest)
        }
        func withPairLock(_ operation: @escaping @Sendable (any Database) async throws -> Void) async throws {
            try await control.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                let key = V2DirectSendControlPair(sender: sender, recipient: recipient).canonicalKey
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                try await operation(transaction)
            }
        }
        func block(on transaction: any Database, now: Date) async throws {
            let sql = try #require(transaction as? any SQLDatabase)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: controlSchema).user_blocks (blocker_user_id, blocked_user_id, created_at)
                VALUES (\(bind: recipient), \(bind: sender), \(bind: now))
                """).run()
        }
    }
    private struct Count: Decodable { let value: Int64 }
    private struct Flag: Decodable { let value: Bool }
}
