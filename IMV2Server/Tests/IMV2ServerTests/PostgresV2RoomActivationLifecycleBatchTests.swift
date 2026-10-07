@testable import IMV2ServerInfrastructure
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing

@Suite("Bounded activation lifecycle transactions", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2RoomActivationLifecycleBatchTests {
    private let owner = try! V2RoomDataOwner(shardID: "owner-a", epoch: 0)
    private let host = V2ActorHostIdentity(hostID: try! .init("lifecycle-host"), incarnationID: UUID())
    private let duration = try! V2ActorMilliseconds(30_000)

    @Test("129 first acquisitions share bounded transactions with exact committed identities")
    func coalescedFirstAcquisitions() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let rooms = try await createRooms(129, sql: sql, schema: schema)
            try await installAudit(sql: sql, schema: schema)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            let start = LifecycleLockGate()
            let jobs = rooms.map { room in Task {
                await start.wait()
                return try await store.acquire(roomID: room, owner: owner, host: host, duration: duration)
            } }
            try await start.waitForEntries(rooms.count)
            await start.open()
            for (room, job) in zip(rooms, jobs) {
                let lease = try acquired(try await job.value)
                #expect(lease.token.roomID == room && lease.token.owner == owner && lease.token.host == host)
                #expect(lease.token.activationEpoch.rawValue == 1)
            }
            let audit = try #require(try await sql.raw("""
                SELECT count(*) AS batches, sum(size)::bigint AS total, max(size) AS largest
                FROM (SELECT count(*) AS size FROM \(unsafeRaw: schema).lifecycle_audit GROUP BY transaction_id) batches
                """).first(decoding: LifecycleAudit.self))
            #expect(audit.total == 129)
            #expect(audit.batches >= 2 && audit.batches < 129)
            #expect(audit.largest <= 128)
            await store.shutdownRenewals()
        }
    }

    @Test("occupied, expired, released, stale owner and exhausted epochs retain independent outcomes")
    func independentLifecycleDecisions() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let rooms = try await createRooms(7, sql: sql, schema: schema)
            let seeded = try await commit(rooms.map { .init(roomID: $0,
                operation: .acquire(owner: owner, host: host, duration: duration)) }, database: database, schema: schema)
            let leases = try seeded.map { result in
                guard case .acquired(let value) = try result.get() else { throw LifecycleTestFailure.wrongValue }
                return try acquired(value)
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET host_id=NULL,host_incarnation_id=NULL,expires_at=NULL WHERE room_id=\(bind: rooms[2].uuidValue!)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch=1 WHERE room_id=\(bind: rooms[3].uuidValue!)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET activation_epoch=\(bind: Int64.max),expires_at=clock_timestamp()-interval '1 second' WHERE room_id=\(bind: rooms[4].uuidValue!)").run()
            let otherHost = V2ActorHostIdentity(hostID: host.hostID, incarnationID: UUID())
            let wrong = V2RoomActivationToken(roomID: rooms[6], owner: owner,
                activationEpoch: leases[6].token.activationEpoch, host: otherHost)
            let absent = try RoomID(UUID().uuidString)
            let inputs = rooms.prefix(5).map { V2RoomActivationLifecycleInput(roomID: $0,
                operation: .acquire(owner: owner, host: otherHost, duration: duration)) }
                + [.init(roomID: rooms[5], operation: .release(token: leases[5].token)),
                   .init(roomID: rooms[6], operation: .release(token: wrong)),
                   .init(roomID: absent, operation: .locate(owner: owner))]
            let results = try await commit(inputs, database: database, schema: schema)
            guard case .acquired(.occupied(let occupied)) = try results[0].get() else { throw LifecycleTestFailure.wrongValue }
            #expect(occupied.token == leases[0].token)
            for index in [1, 2] {
                guard case .acquired(.acquired(let successor)) = try results[index].get() else { throw LifecycleTestFailure.wrongValue }
                #expect(successor.token.activationEpoch.rawValue == 2 && successor.token.host == otherHost)
            }
            #expect(leaseError(results[3]) == .ownerChanged)
            #expect(leaseError(results[4]) == .epochExhausted)
            guard case .released(let released) = try results[5].get(),
                  case .released(let rejected) = try results[6].get() else { throw LifecycleTestFailure.wrongValue }
            #expect(released && !rejected)
            #expect(leaseError(results[7]) == .roomNotFound)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            #expect(try await store.locate(roomID: rooms[5], owner: owner) == nil)
            #expect(try await store.locate(roomID: rooms[6], owner: owner)?.token == leases[6].token)
            #expect(try await store.release(token: leases[1].token) == false)
            await store.shutdownRenewals()
        }
    }

    @Test("batched restoration validates full tokens without mutating leases or masking sibling outcomes")
    func validationRetainsFullFence() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let rooms = try await createRooms(9, sql: sql, schema: schema)
            let seeded = try await commit(rooms.prefix(7).map { .init(roomID: $0,
                operation: .acquire(owner: owner, host: host, duration: duration)) }, database: database, schema: schema)
            let tokens = try seeded.map { result in
                guard case .acquired(let value) = try result.get() else { throw LifecycleTestFailure.wrongValue }
                return try acquired(value).token
            }
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE room_id=\(bind: rooms[1].uuidValue!)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch=1 WHERE room_id=\(bind: rooms[2].uuidValue!)").run()
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET host_id=NULL,host_incarnation_id=NULL,expires_at=NULL WHERE room_id=\(bind: rooms[6].uuidValue!)").run()
            let wrongEpoch = V2RoomActivationToken(roomID: rooms[3], owner: owner,
                activationEpoch: try .init(2), host: host)
            let wrongIncarnation = V2RoomActivationToken(roomID: rooms[4], owner: owner,
                activationEpoch: tokens[4].activationEpoch, host: .init(hostID: host.hostID, incarnationID: UUID()))
            let wrongHost = V2RoomActivationToken(roomID: rooms[5], owner: owner,
                activationEpoch: tokens[5].activationEpoch, host: .init(hostID: try .init("other-host"), incarnationID: host.incarnationID))
            let missing = V2RoomActivationToken(roomID: rooms[7], owner: owner,
                activationEpoch: try .init(1), host: host)
            let absent = V2RoomActivationToken(roomID: try .init(UUID().uuidString), owner: owner,
                activationEpoch: try .init(1), host: host)
            let validationTokens = [tokens[0], tokens[1], tokens[2], wrongEpoch,
                wrongIncarnation, wrongHost, tokens[6], missing, absent]
            let before = try await leaseSnapshot(excluding: rooms[8], sql: sql, schema: schema)
            try await installAudit(sql: sql, schema: schema)
            let inputs = validationTokens.map { V2RoomActivationLifecycleInput(roomID: $0.roomID,
                operation: .validate(token: $0)) } + [.init(roomID: rooms[8],
                operation: .acquire(owner: owner, host: host, duration: duration))]
            let results = try await commit(inputs, database: database, schema: schema)
            guard case .validated = try results[0].get(),
                  case .acquired(.acquired(let sibling)) = try results[9].get() else {
                throw LifecycleTestFailure.wrongValue
            }
            #expect(sibling.token.roomID == rooms[8])
            #expect(leaseError(results[1]) == .leaseExpired)
            #expect(leaseError(results[2]) == .ownerChanged)
            for index in 3...7 { #expect(leaseError(results[index]) == .activationChanged) }
            #expect(leaseError(results[8]) == .roomNotFound)
            #expect(try await leaseSnapshot(excluding: rooms[8], sql: sql, schema: schema) == before)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).lifecycle_audit").first(decoding: LifecycleCount.self)?.value == 1)
            let store = PostgresV2RoomActivationStore(database: database, schema: schema)
            try await store.validate(token: tokens[0])
            await store.shutdownLifecycle()
        }
    }

    @Test("restoration rejects a committed predecessor replacement and expiry after actual lock waiting", arguments: [false, true])
    func validationLockWaitUsesFreshFacts(expiryCase: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try #require(try await createRooms(1, sql: sql, schema: schema).first)
            let seeded = try await commit([.init(roomID: room, operation: .acquire(owner: owner,
                host: host, duration: duration))], database: database, schema: schema)
            guard case .acquired(let acquisition) = try seeded[0].get() else { throw LifecycleTestFailure.wrongValue }
            let token = try acquired(acquisition).token
            if expiryCase {
                try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET expires_at=clock_timestamp()+interval '800 milliseconds' WHERE room_id=\(bind: room.uuidValue!)").run()
            }
            let gate = LifecycleLockGate()
            let deadline = ContinuousClock.now + .seconds(5)
            let holder = Task {
                try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await v2WithRoomScopedTransaction(database: database) { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: LifecycleCount.self))
                        if expiryCase {
                            _ = try await connection.raw("SELECT room_id FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id=\(bind: room.uuidValue!) FOR UPDATE").all()
                        } else {
                            _ = try await connection.raw("SELECT room_id FROM \(unsafeRaw: schema).rooms WHERE room_id=\(bind: room.uuidValue!) FOR NO KEY UPDATE").all()
                        }
                        await gate.hold(pid: pid.value)
                        if !expiryCase {
                            try await connection.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET activation_epoch=activation_epoch+1 WHERE room_id=\(bind: room.uuidValue!)").run()
                        }
                    }
                }
            }
            var worker: Task<[Result<V2RoomActivationLifecycleValue, any Error>], any Error>?
            do {
                let pid = try await gate.waitUntilHeld(deadline: deadline)
                worker = Task { try await commit([.init(roomID: room, operation: .validate(token: token))],
                    database: database, schema: schema) }
                var blockedBeforeExpiry = false, observedBlocked = false
                while ContinuousClock.now < deadline {
                    let state = try #require(try await sql.raw("""
                        SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname=current_database()
                          AND state='active' AND wait_event_type='Lock' AND \(bind: pid)::int=ANY(pg_blocking_pids(pid))
                          AND query LIKE \(bind: "%"+schema+"%")) AS blocked,
                        COALESCE((SELECT clock_timestamp()>=expires_at FROM \(unsafeRaw: schema).room_activation_leases
                          WHERE room_id=\(bind: room.uuidValue!)),false) AS expired
                        """).first(decoding: LifecycleBlocked.self))
                    observedBlocked = observedBlocked || state.blocked
                    blockedBeforeExpiry = blockedBeforeExpiry || (state.blocked && !state.expired)
                    if observedBlocked && (!expiryCase || state.expired) { break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                await gate.open()
                try await holder.value
                let values = try await #require(worker).value
                try #require(observedBlocked)
                if expiryCase { try #require(blockedBeforeExpiry) }
                #expect(leaseError(values[0]) == (expiryCase ? .leaseExpired : .activationChanged))
            } catch {
                await gate.open()
                _ = await holder.result
                if let worker { _ = await worker.result }
                throw error
            }
        }
    }

    @Test("a real predecessor insert is visible, and expiry is sampled after a real lease lock wait", arguments: [false, true])
    func lockWaitUsesFreshFacts(expiryCase: Bool) async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = try #require(try await createRooms(1, sql: sql, schema: schema).first)
            let token = V2RoomActivationToken(roomID: room, owner: owner,
                activationEpoch: try .init(1), host: host)
            if expiryCase {
                _ = try await commit([.init(roomID: room, operation: .acquire(owner: owner, host: host, duration: duration))], database: database, schema: schema)
                try await sql.raw("UPDATE \(unsafeRaw: schema).room_activation_leases SET expires_at=clock_timestamp()+interval '800 milliseconds' WHERE room_id=\(bind: room.uuidValue!)").run()
            }
            let gate = LifecycleLockGate()
            let deadline = ContinuousClock.now + .seconds(5)
            let holder = Task {
                try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await v2WithRoomScopedTransaction(database: database) { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: LifecycleCount.self))
                        if expiryCase {
                            _ = try await connection.raw("SELECT room_id FROM \(unsafeRaw: schema).room_activation_leases WHERE room_id=\(bind: room.uuidValue!) FOR UPDATE").all()
                        } else {
                            _ = try await connection.raw("SELECT room_id FROM \(unsafeRaw: schema).rooms WHERE room_id=\(bind: room.uuidValue!) FOR NO KEY UPDATE").all()
                        }
                        await gate.hold(pid: pid.value)
                        if !expiryCase {
                            try await connection.raw("""
                                INSERT INTO \(unsafeRaw: schema).room_activation_leases
                                (room_id,activation_epoch,owner_shard_id,owner_epoch,host_id,host_incarnation_id,expires_at)
                                VALUES (\(bind: room.uuidValue!),1,\(bind: owner.shardID),0,\(bind: host.hostID.rawValue),\(bind: host.incarnationID),clock_timestamp()+interval '30 seconds')
                                """).run()
                        }
                    }
                }
            }
            var worker: Task<[Result<V2RoomActivationLifecycleValue, any Error>], any Error>?
            do {
                let pid = try await gate.waitUntilHeld(deadline: deadline)
                let input: V2RoomActivationLifecycleInput = .init(roomID: room, operation: expiryCase
                    ? .release(token: token) : .acquire(owner: owner, host: .init(hostID: host.hostID, incarnationID: UUID()), duration: duration))
                worker = Task { try await commit([input], database: database, schema: schema) }
                var blockedBeforeExpiry = false, observedBlocked = false
                while ContinuousClock.now < deadline {
                    let state = try #require(try await sql.raw("""
                        SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname=current_database()
                          AND state='active' AND wait_event_type='Lock' AND \(bind: pid)::int=ANY(pg_blocking_pids(pid))
                          AND query LIKE \(bind: "%"+schema+"%")) AS blocked,
                        COALESCE((SELECT clock_timestamp()>=expires_at FROM \(unsafeRaw: schema).room_activation_leases
                          WHERE room_id=\(bind: room.uuidValue!)),false) AS expired
                        """).first(decoding: LifecycleBlocked.self))
                    observedBlocked = observedBlocked || state.blocked
                    blockedBeforeExpiry = blockedBeforeExpiry || (state.blocked && !state.expired)
                    if observedBlocked && (!expiryCase || state.expired) { break }
                    try await Task.sleep(for: .milliseconds(2))
                }
                await gate.open()
                try await holder.value
                let values = try await #require(worker).value
                try #require(observedBlocked)
                if expiryCase {
                    try #require(blockedBeforeExpiry)
                    guard case .released(let value) = try values[0].get() else { throw LifecycleTestFailure.wrongValue }
                    #expect(!value)
                } else {
                    guard case .acquired(.occupied(let lease)) = try values[0].get() else { throw LifecycleTestFailure.wrongValue }
                    #expect(lease.token == token)
                }
            } catch {
                await gate.open()
                _ = await holder.result
                if let worker { _ = await worker.result }
                throw error
            }
        }
    }

    @Test("successful batch COMMIT with lost ACK is unknown for every mutation without reexecution",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_ACK_LOSS_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func committedBatchAckLoss() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_ACK_LOSS_DATABASE_URL"])
        let components = try #require(URLComponents(string: url))
        let proxy = try await V2PostgresCommitAckLossProxy.start(backendHost: try #require(components.host), backendPort: components.port ?? 5432)
        let proxied = makeV2DatabaseTestResources()
        do {
            var through = components
            through.host = "127.0.0.1"; through.port = proxy.port
            through.queryItems = (through.queryItems ?? []).filter { !["sslmode", "tlsmode", "ssl", "tls"].contains($0.name.lowercased()) }
                + [URLQueryItem(name: "sslmode", value: "disable")]
            proxied.databases.use(try .postgres(url: try #require(through.url?.absoluteString), maxConnectionsPerEventLoop: 1), as: .psql, isDefault: true)
            try await withUserEventDatabase(databaseURL: url) { database, sql, schema in
                let rooms = try await createRooms(3, sql: sql, schema: schema)
                let seeded = try await commit([.init(roomID: rooms[2], operation: .acquire(owner: owner,
                    host: host, duration: duration))], database: database, schema: schema)
                guard case .acquired(let acquisition) = try seeded[0].get() else { throw LifecycleTestFailure.wrongValue }
                let token = try acquired(acquisition).token
                try await installAudit(sql: sql, schema: schema)
                let result = try await V2RoomSQLDeadline.withDeadline(.now + .seconds(5)) {
                    let inputs = rooms.prefix(2).map { V2RoomActivationLifecycleInput(roomID: $0,
                        operation: .acquire(owner: owner, host: host, duration: duration)) }
                        + [.init(roomID: rooms[2], operation: .validate(token: token))]
                    return try await commit(inputs, database: proxied.database(.psql), schema: schema)
                }
                #expect(proxy.observedSuccessfulCommit)
                #expect(result.count == 3 && result.allSatisfy { leaseError($0) == .outcomeUnknown })
                let facts = try await sql.raw("SELECT activation_epoch AS value FROM \(unsafeRaw: schema).room_activation_leases").all(decoding: LifecycleCount.self)
                #expect(facts.count == 3 && facts.allSatisfy { $0.value == 1 })
                #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).lifecycle_audit").first(decoding: LifecycleCount.self)?.value == 2)
            }
            try await proxied.shutdown(); try await proxy.shutdown()
        } catch {
            try? await proxied.shutdown(); try? await proxy.shutdown()
            throw error
        }
    }

    private func leaseSnapshot(excluding room: RoomID, sql: any SQLDatabase, schema: String) async throws -> String {
        try #require(try await sql.raw("""
            SELECT COALESCE(jsonb_agg(to_jsonb(lease) ORDER BY room_id),'[]'::jsonb)::text AS value
            FROM \(unsafeRaw: schema).room_activation_leases AS lease WHERE room_id<>\(bind: room.uuidValue!)
            """).first(decoding: LifecycleText.self)).value
    }

    private func commit(_ inputs: [V2RoomActivationLifecycleInput], database: any Database, schema: String) async throws -> [Result<V2RoomActivationLifecycleValue, any Error>] {
        try await V2RoomActivationLifecycleSQL.commit(inputs, database: database, schema: schema, timeouts: .default)
    }
    private func acquired(_ value: V2RoomActivationAcquisition) throws -> V2RoomActivationLease {
        guard case .acquired(let lease) = value else { throw LifecycleTestFailure.wrongValue }
        return lease
    }
    private func leaseError(_ result: Result<V2RoomActivationLifecycleValue, any Error>) -> V2RoomActivationLeaseError? {
        guard case .failure(let error) = result else { return nil }
        return error as? V2RoomActivationLeaseError
    }
    private func createRooms(_ count: Int, sql: any SQLDatabase, schema: String) async throws -> [RoomID] {
        let rooms = try (0..<count).map { _ in try RoomID(UUID().uuidString) }
        let payload = String(decoding: try JSONEncoder().encode(rooms.map { $0.uuidValue! }), as: UTF8.self)
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).rooms (room_id,room_shard_id,capacity_profile_id)
            SELECT value::uuid,'owner-a','standard' FROM jsonb_array_elements_text(\(bind: payload)::jsonb)
            """).run()
        return rooms
    }
    private func installAudit(sql: any SQLDatabase, schema: String) async throws {
        try await sql.raw("CREATE TABLE \(unsafeRaw: schema).lifecycle_audit (transaction_id bigint NOT NULL)").run()
        try await sql.raw("""
            CREATE FUNCTION \(unsafeRaw: schema).audit_lifecycle() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN INSERT INTO \(unsafeRaw: schema).lifecycle_audit VALUES (txid_current()); RETURN NEW; END; $$
            """).run()
        try await sql.raw("CREATE TRIGGER audit_lifecycle AFTER INSERT OR UPDATE ON \(unsafeRaw: schema).room_activation_leases FOR EACH ROW EXECUTE FUNCTION \(unsafeRaw: schema).audit_lifecycle()").run()
    }
}

private enum LifecycleTestFailure: Error { case wrongValue, timeout }
private struct LifecycleAudit: Decodable { let batches: Int64; let total: Int64; let largest: Int64 }
private struct LifecycleText: Decodable { let value: String }
private struct LifecycleCount: Decodable { let value: Int64 }
private struct LifecycleBlocked: Decodable { let blocked: Bool; let expired: Bool }
private actor LifecycleLockGate {
    private var opened = false
    private var entries = 0
    private var pid: Int64?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entries += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func hold(pid: Int64) async { self.pid = pid; await wait() }
    func waitUntilHeld(deadline: ContinuousClock.Instant) async throws -> Int64 {
        while ContinuousClock.now < deadline {
            if let pid { return pid }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw LifecycleTestFailure.timeout
    }
    func waitForEntries(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while entries < count {
            guard ContinuousClock.now < deadline else { throw LifecycleTestFailure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
