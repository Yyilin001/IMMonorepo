import Foundation
import IMV2ActorContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("fixed policy deployment placement", .serialized)
struct PostgresV2PolicyDeploymentPlacementTests {
    @Test("canonical scope hashing matches fixed vectors and placement ignores array order")
    func stableHashing() throws {
        let a = UUID(), b = UUID()
        let first = try V2PolicyOwnerPlacementConfiguration.Owner(hostID: a, endpoint: "a", partitions: [3, 1, 0, 2])
        let second = try V2PolicyOwnerPlacementConfiguration.Owner(hostID: b, endpoint: "b", partitions: Array(4..<16))
        let placement = try V2PolicyOwnerPlacement(.init(revision: 1, partitionCount: 16, owners: [first, second]))
        let reordered = try V2PolicyOwnerPlacement(.init(revision: 1, partitionCount: 16, owners: [second, first]))
        #expect(placement.digest == reordered.digest)
        let scopes = ["account:00000000-0000-0000-0000-000000000012",
            "account:00000000-0000-0000-0000-000000000015",
            "pair:00000000-0000-0000-0000-000000000012:00000000-0000-0000-0000-000000000015"]
        #expect(try scopes.map { try placement.partition(for: $0) } == [3, 4, 14])
        for key in ["account:invalid", "unknown:" + a.uuidString.lowercased(), "account:" + a.uuidString + ":extra",
            "pair:00000000-0000-0000-0000-000000000015:00000000-0000-0000-0000-000000000012"] {
            #expect(throws: V2PolicyOwnerPlacement.Failure.invalidScope) { try placement.partition(for: key) }
        }
        #expect(throws: (any Error).self) { try V2PolicyOwnerPlacementConfiguration(revision: 1, partitionCount: 16, owners: [first]) }
        #expect(throws: (any Error).self) { try V2PolicyOwnerPlacementConfiguration(revision: 1, partitionCount: 3, owners: [first]) }
        #expect(throws: (any Error).self) { try V2PolicyOwnerPlacementConfiguration.Owner(hostID: a, endpoint: "a", partitions: [1, 1]) }
        #expect(try JSONDecoder().decode(V2PolicyOwnerPlacementConfiguration.self,
            from: JSONEncoder().encode(placement.configuration)) == placement.configuration)
    }
    @Test("control database rejects a conflicting deployment without rewriting the existing snapshot")
    func durableDeploymentContract() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let host = UUID()
            let placement = try V2PolicyOwnerPlacement(.init(revision: 1, partitionCount: 1,
                owners: [.init(hostID: host, endpoint: "a", partitions: [0])]))
            let store = PostgresV2PolicyDeploymentPlacementStore(database: database, schema: schema)
            try await store.require(placement); try await store.require(placement)
            let conflict = try V2PolicyOwnerPlacement(.init(revision: 1, partitionCount: 1,
                owners: [.init(hostID: host, endpoint: "different", partitions: [0])]))
            await #expect(throws: V2PolicyOwnerPlacement.Failure.deploymentChanged) { try await store.require(conflict) }
            let newer = try V2PolicyOwnerPlacement(.init(revision: 2, partitionCount: 1,
                owners: [.init(hostID: host, endpoint: "a", partitions: [0])]))
            await #expect(throws: V2PolicyOwnerPlacement.Failure.deploymentChanged) { try await store.require(newer) }
            try await store.require(placement)
            #expect(try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: schema).policy_owner_deployment").first(decoding: Count.self)?.value == 1)
        }
    }
    private struct Count: Decodable { let value: Int64 }
}
