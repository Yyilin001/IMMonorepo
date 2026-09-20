import Crypto
import Fluent
import Foundation
import SQLKit

/// Combines deployment identity with a transactionally updated routing fence.
/// Use the control database, not an owner replica or a cached routing snapshot.
public struct PostgresV2RoomRecoveryTopology: V2RoomRecoveryTopologyReading {
    private let database: any Database
    private let schema: String
    private let stores: [any V2UserRoomDirectoryReading]
    private let configurationDigest: String

    public init(database: any Database, schema: String = "im_v2",
                stores: [any V2UserRoomDirectoryReading], orderedStoreIdentities: [String]) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
              !stores.isEmpty, stores.count == orderedStoreIdentities.count,
              orderedStoreIdentities.allSatisfy({ !$0.isEmpty }),
              Set(orderedStoreIdentities).count == orderedStoreIdentities.count else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        self.database = database
        self.schema = schema
        self.stores = stores
        // Length-delimited encoding prevents ambiguous configuration identities.
        let encoded = try JSONEncoder().encode(orderedStoreIdentities)
        self.configurationDigest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    public func topology() async throws -> V2RoomRecoveryTopology {
        try Task.checkCancellation()
        guard let sql = database as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
        guard let row = try await sql.raw("""
            SELECT generation FROM \(unsafeRaw: schema).room_recovery_topology WHERE singleton = true
            """).first(decoding: GenerationRow.self) else {
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        return try .init(generation: configurationDigest + ":" + row.generation.uuidString.lowercased(), stores: stores)
    }
}

private struct GenerationRow: Decodable {
    let generation: UUID
}
