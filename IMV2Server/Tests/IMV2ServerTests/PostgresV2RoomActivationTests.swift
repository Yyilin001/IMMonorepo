import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("PostgreSQL room activation and commit fence", .serialized)
struct PostgresV2RoomActivationTests {
    private let duration = try! V2ActorMilliseconds(10_000)

    @Test("failure at deferred COMMIT stays uncertain at the lease boundary")
    func commitStageFailure() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try await createRoom(sql: sql, schema: schema)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let identity = try host("commit-stage")
            try await sql.raw("""
                CREATE FUNCTION \(unsafeRaw: schema).reject_lease_commit() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'injected deferred lease failure'; END; $$
                """).run()
            try await sql.raw("""
                CREATE CONSTRAINT TRIGGER reject_lease_commit AFTER INSERT ON \(unsafeRaw: schema).room_activation_leases
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
                EXECUTE FUNCTION \(unsafeRaw: schema).reject_lease_commit()
                """).run()
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            await #expect(throws: V2RoomActivationLeaseError.outcomeUnknown) {
                _ = try await store.acquire(roomID: room, owner: owner, host: identity, duration: duration)
            }
            // This injection actually rolls back. The public boundary remains
            // conservative because it must also cover a lost successful ACK.
            #expect(try await store.locate(roomID: room, owner: owner) == nil)
            try await sql.raw("DROP TRIGGER reject_lease_commit ON \(unsafeRaw: schema).room_activation_leases").run()
            guard case .acquired(let lease) = try await store.acquire(roomID: room,
                owner: owner, host: identity, duration: duration) else { Issue.record("recovery"); return }
            #expect(try await store.release(token: lease.token))
        }
    }

    @Test("acquire race, complete token equality, release retains epoch")
    func acquisitionAndRelease() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try await createRoom(sql: sql, schema: schema)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let hostA = try host("host-a")
            let hostB = try host("host-b")
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            let leaseDuration = duration
            let start = ActivationGate()
            let first = Task { await start.wait(); return try await store.acquire(roomID: room, owner: owner, host: hostA, duration: leaseDuration) }
            let second = Task { await start.wait(); return try await store.acquire(roomID: room, owner: owner, host: hostB, duration: leaseDuration) }
            await start.signal()
            let results = try await [first.value, second.value]
            let acquired = results.compactMap { if case .acquired(let lease) = $0 { lease } else { nil } }
            let occupied = results.compactMap { if case .occupied(let lease) = $0 { lease } else { nil } }
            #expect(acquired.count == 1)
            #expect(occupied.count == 1)
            let lease = try #require(acquired.first)
            #expect(occupied.first?.token == lease.token)
            #expect(try await store.locate(roomID: room, owner: owner)?.token == lease.token)

            let wrongHost = V2RoomActivationToken(roomID: room, owner: owner,
                activationEpoch: lease.token.activationEpoch,
                host: V2ActorHostIdentity(hostID: lease.token.host.hostID, incarnationID: UUID()))
            #expect(try await store.release(token: wrongHost) == false)
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await store.renew(token: wrongHost, duration: duration)
            }
            let renewed = try await store.renew(token: lease.token, duration: duration)
            #expect(renewed.token == lease.token)
            #expect(try await store.release(token: lease.token))
            #expect(try await store.locate(roomID: room, owner: owner) == nil)
            #expect(try await store.release(token: lease.token) == false)
            guard case .acquired(let successor) = try await store.acquire(roomID: room, owner: owner,
                host: hostB, duration: duration) else { Issue.record("released epoch was not reacquired"); return }
            #expect(successor.token.activationEpoch.rawValue == lease.token.activationEpoch.rawValue + 1)
            #expect(try await store.release(token: lease.token) == false)
            #expect(try await store.locate(roomID: room, owner: owner)?.token == successor.token)
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch = 1 WHERE room_id = \(bind: room.uuidValue!)").run()
            #expect(try await store.release(token: successor.token) == false)
            await #expect(throws: V2RoomActivationLeaseError.ownerChanged) {
                _ = try await store.renew(token: successor.token, duration: duration)
            }
            let nextOwner = try V2RoomDataOwner(shardID: "owner-a", epoch: 1)
            guard case .acquired(let ownerSuccessor) = try await store.acquire(roomID: room,
                owner: nextOwner, host: hostA, duration: duration) else {
                Issue.record("new owner epoch did not supersede prior activation"); return
            }
            #expect(ownerSuccessor.token.activationEpoch.rawValue == successor.token.activationEpoch.rawValue + 1)
            await #expect(throws: V2RoomActivationLeaseError.ownerChanged) {
                _ = try await store.locate(roomID: room, owner: .init(shardID: "owner-b", epoch: 0))
            }
            let absent = try RoomID(UUID().uuidString)
            await #expect(throws: V2RoomActivationLeaseError.roomNotFound) {
                _ = try await store.locate(roomID: absent, owner: owner)
            }
            let absentToken = V2RoomActivationToken(roomID: absent, owner: owner,
                activationEpoch: try V2ActorEpoch(1), host: hostA)
            #expect(try await store.release(token: absentToken) == false)
        }
    }

    @Test("old fenced write commits before new epoch; successor excludes old write")
    func bothCommitSchedules() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try await createRoom(sql: sql, schema: schema)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            let short = try V2ActorMilliseconds(350)
            let leaseDuration = duration
            let nextHost = try host("new-host")
            guard case .acquired(let old) = try await store.acquire(roomID: room, owner: owner,
                host: try host("old-host"), duration: short) else { Issue.record("initial lease occupied"); return }
            let locked = ActivationGate(), finishOld = ActivationGate(), newStarted = ActivationGate()
            let oldWrite = Task {
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    try await v2RequireRoomActivation(token: old.token, sql: txSQL, schema: schema)
                    await locked.signal()
                    await finishOld.wait()
                    try await txSQL.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 1 WHERE room_id = \(bind: room.uuidValue!)").run()
                }
            }
            await locked.wait()
            let newAcquire = Task {
                await newStarted.signal()
                return try await store.acquire(roomID: room, owner: owner,
                    host: nextHost, duration: leaseDuration)
            }
            await newStarted.wait()
            try await Task.sleep(for: .milliseconds(425))
            await finishOld.signal()
            try await oldWrite.value
            guard case .acquired(let successor) = try await newAcquire.value else { Issue.record("successor not acquired"); return }
            #expect(successor.token.activationEpoch.rawValue == old.token.activationEpoch.rawValue + 1)
            let sequence = try #require(try await sql.raw("SELECT room_sequence FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: room.uuidValue!)")
                .first(decoding: ActivationSequenceRow.self)).roomSequence
            #expect(sequence == 1)
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    try await v2RequireRoomActivation(token: old.token, sql: txSQL, schema: schema)
                    try await txSQL.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 2 WHERE room_id = \(bind: room.uuidValue!)").run()
                }
            }
            let after = try #require(try await sql.raw("SELECT room_sequence FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: room.uuidValue!)")
                .first(decoding: ActivationSequenceRow.self)).roomSequence
            #expect(after == 1)
        }
    }

    @Test("transaction begun before expiry rechecks clock after lock wait")
    func lockWaitCrossesExpiry() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try await createRoom(sql: sql, schema: schema)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            guard case .acquired(let lease) = try await store.acquire(roomID: room, owner: owner,
                host: try host("expiring-host"), duration: try V2ActorMilliseconds(350)) else {
                Issue.record("initial lease occupied"); return
            }
            let blockerLocked = ActivationGate(), releaseBlocker = ActivationGate(), waiterBegun = ActivationGate()
            let blocker = Task {
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    try await txSQL.raw("SELECT room_id FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: room.uuidValue!) FOR UPDATE").run()
                    await blockerLocked.signal()
                    await releaseBlocker.wait()
                }
            }
            await blockerLocked.wait()
            let waiter = Task {
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    try await txSQL.raw("SELECT clock_timestamp()").run()
                    await waiterBegun.signal()
                    try await v2RequireRoomActivation(token: lease.token, sql: txSQL, schema: schema)
                }
            }
            await waiterBegun.wait()
            try await Task.sleep(for: .milliseconds(425))
            await releaseBlocker.signal()
            try await blocker.value
            await #expect(throws: V2RoomActivationLeaseError.leaseExpired) { try await waiter.value }
        }
    }

    @Test("expired renew fails and reacquire increments epoch")
    func expiredRenew() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try await createRoom(sql: sql, schema: schema)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            guard case .acquired(let old) = try await store.acquire(roomID: room, owner: owner,
                host: try host("old-expired"), duration: try V2ActorMilliseconds(100)) else {
                Issue.record("initial lease occupied"); return
            }
            try await Task.sleep(for: .milliseconds(200))
            await #expect(throws: V2RoomActivationLeaseError.leaseExpired) {
                _ = try await store.renew(token: old.token, duration: duration)
            }
            guard case .acquired(let replacement) = try await store.acquire(roomID: room, owner: owner,
                host: try host("new-expired"), duration: duration) else {
                Issue.record("expired lease was not replaced"); return
            }
            #expect(replacement.token.activationEpoch.rawValue == old.token.activationEpoch.rawValue + 1)
        }
    }

    @Test("opposite room order uses canonical locks and schema drift fails startup")
    func pairOrderAndReadiness() async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            let rooms = [try await createRoom(sql: sql, schema: schema), try await createRoom(sql: sql, schema: schema)]
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            var tokens: [V2RoomActivationToken] = []
            for room in rooms {
                guard case .acquired(let lease) = try await store.acquire(roomID: room, owner: owner,
                    host: try host("pair-host"), duration: duration) else { Issue.record("pair lease occupied"); return }
                tokens.append(lease.token)
            }
            let pairTokens = tokens
            let first = Task {
                try await database.transaction { transaction in
                    try await v2RequireRoomActivations(tokens: pairTokens, sql: try #require(transaction as? any SQLDatabase), schema: schema)
                }
            }
            let reverse = Array(tokens.reversed())
            let second = Task {
                try await database.transaction { transaction in
                    try await v2RequireRoomActivations(tokens: reverse, sql: try #require(transaction as? any SQLDatabase), schema: schema)
                }
            }
            try await first.value
            try await second.value
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).room_activation_leases DROP CONSTRAINT room_activation_leases_holder_check").run()
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).room_activation_leases ADD CONSTRAINT room_activation_leases_holder_check CHECK (true)").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".room_activation_leases[activation-contract]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
            try await sql.raw("DROP TABLE \(unsafeRaw: schema).room_activation_leases").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".room_activation_leases")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }

    @Test("failed business transaction rolls back while lease remains valid")
    func rolledBackWrite() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try await createRoom(sql: sql, schema: schema)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            guard case .acquired(let lease) = try await store.acquire(roomID: room, owner: owner,
                host: try host("rollback-host"), duration: duration) else {
                Issue.record("initial lease occupied"); return
            }
            await #expect(throws: ActivationRollback.self) {
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    try await v2RequireRoomActivation(token: lease.token, sql: txSQL, schema: schema)
                    try await txSQL.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 7 WHERE room_id = \(bind: room.uuidValue!)").run()
                    throw ActivationRollback()
                }
            }
            let sequence = try #require(try await sql.raw("SELECT room_sequence FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: room.uuidValue!)")
                .first(decoding: ActivationSequenceRow.self)).roomSequence
            #expect(sequence == 0)
            #expect(try await store.locate(roomID: room, owner: owner)?.token == lease.token)
        }
    }

    @Test("terminated database connection rolls back fenced write")
    func connectionLossRollsBack() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try await createRoom(sql: sql, schema: schema)
            let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            guard case .acquired(let lease) = try await store.acquire(roomID: room, owner: owner,
                host: try host("disconnect-host"), duration: duration) else {
                Issue.record("initial lease occupied"); return
            }
            var connectionFailed = false
            do {
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    try await v2RequireRoomActivation(token: lease.token, sql: txSQL, schema: schema)
                    try await txSQL.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 9 WHERE room_id = \(bind: room.uuidValue!)").run()
                    try await txSQL.raw("SELECT pg_terminate_backend(pg_backend_pid())").run()
                    try await txSQL.raw("SELECT 1").run()
                }
            } catch {
                connectionFailed = true
            }
            #expect(connectionFailed)
            let sequence = try #require(try await sql.raw("SELECT room_sequence FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: room.uuidValue!)")
                .first(decoding: ActivationSequenceRow.self)).roomSequence
            #expect(sequence == 0)
            #expect(try await store.locate(roomID: room, owner: owner)?.token == lease.token)
        }
    }

    private func createRoom(sql: any SQLDatabase, schema: String) async throws -> RoomID {
        let room = try RoomID(UUID().uuidString)
        try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms (room_id, room_shard_id, capacity_profile_id) VALUES (\(bind: room.uuidValue!), 'owner-a', 'standard')").run()
        return room
    }

    private func host(_ id: String) throws -> V2ActorHostIdentity {
        V2ActorHostIdentity(hostID: try V2ActorHostID(id), incarnationID: UUID())
    }
}

private actor ActivationGate {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct ActivationSequenceRow: Decodable {
    let roomSequence: Int64
    enum CodingKeys: String, CodingKey { case roomSequence = "room_sequence" }
}

private struct ActivationRollback: Error {}
