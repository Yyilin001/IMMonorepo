import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

/// Opt-in PostgreSQL schedules for fault-matrix #14. Both sends go through
/// the production direct-room fast append, which owns credit acquisition,
/// refill, release, and the fenced business transaction.
@Suite("Direct room credit refill and activation fence on PostgreSQL", .serialized,
       .timeLimit(.minutes(3)))
struct V2RoomCreditRefillFencePostgresTests {
    @Test("a warm direct append exhausts credits before its next refill waits behind a business fence",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_CREDIT_FENCE_DATABASE_IS_DISPOSABLE"] == "1"))
    func refillCannotSelfWaitBehindBusinessFence() async throws {
        try await withCreditFenceDatabase { context in
            let activation = try await creditFenceActivate(context)
            let writer = context.writer.usingActivationScope(try .init(tokens: [activation.token]))
            try await creditFenceWarm(writer: writer, context: context)
            guard case .accepted = try await creditFenceSend(writer: writer, context: context,
                text: "first warm credit") else { throw CreditFenceFailure.businessNotAccepted }
            #expect((await context.credits.snapshot()).databaseCreditsReserved == 1)
            #expect((await context.credits.snapshot()).committedCredits == 1)
            #expect((await context.credits.snapshot()).activeCredits == 0)
            #expect(try await creditFenceUsed(context) == 5)

            // The trigger runs inside the real fast-append business transaction,
            // after it has acquired the full activation fence. The locker uses
            // a different PG connection and is the only test-specific barrier.
            try await context.sql.raw("""
                CREATE FUNCTION im_v2.test_hold_credit_fence_send() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(9240141); RETURN NEW; END $$
                """).run()
            try await context.sql.raw("""
                CREATE TRIGGER test_hold_credit_fence_send BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_hold_credit_fence_send()
                """).run()
            let gate = CreditFenceGate()
            let locker = Task {
                try await context.database.transaction { transaction in
                    let sql = try creditFenceSQL(transaction)
                    try await sql.raw("SELECT pg_advisory_xact_lock(9240141)").run()
                    let backend = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value")
                        .first(decoding: CreditFenceCountRow.self)).value
                    await gate.markHeld(backend: backend)
                    try await gate.waitUntilOpen()
                }
            }
            var business: Task<V2SendMessageOutcome, any Error>?
            var refill: Task<V2SendMessageOutcome, any Error>?
            do {
                let blocker = try await gate.waitUntilHeld()
                business = Task {
                    let scoped = context.writer.usingActivationScope(try .init(tokens: [activation.token]))
                    return try await creditFenceSend(writer: scoped, context: context,
                        text: "held warm business")
                }
                try await creditFenceWaitUntil(.seconds(1), phase: "business insert advisory wait") {
                    try await creditFenceAdvisoryWait(sql: context.sql, blocker: blocker)
                }
                #expect((await context.credits.snapshot()).databaseCreditsReserved == 2)
                #expect(try await creditFenceUsed(context) == 6)
                // batchSize=1 leaves no process-local credit. This second
                // production send must refill on a different connection.
                refill = Task {
                    let scoped = context.writer.usingActivationScope(try .init(tokens: [activation.token]))
                    return try await creditFenceSend(writer: scoped, context: context,
                        text: "refill after held business")
                }
                try await creditFenceWaitUntil(.seconds(1), phase: "refill room lock wait") {
                    try await creditFenceRoomWait(sql: context.sql)
                }
                #expect((await context.credits.snapshot()).databaseCreditsReserved == 2)
                #expect(try await creditFenceUsed(context) == 6)
                await gate.open()
                try await locker.value
                guard case .accepted = try await business!.value,
                      case .accepted = try await refill!.value else {
                    throw CreditFenceFailure.businessNotAccepted
                }
                let snapshot = await context.credits.snapshot()
                #expect(snapshot.databaseCreditsReserved == 3)
                #expect(snapshot.committedCredits == 3)
                #expect(snapshot.returnedCredits == 0)
                #expect(snapshot.activeCredits == 0)
                #expect(try await creditFenceUsed(context) == 7)
                #expect(try await context.fixture.count("im_v2.messages", on: context.sql) == 7)
                #expect(try await context.leases.release(token: activation.token))
            } catch {
                await gate.open()
                business?.cancel()
                refill?.cancel()
                _ = await locker.result
                if let business { _ = await business.result }
                if let refill { _ = await refill.result }
                throw error
            }
        }
    }

    @Test("warm direct rollback returns one local credit; uncertain credit and old epoch cannot be reused",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_CREDIT_FENCE_DATABASE_IS_DISPOSABLE"] == "1"))
    func rollbackUnknownAndTakeover() async throws {
        try await withCreditFenceDatabase { context in
            let first = try await creditFenceActivate(context)
            let oldWriter = context.writer.usingActivationScope(try .init(tokens: [first.token]))
            try await creditFenceWarm(writer: oldWriter, context: context)
            guard case .accepted = try await creditFenceSend(writer: oldWriter,
                context: context, text: "consume first credit") else {
                throw CreditFenceFailure.businessNotAccepted
            }
            #expect((await context.credits.snapshot()).databaseCreditsReserved == 1)
            #expect((await context.credits.snapshot()).activeCredits == 0)

            try await context.sql.raw("""
                CREATE FUNCTION im_v2.test_reject_credit_fence_send() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'credit fence rollback probe'; END $$
                """).run()
            try await context.sql.raw("""
                CREATE TRIGGER test_reject_credit_fence_send BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_reject_credit_fence_send()
                """).run()
            do {
                _ = try await creditFenceSend(writer: oldWriter, context: context,
                    text: "rolled back")
                Issue.record("the direct append unexpectedly committed")
            } catch {
                // The production writer, not the test, returns the confirmed
                // rollback's local credit. Its DB reservation remains spent.
            }
            try await context.sql.raw("DROP TRIGGER test_reject_credit_fence_send ON im_v2.messages").run()
            let afterRollback = await context.credits.snapshot()
            #expect(afterRollback.databaseCreditsReserved == 2)
            #expect(afterRollback.returnedCredits == 1)
            #expect(afterRollback.activeCredits == 1)
            #expect(try await creditFenceUsed(context) == 6)
            #expect(try await context.fixture.count("im_v2.messages", on: context.sql) == 5)

            // The ACK-loss suite separately proves how a real ambiguous SQL
            // completion is classified. Here exercise the exact local token
            // cleanup that such a result must use: discard, never release.
            guard case .granted(let uncertain) = try await context.credits.acquire(
                roomID: context.roomUUID, shardState: context.shard,
                now: context.now, activation: first.token) else {
                throw CreditFenceFailure.creditUnavailable
            }
            #expect((await context.credits.snapshot()).databaseCreditsReserved == 2)
            await context.credits.discard(uncertain)
            await context.credits.release(uncertain, now: context.now)
            #expect((await context.credits.snapshot()).returnedCredits == 1)
            #expect((await context.credits.snapshot()).activeCredits == 0)

            #expect(try await context.leases.release(token: first.token))
            let next = try await creditFenceActivate(context, hostName: "credit-fence-next")
            #expect(next.token.activationEpoch.rawValue == first.token.activationEpoch.rawValue + 1)
            await oldWriter.closeActorState(token: first.token)
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await context.credits.acquire(roomID: context.roomUUID,
                    shardState: context.shard, now: context.now, activation: first.token)
            }
            let replay = try creditFenceRequest(context: context, text: "old epoch replay")
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await oldWriter.accept(command: replay.command,
                    capacityProfile: replay.capacityProfile,
                    identifiers: replay.identifiers, now: replay.now)
            }
            guard case .granted(let successorCredit) = try await context.credits.acquire(
                roomID: context.roomUUID, shardState: context.shard,
                now: context.now, activation: next.token) else {
                throw CreditFenceFailure.creditUnavailable
            }
            #expect((await context.credits.snapshot()).databaseCreditsReserved == 3)
            let nextWriter = context.writer.usingActivationScope(try .init(tokens: [next.token]))
            guard case .accepted = try await creditFenceSend(writer: nextWriter,
                context: context, text: "successor business") else {
                throw CreditFenceFailure.businessNotAccepted
            }
            await context.credits.release(successorCredit, now: context.now)
            await context.credits.release(successorCredit, now: context.now)
            let final = await context.credits.snapshot()
            #expect(final.returnedCredits == 2)
            #expect(final.databaseCreditsReserved == 3)
            #expect(try await creditFenceUsed(context) == 8)
            #expect(try await context.fixture.count("im_v2.messages", on: context.sql) == 6)
            #expect(try await context.leases.release(token: next.token))
        }
    }
}

// Immutable fixture values are shared only by task-safe database handles,
// value stores, and actors during the two deliberately concurrent sends.
private struct CreditFenceContext: @unchecked Sendable {
    let database: any Database
    let sql: any SQLDatabase
    let fixture: PostgresV2RoomWriteStoreIntegrationTests
    let roomID: RoomID
    let roomUUID: UUID
    let now: Date
    let profile: V2CapacityProfile
    let shard: ShardAdmissionState
    let writer: PostgresV2RoomWriteStore
    let credits: V2RoomAdmissionCommandCreditPool
    let cache: V2DirectRoomLogFastAppendCache
    let leases: PostgresV2RoomActivationStore
}

private struct CreditFenceCountRow: Decodable { let value: Int64 }
private struct CreditFenceBoolRow: Decodable { let value: Bool }
private enum CreditFenceFailure: Error {
    case activationUnavailable, creditUnavailable, businessNotAccepted
    case phaseTimeout(String), schemaAlreadyExists, nonSQLDatabase
}

private func creditFenceActivate(_ context: CreditFenceContext,
    hostName: String = "credit-fence-first") async throws -> V2RoomActivationLease {
    let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
    let host = V2ActorHostIdentity(hostID: try .init(hostName), incarnationID: UUID())
    guard case .acquired(let lease) = try await context.leases.acquire(
        roomID: context.roomID, owner: owner, host: host, duration: .init(30_000)) else {
        throw CreditFenceFailure.activationUnavailable
    }
    return lease
}

private func creditFenceRequest(context: CreditFenceContext,
    text: String) throws -> V2RoomWriteRequest {
    .init(command: try .init(roomID: context.roomID, senderUserID: senderID,
        clientMessageID: .init(uuid: UUID()), text: text, limits: .init(maxUTF8Bytes: 64)),
        capacityProfile: context.profile,
        identifiers: try V2AcceptanceIDFactory().make(at: context.now), now: context.now)
}

private func creditFenceSend(writer: PostgresV2RoomWriteStore,
    context: CreditFenceContext, text: String) async throws -> V2SendMessageOutcome {
    let request = try creditFenceRequest(context: context, text: text)
    return try await writer.accept(command: request.command,
        capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now)
}

private func creditFenceWarm(writer: PostgresV2RoomWriteStore,
    context: CreditFenceContext) async throws {
    for index in 0..<4 {
        guard case .accepted = try await creditFenceSend(writer: writer,
            context: context, text: "warm \(index)") else {
            throw CreditFenceFailure.businessNotAccepted
        }
    }
    #expect(await context.credits.shouldUseCredits(roomID: context.roomUUID, now: context.now))
    let cached = try #require(await context.cache.value(for: .init(
        roomID: context.roomUUID, senderID: senderUUID)))
    #expect(cached.policy.senderHasReplied && cached.policy.isFriend)
    #expect((await context.credits.snapshot()).databaseCreditsReserved == 0)
    #expect(try await creditFenceUsed(context) == 4)
}

private func creditFenceUsed(_ context: CreditFenceContext) async throws -> Int64 {
    try #require(try await context.sql.raw("SELECT command_window_used AS value FROM im_v2.room_admission WHERE room_id = \(bind: context.roomUUID)")
        .first(decoding: CreditFenceCountRow.self)).value
}

private func creditFenceSQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw CreditFenceFailure.nonSQLDatabase }
    return sql
}

private func creditFenceAdvisoryWait(sql: any SQLDatabase, blocker: Int64) async throws -> Bool {
    (try await sql.raw("""
        SELECT count(*)::bigint AS value FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
          AND \(bind: blocker)::integer = ANY(pg_blocking_pids(pid))
        """).first(decoding: CreditFenceCountRow.self)?.value ?? 0) > 0
}

private func creditFenceRoomWait(sql: any SQLDatabase) async throws -> Bool {
    (try await sql.raw("""
        SELECT count(*)::bigint AS value FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
          AND query LIKE '%FROM im_v2.rooms%FOR NO KEY UPDATE%'
        """).first(decoding: CreditFenceCountRow.self)?.value ?? 0) > 0
}

private func creditFenceWaitUntil(_ limit: Duration, phase: String,
    _ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while try !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CreditFenceFailure.phaseTimeout(phase) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor CreditFenceGate {
    private var backend: Int64?
    private var opened = false
    func markHeld(backend: Int64) { self.backend = backend }
    func open() { opened = true }
    func waitUntilHeld() async throws -> Int64 {
        try await creditFenceWaitUntil(.seconds(1), phase: "advisory locker ready") { await self.backend != nil }
        return try #require(backend)
    }
    func waitUntilOpen() async throws {
        try await creditFenceWaitUntil(.seconds(5), phase: "advisory locker released") { await self.opened }
    }
}

private func withCreditFenceDatabase(_ operation: (CreditFenceContext) async throws -> Void) async throws {
    guard ProcessInfo.processInfo.environment["IMV2_ACTOR_CREDIT_FENCE_DATABASE_IS_DISPOSABLE"] == "1",
          let url = ProcessInfo.processInfo.environment["IMV2_ACTOR_CREDIT_FENCE_DATABASE_URL"] else {
        throw CreditFenceFailure.schemaAlreadyExists
    }
    let resources = makeV2DatabaseTestResources()
    var installed = false
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 6),
            as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try creditFenceSQL(database)
        guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
            .first(decoding: CreditFenceBoolRow.self)?.value == false else {
            throw CreditFenceFailure.schemaAlreadyExists
        }
        let fixture = PostgresV2RoomWriteStoreIntegrationTests()
        installed = true
        try await fixture.installSchema(on: sql)
        try await fixture.seedRoom(on: sql)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let profile = try fixture.forwardImportTestProfile()
        let direct = try V2DirectMessagingService(
            store: PostgresV2DirectMessagingStore(database: database),
            capacityProfile: profile, roomShardID: "room-a", now: { now })
        guard case .opened(let room) = try await direct.open(actorUserID: senderID,
            operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID)) else {
            throw CreditFenceFailure.activationUnavailable
        }
        // Keep the direct policy stable and eligible for the production fast
        // append after the sender's first reply marker has been committed.
        try await sql.raw("""
            INSERT INTO im_v2.user_relationships
                (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at)
            VALUES (\(bind: senderUUID), \(bind: memberTwoUUID), 'accepted',
                    \(bind: senderUUID), \(bind: now))
            """).run()
        let roomUUID = try #require(room.roomID.uuidValue)
        // Keep only the heat hint's monotonic clock fixed so slow CI setup
        // cannot age four real committed warm-up appends out of its 5s window.
        let heatClock = ContinuousClock.now
        let credits = V2RoomAdmissionCommandCreditPool(database: database,
            batchSize: 1, monotonicNow: { heatClock })
        let cache = V2DirectRoomLogFastAppendCache()
        let writer = PostgresV2RoomWriteStore(database: database,
            strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400),
            contentReviewMode: .disabled,
            directRoomLogFastAppendCache: cache,
            shardAdmissionCommandCreditPool: .init(database: database, batchSize: 1),
            roomAdmissionCommandCreditPool: credits)
        let shard = try ShardAdmissionState(lease: .init(id: .init(uuid: leaseUUID),
            generation: 1, validUntil: now.addingTimeInterval(100),
            commandWindow: .init(limit: 10, used: 0)))
        let context = CreditFenceContext(database: database, sql: sql, fixture: fixture,
            roomID: room.roomID, roomUUID: roomUUID, now: now, profile: profile,
            shard: shard, writer: writer, credits: credits, cache: cache,
            leases: .init(database: database))
        try await operation(context)
        try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        installed = false
        try await resources.shutdown()
    } catch {
        if installed, let sql = resources.database(.psql) as? any SQLDatabase {
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
        }
        try? await resources.shutdown()
        throw error
    }
}
