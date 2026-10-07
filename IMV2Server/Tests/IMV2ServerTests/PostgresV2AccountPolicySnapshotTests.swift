import Foundation
import FluentKit
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("registered sending-account policy", .serialized, .timeLimit(.minutes(2)))
struct PostgresV2AccountPolicySnapshotTests {
    @Test("one account dependency drains real work before publishing an inactive version")
    func accountDependency() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let sender = UUID(), activation = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).public_user_profiles
                (user_id,public_handle,display_name,created_at,updated_at)
                VALUES (\(bind: sender),'account_policy_sender','Sender',clock_timestamp(),clock_timestamp())
                """).run()
            let journal = PostgresV2PolicyAuthorizationJournal(database: database, schema: schema)
            let owner = try await journal.acquireOwner(scope: .account(sender), ownerID: UUID(), durationSeconds: 30)
            let state = try await journal.readOwnerState(owner: owner)
            let store = PostgresV2AccountPolicySnapshotStore(database: database, schema: schema)
            let tables = ["public_user_profiles", "special_accounts", "account_disables", "user_stranger_message_preferences"]
            for table in tables { try await sql.raw("ALTER TABLE \(unsafeRaw: schema).\(unsafeRaw: table) RENAME TO \(unsafeRaw: table + "_hidden")").run() }
            let snapshot = try await store.register(sender: sender, state: state, registrationID: UUID(), roomID: UUID(),
                activationID: activation, roomOwnerEpoch: 1, endpoint: "group-owner", durationSeconds: 20)
            for table in tables { try await sql.raw("ALTER TABLE \(unsafeRaw: schema).\(unsafeRaw: table + "_hidden") RENAME TO \(unsafeRaw: table)").run() }
            #expect(snapshot.account.userID == sender && snapshot.account.isActive)
            #expect(snapshot.versions == .init(accountSender: 1))
            #expect(snapshot.deadline <= state.deadline)
            let rows = try await sql.raw("SELECT scope_key FROM \(unsafeRaw: schema).policy_authorization_holders WHERE registration_id=\(bind: snapshot.holder.registrationID)").all(decoding: ScopeRow.self)
            #expect(rows.map(\.scope_key) == [V2PolicyAuthorizationScope.account(sender).key])
            await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidRequest) {
                try await store.register(sender: UUID(), state: state, registrationID: UUID(), roomID: UUID(),
                    activationID: activation, roomOwnerEpoch: 1, endpoint: "group-owner", durationSeconds: 20)
            }
            let fence = PostgresV2RoomPolicyLeaseFence(database: database, schema: schema)
            try await fence.install(snapshot.holder)
            let gate = V2RoomPolicyAuthorizationGate(activation: activation, ownerEpoch: 1, maximumInFlight: 1)
            try await gate.install(snapshot.gatePolicy(), lease: .init(id: snapshot.holder.registrationID,
                activation: activation, ownerEpoch: 1, generation: snapshot.holder.generation, validUntil: snapshot.deadline))
            let permit = try await gate.reserveExecution(callerDeadline: .now + .seconds(20))
            let held = AccountSnapshotSQLHold()
            var executing: Task<Void, any Error>?
            var revoking: Task<V2PolicyAuthorizationRevocationProof, any Error>?
            do {
                let task = Task {
                    do {
                        try await database.transaction { transaction in
                            try await fence.requireActive(snapshot.holder, transaction: transaction)
                            await held.wait()
                        }
                        try await gate.settled(permit)
                    } catch { try? await gate.settled(permit); throw error }
                }; executing = task
                try await observe { await held.entered }
                let change = try await journal.beginChange(owner: owner, operationKey: "group-sender-inactive",
                    fingerprint: Data(repeating: 5, count: 32), commandJSON: "{}")
                await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
                    try await store.register(sender: sender, state: state, registrationID: UUID(), roomID: UUID(),
                        activationID: activation, roomOwnerEpoch: 1, endpoint: "group-owner", durationSeconds: 20)
                }
                let revoke = Task {
                    #expect(await gate.revoke(leaseID: snapshot.holder.registrationID))
                    return try await fence.revoke(snapshot.holder)
                }; revoking = revoke
                try await observe { await gate.snapshot().waitingForSettlement == 1 }
                #expect(try await journal.targets(operationKey: change.operationKey) == [snapshot.holder])
                await #expect(throws: V2PolicyAuthorizationLifecycleError.notDrained) {
                    try await journal.commitChange(owner: owner, operationKey: change.operationKey) { _, _ in Data([5]) }
                }
                await held.release(); try await task.value
                let proof = try await revoke.value
                try await journal.acknowledge(operationKey: change.operationKey, proof: proof)
                _ = try await journal.commitChange(owner: owner, operationKey: change.operationKey) { transaction, _ in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("UPDATE \(unsafeRaw: schema).public_user_profiles SET state='suspended' WHERE user_id=\(bind: sender)").run()
                    return Data([5])
                }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) { try await fence.install(snapshot.holder) }
                await #expect(throws: V2PolicyAuthorizationLifecycleError.staleVersion) {
                    try await store.register(sender: sender, state: state, registrationID: UUID(), roomID: UUID(),
                        activationID: activation, roomOwnerEpoch: 1, endpoint: "group-owner", durationSeconds: 20)
                }
                let refreshedOwner = try await journal.acquireOwner(scope: .account(sender), ownerID: owner.ownerID, durationSeconds: 30)
                let refreshedState = try await journal.readOwnerState(owner: refreshedOwner)
                let refreshed = try await store.register(sender: sender, state: refreshedState,
                    registrationID: UUID(), roomID: snapshot.holder.roomID,
                    activationID: activation, roomOwnerEpoch: 1, endpoint: "group-owner", durationSeconds: 20)
                #expect(!refreshed.account.isActive && refreshed.versions == .init(accountSender: 2))
                #expect(refreshed.holder.registrationID != snapshot.holder.registrationID)
                #expect(refreshed.holder.generation > snapshot.holder.generation)
                try await fence.install(refreshed.holder)
                try await gate.install(refreshed.gatePolicy(), lease: .init(id: refreshed.holder.registrationID,
                    activation: activation, ownerEpoch: 1, generation: refreshed.holder.generation, validUntil: refreshed.deadline))
                await #expect(throws: V2RoomPolicyAuthorizationGate.Failure.senderInactive) {
                    try await gate.acquire(callerDeadline: .now + .seconds(5))
                }
            } catch {
                await held.release(); _ = await executing?.result; _ = await revoking?.result
                await gate.shutdown(); throw error
            }
            await gate.shutdown()
        }
    }
    private func observe(_ check: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while .now < deadline { if await check() { return }; await Task.yield() }
        throw V2PolicyAuthorizationLifecycleError.notDrained
    }
    private struct ScopeRow: Decodable { let scope_key: String }
}
private actor AccountSnapshotSQLHold {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
