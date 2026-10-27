import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure

@Suite("Timed media scan publication", .serialized)
struct V2ResourceMediaProbePostgresTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["ready", "invalid", "expired", "generation"])
    func metadataPublishesOnlyForTheCurrentScanningBytes(mode: String) async throws {
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let f = try await ResourcePlacementTestFixture(database: resources.database(.psql), root: root,
                bytes: mode == "invalid" ? Data("not an audio container".utf8) : V2ResourceMediaProbeTests.wave())
            try await f.sql.raw("UPDATE im_v2.media_objects SET content_type='audio/wav',state='scanning' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            try await f.sql.raw("UPDATE im_v2.resource_catalog SET home_kind='room',home_id=\(bind: f.room.uuidValue!),usage_kind='message_attachment' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            try await f.sql.raw("DELETE FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!)").run()
            let probe = try V2LocalResourceMediaProbe(temporaryDirectory: root.appendingPathComponent("probe"), maximumBytes: 100_000)
            let scanner = V2PlacementMediaScanner(database: f.database, registry: f.registry, scanner: V2LocalResourceScanner(),
                mediaProbe: MutatingTimedMediaProbe(base: probe, sql: f.sql, media: f.media, mode: mode))
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_catalog WHERE media_id=\(bind: f.media.uuidValue!) AND duration_ms IS NOT NULL").first() == nil)
            if mode == "expired" || mode == "generation" {
                await #expect(throws: V2ResourceProviderError.preconditionFailed) { try await scanner.scan(mediaID: f.media) }
            } else {
                try await f.sql.raw("INSERT INTO im_v2.media_scan_outbox(media_id,state,created_at) VALUES(\(bind: f.media.uuidValue!),'pending',TIMESTAMPTZ '1900-01-01')").run()
                let worker = try V2MediaScanWorker(store: PostgresV2MediaScanStore(database: f.database), provider: scanner, leaseDuration: 300)
                #expect(try await worker.runOnce(limit: 1).completedCount == 1)
            }
            let row = try #require(try await f.sql.raw("""
                SELECT m.state,c.duration_ms,c.pixel_width,c.pixel_height FROM im_v2.media_objects m
                JOIN im_v2.resource_catalog c USING(media_id) WHERE media_id=\(bind: f.media.uuidValue!)
                """).first(decoding: TimedMediaScanRow.self))
            if mode == "ready" { #expect(row.state == "available" && row.duration_ms == 2000) }
            else {
                #expect(row.duration_ms == nil)
                #expect(row.state == (mode == "invalid" ? "failed" : mode == "expired" ? "expired" : "scanning"))
            }
            #expect(row.pixel_width == nil && row.pixel_height == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("probe").path).isEmpty)
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

private struct TimedMediaScanRow: Decodable {
    let state: String; let duration_ms: Int64?; let pixel_width: Int?; let pixel_height: Int?
}
private struct MutatingTimedMediaProbe: V2ResourceMediaProbing {
    let base: V2LocalResourceMediaProbe; let sql: any SQLDatabase; let media: MediaID; let mode: String
    func probe(_ input: V2StoredObjectFacts, contentType: String, storage: any V2ObjectStorage) async throws -> V2ResourceTimedMediaMetadata {
        let metadata = try await base.probe(input, contentType: contentType, storage: storage)
        if mode == "expired" {
            try await sql.raw("UPDATE im_v2.media_objects SET state='expired' WHERE media_id=\(bind: media.uuidValue!)").run()
        } else if mode == "generation" {
            try await sql.raw("UPDATE im_v2.resource_catalog SET generation=generation+1 WHERE media_id=\(bind: media.uuidValue!)").run()
        }
        return metadata
    }
}
