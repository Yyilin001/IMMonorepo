import FluentKit
import Foundation
import SQLKit

/// Validate the physical data source, including after a dump/restore move.
public enum V2FixedShardSources {
    public static func verify(control: any Database, rooms: [V2RoomShardStorageConfiguration],
                              users: [V2UserShardStorageConfiguration]?, resolve: (String) -> (any Database)?) async throws {
        guard let sql = control as? any SQLDatabase else { throw V2UserShardRouterError.invalidRoute }
        struct Binding: Decodable { let logical_id: String; let source_id: UUID }
        let bindings = try await sql.raw("SELECT logical_id, source_id FROM im_v2.deployment_shard_sources").all(decoding: Binding.self)
        // Older single-store fixtures use the unbound schema.
        guard !bindings.isEmpty else { return }
        let locations = rooms.map { ($0.shardID, $0.databaseURL, $0.schema) } +
            (users ?? []).map { ("user:" + $0.bucket, $0.databaseURL, $0.schema) }
        let expected = Dictionary(uniqueKeysWithValues: bindings.map { ($0.logical_id, $0.source_id) })
        let required = expected.keys.filter { users != nil || !$0.hasPrefix("user:") }
        guard Set(required) == Set(locations.map { $0.0 }) else { throw V2UserShardRouterError.invalidRoute }
        for (id, address, schema) in locations {
            v2PreconditionSQLSchema(schema)
            guard let db = resolve(address) as? any SQLDatabase,
                  let row = try await db.raw("SELECT source_id FROM \(unsafeRaw: schema).realtime_journal_source_identity WHERE singleton").first(),
                  try row.decode(column: "source_id", as: UUID.self) == expected[id] else {
                throw V2UserShardRouterError.invalidRoute
            }
        }
    }
}
