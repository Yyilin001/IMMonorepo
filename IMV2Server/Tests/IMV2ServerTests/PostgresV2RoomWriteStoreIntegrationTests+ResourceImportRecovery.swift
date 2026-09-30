@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import FluentKit
import Foundation
import IMV2Core
import PostgresNIO
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("resource import recovery acknowledges a committed source release across distinct owner databases",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"
            && ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"] != nil
            && ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"] != nil))
    func resourceImportRecoversAcrossOwnerDatabases() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, sourceSQL, targetSQL, _ in
            let sourceName = try #require(try await sourceSQL.raw("SELECT current_database() AS value").first(decoding: ImportRecoveryDatabaseName.self))
            let targetName = try #require(try await targetSQL.raw("SELECT current_database() AS value").first(decoding: ImportRecoveryDatabaseName.self))
            #expect(sourceName.value != targetName.value)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("resource-import-two-owners-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
            let f = try await ResourcePlacementTestFixture(database: sourceDB, root: root, bytes: image)
            try await sourceSQL.raw("UPDATE im_v2.resource_catalog SET home_kind='room',home_id=\(bind: f.room.uuidValue!),usage_kind='message_attachment' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            let fixtureService = try await f.imports()
            let fixtureStore = try #require(fixtureService.persistence as? PostgresV2ResourceImportStore)
            let resolve: @Sendable (V2ResourceHome, V2ResourceUsage?, UserID, DeviceID) async throws -> PostgresV2ResourceLifecycleStore = { home, _, _, _ in
                switch home {
                case .account: return .init(database: targetDB, authorize: { _ in })
                case .room: return .init(database: sourceDB, authorize: { _ in })
                }
            }
            let sourceResolver = V2ResourceImportSourceResolver(controlDatabase: targetDB,
                rooms: fixtureStore.sources.rooms, ownerDatabases: ["identity": sourceDB],
                authorization: fixtureStore.sources.authorization,
                avatarAuthorization: { _, _, _, _, _ in throw V2MediaStoreError.downloadNotAuthorized })
            let persistence = PostgresV2ResourceImportStore(resolve: resolve, sources: sourceResolver,
                recoveryDatabases: ["identity": sourceDB, "target": targetDB])
            let resources = try V2ResourceService(resolve: { home, usage, actor, device in
                try await resolve(home, usage, actor, device)
            }, registry: f.registry, transports: Array(fixtureService.transports.values),
                maximumBytes: 1_000_000, supportsAvatars: true, allocate: { _ in try f.target.allocate() })
            let service = V2ResourceImportService(resources: resources, resolve: { home, usage, actor, device in
                try await resolve(home, usage, actor, device)
            }, persistence: persistence, registry: f.registry, transports: Array(fixtureService.transports.values))
            let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
                source: f.request(variant: false).source, targetUsage: .userAvatar, targetMediaID: .init(uuid: UUID()))

            // Fail the actual target acknowledgement statement after the source transaction commits.
            try await targetSQL.raw("""
                CREATE FUNCTION im_v2.reject_test_import_release_ack() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    RAISE EXCEPTION 'injected target acknowledgement failure'
                        USING ERRCODE='23514', CONSTRAINT='test_import_source_release_ack';
                END;
                $$
                """).run()
            try await targetSQL.raw("""
                CREATE TRIGGER reject_test_import_release_ack BEFORE UPDATE OF source_released_at
                ON im_v2.resource_imports FOR EACH ROW WHEN (NEW.source_released_at IS NOT NULL)
                EXECUTE FUNCTION im_v2.reject_test_import_release_ack()
                """).run()
            do {
                _ = try await service.create(request, actor: f.user, device: f.device)
                Issue.record("target acknowledgement unexpectedly succeeded despite its injected failure")
                return
            } catch let failure as PSQLError {
                try #require(failure.serverInfo?[.sqlState] == "23514")
                try #require(failure.serverInfo?[.constraintName] == "test_import_source_release_ack")
            }
            let released = try await f.hold(request).released
            #expect(released != nil)
            #expect(try await sourceSQL.raw("SELECT 1 FROM im_v2.resource_import_source_closures WHERE actor_user_id=\(bind: f.user.uuidValue!) AND operation_id=\(bind: request.operationID.uuidValue!)").first() != nil)
            let unacknowledged = try #require(try await targetSQL.raw("SELECT state,source_released_at AS released FROM im_v2.resource_imports WHERE operation_id=\(bind: request.operationID.uuidValue!)").first(decoding: CrossOwnerImportRecoveryState.self))
            #expect(unacknowledged.state == "processing" && unacknowledged.released == nil)
            #expect(try await targetSQL.raw("SELECT 1 FROM im_v2.resource_upload_sessions WHERE media_id=\(bind: request.targetMediaID.uuidValue!) AND state='completed'").first() != nil)
            #expect(try await persistence.recoveryCandidates(ownerID: "target", limit: 100).contains { $0.request.operationID == request.operationID })
            #expect(try await targetSQL.raw("SELECT 1 FROM im_v2.resource_import_holds WHERE operation_id=\(bind: request.operationID.uuidValue!)").first() == nil)
            #expect(try await sourceSQL.raw("SELECT 1 FROM im_v2.resource_imports WHERE operation_id=\(bind: request.operationID.uuidValue!)").first() == nil)

            try await targetSQL.raw("DROP TRIGGER reject_test_import_release_ack ON im_v2.resource_imports").run()
            try await targetSQL.raw("UPDATE im_v2.media_objects SET state='available' WHERE media_id=\(bind: request.targetMediaID.uuidValue!)").run()
            let reads = await f.source.reads
            try await service.runOnce(ownerID: "target")
            #expect(try await f.hold(request).released == released)
            #expect(await f.source.reads == reads)
            let acknowledged = try #require(try await targetSQL.raw("SELECT state,source_released_at AS released FROM im_v2.resource_imports WHERE operation_id=\(bind: request.operationID.uuidValue!)").first(decoding: CrossOwnerImportRecoveryState.self))
            #expect(acknowledged.state == "ready" && acknowledged.released != nil)
            #expect(try await persistence.recoveryCandidates(ownerID: "target", limit: 100).contains { $0.request.operationID == request.operationID } == false)
        }
    }
}

private struct ImportRecoveryDatabaseName: Decodable { let value: String }
private struct CrossOwnerImportRecoveryState: Decodable { let state: String; let released: Date? }
