import Crypto
import Foundation
import FluentKit
import IMV2ActorCluster
import IMV2ActorContracts
import SQLKit

package struct V2PolicyOwnerPlacement: Sendable {
    package enum Failure: Error, Equatable { case invalidScope, deploymentChanged, corruptPersistence }
    package let configuration: V2PolicyOwnerPlacementConfiguration
    package let digest: Data
    private let assignments: [V2PolicyOwnerPlacementConfiguration.Owner]
    package init(_ configuration: V2PolicyOwnerPlacementConfiguration) throws {
        self.configuration = configuration
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        digest = Data(SHA256.hash(data: Data("imv2-policy-placement-sha256-v1\u{0}".utf8) + (try encoder.encode(configuration))))
        var slots = Array<V2PolicyOwnerPlacementConfiguration.Owner?>(repeating: nil, count: configuration.partitionCount)
        for owner in configuration.owners { for partition in owner.partitions { slots[partition] = owner } }
        assignments = slots.map { $0! } // Validated DTO covers every slot exactly once.
    }
    package func partition(for key: String) throws -> Int {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let first = UUID(uuidString: String(parts[1])), first.uuidString.lowercased() == parts[1] else { throw Failure.invalidScope }
        if parts[0] == "account" || parts[0] == "stranger" {
            guard parts.count == 2 else { throw Failure.invalidScope }
        } else if parts[0] == "pair" {
            guard parts.count == 3, let second = UUID(uuidString: String(parts[2])),
                  second.uuidString.lowercased() == parts[2], parts[1] < parts[2] else { throw Failure.invalidScope }
        } else { throw Failure.invalidScope }
        // Fixed bytes and byte order, independent of Swift's randomized Hasher.
        let bytes = SHA256.hash(data: Data(("imv2-policy-scope-v1\u{0}" + key).utf8))
        let value = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(value & UInt64(configuration.partitionCount - 1))
    }
    package func assignment(for key: String) throws -> V2PolicyOwnerPlacementConfiguration.Owner {
        assignments[try partition(for: key)]
    }
    package func owns(_ key: String, hostID: UUID) -> Bool { (try? assignment(for: key).hostID) == hostID }
}

/// First startup records the control database's immutable deployment contract.
/// A conflicting mapping cannot silently start competing policy owners.
package struct PostgresV2PolicyDeploymentPlacementStore: Sendable {
    private let database: any Database
    private let schema: String
    package init(database: any Database, schema: String = "im_v2") {
        v2PreconditionSQLSchema(schema); self.database = database; self.schema = schema
    }
    /// A process without policy routing must not silently become a legacy
    /// writer after the control database has activated owner authorization.
    package func requireLegacy() async throws {
        guard let sql = database as? any SQLDatabase else { throw V2PolicyOwnerPlacement.Failure.corruptPersistence }
        let row = try await sql.raw("""
            SELECT EXISTS(SELECT 1 FROM \(unsafeRaw: schema).policy_owner_deployment
                WHERE deployment_id='active') AS active
            """).first(decoding: LegacyRow.self)
        guard let row else { throw V2PolicyOwnerPlacement.Failure.corruptPersistence }
        guard !row.active else { throw V2PolicyOwnerPlacement.Failure.deploymentChanged }
    }
    package func require(_ placement: V2PolicyOwnerPlacement) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PolicyOwnerPlacement.Failure.corruptPersistence }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).policy_owner_deployment(deployment_id,revision,snapshot_digest)
                VALUES('active',\(bind: placement.configuration.revision),\(bind: placement.digest)) ON CONFLICT DO NOTHING
                """).run()
            guard let row = try await sql.raw("""
                SELECT revision,snapshot_digest FROM \(unsafeRaw: schema).policy_owner_deployment
                WHERE deployment_id='active' FOR SHARE
                """).first(decoding: DeploymentRow.self) else { throw V2PolicyOwnerPlacement.Failure.corruptPersistence }
            guard row.revision == placement.configuration.revision, row.snapshot_digest == placement.digest else {
                throw V2PolicyOwnerPlacement.Failure.deploymentChanged
            }
        }
    }
    private struct DeploymentRow: Decodable { let revision: Int64; let snapshot_digest: Data }
    private struct LegacyRow: Decodable { let active: Bool }
}

package struct PostgresV2PolicyDeploymentRoutes: Sendable {
    private let placement: V2PolicyOwnerPlacement
    private let client: V2RoomClusterClient
    package init(placement: V2PolicyOwnerPlacement, client: V2RoomClusterClient) {
        self.placement = placement; self.client = client
    }
    package func resolveScopes(_ keys: [String]) throws -> [PostgresV2RemotePolicyOwners.Route] {
        let snapshot = client.routingSnapshot()
        return try keys.map { key in
            let target = try placement.assignment(for: key)
            let host = try snapshot.resolvePolicyHost(hostID: .init(uuid: target.hostID), endpoint: target.endpoint)
            return .init(host: host, endpoint: target.endpoint, ownerID: host.incarnationID)
        }
    }
    package func resolveScope(_ key: String) throws -> PostgresV2RemotePolicyOwners.Route {
        let target = try placement.assignment(for: key)
        let host = try client.resolvePolicyHost(hostID: .init(uuid: target.hostID), endpoint: target.endpoint)
        return .init(host: host, endpoint: target.endpoint, ownerID: host.incarnationID)
    }
}
