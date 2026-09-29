import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import SQLKit

/// Every owner must retain adapters for persisted bindings, including unpublished
/// copy intents. Changing the default never changes an existing object's backend.
public enum V2ResourceStorageReadiness {
    public static func verify(database: any Database, registry: V2ResourceStorageRegistry) async throws {
        try registry.verifyReferencedBindings(try await referencedBindings(database: database))
    }

    static func referencedBindings(database: any Database) async throws -> Set<V2StorageBinding> {
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        let rows = try await sql.raw("""
            SELECT storage_binding_id AS id, storage_configuration_revision AS revision
            FROM im_v2.resource_upload_sessions
            UNION
            SELECT reference_json->'binding'->>'id',
                (reference_json->'binding'->>'configurationRevision')::integer
            FROM im_v2.resource_blob_placements WHERE state<>'deleted'
            UNION
            SELECT reference_json->'binding'->>'id',
                (reference_json->'binding'->>'configurationRevision')::integer
            FROM im_v2.resource_variants WHERE state<>'deleted'
            UNION
            SELECT reference_json->'binding'->>'id',
                (reference_json->'binding'->>'configurationRevision')::integer
            FROM im_v2.resource_forward_outputs
            UNION
            SELECT reference_json->'binding'->>'id',
                (reference_json->'binding'->>'configurationRevision')::integer
            FROM im_v2.resource_import_holds WHERE released_at IS NULL
            UNION
            SELECT reference->'binding'->>'id', (reference->'binding'->>'configurationRevision')::integer
            FROM im_v2.resource_storage_migrations migration
            CROSS JOIN LATERAL (VALUES(migration.source_json),(migration.destination_json)) refs(reference)
            WHERE migration.source_released_at IS NULL
            """).all(decoding: Binding.self)
        return try Set(rows.map { try .init(id: $0.id, configurationRevision: $0.revision) })
    }

    private struct Binding: Decodable { let id: String; let revision: Int }
}
