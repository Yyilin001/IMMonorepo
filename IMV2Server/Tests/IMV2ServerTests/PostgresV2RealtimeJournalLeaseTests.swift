import Foundation
import Testing
import SQLKit
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

@Suite("Source database journal fencing", .serialized)
struct PostgresV2RealtimeJournalLeaseTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func localClaimRenewalAndSuccessorRejectRoutingAndOldEpochs() async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await sql.raw("""
                CREATE TABLE IF NOT EXISTS \(unsafeRaw: schema).realtime_journal_publisher_leases
                (LIKE \(unsafeRaw: schema).realtime_partition_leases INCLUDING ALL)
                """).run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).realtime_journal_publisher_leases(partition_id) SELECT generate_series(0,255) ON CONFLICT DO NOTHING").run()
            let store = try PostgresV2RealtimeChangeJournalStore(database: database, schema: schema)
            let a = V2GatewayRealtimeIdentity(nodeID: "publisher-a", serviceID: "journal", incarnationID: UUID())
            let b = V2GatewayRealtimeIdentity(nodeID: "publisher-b", serviceID: "journal", incarnationID: UUID())
            let token = UUID()
            let claimed = try await store.claim(partitionIDs: [2], identity: a, token: token, leaseDuration: 15)
            #expect(claimed.count == 1)
            let first = try #require(claimed.first)
            let replayed = try await store.claim(partitionIDs: [2], identity: a, token: token, leaseDuration: 15)
            #expect(replayed.first?.epoch == first.epoch)
            #expect(try await store.renew(claimed, leaseDuration: 15).count == 1)
            #expect(try await store.claim(partitionIDs: [2], identity: b, token: UUID(), leaseDuration: 15).isEmpty)
            try await sql.raw("UPDATE \(unsafeRaw: schema).realtime_journal_publisher_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE partition_id=2").run()
            let successor = try await store.claim(partitionIDs: [2], identity: b, token: UUID(), leaseDuration: 15)
            #expect(successor.first?.epoch == first.epoch + 1)
            #expect(try await store.renew(claimed, leaseDuration: 15).isEmpty)
            await #expect(throws: V2RealtimeJournalError.leaseLost) {
                _ = try await store.publishPending(lease: first, limit: 128)
            }
            try await store.release(claimed)
            #expect(try await store.confirm(successor).count == 1)
        }
    }
}
