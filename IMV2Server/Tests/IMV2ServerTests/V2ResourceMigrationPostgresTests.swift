import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
struct V2ResourceMigrationPostgresTests {
    @Test("migration copies exact bytes and switches only location, retaining both adapters", arguments: [false, true])
    func copySwitchAndReplay(variant: Bool) async throws {
        try await withFixture { f in
            let destination = MigrationDestination(storage: f.target)
            let store = PostgresV2ResourceMigrationStore(database: f.database, authorize: { _,_ in })
            let service = try service(f, store: store, destination: destination)
            let request = try request(f, variant: variant)
            let delivery = try V2LocalResourceDelivery(registry: f.registry, baseURL: #require(URL(string: "https://migration.test")),
                keyID: "test", keys: ["test": Data(repeating: 7, count: 32)])
            let avatars = V2ResourceAvatarDelivery(delivery: delivery)
            let before = variant ? try await avatars.authorizedAvatar(mediaID: f.media, database: f.database, expiresAt: Date().addingTimeInterval(60)) : nil
            let prepared = try await service.prepare(request)
            #expect(prepared.source.reference == f.old && prepared.destination.reference.binding == f.target.binding)
            #expect(prepared.destination.reference != f.replacement && prepared.state == .pending)
            let repeated = try await service.prepare(request)
            #expect(repeated.destination == prepared.destination)
            #expect(await destination.writes == 0)
            await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) {
                _ = try await service.prepare(self.request(f, variant: variant))
            }
            let changed = try V2ResourceMigrationRequest(operationID: request.operationID, mediaID: f.media.uuidValue!, generation: 2, targetBinding: f.target.binding)
            await #expect(throws: V2MediaStoreError.idempotencyConflict) { _ = try await service.prepare(changed) }
            let switched = try await service.resume(request.operationID)
            #expect(switched.state == .switched && switched.destination == prepared.destination)
            #expect(try await f.localSource.inspect(f.old).sha256 == switched.destination.sha256)
            #expect(try await f.target.inspect(switched.destination.reference) == switched.destination)
            #expect(try await current(f, variant: variant) == switched.destination.reference)
            if let before {
                let after = try await avatars.authorizedAvatar(mediaID: f.media, database: f.database, expiresAt: Date().addingTimeInterval(60))
                #expect(before.variantID == after.variantID && before.checksum == after.checksum)
                for (access, reference) in [(before, f.old), (after, switched.destination.reference)] {
                    let token = try #require(URLComponents(url: access.plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cap" })?.value)
                    #expect(try await delivery.bytes(placementID: reference.placementID, capability: token) == f.bytes)
                }
            }
            let again = try await service.resume(request.operationID)
            #expect(again.state == .switched)
            #expect(await destination.writes == 1)
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!) AND variant_id=\(bind: f.variant.uuidValue!)").first() != nil)
            if variant { try await f.sql.raw("DELETE FROM im_v2.resource_blob_placements WHERE media_id=\(bind: f.media.uuidValue!)").run() }
            else { try await f.sql.raw("DELETE FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!)").run() }
            #expect(try await V2ResourceStorageReadiness.referencedBindings(database: f.database).contains(f.localSource.binding))
            try await assertRetained(f)
        }
    }

    @Test("unknown write outcome is inspected under the original identity without reading the source again")
    func lostWriteResponse() async throws {
        try await withFixture { f in
            let destination = MigrationDestination(storage: f.target, mode: .loseResponse)
            let store = PostgresV2ResourceMigrationStore(database: f.database, authorize: { _,_ in })
            let service = try service(f, store: store, destination: destination)
            let prepared = try await service.prepare(request(f))
            await #expect(throws: V2ResourceProviderError.operationOutcomeUnknown) { _ = try await service.resume(prepared.request.operationID) }
            #expect(try await current(f, variant: false) == f.old)
            try await assertRetained(f)
            await f.source.failNextRead()
            try await due(prepared.request.operationID, f: f)
            let recovered = try await service.recover(limit: 100)
            #expect(recovered.switched.contains(prepared.request.operationID))
            #expect(try await store.status(prepared.request.operationID).destination == prepared.destination)
            #expect(await destination.writes == 1)
            #expect(await f.source.reads == [f.old])
        }
    }

    @Test("stale copy completion cannot switch after a successor claim has published")
    func lateCopy() async throws {
        try await withFixture { f in
            let destination = MigrationDestination(storage: f.target, mode: .pause)
            let store = PostgresV2ResourceMigrationStore(database: f.database, authorize: { _,_ in })
            let service = try service(f, store: store, destination: destination)
            let prepared = try await service.prepare(request(f, variant: true))
            let old = Task { try await service.resume(prepared.request.operationID) }
            do {
                try await destination.waitUntilPaused()
                try await assertRetained(f)
                await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) { _ = try await service.resume(prepared.request.operationID) }
                try await f.sql.raw("UPDATE im_v2.resource_storage_migrations SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE operation_id=\(bind: prepared.request.operationID)").run()
                let replacement = try await service.resume(prepared.request.operationID)
                #expect(replacement.state == .switched)
                await destination.release()
                await #expect(throws: V2ResourceProviderError.preconditionFailed) { _ = try await old.value }
                #expect(try await store.status(prepared.request.operationID).state == .switched)
                #expect(try await current(f, variant: true) == prepared.destination.reference)
                #expect(await destination.writes == 2)
                try await assertRetained(f)
            } catch { await destination.release(); _ = await old.result; throw error }
        }
    }

    @Test("receipt, generation and maintenance authorization failures cannot publish", arguments: ["receipt", "generation", "authorization"])
    func publicationFences(_ scenario: String) async throws {
        try await withFixture { f in
            let permission = MigrationPermission()
            let store = PostgresV2ResourceMigrationStore(database: f.database, authorize: { _,_ in try await permission.check() })
            let destination = MigrationDestination(storage: f.target, mode: scenario == "receipt" ? .wrongReceipt : .pause)
            let service = try service(f, store: store, destination: destination)
            let prepared = try await service.prepare(request(f))
            let copy = Task { try await service.resume(prepared.request.operationID) }
            do {
                if scenario != "receipt" {
                    try await destination.waitUntilPaused()
                    if scenario == "generation" { try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind: f.media.uuidValue!)").run() }
                    else { await permission.deny() }
                    await destination.release()
                }
                await #expect(throws: scenario == "receipt" ? V2ResourceProviderError.integrityMismatch : .preconditionFailed) { _ = try await copy.value }
                #expect(try await current(f, variant: false) == f.old)
                #expect(try await f.target.inspect(prepared.destination.reference) == prepared.destination)
                #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_storage_migrations WHERE operation_id=\(bind: prepared.request.operationID) AND state='pending' AND source_released_at IS NULL").first() != nil)
                try await assertRetained(f)
            } catch { await destination.release(); _ = await copy.result; throw error }
        }
    }

    @Test("purge closes admission before deleting objects; rejected requests allocate nothing")
    func admissionAndPurge() async throws {
        try await withFixture { f in
            let store = PostgresV2ResourceMigrationStore(database: f.database, authorize: { _,_ in })
            let service = try service(f, store: store, destination: MigrationDestination(storage: f.target))
            let missingVariant = try V2ResourceMigrationRequest(operationID: UUID(), mediaID: f.media.uuidValue!, generation: 1, variantID: UUID(), targetBinding: f.target.binding)
            await #expect(throws: V2ResourceProviderError.notFound) { _ = try await service.prepare(missingVariant) }
            let denied = PostgresV2ResourceMigrationStore(database: f.database, authorize: { _,_ in throw V2ResourceProviderError.preconditionFailed })
            await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                _ = try await self.service(f, store: denied, destination: MigrationDestination(storage: f.target)).prepare(self.request(f))
            }
            let wrong = try V2ResourceMigrationService(store: store, registry: f.registry, maximumBytes: 1024, allocate: { _ in f.old })
            await #expect(throws: V2ResourceProviderError.configurationInvalid) { _ = try await wrong.prepare(self.request(f)) }
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_storage_migrations WHERE media_id=\(bind: f.media.uuidValue!)").first() == nil)
            try await V2PlacementMediaPurger(database: f.database, registry: f.registry, uploads: MigrationNoStagingPurge()).purge(mediaID: f.media)
            await #expect(throws: V2ResourceProviderError.preconditionFailed) { _ = try await service.prepare(self.request(f)) }
            await #expect(throws: V2ResourceProviderError.notFound) { _ = try await f.localSource.inspect(f.old) }
        }
    }

    private func assertRetained(_ f: ResourcePlacementTestFixture) async throws {
        _ = try await PostgresV2MediaRetentionStore(database: f.database).expireEligibleMedia(now: Date().addingTimeInterval(7200), withdrawnRetention: 60, limit: 1000)
        #expect(try await f.sql.raw("SELECT 1 FROM im_v2.media_objects WHERE media_id=\(bind: f.media.uuidValue!) AND state='available'").first() != nil)
        await #expect(throws: V2ResourceProviderError.preconditionFailed) {
            try await V2PlacementMediaPurger(database: f.database, registry: f.registry, uploads: MigrationNoStagingPurge()).purge(mediaID: f.media)
        }
        #expect(try await f.localSource.inspect(f.old).sha256 == f.digest)
    }
    private func request(_ f: ResourcePlacementTestFixture, variant: Bool = false) throws -> V2ResourceMigrationRequest {
        try .init(operationID: UUID(), mediaID: f.media.uuidValue!, generation: 1, variantID: variant ? f.variant.uuidValue : nil, targetBinding: f.target.binding)
    }
    private func service(_ f: ResourcePlacementTestFixture, store: PostgresV2ResourceMigrationStore, destination: MigrationDestination) throws -> V2ResourceMigrationService {
        try .init(store: store, registry: .init(storages: [f.source, destination], defaultBinding: f.localSource.binding),
                  maximumBytes: 1024, allocate: { _ in try f.target.allocate() })
    }
    private func due(_ id: UUID, f: ResourcePlacementTestFixture) async throws {
        try await f.sql.raw("UPDATE im_v2.resource_storage_migrations SET retry_at=clock_timestamp()-interval '1 second' WHERE operation_id=\(bind: id)").run()
    }
    private func current(_ f: ResourcePlacementTestFixture, variant: Bool) async throws -> V2StoredObjectReference {
        let query: SQLQueryString = variant
            ? "SELECT reference_json::text AS reference FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!) AND variant_id=\(bind: f.variant.uuidValue!)"
            : "SELECT reference_json::text AS reference FROM im_v2.resource_blob_placements WHERE media_id=\(bind: f.media.uuidValue!) AND state='active'"
        let row = try #require(try await f.sql.raw(query).first(decoding: MigrationTestReference.self))
        return try JSONDecoder().decode(V2StoredObjectReference.self, from: Data(row.reference.utf8))
    }
    private func withFixture(_ body: (ResourcePlacementTestFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resource-migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            try await body(ResourcePlacementTestFixture(database: resources.database(.psql), root: root))
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}
private struct MigrationTestReference: Decodable { let reference: String }
private struct MigrationNoStagingPurge: V2MediaPurgeProvider { func purge(mediaID: MediaID) async throws {} }
private actor MigrationPermission {
    var allowed = true
    func deny() { allowed=false }
    func check() throws { guard allowed else { throw V2ResourceProviderError.preconditionFailed } }
}
private actor MigrationDestination: V2ObjectStorage {
    enum Mode { case normal, loseResponse, wrongReceipt, pause }
    nonisolated let binding: V2StorageBinding
    let storage: V2LocalResourceStorage
    var mode: Mode
    private(set) var writes = 0
    var paused: CheckedContinuation<Void, Never>?
    init(storage: V2LocalResourceStorage, mode: Mode = .normal) { self.storage=storage; self.binding=storage.binding; self.mode=mode }
    func inspect(_ reference: V2StoredObjectReference) async throws -> V2StoredObjectFacts { try await storage.inspect(reference) }
    func read(_ reference: V2StoredObjectReference) async throws -> V2ResourceByteStream { try await storage.read(reference) }
    func delete(_ reference: V2StoredObjectReference) async throws { try await storage.delete(reference) }
    func write(_ reference: V2StoredObjectReference, byteCount: Int64, sha256: Data, bytes: V2ResourceByteStream) async throws -> V2StoredObjectFacts {
        writes += 1
        let selected = mode; mode = .normal
        if selected == .pause { await withCheckedContinuation { paused=$0 } }
        let result = try await storage.write(reference, byteCount: byteCount, sha256: sha256, bytes: bytes)
        if selected == .loseResponse { throw V2ResourceProviderError.operationOutcomeUnknown }
        if selected == .wrongReceipt { return try .init(reference: storage.allocate(), byteCount: result.byteCount, sha256: result.sha256) }
        return result
    }
    func waitUntilPaused() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while paused == nil {
            guard ContinuousClock.now < deadline else { throw V2ResourceProviderError.temporarilyUnavailable }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { paused?.resume(); paused=nil }
}
