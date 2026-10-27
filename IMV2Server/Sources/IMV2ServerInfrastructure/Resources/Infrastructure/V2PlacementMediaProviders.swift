import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Scans and purges the exact objects registered in the resource catalog.
public struct V2PlacementMediaScanner: V2MediaScanProvider {
    let database: any Database
    let registry: V2ResourceStorageRegistry
    let scanner: any V2ResourceScanner
    let variants: V2ResourceVariantProcessor?
    let mediaProbe: (any V2ResourceMediaProbing)?
    public init(database: any Database, registry: V2ResourceStorageRegistry, scanner: any V2ResourceScanner, variants: V2ResourceVariantProcessor? = nil, mediaProbe: (any V2ResourceMediaProbing)? = nil) {
        self.database = database; self.registry = registry; self.scanner = scanner; self.variants = variants; self.mediaProbe = mediaProbe
    }
    public func scan(mediaID: MediaID) async throws -> V2MediaScanResult {
        guard let sql = database as? any SQLDatabase, let id = UUID(uuidString: mediaID.rawValue) else { throw V2ResourceProviderError.configurationInvalid }
        if let row = try await sql.raw("""
            SELECT p.reference_json::text AS reference,p.byte_count,p.sha256,c.generation,m.content_type
            FROM im_v2.resource_blob_placements p JOIN im_v2.resource_catalog c ON c.media_id=p.media_id AND c.generation=p.generation
            JOIN im_v2.media_objects m ON m.media_id=c.media_id
            WHERE p.media_id=\(bind:id) AND p.state='active'
            """).first(decoding: PlacementRow.self) {
            let facts = try row.facts()
            let receipt = try await scanner.scan(facts, storage: registry.storage(for: facts.reference.binding))
            guard receipt.input == facts else { throw V2ResourceProviderError.integrityMismatch }
            if receipt.result == .passed, row.contentType.hasPrefix("audio/") || row.contentType.hasPrefix("video/") {
                guard let mediaProbe else { throw V2ResourceProviderError.configurationInvalid }
                do {
                    let metadata = try await mediaProbe.probe(facts, contentType: row.contentType, storage: registry.storage(for: facts.reference.binding))
                    guard metadata.kind == (row.contentType.hasPrefix("video/") ? .video : .audio) else { throw V2ResourceProviderError.integrityMismatch }
                    try await database.transaction { transaction in
                        guard let owner = transaction as? any SQLDatabase,
                              try await owner.raw("""
                                SELECT 1 FROM im_v2.media_objects m
                                JOIN im_v2.resource_catalog c ON c.media_id=m.media_id
                                JOIN im_v2.resource_blob_placements p ON p.media_id=c.media_id AND p.generation=c.generation AND p.state='active'
                                WHERE m.media_id=\(bind: id) AND m.state='scanning' AND c.generation=\(bind: row.generation)
                                    AND p.byte_count=\(bind: facts.byteCount) AND p.sha256=\(bind: facts.sha256)
                                FOR UPDATE OF m,c
                                """).first() != nil else { throw V2ResourceProviderError.preconditionFailed }
                        try await owner.raw("""
                            UPDATE im_v2.resource_catalog SET duration_ms=\(bind: metadata.durationMilliseconds),
                                pixel_width=\(bind: metadata.dimensions?.width),pixel_height=\(bind: metadata.dimensions?.height)
                            WHERE media_id=\(bind: id) AND generation=\(bind: row.generation)
                            """).run()
                    }
                } catch V2ResourceTransformError.contentRejected { return .failed }
            }
            if receipt.result == .passed, let variants {
                do { try await variants.prepare(mediaID: id,input: facts) }
                catch V2ResourceTransformError.contentRejected { return .failed }
            }
            return receipt.result
        }
        throw V2ResourceProviderError.notFound
    }
}
public struct V2PlacementMediaPurger: V2MediaPurgeProvider {
    let database: any Database
    let registry: V2ResourceStorageRegistry
    let uploads: any V2MediaPurgeProvider
    public init(database: any Database, registry: V2ResourceStorageRegistry, uploads: any V2MediaPurgeProvider) {
        self.database = database; self.registry = registry; self.uploads = uploads
    }
    public func purge(mediaID: MediaID) async throws {
        guard let sql = database as? any SQLDatabase, let id = UUID(uuidString: mediaID.rawValue) else { throw V2ResourceProviderError.configurationInvalid }
        // Fence new migration admission before collecting object identities. The
        // normal GC path already expires media; direct rejected-copy cleanup also
        // needs the same durable closure, not just a transient row lock.
        try await database.transaction { transaction in
            guard let owner = transaction as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
            _ = try await owner.raw("SELECT 1 FROM im_v2.media_objects WHERE media_id=\(bind: id) FOR UPDATE").first()
            guard try await owner.raw("SELECT 1 FROM im_v2.resource_storage_migrations WHERE media_id=\(bind: id) AND source_released_at IS NULL").first() == nil
            else { throw V2ResourceProviderError.preconditionFailed }
            try await owner.raw("""
                UPDATE im_v2.media_objects m SET state='expired',state_updated_at=clock_timestamp()
                WHERE media_id=\(bind: id) AND state<>'expired'
                  AND EXISTS(SELECT 1 FROM im_v2.resource_catalog c WHERE c.media_id=m.media_id)
                """).run()
        }
        // Include unpublished destinations so cancel/crash cleanup also fences late writes.
        let rows = try await sql.raw("""
            SELECT placement_json::text AS reference FROM im_v2.resource_upload_sessions WHERE media_id=\(bind: id)
            UNION SELECT reference_json::text AS reference FROM im_v2.resource_blob_placements WHERE media_id=\(bind: id) AND state<>'deleted'
            UNION SELECT reference_json::text AS reference FROM im_v2.resource_variants WHERE media_id=\(bind: id) AND state<>'deleted'
            UNION SELECT reference_json::text AS reference FROM im_v2.resource_forward_outputs WHERE target_media_id=\(bind:id)
            """).all(decoding: PlacementReferenceRow.self)
        for row in rows {
            let reference = try JSONDecoder().decode(V2StoredObjectReference.self, from: Data(row.reference.utf8))
            try await registry.storage(for: reference.binding).delete(reference)
        }
        try await uploads.purge(mediaID: mediaID)
        try await sql.raw("UPDATE im_v2.resource_blob_placements SET state='deleted' WHERE media_id=\(bind: id)").run()
        try await sql.raw("UPDATE im_v2.resource_variants SET state='deleted' WHERE media_id=\(bind: id)").run()
    }
}
private struct PlacementReferenceRow: Decodable { let reference: String }
private struct PlacementRow: Decodable {
    let reference: String; let byteCount: Int64; let sha256: Data; let generation: Int64; let contentType: String
    enum CodingKeys: String, CodingKey { case reference,byteCount="byte_count",sha256,generation,contentType="content_type" }
    func facts() throws -> V2StoredObjectFacts {
        try .init(reference: JSONDecoder().decode(V2StoredObjectReference.self, from: Data(reference.utf8)), byteCount: byteCount, sha256: sha256)
    }
}
