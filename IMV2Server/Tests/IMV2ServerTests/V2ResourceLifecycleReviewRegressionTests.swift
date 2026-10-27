@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import SQLKit
import Testing

@Suite(.serialized)
struct V2ResourceLifecycleReviewRegressionTests {
    @Test("client dimensions remain declarations until measured facts match",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil), arguments: [true, false])
    func declaredImageDimensions(match: Bool) async throws {
        try await withFixture { f in
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: f.media, usage: .userAvatar,
                contentType: "image/png", byteCount: Int64(f.bytes.count),
                checksum: .init(value: f.digest.map { String(format: "%02x", $0) }.joined()),
                clientImageDimensions: .init(width: match ? 300 : 1, height: match ? 160 : 1))
            let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            let placement = String(decoding: try JSONEncoder().encode(f.old), as: UTF8.self)
            try await f.sql.raw("DELETE FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!)").run()
            try await f.sql.raw("""
                INSERT INTO im_v2.resource_upload_sessions(session_id,media_id,home_kind,home_id,actor_user_id,device_id,operation_id,
                    request_json,state,storage_binding_id,storage_configuration_revision,placement_json,expires_at,created_at,updated_at)
                VALUES(\(bind: UUID()),\(bind: f.media.uuidValue!),'account',\(bind: f.user.uuidValue!),\(bind: f.user.uuidValue!),
                    \(bind: f.device.uuidValue!),\(bind: request.operationID.uuidValue!),\(bind: json)::jsonb,'completed',
                    \(bind: f.old.binding.id),\(bind: f.old.binding.configurationRevision),\(bind: placement)::jsonb,
                    clock_timestamp()+interval '1 hour',clock_timestamp(),clock_timestamp())
                """).run()
            try await f.sql.raw("UPDATE im_v2.media_objects SET state='scanning' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            try await f.sql.raw("INSERT INTO im_v2.media_scan_outbox(media_id,state,created_at) VALUES(\(bind: f.media.uuidValue!),'pending',clock_timestamp())").run()
            let variants = V2ResourceVariantProcessor(database: f.database, registry: f.registry,
                transformer: MeasuredMetadataTransformer(), allocate: { _ in try f.localSource.allocate() })
            let scanner = V2PlacementMediaScanner(database: f.database, registry: f.registry, scanner: AcceptingReviewScanner(), variants: variants)
            let worker = try V2MediaScanWorker(store: PostgresV2MediaScanStore(database: f.database), provider: scanner)
            _ = try await worker.runOnce(limit: 1)
            let actual = try #require(try await f.sql.raw("""
                SELECT m.state,c.pixel_width AS width,c.pixel_height AS height
                FROM im_v2.media_objects m JOIN im_v2.resource_catalog c USING(media_id) WHERE m.media_id=\(bind: f.media.uuidValue!)
                """).first(decoding: MeasuredMetadataState.self))
            #expect(actual.state == (match ? "available" : "failed"))
            #expect(actual.width == (match ? 300 : nil) && actual.height == (match ? 160 : nil))
        }
    }
    @Test("image admission matches processing policy and permanent decoding failures terminate scanning",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["invalid-image", "too-large", "transient"])
    func imagePolicy(mode: String) async throws {
        try await withFixture { f in
            let imports = try await f.imports()
            let limit = V2LocalResourceTransformer.maximumInputBytes
            let service = try V2ResourceService(resolve: imports.resolve, registry: f.registry,
                transports: Array(imports.transports.values), maximumBytes: limit * 2,
                maximumImageBytes: limit, allocate: { _ in try f.target.allocate() })
            let capability = try service.capabilities()
            #expect(capability.maximumImageBytes == min(capability.maximumBytes, limit))
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
                usage: .messageAttachment(f.room), contentType: "image/png", byteCount: limit + 1,
                checksum: .init(value: String(repeating: "a", count: 64)))
            await #expect(throws: V2ResourceProviderError.unsupportedCapability) {
                _ = try await service.create(request, actor: f.user, device: f.device)
            }
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_upload_sessions WHERE media_id=\(bind: request.mediaID.uuidValue!)").first() == nil)

            try await f.sql.raw("UPDATE im_v2.media_objects SET state='scanning' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            try await f.sql.raw("INSERT INTO im_v2.media_scan_outbox(media_id,state,created_at) VALUES(\(bind: f.media.uuidValue!),'pending',TIMESTAMPTZ '1900-01-01')").run()
            if mode == "too-large" {
                // A legacy upload accepted before the new admission policy still needs terminal closure.
                try await f.sql.raw("UPDATE im_v2.resource_blob_placements SET byte_count=\(bind: limit + 1) WHERE media_id=\(bind: f.media.uuidValue!)").run()
            }
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let local = try V2LocalResourceTransformer(executable: package.appendingPathComponent(".build/debug/IMV2ResourceImageWorker"),
                temporaryDirectory: f.root.appendingPathComponent("processing"))
            let transformer: any V2ResourceTransformer = mode == "transient" ? UnavailableImageTransformer() : local
            let variants = V2ResourceVariantProcessor(database: f.database, registry: f.registry,
                transformer: transformer, allocate: { _ in try f.localSource.allocate() })
            let scanner = V2PlacementMediaScanner(database: f.database, registry: f.registry,
                scanner: AcceptingReviewScanner(), variants: variants)
            let worker = try V2MediaScanWorker(store: PostgresV2MediaScanStore(database: f.database), provider: scanner)
            let report = try await worker.runOnce(limit: 1)
            let row = try #require(try await f.sql.raw("""
                SELECT media.state AS media, outbox.state AS job
                FROM im_v2.media_objects media JOIN im_v2.media_scan_outbox outbox USING(media_id)
                WHERE media_id=\(bind: f.media.uuidValue!)
                """).first(decoding: ReviewScanState.self))
            if mode == "transient" {
                #expect(report.releasedCount == 1 && row.media == "scanning" && row.job == "pending")
            } else {
                #expect(report.completedCount == 1 && row.media == "failed" && row.job == "completed")
            }
        }
    }

    @Test("terminal scans close before provider I/O and after a concurrent purge",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func terminalScanClosure() async throws {
        try await withFixture { f in
            let now = Date()
            let scans = PostgresV2MediaScanStore(database: f.database)
            try await f.sql.raw("INSERT INTO im_v2.media_scan_outbox(media_id,state,next_attempt_at,created_at) VALUES(\(bind: f.media.uuidValue!),'pending',\(bind: now.addingTimeInterval(600)),TIMESTAMPTZ '1900-01-01')").run()
            // Available media is terminal for this scan, even when its retry delay has not elapsed.
            let leases = try await scans.claimPending(now: now, leaseDuration: 30, limit: 1)
            #expect(!leases.contains { $0.mediaID == f.media })
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.media_scan_outbox WHERE media_id=\(bind: f.media.uuidValue!) AND state='completed'").first() != nil)
            try await f.sql.raw("DELETE FROM im_v2.media_scan_outbox WHERE media_id=\(bind: f.media.uuidValue!)").run()
            try await f.sql.raw("UPDATE im_v2.media_objects SET state='scanning' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            try await f.sql.raw("INSERT INTO im_v2.media_scan_outbox(media_id,state,created_at) VALUES(\(bind: f.media.uuidValue!),'pending',TIMESTAMPTZ '1900-01-01')").run()
            let worker = try V2MediaScanWorker(store: scans, provider: PurgingReviewScanner(sql: f.sql), now: { now })
            _ = try await worker.runOnce(limit: 1)
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.media_scan_outbox WHERE media_id=\(bind: f.media.uuidValue!) AND state='completed' AND next_attempt_at IS NULL AND claim_token IS NULL").first() != nil)
        }
    }

    private func withFixture(_ body: (ResourcePlacementTestFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resource-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let fixture = try await ResourcePlacementTestFixture(database: resources.database(.psql), root: root)
            try await body(fixture)
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

private struct ReviewScanState: Decodable { let media: String; let job: String }
private struct MeasuredMetadataState: Decodable { let state: String; let width: Int?; let height: Int? }
/// SQL/publication test boundary; decoder behavior is tested with the real worker separately.
private struct MeasuredMetadataTransformer: V2ResourceTransformer {
    func transform(input: V2StoredObjectFacts, recipe: V2ResourceRecipe, outputs: [Int: V2StoredObjectReference], registry: V2ResourceStorageRegistry) async throws -> [V2ResourceTransformOutput] {
        var result: [V2ResourceTransformOutput] = []
        for (size, reference) in outputs {
            let facts = try await registry.storage(for: reference.binding).write(reference, byteCount: input.byteCount,
                sha256: input.sha256, bytes: registry.storage(for: input.reference.binding).read(input.reference))
            result.append(try .init(size: size, facts: facts, sourceDimensions: .init(width: 300, height: 160)))
        }
        return result
    }
}
private struct AcceptingReviewScanner: V2ResourceScanner {
    func scan(_ input: V2StoredObjectFacts, storage: any V2ObjectStorage) async throws -> V2ResourceScanReceipt {
        try .init(input: input, policyVersion: "review-policy", engineVersion: "review-engine", result: .passed)
    }
}
private struct UnavailableImageTransformer: V2ResourceTransformer {
    func transform(input: V2StoredObjectFacts, recipe: V2ResourceRecipe, outputs: [Int: V2StoredObjectReference],
                   registry: V2ResourceStorageRegistry) async throws -> [V2ResourceTransformOutput] {
        throw V2ResourceProviderError.temporarilyUnavailable
    }
}
private struct PurgingReviewScanner: V2MediaScanProvider {
    let sql: any SQLDatabase
    func scan(mediaID: MediaID) async throws -> V2MediaScanResult {
        try await sql.raw("UPDATE im_v2.media_objects SET state='expired' WHERE media_id=\(bind: mediaID.uuidValue!)").run()
        try await sql.raw("DELETE FROM im_v2.resource_blob_placements WHERE media_id=\(bind: mediaID.uuidValue!)").run()
        throw V2ResourceProviderError.notFound
    }
}
