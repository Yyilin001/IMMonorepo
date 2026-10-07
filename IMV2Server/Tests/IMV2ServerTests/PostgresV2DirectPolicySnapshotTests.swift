import Foundation
import FluentKit
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("registered direct policy snapshots", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2DirectPolicySnapshotTests {
    @Test("cold load preserves special account rules and seals exclude stale refresh")
    func completeSnapshot() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let sender = UUID(), recipient = UUID()
            for (user, handle) in [(sender, "snapshot_sender"), (recipient, "snapshot_recipient")] {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).public_user_profiles
                    (user_id,public_handle,display_name,created_at,updated_at)
                    VALUES (\(bind: user),\(bind: handle),'Snapshot',clock_timestamp(),clock_timestamp())
                    """).run()
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).special_accounts
                (account_user_id,stable_key,account_kind,status,allows_customer_messages,allows_service_messages,created_at,updated_at)
                VALUES (\(bind: recipient),'snapshot_support','customer_support','paused',false,true,clock_timestamp(),clock_timestamp())
                """).run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).user_stranger_message_preferences VALUES (\(bind: recipient),false,clock_timestamp())").run()
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            var owners: [V2PolicyOwnerLease] = []
            for scope in [V2PolicyAuthorizationScope.account(sender), .account(recipient), .pair(sender, recipient), .stranger(recipient)] {
                owners.append(try await journal.acquireOwner(scope: scope, ownerID: UUID(), durationSeconds: 30))
            }
            let store = PostgresV2DirectPolicySnapshotStore(database: database, schema: schema)
            let snapshot = try await store.register(pair: .init(sender: sender, recipient: recipient), owners: owners,
                registrationID: UUID(), roomID: UUID(), activationID: UUID(), roomOwnerEpoch: 1,
                endpoint: "room-a", durationSeconds: 20)
            #expect(snapshot.policy.sender.isActive && snapshot.policy.recipient.isActive)
            #expect(snapshot.policy.recipient.specialKind == "customer_support")
            #expect(snapshot.policy.recipient.specialStatus == "paused")
            #expect(snapshot.policy.recipient.allowsCustomerMessages == false)
            #expect(snapshot.policy.recipient.allowsServiceMessages == true)
            #expect(!snapshot.policy.allowsStrangers && !snapshot.policy.isFriend && !snapshot.policy.blocked)
            #expect(snapshot.versions == .init(sender: 1, recipient: 1, pair: 1))
            _ = try await journal.beginChange(owner: owners[3], operationKey: "change-setting",
                fingerprint: Data(repeating: 1, count: 32), commandJSON: "{}")
            #expect(try await journal.targets(operationKey: "change-setting") == [snapshot.holder])
            let stamps = owners
            await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                try await store.register(pair: .init(sender: sender, recipient: recipient), owners: stamps,
                    registrationID: snapshot.holder.registrationID, roomID: snapshot.holder.roomID,
                    activationID: snapshot.holder.activationID, roomOwnerEpoch: 1, endpoint: "room-a", durationSeconds: 20)
            }
        }
    }

    @Test("failed snapshot read rolls back all dependency registrations and permits retry")
    func failedReadRollsBack() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let owner = try await journal.acquireOwner(scope: .account(UUID()), ownerID: UUID(), durationSeconds: 30)
            let registration = UUID(), room = UUID(), activation = UUID()
            await #expect(throws: SnapshotReadError.unavailable) {
                let _: Int = try await journal.registerSnapshot(owners: [owner], registrationID: registration,
                    roomID: room, activationID: activation, roomOwnerEpoch: 1, endpoint: "room-a", durationSeconds: 20) { transaction, _ in
                        #expect(transaction.inTransaction)
                        throw SnapshotReadError.unavailable
                    }
            }
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_authorization_holders WHERE registration_id=\(bind: registration)").first(decoding: Count.self)?.value == 0)
            let holder = try await journal.register(owners: [owner], registrationID: registration,
                roomID: room, activationID: activation, roomOwnerEpoch: 1, endpoint: "room-a", durationSeconds: 20)
            #expect(holder.registrationID == registration)
        }
    }
    @Test("a concurrent seal waits for snapshot registration and freezes its committed holder")
    func sealWaitsForRead() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let owner = try await journal.acquireOwner(scope: .account(UUID()), ownerID: UUID(), durationSeconds: 30)
            let gate = SnapshotTransactionGate()
            let loading = Task {
                try await journal.registerSnapshot(owners: [owner], registrationID: UUID(), roomID: UUID(),
                    activationID: UUID(), roomOwnerEpoch: 1, endpoint: "room-a", durationSeconds: 20) { transaction, holder in
                        let sql = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await sql.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: Count.self)).value
                        await gate.hold(pid: pid)
                        return holder
                    }
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while await gate.pid == nil, ContinuousClock.now < deadline { await Task.yield() }
            guard let pid = await gate.pid else {
                await gate.release(); _ = await loading.result
                throw SnapshotReadError.unavailable
            }
            let sealing = Task {
                try await journal.beginChange(owner: owner, operationKey: "seal",
                    fingerprint: Data(repeating: 2, count: 32), commandJSON: "{}")
            }
            do {
                var blocked: Int64 = 0
                let deadline = ContinuousClock.now + .seconds(5)
                repeat {
                    blocked = try await sql.raw("""
                        SELECT count(*)::bigint AS value FROM pg_stat_activity
                        WHERE \(bind: pid)::integer = ANY(pg_blocking_pids(pid))
                        """).first(decoding: Count.self)?.value ?? 0
                    if blocked > 0 { break }
                    await Task.yield()
                } while ContinuousClock.now < deadline
                #expect(blocked > 0)
                await gate.release()
                let holder = try await loading.value
                _ = try await sealing.value
                #expect(try await journal.targets(operationKey: "seal") == [holder])
            } catch {
                await gate.release(); _ = await loading.result; _ = await sealing.result
                throw error
            }
        }
    }
    private struct Count: Decodable { let value: Int64 }
}
private enum SnapshotReadError: Error { case unavailable }
private actor SnapshotTransactionGate {
    private(set) var pid: Int64?
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(pid: Int64) async {
        self.pid = pid
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
