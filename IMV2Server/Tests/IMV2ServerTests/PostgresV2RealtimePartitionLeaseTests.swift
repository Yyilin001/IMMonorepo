import Foundation
import SQLKit
import Testing
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

@Suite("Realtime partition control fencing", .serialized)
struct PostgresV2RealtimePartitionLeaseTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func claimsAreIdempotentAndExpiredTokensCannotAffectSuccessors() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = try PostgresV2RealtimePartitionLeaseStore(database: database, schema: schema)
            let host = identity("gateway-a")
            let token = UUID()
            let first = try await store.claim(partitionIDs: [7, 2], identity: host, token: token, leaseDuration: 30)
            #expect(first.map(\.partitionID) == [2, 7])
            #expect(first.allSatisfy { $0.epoch == 1 && $0.token == token && $0.remainingLeaseSeconds > 0 })
            let replay = try await store.claim(partitionIDs: [2, 7], identity: host, token: token, leaseDuration: 30)
            #expect(replay.map(\.epoch) == first.map(\.epoch))
            #expect(replay.allSatisfy { $0.remainingLeaseSeconds <= 30 })
            #expect(try await store.claim(partitionIDs: [2, 7], identity: identity("gateway-b"),
                                         token: UUID(), leaseDuration: 30).isEmpty)
            #expect(try await store.claim(partitionIDs: [2], identity: host, token: UUID(), leaseDuration: 30).isEmpty)
            let renewed = try await store.renew(first, leaseDuration: 30)
            #expect(renewed.count == 2)
            #expect(try await store.confirm(first).count == 2)

            // Controlled expiry, without test sleep or assumptions about scheduler timing.
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_partition_leases SET expires_at = clock_timestamp() - interval '1 second' WHERE partition_id IN (2,7)").run()
            #expect(try await store.renew(first, leaseDuration: 30).isEmpty)
            #expect(try await store.confirm(first).isEmpty)
            let successor = try await store.claim(partitionIDs: [2, 7], identity: identity("gateway-b"),
                                                  token: UUID(), leaseDuration: 30)
            #expect(successor.count == 2 && successor.allSatisfy { $0.epoch == 2 })
            try await store.release(first)
            #expect(try await store.confirm(successor).count == 2)
            try await store.release(successor)
            #expect(try await store.confirm(successor).isEmpty)
            let third = try await store.claim(partitionIDs: [2], identity: host, token: UUID(), leaseDuration: 30)
            #expect(third.first?.epoch == 3)
            await #expect(throws: V2RealtimePartitionStoreError.invalidInput) {
                _ = try await store.claim(partitionIDs: [256], identity: host, token: UUID(), leaseDuration: 30)
            }
            await #expect(throws: V2RealtimePartitionStoreError.invalidInput) {
                _ = try await store.claim(partitionIDs: [2, 2], identity: host, token: UUID(), leaseDuration: 30)
            }
            let count = try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).realtime_partition_leases").first(decoding: Count.self)
            #expect(count?.value == 256)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func competingClaimsUseOneLockOrder() async throws {
        try await withUserEventDatabase { database, _, schema in
            let store = try PostgresV2RealtimePartitionLeaseStore(database: database, schema: schema)
            let results = try await withThrowingTaskGroup(of: [V2RealtimePartitionLease].self) { group in
                for candidate in 0..<4 {
                    let host = identity("gateway-\(candidate)")
                    let token = UUID()
                    group.addTask {
                        try await store.claim(partitionIDs: candidate.isMultiple(of: 2) ? [1, 0] : [0, 1],
                                              identity: host, token: token, leaseDuration: 30)
                    }
                }
                var results: [[V2RealtimePartitionLease]] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(results.filter { !$0.isEmpty }.count == 1)
            #expect(results.flatMap { $0 }.count == 2)
            #expect(results.allSatisfy { $0.isEmpty || $0.map(\.partitionID) == [0, 1] })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func lockedPartitionTimesOutWithoutExtendingLease() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let store = try PostgresV2RealtimePartitionLeaseStore(database: database, schema: schema)
            let leases = try await store.claim(partitionIDs: [3], identity: identity("bounded"), token: UUID(), leaseDuration: 30)
            struct Expiry: Decodable { let expires_at: Date }
            let before = try #require(try await sql.raw("SELECT expires_at FROM \(unsafeRaw:schema).realtime_partition_leases WHERE partition_id=3").first(decoding: Expiry.self))
            let gate = PartitionLeaseRowGate()
            let holder = Task {
                try await database.transaction { borrowed in
                    let locked = try #require(borrowed as? any SQLDatabase)
                    _ = try await locked.raw("SELECT partition_id FROM \(unsafeRaw:schema).realtime_partition_leases WHERE partition_id=3 FOR UPDATE").all()
                    await gate.enter()
                }
            }
            await gate.waitEntered()
            do {
                await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
                    try await store.renew(leases, leaseDuration: 30)
                }
                await gate.release(); try await holder.value
                let after = try #require(try await sql.raw("SELECT expires_at FROM \(unsafeRaw:schema).realtime_partition_leases WHERE partition_id=3").first(decoding: Expiry.self))
                #expect(after.expires_at == before.expires_at)
                #expect(try await store.confirm(leases).count == 1)
            } catch { await gate.release(); _ = try? await holder.value; throw error }
        }
    }

    private func identity(_ node: String) -> V2GatewayRealtimeIdentity {
        .init(nodeID: node, serviceID: "gateway-service", incarnationID: UUID())
    }
    private struct Count: Decodable { let value: Int }
}

private actor PartitionLeaseRowGate {
    var entered = false, released = false
    var held: CheckedContinuation<Void,Never>?
    var waiting: [CheckedContinuation<Void,Never>] = []
    func enter() async {
        entered = true; for item in waiting { item.resume() }; waiting.removeAll()
        if !released { await withCheckedContinuation { held = $0 } }
    }
    func waitEntered() async { if !entered { await withCheckedContinuation { waiting.append($0) } } }
    func release() { released = true; held?.resume(); held = nil }
}
