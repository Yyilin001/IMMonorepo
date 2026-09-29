import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Resolves already-authorized downloads through the unified resource catalog.
public struct V2BoundMediaProvider: V2MediaObjectProvider, V2MediaPurgeProvider {
    private let database: any Database
    private let registry: V2ResourceStorageRegistry
    private let now: @Sendable () -> Date
    private let delivery: any V2ResourceDelivery
    private let transports: [V2StorageBinding: any V2UploadTransport]

    public init(database: any Database, registry: V2ResourceStorageRegistry,
                delivery: any V2ResourceDelivery, transports: [any V2UploadTransport], now: @escaping @Sendable () -> Date = Date.init) throws {
        var indexed: [V2StorageBinding: any V2UploadTransport] = [:]
        for transport in transports {
            guard indexed.updateValue(transport, forKey: transport.binding) == nil
            else { throw V2ResourceProviderError.configurationInvalid }
        }
        self.database = database; self.registry = registry; self.delivery = delivery
        self.transports = indexed; self.now = now
    }

    public func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2ResourceTransferPlan {
        let sql = try sqlDatabase()
        guard let id = mediaID.uuidValue else { throw V2ResourceProviderError.configurationInvalid }
        guard let row = try await sql.raw("""
            SELECT p.reference_json::text AS reference,p.byte_count,p.sha256
            FROM im_v2.resource_blob_placements p
            JOIN im_v2.resource_catalog resource ON resource.media_id=p.media_id AND resource.generation=p.generation
            JOIN im_v2.media_objects m ON m.media_id=p.media_id
            WHERE p.media_id=\(bind: id) AND p.state='active' AND m.state='available'
            """).first(decoding: BoundPlacementRow.self)
        else { throw V2ResourceProviderError.notFound }
        let reference = try JSONDecoder().decode(V2StoredObjectReference.self, from: Data(row.reference.utf8))
        _ = try registry.storage(for: reference.binding)
        let facts = try V2StoredObjectFacts(reference: reference, byteCount: row.byteCount, sha256: row.sha256)
        let deadline = min(expiresAt, now().addingTimeInterval(120))
        let plan = try await delivery.issue(.init(facts: facts, expiresAt: deadline))
        try plan.validateDownload(facts: facts, expiresAt: deadline, now: now())
        return plan
    }

    /// Exact immutable placements are deleted by V2PlacementMediaPurger first.
    /// This operation removes/fences the upload transport's original staging bytes.
    public func purge(mediaID: MediaID) async throws {
        guard let binding = try await binding(mediaID) else { return }
        guard let transport = transports[binding] else { throw V2ResourceProviderError.configurationInvalid }
        if let multipart = transport as? any V2MultipartUploadTransport, let id = mediaID.uuidValue,
           let row = try await sqlDatabase().raw("SELECT request_json::text AS request FROM im_v2.resource_upload_sessions WHERE media_id=\(bind: id)").first(decoding: MultipartPurgeRequest.self) {
            let request = try JSONDecoder().decode(V2ResourceUploadRequest.self, from: Data(row.request.utf8))
            if request.clientModes.contains(.httpPartPut) {
                try await multipart.abortParts(mediaID: mediaID, byteCount: request.byteCount, checksum: request.checksum)
            }
        }
        try await transport.abort(mediaID: mediaID)
    }

    public func verifyReferencedBindings() async throws {
        let sql = try sqlDatabase()
        let sessions = try await sql.raw("SELECT DISTINCT storage_binding_id,storage_configuration_revision FROM im_v2.resource_upload_sessions")
            .all(decoding: ResourceBindingRow.self)
        for row in sessions {
            let binding = try row.binding
            _ = try registry.storage(for: binding)
            guard transports[binding] != nil else { throw V2ResourceProviderError.configurationInvalid }
        }
        try await V2ResourceStorageReadiness.verify(database: database, registry: registry)
    }

    private func sqlDatabase() throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2ResourceProviderError.configurationInvalid }
        return sql
    }
    private func binding(_ mediaID: MediaID) async throws -> V2StorageBinding? {
        guard let id = mediaID.uuidValue else { throw V2ResourceProviderError.configurationInvalid }
        return try await sqlDatabase().raw("SELECT storage_binding_id,storage_configuration_revision FROM im_v2.resource_upload_sessions WHERE media_id=\(bind: id)")
            .first(decoding: ResourceBindingRow.self)?.binding
    }
}
private struct ResourceBindingRow: Decodable {
    let id: String; let revision: Int
    var binding: V2StorageBinding { get throws { try .init(id: id, configurationRevision: revision) } }
    enum CodingKeys: String, CodingKey { case id="storage_binding_id",revision="storage_configuration_revision" }
}
private struct BoundPlacementRow: Decodable {
    let reference: String; let byteCount: Int64; let sha256: Data
    enum CodingKeys: String, CodingKey { case reference,byteCount="byte_count",sha256 }
}

private struct MultipartPurgeRequest: Decodable { let request: String }
