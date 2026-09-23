import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("Room actor query and receipt executors on PostgreSQL", .serialized)
struct V2ActorRoomQueryExecutorIntegrationTests {
    @Test("receipt replay is fenced before reading the operation record")
    func receiptReplayFence() async throws {
        try await withActorQueryDatabase { database, sql in
            let room = UUID(), actor = UUID()
            try await seedRoom(sql: sql, room: room, actor: actor, sequence: 1)
            let activation = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let old = try await acquire(activation, room: room, owner: owner, host: "host-a")
            let receipt = V2ActorRoomReceiptExecutor(database: database,
                shadowForwarder: SuccessfulProjectionShadowForwarder())
            let operation = ReadReceiptOperationID(uuid: UUID())
            let request = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: room),
                actorUserID: .init(uuid: actor), operationID: operation, readThroughRoomSequence: 1)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let first = try await receipt.command(.record(request), token: old, ingressAt: now)
            guard case .record(.recorded(let recorded)) = first else {
                Issue.record("first receipt did not record"); return
            }
            #expect(recorded.readThroughRoomSequence == 1)
            let replay = try await receipt.command(.record(request), token: old, ingressAt: now)
            guard case .record(.idempotent(let prior)) = replay else {
                Issue.record("receipt replay was not idempotent"); return
            }
            #expect(prior.readThroughRoomSequence == 1)
            let readers = try V2ActorReadReceiptReadersQueryWire(roomID: .init(uuid: room),
                messageID: .init(uuid: UUID()), actorUserID: .init(uuid: actor), cursor: nil, pageSize: 10)
            let missing = try await receipt.query(.readers(readers), token: old)
            #expect(missing == .readersFailure(.messageNotFound))
            #expect(try await activation.release(token: old))
            let successor = try await acquire(activation, room: room, owner: owner, host: "host-b")
            let stale = try await receipt.command(.record(request), token: old, ingressAt: now)
            #expect(stale == .recordFailure(.store(.ownerChanged)))
            let retry = try await receipt.command(.record(request), token: successor, ingressAt: now)
            guard case .record(.idempotent) = retry else { Issue.record("successor did not recover replay"); return }
            let row = try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.read_receipt_operations")
                .first(decoding: ActorQueryCountRow.self))
            #expect(row.value == 1)
        }
    }

    @Test("mixed stale and valid receipt batch preserves per-row results and zero stale writes")
    func mixedReceiptBatch() async throws {
        try await withActorQueryDatabase { database, sql in
            let roomA = UUID(), roomB = UUID(), actor = UUID()
            try await seedRoom(sql: sql, room: roomA, actor: actor, sequence: 1)
            try await seedRoom(sql: sql, room: roomB, actor: actor, sequence: 1)
            let activation = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let oldA = try await acquire(activation, room: roomA, owner: owner, host: "host-a")
            let currentB = try await acquire(activation, room: roomB, owner: owner, host: "host-a")
            let executor = V2ActorRoomReceiptExecutor(database: database,
                shadowForwarder: SuccessfulProjectionShadowForwarder())
            let user = UserID(uuid: actor), now = Date(timeIntervalSince1970: 1_750_000_000)
            let oldOperation = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: roomA),
                actorUserID: user, operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            _ = try await executor.command(.record(oldOperation), token: oldA, ingressAt: now)
            #expect(try await activation.release(token: oldA))
            _ = try await acquire(activation, room: roomA, owner: owner, host: "host-b")
            let staleNewOperation = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: roomA),
                actorUserID: user, operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            let validOperation = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: roomB),
                actorUserID: user, operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
            let batch = try V2ActorReadReceiptRecordBatchWire(requests: [oldOperation, staleNewOperation, validOperation])
            let result = try await executor.recordBatch(batch, scope: .init(tokens: [oldA, currentB]), ingressAt: now)
            #expect(result.results.count == 3)
            #expect(result.results[0] == .failure(.ownerChanged))
            #expect(result.results[1] == .failure(.ownerChanged))
            guard case .success(.recorded) = result.results[2] else {
                Issue.record("valid receipt did not commit beside stale rows"); return
            }
            let operationCount = try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.read_receipt_operations")
                .first(decoding: ActorQueryCountRow.self))
            #expect(operationCount.value == 2)
            let staleCount = try #require(try await sql.raw("""
                SELECT count(*) AS value FROM im_v2.read_receipt_operations
                WHERE operation_id = \(bind: staleNewOperation.operationID.uuidValue!)
                """).first(decoding: ActorQueryCountRow.self))
            #expect(staleCount.value == 0)
        }
    }

    @Test("receipt lock timeout remains an infrastructure failure, not a per-row owner denial")
    func receiptLockTimeout() async throws {
        try await withActorQueryDatabase { database, sql in
            let room = UUID(), actor = UUID()
            try await seedRoom(sql: sql, room: room, actor: actor, sequence: 1)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let token = try await acquire(PostgresV2RoomActivationStore(database: database),
                room: room, owner: owner, host: "host-a")
            let locked = ActorQueryGate()
            let blocker = Task {
                defer { Task { await locked.signal() } }
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    try await txSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: room) FOR UPDATE").run()
                    await locked.signal()
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            await locked.wait()
            let executor = V2ActorRoomReceiptExecutor(database: database,
                shadowForwarder: SuccessfulProjectionShadowForwarder(),
                timeouts: try .init(lockMilliseconds: 75, statementMilliseconds: 1_000,
                    idleTransactionMilliseconds: 1_000))
            let request = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: room),
                actorUserID: .init(uuid: actor), operationID: .init(uuid: UUID()),
                readThroughRoomSequence: 1)
            do {
                _ = try await executor.command(.record(request), token: token,
                    ingressAt: Date(timeIntervalSince1970: 1_750_000_000))
                Issue.record("lock timeout was hidden as success or owner denial")
            } catch is V2ReadReceiptStoreError {
                Issue.record("lock timeout was converted to a domain denial")
            } catch is V2RoomActivationLeaseError {
                Issue.record("lock timeout was converted to an authority denial")
            } catch {
                // PostgreSQL lock_timeout is a transaction failure, not an
                // activation mismatch; the caller must retry or fail the turn.
            }
            try await blocker.value
            let rows = try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.read_receipt_operations")
                .first(decoding: ActorQueryCountRow.self))
            #expect(rows.value == 0)
        }
    }

    @Test("collection state/latest queries and per-room directory/log stay database-authoritative")
    func queryFamilies() async throws {
        try await withActorQueryDatabase { database, sql in
            let actor = UUID(), roomA = UUID(), roomB = UUID()
            try await seedRoom(sql: sql, room: roomA, actor: actor, sequence: 0)
            try await seedRoom(sql: sql, room: roomB, actor: actor, sequence: 0)
            let activation = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let tokenA = try await acquire(activation, room: roomA, owner: owner, host: "host-a")
            let tokenB = try await acquire(activation, room: roomB, owner: owner, host: "host-a")
            let executor = V2ActorRoomQueryExecutor(database: database)
            let ids = [RoomID(uuid: roomA), RoomID(uuid: roomB)]
            let user = UserID(uuid: actor)
            let wire = try V2ActorRoomRecoveryBatchQueryWire(roomIDs: ids, actorUserID: user)
            let stateResult = try await executor.recovery(.states(wire), tokens: [tokenA, tokenB])
            guard case .states(let stateBatch) = stateResult else { Issue.record("state batch missing"); return }
            let states = try stateBatch.domainValue(expectedRoomIDs: ids)
            #expect(states.count == 2)
            for id in ids {
                guard case .state(let state)? = states[id] else { Issue.record("state unavailable"); continue }
                #expect(state.ownerEpoch == 0 && state.head == 0 && state.viewerMembershipRevision == 1)
            }
            let latestResult = try await executor.recovery(.latestVisible(wire), tokens: [tokenA, tokenB])
            guard case .latestVisible(let latestBatch) = latestResult else { Issue.record("latest batch missing"); return }
            let latest = try latestBatch.domainValue(expectedRoomIDs: ids)
            #expect(latest.count == 2)
            for id in ids {
                guard case .snapshot(let snapshot)? = latest[id] else { Issue.record("latest unavailable"); continue }
                #expect(snapshot.latest == nil && snapshot.head == 0)
            }
            let subscription = try await executor.log(.subscribe(.init(roomID: ids[0], actorUserID: user)), token: tokenA)
            guard case .subscription(let sub) = subscription else { Issue.record("subscription missing"); return }
            #expect(sub.highWatermark == 0 && sub.membershipRevision == 1)
            let pull = try V2ActorRoomLogPullWire(roomID: ids[0], actorUserID: user,
                afterRoomSequence: 0, pageSize: 10)
            let logPage = try await executor.log(.pull(pull), token: tokenA)
            guard case .page(let pageWire) = logPage else { Issue.record("log page missing"); return }
            #expect(pageWire.events.isEmpty && pageWire.nextRoomSequence == 0)
            let membership = try V2ActorMembershipDirectoryQueryWire(roomID: ids[0], actorUserID: user,
                cursor: nil, pageSize: 10)
            let directory = try await executor.directory(.membership(membership), token: tokenA)
            guard case .membership(let page) = directory else { Issue.record("directory missing"); return }
            #expect(page.entries.map(\.userID) == [user])
            let baseline = try await executor.directory(.roleBaseline(.init(roomID: ids[0], actorUserID: user)), token: tokenA)
            guard case .roleBaseline(let policy) = baseline else { Issue.record("baseline missing"); return }
            #expect(policy.permissionRevision == 1 && policy.membershipRevision == 1)
            #expect(try await activation.release(token: tokenA))
            _ = try await acquire(activation, room: roomA, owner: owner, host: "host-b")
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await executor.recovery(.states(wire), tokens: [tokenA, tokenB])
            }
        }
    }

    @Test("host batcher accepts granted turns, releases results independently, and honors original deadline")
    func grantedBatcher() async throws {
        try await withActorQueryDatabase { database, sql in
            let actor = UUID(), roomA = UUID(), roomB = UUID()
            try await seedRoom(sql: sql, room: roomA, actor: actor, sequence: 0)
            try await seedRoom(sql: sql, room: roomB, actor: actor, sequence: 0)
            let activation = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let tokenA = try await acquire(activation, room: roomA, owner: owner, host: "host-a")
            let tokenB = try await acquire(activation, room: roomB, owner: owner, host: "host-a")
            let batcher = V2HostRoomRecoveryQueryBatcher(executor: .init(database: database),
                configuration: try .init(maximumItems: 2))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2)), user = UserID(uuid: actor)
            let first = Task { try await batcher.state(.init(token: tokenA, actorUserID: user, batchDeadline: deadline)) }
            let second = Task { try await batcher.state(.init(token: tokenB, actorUserID: user, batchDeadline: deadline)) }
            guard case .state(let stateA) = try await first.value,
                  case .state(let stateB) = try await second.value else {
                Issue.record("granted batch did not return both states"); return
            }
            #expect(stateA.roomID == .init(uuid: roomA) && stateB.roomID == .init(uuid: roomB))
            guard case .snapshot(let latest) = try await batcher.latestVisible(.init(token: tokenA,
                actorUserID: user, batchDeadline: ContinuousClock.now.advanced(by: .seconds(2)))) else {
                Issue.record("granted latest-visible turn did not complete"); return
            }
            #expect(latest.roomID == .init(uuid: roomA) && latest.latest == nil)
            await #expect(throws: V2HostRoomRecoveryBatchError.deadlineExceeded) {
                _ = try await batcher.state(.init(token: tokenA, actorUserID: user,
                    batchDeadline: ContinuousClock.now.advanced(by: .milliseconds(-1))))
            }
        }
    }
}

private struct ActorQueryCountRow: Decodable { let value: Int64 }

private actor ActorQueryGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func seedRoom(sql: any SQLDatabase, room: UUID, actor: UUID, sequence: Int64) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.rooms(room_id, room_shard_id, capacity_profile_id, membership_revision, room_sequence)
        VALUES (\(bind: room), 'owner-a', 'standard', 1, \(bind: sequence))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_memberships(room_id, user_id, joined_revision)
        VALUES (\(bind: room), \(bind: actor), 1)
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.public_user_profiles(user_id, public_handle, display_name, created_at, updated_at)
        VALUES (\(bind: actor), \(bind: "actor_" + actor.uuidString.prefix(8).lowercased()), 'Actor', now(), now())
        ON CONFLICT (user_id) DO NOTHING
        """).run()
}

private func acquire(_ store: PostgresV2RoomActivationStore, room: UUID,
                     owner: V2RoomDataOwner, host: String) async throws -> V2RoomActivationToken {
    let identity = V2ActorHostIdentity(hostID: try .init(host), incarnationID: UUID())
    guard case .acquired(let lease) = try await store.acquire(roomID: .init(uuid: room), owner: owner,
        host: identity, duration: try .init(10_000)) else {
        throw V2RoomActivationLeaseError.activationChanged
    }
    return lease.token
}

private func withActorQueryDatabase(
    _ operation: (any Database, any SQLDatabase) async throws -> Void
) async throws {
    guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
          ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
    let resources = makeV2DatabaseTestResources()
    resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
    let database = resources.database(.psql)
    let sql = try #require(database as? any SQLDatabase)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
    do {
        let executable = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
        for statement in postgresStatements(in: executable) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
        try await operation(database, sql)
        try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        try await resources.shutdown()
    } catch {
        try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
        try? await resources.shutdown()
        throw error
    }
}
