import FluentKit
import Foundation
import IMV2Core
import SQLKit

public struct V2ResourceVariantProcessor: Sendable {
    let database:any Database
    let registry:V2ResourceStorageRegistry
    let transformer:any V2ResourceTransformer
    let allocate:@Sendable (V2StorageBinding) throws -> V2StoredObjectReference
    public init(database:any Database,registry:V2ResourceStorageRegistry,transformer:any V2ResourceTransformer,
                allocate:@escaping @Sendable (V2StorageBinding) throws -> V2StoredObjectReference) {
        self.database=database;self.registry=registry;self.transformer=transformer;self.allocate=allocate
    }
    public func prepare(mediaID:UUID,input:V2StoredObjectFacts) async throws {
        guard let sql=database as? any SQLDatabase,
              let session=try await sql.raw("""
                SELECT resource.generation,resource.usage_kind,media.content_type
                FROM im_v2.resource_catalog resource JOIN im_v2.media_objects media USING(media_id)
                WHERE resource.media_id=\(bind:mediaID) AND media.state='scanning'
                """).first(decoding:VariantResourceRow.self)
        else { throw V2ResourceProviderError.preconditionFailed }
        let recipe:V2ResourceRecipe
        switch session.usageKind {
        case "user_avatar","group_avatar": recipe = .avatar
        case "message_attachment":
            guard session.contentType.hasPrefix("image/") else { return }
            recipe = .preview
        default: throw V2ResourceProviderError.configurationInvalid
        }
        let sizes=recipe == .avatar ? [128,256] : [320,1280]
        // Resource mutex prevents an intent appearing after GC has collected its output set.
        let rows = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  try await sql.raw("SELECT 1 FROM im_v2.media_objects WHERE media_id=\(bind: mediaID) AND state='scanning' FOR UPDATE").first() != nil
            else { throw V2ResourceProviderError.preconditionFailed }
            for size in sizes {
                let reference=try allocate(input.reference.binding)
                let json=String(decoding:try JSONEncoder().encode(reference),as:UTF8.self)
                try await sql.raw("""
                    INSERT INTO im_v2.resource_variants(variant_id,media_id,generation,recipe,size,reference_json,created_at)
                    VALUES(\(bind: UUID()),\(bind: mediaID),\(bind: session.generation),\(bind: recipe.rawValue),\(bind: size),\(bind: json)::jsonb,clock_timestamp())
                    ON CONFLICT(media_id,generation,recipe,recipe_version,size) DO NOTHING
                    """).run()
            }
            return try await sql.raw("SELECT size,reference_json::text AS reference,state FROM im_v2.resource_variants WHERE media_id=\(bind: mediaID) AND generation=\(bind: session.generation) AND recipe=\(bind: recipe.rawValue) AND recipe_version=1").all(decoding:VariantOutputRow.self)
        }
        guard rows.count==sizes.count else { throw V2ResourceProviderError.configurationInvalid }
        if rows.allSatisfy({$0.state=="ready"}) { return }
        let outputs=try Dictionary(uniqueKeysWithValues:rows.map { ($0.size,try JSONDecoder().decode(V2StoredObjectReference.self,from:Data($0.reference.utf8))) })
        let receipts=try await transformer.transform(input:input,recipe:recipe,outputs:outputs,registry:registry)
        guard Set(receipts.map(\.size))==Set(sizes), receipts.count==sizes.count else { throw V2ResourceProviderError.integrityMismatch }
        try await database.transaction { transaction in
            guard let sql=transaction as? any SQLDatabase,
                  try await sql.raw("SELECT 1 FROM im_v2.media_objects WHERE media_id=\(bind: mediaID) AND state='scanning' FOR UPDATE").first() != nil
            else { throw V2ResourceProviderError.preconditionFailed }
            guard try await sql.raw("SELECT 1 FROM im_v2.resource_catalog WHERE media_id=\(bind: mediaID) AND generation=\(bind: session.generation)").first() != nil else { throw V2ResourceProviderError.preconditionFailed }
            for receipt in receipts {
                guard receipt.facts.reference==outputs[receipt.size] else { throw V2ResourceProviderError.integrityMismatch }
                try await sql.raw("UPDATE im_v2.resource_variants SET state='ready',byte_count=\(bind: receipt.facts.byteCount),sha256=\(bind: receipt.facts.sha256) WHERE media_id=\(bind: mediaID) AND generation=\(bind: session.generation) AND recipe=\(bind: recipe.rawValue) AND size=\(bind: receipt.size)").run()
            }
        }
    }
}
private struct VariantResourceRow:Decodable {
    let generation:Int64;let usageKind:String;let contentType:String
    enum CodingKeys:String,CodingKey { case generation,usageKind="usage_kind",contentType="content_type" }
}
private struct VariantOutputRow:Decodable { let size:Int;let reference:String;let state:String }
