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
struct V2ResourceImportRecoveryPostgresTests {
    @Test("terminal imports retry failed source release without retaining bytes forever",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["ready", "failed", "cancelled"])
    func terminalReleaseRecovery(terminal: String) async throws {
        try await withFixture { f in
            let healthy = try await f.imports()
            let failing = withPersistence(healthy, ImportFailingRelease(delegate: healthy.persistence))
            let request = try f.request(variant: false)
            if terminal == "cancelled" {
                await f.source.failNextRead()
                await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
                    _ = try await healthy.create(request, actor: f.user, device: f.device)
                }
                let locator = V2ResourceImportLocator(home: request.targetUsage.home(actorUserID: f.user), operationID: request.operationID)
                await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
                    _ = try await failing.cancel(locator, actor: f.user, device: f.device)
                }
            } else {
                await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
                    _ = try await failing.create(request, actor: f.user, device: f.device)
                }
                try await f.sql.raw("UPDATE im_v2.media_objects SET state=\(bind: terminal == "ready" ? "available" : "failed") WHERE media_id=\(bind: request.targetMediaID.uuidValue!)").run()
                try await failing.runOnce(ownerID: "identity")
            }
            #expect(try await f.hold(request).released == nil)
            let before = try await healthy.persistence.recoveryCandidates(ownerID: "identity", limit: 100)
            #expect(before.contains { $0.request.operationID == request.operationID })
            try await healthy.runOnce(ownerID: "identity")
            #expect(try await f.hold(request).released != nil)
            let row = try #require(try await f.sql.raw("SELECT state,source_released_at AS released FROM im_v2.resource_imports WHERE operation_id=\(bind: request.operationID.uuidValue!)").first(decoding: ImportRecoveryState.self))
            #expect(row.state == terminal && row.released != nil)
            let after = try await healthy.persistence.recoveryCandidates(ownerID: "identity", limit: 100)
            #expect(!after.contains { $0.request.operationID == request.operationID })
        }
    }

    @Test("cleanup preserves an available avatar after its staging deadline",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func boundAvatarSurvivesStagingExpiry() async throws {
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        try await withFixture(bytes: image) { f in
            let healthy = try await f.imports(supportsAvatars: true)
            let failing = withPersistence(healthy, ImportFailingRelease(delegate: healthy.persistence))
            let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
                source: f.request(variant: true).source, targetUsage: .userAvatar, targetMediaID: .init(uuid: UUID()))
            await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
                _ = try await failing.create(request, actor: f.user, device: f.device)
            }
            try await f.sql.raw("UPDATE im_v2.media_objects SET state='available',expires_at=clock_timestamp()-interval '1 hour' WHERE media_id=\(bind: request.targetMediaID.uuidValue!)").run()
            let handle = "ir" + f.user.rawValue.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
            try await f.sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,avatar_media_id,created_at,updated_at) VALUES(\(bind: f.user.uuidValue!),\(bind: handle),'Imported avatar',\(bind: request.targetMediaID.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            try await healthy.runOnce(ownerID: "identity")
            let locator = V2ResourceImportLocator(home: .account(f.user), operationID: request.operationID)
            #expect(try await healthy.status(locator, actor: f.user, device: f.device).state == .ready)
            let row = try #require(try await f.sql.raw("SELECT state,source_released_at AS released FROM im_v2.resource_imports WHERE operation_id=\(bind: request.operationID.uuidValue!)").first(decoding: ImportRecoveryState.self))
            #expect(row.state == "ready" && row.released != nil)
            #expect(try await f.hold(request).released != nil)
        }
    }

    @Test("cancellation before source acquisition prevents a late retained hold",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func cancellationBeforeFirstHold() async throws {
        try await withFixture { f in
            let healthy = try await f.imports()
            let original = try #require(healthy.persistence as? PostgresV2ResourceImportStore)
            let gate = ImportSourceAcquisitionGate()
            let sources = V2ResourceImportSourceResolver(controlDatabase: f.database, rooms: original.sources.rooms,
                ownerDatabases: ["identity": f.database], authorization: original.sources.authorization,
                avatarAuthorization: { _, _, _, _, _ in await gate.pause() })
            let store = PostgresV2ResourceImportStore(resolve: original.resolveConcrete,
                sources: sources, ownerDatabases: ["identity": f.database])
            let service = withPersistence(healthy, store)
            let request = try f.request(variant: true)
            let create = Task { try await service.create(request, actor: f.user, device: f.device) }
            await gate.waitUntilEntered()
            let locator = V2ResourceImportLocator(home: request.targetUsage.home(actorUserID: f.user), operationID: request.operationID)
            do {
                #expect(try await service.cancel(locator, actor: f.user, device: f.device).state == .cancelled)
            } catch {
                await gate.resume()
                _ = try? await create.value
                throw error
            }
            await gate.resume()
            await #expect(throws: V2ResourceProviderError.preconditionFailed) { _ = try await create.value }
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_import_holds WHERE operation_id=\(bind: request.operationID.uuidValue!)").first() == nil)
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_import_source_closures WHERE operation_id=\(bind: request.operationID.uuidValue!)").first() != nil)
            #expect(try await store.recoveryCandidates(ownerID: "identity", limit: 100).contains { $0.request.operationID == request.operationID } == false)
            #expect(await f.source.reads.isEmpty)
        }
    }

    @Test("source release is idempotently replayed when its target acknowledgement was lost",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func sourceReleasedBeforeAcknowledgement() async throws {
        try await withFixture { f in
            let healthy = try await f.imports()
            let failing = withPersistence(healthy, ImportFailingRelease(delegate: healthy.persistence))
            let request = try f.request(variant: false)
            await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
                _ = try await failing.create(request, actor: f.user, device: f.device)
            }
            // Persist exactly the crash boundary between the independent source and target commits.
            try await f.sql.raw("UPDATE im_v2.resource_import_holds SET released_at=clock_timestamp() WHERE operation_id=\(bind: request.operationID.uuidValue!)").run()
            try await f.sql.raw("UPDATE im_v2.media_objects SET state='available' WHERE media_id=\(bind: request.targetMediaID.uuidValue!)").run()
            try await f.sql.raw("UPDATE im_v2.resource_imports SET state='ready' WHERE operation_id=\(bind: request.operationID.uuidValue!)").run()
            let before = try await f.hold(request)
            try await healthy.runOnce(ownerID: "identity")
            async let firstReplay: Void = healthy.persistence.releaseSource(request, actor: f.user)
            async let secondReplay: Void = healthy.persistence.releaseSource(request, actor: f.user)
            _ = try await (firstReplay, secondReplay)
            #expect(try await f.hold(request).released == before.released)
            let row = try #require(try await f.sql.raw("SELECT state,source_released_at AS released FROM im_v2.resource_imports WHERE operation_id=\(bind: request.operationID.uuidValue!)").first(decoding: ImportRecoveryState.self))
            #expect(row.state == "ready" && row.released != nil)
            #expect(try await healthy.persistence.recoveryCandidates(ownerID: "identity", limit: 100).contains { $0.request.operationID == request.operationID } == false)
        }
    }

    @Test("a committed target is reconciled after its original device loses authorization",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["revoked", "expired"])
    func closedTargetDoesNotNeedClientAuthority(reason: String) async throws {
        try await withFixture { f in
            let healthy = try await f.imports()
            let failing = withPersistence(healthy, ImportFailingRelease(delegate: healthy.persistence))
            let request = try f.request(variant: false)
            await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
                _ = try await failing.create(request, actor: f.user, device: f.device)
            }
            // Crash immediately after finalize, before the import state or source release commit.
            try await f.sql.raw("UPDATE im_v2.resource_imports SET state='copying' WHERE operation_id=\(bind: request.operationID.uuidValue!)").run()
            try await f.sql.raw("UPDATE im_v2.media_objects SET state='available' WHERE media_id=\(bind: request.targetMediaID.uuidValue!)").run()
            try await f.sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at,session_expires_at,revoked_at) VALUES(\(bind: f.user.uuidValue!),\(bind: f.device.uuidValue!),clock_timestamp(),clock_timestamp(),\(bind: reason == "expired" ? Date().addingTimeInterval(-60) : Date().addingTimeInterval(600)),\(bind: reason == "revoked" ? Date() : nil as Date?))").run()
            let original = try #require(healthy.persistence as? PostgresV2ResourceImportStore)
            let denied = PostgresV2ResourceImportStore(resolve: { _, _, _, _ in
                guard try await f.sql.raw("SELECT 1 FROM im_v2.auth_devices WHERE user_id=\(bind: f.user.uuidValue!) AND device_id=\(bind: f.device.uuidValue!) AND revoked_at IS NULL AND session_expires_at > clock_timestamp()").first() != nil else {
                    throw V2MediaStoreError.uploadNotAuthorized
                }
                return PostgresV2ResourceLifecycleStore(database: f.database, authorize: { _ in })
            }, sources: original.sources, ownerDatabases: ["identity": f.database])
            let worker = withPersistence(healthy, denied)
            let locator = V2ResourceImportLocator(home: request.targetUsage.home(actorUserID: f.user), operationID: request.operationID)
            await #expect(throws: V2MediaStoreError.uploadNotAuthorized) {
                _ = try await worker.status(locator, actor: f.user, device: f.device)
            }
            let reads = await f.source.reads
            try await worker.runOnce(ownerID: "identity")
            #expect(try await f.hold(request).released != nil)
            #expect(await f.source.reads == reads)
            #expect(try await denied.recoveryCandidates(ownerID: "identity", limit: 100).contains { $0.request.operationID == request.operationID } == false)
            await #expect(throws: V2MediaStoreError.uploadNotAuthorized) {
                _ = try await worker.resume(locator, actor: f.user, device: f.device)
            }
        }
    }

    @Test("import status agrees with resume when a published resource is rejected or expires",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["failed", "expired"])
    func terminalResourceStatus(mediaState: String) async throws {
        try await withFixture { f in
            let service = try await f.imports()
            let request = try f.request(variant: false)
            let initial = try await service.create(request, actor: f.user, device: f.device)
            try await f.sql.raw("UPDATE im_v2.media_objects SET state='available' WHERE media_id=\(bind: request.targetMediaID.uuidValue!)").run()
            #expect(try await service.resume(initial.locator, actor: f.user, device: f.device).state == .ready)
            try await f.sql.raw("UPDATE im_v2.media_objects SET state=\(bind: mediaState) WHERE media_id=\(bind: request.targetMediaID.uuidValue!)").run()
            let status = try await service.status(initial.locator, actor: f.user, device: f.device)
            #expect(status.state == .failed && status.bindableUntilUnixMilliseconds == nil)
            let resumed = try await service.resume(initial.locator, actor: f.user, device: f.device)
            #expect(resumed.state == status.state && resumed.bindableUntilUnixMilliseconds == nil)
        }
    }

    private func withFixture(bytes: Data = Data("immutable input snapshot".utf8), _ body: (ResourcePlacementTestFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resource-import-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let fixture = try await ResourcePlacementTestFixture(database: resources.database(.psql), root: root, bytes: bytes)
            try await body(fixture)
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    private func withPersistence(_ service: V2ResourceImportService, _ persistence: any V2ResourceImportPort) -> V2ResourceImportService {
        .init(resources: service.resources, resolve: service.resolve, persistence: persistence,
              registry: service.registry, transports: Array(service.transports.values))
    }
}

private struct ImportRecoveryState: Decodable { let state: String; let released: Date? }

private actor ImportSourceAcquisitionGate {
    var entered = false
    var waitingForEntry: CheckedContinuation<Void, Never>?
    var waitingForResume: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        waitingForEntry?.resume(); waitingForEntry = nil
        await withCheckedContinuation { waitingForResume = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { waitingForEntry = $0 } }
    }
    func resume() { waitingForResume?.resume(); waitingForResume = nil }
}

private struct ImportFailingRelease: V2ResourceImportPort {
    let delegate: any V2ResourceImportPort
    func create(_ request: V2ResourceImportRequest, actor: UserID, device: DeviceID) async throws { try await delegate.create(request, actor: actor, device: device) }
    func snapshot(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSnapshot { try await delegate.snapshot(locator, actor: actor, device: device) }
    func cancellationSnapshot(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSnapshot { try await delegate.cancellationSnapshot(locator, actor: actor, device: device) }
    func acquireSource(_ request: V2ResourceImportRequest, actor: UserID, device: DeviceID) async throws -> V2ResourceImportSourceGrant { try await delegate.acquireSource(request, actor: actor, device: device) }
    func attach(_ session: V2ResourceUploadSession, locator: V2ResourceImportLocator, actor: UserID, device: DeviceID) async throws { try await delegate.attach(session, locator: locator, actor: actor, device: device) }
    func mark(_ locator: V2ResourceImportLocator, actor: UserID, device: DeviceID, state: V2ResourceImportState) async throws { try await delegate.mark(locator, actor: actor, device: device, state: state) }
    func releaseSource(_ request: V2ResourceImportRequest, actor: UserID) async throws { throw V2ResourceProviderError.temporarilyUnavailable }
    func recoveryCandidates(ownerID: String, limit: Int) async throws -> [V2ResourceImportRecoveryItem] { try await delegate.recoveryCandidates(ownerID: ownerID, limit: limit) }
    func reconcileTargetClosure(_ item: V2ResourceImportRecoveryItem) async throws -> Bool { try await delegate.reconcileTargetClosure(item) }
    func recordRecoveryFailure(_ item: V2ResourceImportRecoveryItem) async throws -> Bool { try await delegate.recordRecoveryFailure(item) }
}
