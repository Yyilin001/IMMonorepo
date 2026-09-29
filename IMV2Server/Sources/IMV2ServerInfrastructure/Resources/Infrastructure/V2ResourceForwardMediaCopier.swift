import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// Bridges the durable forward inbox to exact objects in the resource catalog.
public struct V2ResourceForwardMediaCopier: V2ForwardMediaObjectCopying {
    private let sources: [String: any Database]
    private let target: PostgresV2ForwardMediaImportStore
    private let registry: V2ResourceStorageRegistry
    private let allocate: @Sendable (V2StorageBinding) throws -> V2StoredObjectReference
    private let maximumBytes: Int64
    private let now: @Sendable () -> Date

    public init(sources: [String: any Database], target: PostgresV2ForwardMediaImportStore,
                registry: V2ResourceStorageRegistry, maximumBytes: Int64,
                allocate: @escaping @Sendable (V2StorageBinding) throws -> V2StoredObjectReference,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !sources.isEmpty, maximumBytes > 0 else { throw V2ResourceProviderError.configurationInvalid }
        self.sources=sources;self.target=target;self.registry=registry;self.maximumBytes=maximumBytes
        self.allocate=allocate;self.now=now
    }

    public func copy(_ lease: V2ForwardMediaImportLease) async throws -> V2ForwardMediaCopyReceipt {
        guard lease.source.byteCount <= maximumBytes else { throw V2ForwardMediaCopyError.sizeLimitExceeded }
        guard lease.targetMediaID.uuidValue != lease.source.mediaID else { throw V2ForwardMediaCopyError.contentConflict }
        try Task.checkCancellation()
        let existing = try await target.resourceCopyOutput(lease, now: now())
        if let existing {
            do {
                let observed = try await registry.storage(for: existing.reference.binding).inspect(existing.reference)
                guard observed == existing else { throw V2ForwardMediaCopyError.contentConflict }
                return try .init(byteCount: existing.byteCount, digest: existing.sha256)
            } catch V2ResourceProviderError.notFound {
                // The intent exists but its I/O has not durably completed yet.
            }
        }
        let source = try await sourceFacts(lease)
        // Placement bytes must match the frozen message attachment, before
        // preparing an output. A known short source is a terminal integrity
        // failure, not a transient destination precondition to retry.
        guard source.byteCount == lease.source.byteCount else { throw V2ForwardMediaCopyError.byteCountMismatch }
        let output = try await target.prepareResourceCopy(lease, source: source, allocate: {
            let reference = try allocate(registry.defaultBinding)
            guard reference.binding == registry.defaultBinding else { throw V2ResourceProviderError.configurationInvalid }
            return reference
        }, now: now())
        let sourceStorage = try registry.storage(for: source.reference.binding)
        guard try await sourceStorage.inspect(source.reference) == source else { throw V2ForwardMediaCopyError.contentConflict }
        let bytes = try await sourceStorage.read(source.reference)
        do {
            let copied = try await registry.storage(for: output.reference.binding).write(output.reference,
                byteCount: output.byteCount, sha256: output.sha256, bytes: bytes)
            guard copied == output else { throw V2ForwardMediaCopyError.contentConflict }
            try Task.checkCancellation()
            return try .init(byteCount: copied.byteCount, digest: copied.sha256)
        } catch V2ResourceProviderError.integrityMismatch { throw V2ForwardMediaCopyError.contentConflict }
    }

    private func sourceFacts(_ lease: V2ForwardMediaImportLease) async throws -> V2StoredObjectFacts {
        guard let database = sources[lease.export.intent.sourceShardID], let sql = database as? any SQLDatabase
        else { throw V2ForwardMediaCopyError.sourceUnavailable }
        // The source export is the durable authorization/hold. Do not reinterpret a
        // committed export using current mutable membership or a user download grant.
        guard try await sql.raw("""
            SELECT 1 FROM im_v2.message_forward_exports e
            WHERE e.export_id=\(bind:lease.export.intent.exportID) AND e.payload_digest=\(bind:lease.export.digest)
              AND NOT EXISTS(SELECT 1 FROM im_v2.message_forward_export_receipts r WHERE r.export_id=e.export_id)
            """).first() != nil else { throw V2ForwardMediaCopyError.sourceUnavailable }
        guard try await sql.raw("SELECT 1 FROM im_v2.resource_catalog WHERE media_id=\(bind:lease.source.mediaID)").first() != nil
        else { throw V2ForwardMediaCopyError.sourceUnavailable }
        guard let row = try await sql.raw("""
            SELECT p.reference_json::text AS reference,p.byte_count,p.sha256
            FROM im_v2.resource_catalog c
            JOIN im_v2.resource_blob_placements p ON p.media_id=c.media_id AND p.generation=c.generation
            JOIN im_v2.media_objects m ON m.media_id=c.media_id
            WHERE c.media_id=\(bind:lease.source.mediaID) AND c.home_kind='room'
              AND c.home_id=\(bind:lease.export.intent.sourceRoomID) AND c.usage_kind='message_attachment'
              AND p.state='active' AND m.state='available' AND m.upload_session_id=\(bind:lease.source.uploadSessionID)
              AND m.content_type=\(bind:lease.source.contentType) AND m.byte_count=\(bind:lease.source.byteCount)
            """).first(decoding:ForwardSourcePlacement.self) else { throw V2ForwardMediaCopyError.sourceUnavailable }
        return try .init(reference:JSONDecoder().decode(V2StoredObjectReference.self,from:Data(row.reference.utf8)),byteCount:row.byteCount,sha256:row.sha256)
    }
}

private struct ForwardSourcePlacement:Decodable {
    let reference:String;let byteCount:Int64;let sha256:Data
    enum CodingKeys:String,CodingKey { case reference,byteCount="byte_count",sha256 }
}
