import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import IMV2ServerApplication
import SQLKit
import Testing
@testable import IMV2ServerInfrastructure

@Suite(.serialized)
struct V2ResourceStagingCleanupPostgresTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func publishedPartsCleanUpAfterFailureAndProcessReassembly() async throws {
        try await withFixture { fixture in
            try await V2SchemaReadiness.verify(database: fixture.database)
            let bytes = Data(repeating: 71, count: 8 * 1_024 * 1_024 + 1)
            let upload = try await fixture.upload(bytes)
            await fixture.origin.failNextTombstone(part: 2)
            let status = try await fixture.service.status(upload.session.locator, actor: fixture.actor, device: fixture.device)
            let completed = try await fixture.service.finalize(.init(locator: upload.session.locator, generation: 1, parts: status.confirmedParts),
                actor: fixture.actor, device: fixture.device)
            #expect(completed.state == .completed && completed.resourceState == .scanning)
            let before = try await fixture.state(upload.session.locator.sessionID)
            #expect(before.pending && before.token == nil)
            try await V2ResourceStagingCleanupWorker(database: fixture.database, service: fixture.service).runOnce(limit: 1)
            let failed = try await fixture.state(upload.session.locator.sessionID)
            #expect(failed.pending && failed.token == nil && failed.delayed)
            #expect(await fixture.origin.nativePut(upload.plans[0], bytes: bytes.prefix(8 * 1_024 * 1_024)) == 409)
            // Advance only this durable retry deadline instead of waiting thirty seconds.
            try await fixture.sql.raw("UPDATE im_v2.resource_upload_sessions SET staging_cleanup_retry_at=clock_timestamp() WHERE session_id=\(bind: upload.session.locator.sessionID.uuidValue!)").run()
            let restarted = try fixture.reassembleService()
            try await V2ResourceStagingCleanupWorker(database: fixture.database, service: restarted).runOnce(limit: 1)
            #expect(try await fixture.state(upload.session.locator.sessionID).pending == false)
            #expect(await fixture.origin.allStoredBytesAreEmpty())
            #expect(await fixture.origin.nativePut(upload.plans[1], bytes: Data([71])) == 409)
            let row = try await PostgresV2ResourceLifecycleStore(database: fixture.database, authorize: { _ in })
                .upload(session: upload.session.locator.sessionID.uuidValue!, actor: fixture.actor.uuidValue!, device: fixture.device.uuidValue!)
            #expect(try await collectOSSMultipart(fixture.storage.read(row.placement)) == bytes)
            // Original publication stays complete after all staging bytes are fenced.
            #expect(try await restarted.finalize(.init(locator: upload.session.locator, generation: 1), actor: fixture.actor, device: fixture.device).state == .completed)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func expiredCleanupLeaseRejectsOldAcknowledgmentsAndRequiresQueueIndex() async throws {
        try await withFixture { fixture in
            let upload = try await fixture.upload(Data([1, 2, 3]))
            let persistence = PostgresV2ResourceStagingCleanupPersistence(database: fixture.database)
            #expect(try await persistence.claim(limit: 1).isEmpty)
            // An upload that has not published cannot enter the staging cleanup queue.
            await #expect(throws: (any Error).self) {
                try await fixture.sql.raw("UPDATE im_v2.resource_upload_sessions SET staging_cleanup_pending=true WHERE session_id=\(bind: upload.session.locator.sessionID.uuidValue!)").run()
            }
            let status = try await fixture.service.status(upload.session.locator, actor: fixture.actor, device: fixture.device)
            _ = try await fixture.service.finalize(.init(locator: upload.session.locator, generation: 1, parts: status.confirmedParts), actor: fixture.actor, device: fixture.device)
            let old = try #require(try await persistence.claim(limit: 1).first)
            #expect(try await persistence.claim(limit: 1).isEmpty)
            try await fixture.sql.raw("UPDATE im_v2.resource_upload_sessions SET staging_cleanup_lease_expires_at=clock_timestamp()-interval '1 second' WHERE session_id=\(bind: old.sessionID)").run()
            let reopened = PostgresV2ResourceStagingCleanupPersistence(database: fixture.database)
            let fresh = try #require(try await reopened.claim(limit: 1).first)
            #expect(fresh.token != old.token)
            try await persistence.complete(old)
            try await persistence.retry(old)
            let state = try await fixture.state(upload.session.locator.sessionID)
            #expect(state.pending && state.token == fresh.token && !state.delayed)
            let source = try fresh.source.get()
            try await fixture.service.cleanupStaging(request: source.request, binding: source.binding)
            try await reopened.complete(fresh)
            #expect(try await fixture.state(upload.session.locator.sessionID).pending == false)
            do {
                try await fixture.database.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("DROP INDEX im_v2.resource_upload_sessions_staging_cleanup_idx").run()
                    await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.resource_upload_sessions[lifecycle-contract]")) {
                        try await V2SchemaReadiness.verify(database: transaction)
                    }
                    throw RollbackProbe.finished
                }
            } catch RollbackProbe.finished { }
        }
    }

    private enum RollbackProbe: Error { case finished }

    private func withFixture(_ body: (CleanupFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-oss-cleanup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let fixture = try CleanupFixture(database: resources.database(.psql), root: root)
            try await body(fixture)
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

private struct CleanupState: Decodable { let pending: Bool; let token: UUID?; let delayed: Bool }
private struct CleanupFixture {
    let database: any Database
    let sql: any SQLDatabase
    let origin: OSSMultipartTestOrigin
    let configuration: V2OSSConfiguration
    let storage: V2LocalResourceStorage
    let service: V2ResourceService
    let actor = UserID(uuid: UUID())
    let device = DeviceID(uuid: UUID())

    init(database: any Database, root: URL) throws {
        self.database = database; sql = try #require(database as? any SQLDatabase)
        origin = OSSMultipartTestOrigin(); configuration = try originConfiguration()
        storage = try V2LocalResourceStorage(root: root, binding: configuration.binding)
        service = try Self.service(database: database, storage: storage, origin: origin, configuration: configuration)
    }
    func reassembleService() throws -> V2ResourceService {
        try Self.service(database: database, storage: storage, origin: origin, configuration: configuration)
    }
    private static func service(database: any Database, storage: V2LocalResourceStorage,
                                origin: OSSMultipartTestOrigin, configuration: V2OSSConfiguration) throws -> V2ResourceService {
        try .init(resolve: { _, _, _, _ in PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in }) },
            registry: .init(storages: [storage], defaultBinding: storage.binding),
            transports: [V2OSSUploadTransport(client: originClient(origin, configuration: configuration))],
            maximumBytes: 256 * 1_024 * 1_024, allocate: { _ in try storage.allocate() })
    }
    func upload(_ bytes: Data) async throws -> (session: V2ResourceUploadSession, plans: [V2ResourceTransferPlan]) {
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(.init(uuid: UUID())), contentType: "application/octet-stream", byteCount: Int64(bytes.count),
            checksum: ossMultipartChecksum(bytes), clientModes: [.httpPartPut], displayName: .init("fixture.bin"))
        let session = try await service.create(request, actor: actor, device: device)
        let count = (bytes.count + 8 * 1_024 * 1_024 - 1) / (8 * 1_024 * 1_024)
        let plans = try await service.targets(.init(locator: session.locator, generation: 1, partNumbers: Array(1...count)), actor: actor, device: device)
        for plan in plans {
            let range = try #require(plan.byteRange)
            #expect(await origin.nativePut(plan, bytes: bytes.subdata(in: Int(range.lowerBound)..<(Int(range.upperBound) + 1))) == 200)
        }
        return (session, plans)
    }
    func state(_ session: MediaUploadSessionID) async throws -> CleanupState {
        let row = try await sql.raw("""
            SELECT staging_cleanup_pending AS pending,staging_cleanup_claim_token AS token,
                staging_cleanup_retry_at>clock_timestamp() AS delayed
            FROM im_v2.resource_upload_sessions WHERE session_id=\(bind: session.uuidValue!)
            """).first(decoding: CleanupState.self)
        return try #require(row)
    }
}
