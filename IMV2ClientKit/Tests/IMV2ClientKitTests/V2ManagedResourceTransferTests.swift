import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Canonical managed resource transfers", .timeLimit(.minutes(1)))
struct V2ManagedResourceTransferTests {
    @Test func unclaimedPersistentJobsAreQueuedAndClaimedJobsShowPreparation() async throws {
        let f = try Fixture(), upload = UUID(), imported = UUID(), owner = UUID()
        _ = try await f.upload(id: upload)
        try await f.addImport(id: imported)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.allSatisfy { $0.phase == .queued })
        _ = try #require(try await f.store.claimResourceStep(id: upload, owner: owner, now: Date()))
        #expect(try await f.store.claimResourceImport(imported, owner: owner))
        #expect(try await f.store.managedResourceTransfers(.init()).entries.allSatisfy { $0.phase == .preparing })
        let floor = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 30)
        try await f.store.finishResourceStep(id: upload, owner: owner, next: .create, retryAt: floor)
        try await f.store.pauseResourceImport(id: imported, owner: owner, retryNotBefore: floor)
        try await f.store.releaseResourceImportExecution(imported, owner: owner)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.allSatisfy { $0.phase == .waitingRetry(floor) })
        try await f.close()
    }

    @Test func liveImportCannotResetBudgetAndOldOwnerCannotPublishAfterAdoption() async throws {
        let f = try Fixture(), id = UUID(), firstOwner = UUID(), nextOwner = UUID()
        try await f.addImport(id: id)
        #expect(try await f.store.claimResourceImport(id, owner: firstOwner))
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_import_jobs SET attempts=5") }
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.group == .active)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.actions.contains(.retry) == false)
        try await f.store.retryResourceImport(id: id)
        #expect(try await f.store.resourceImport(id: id)?.attempts == 5)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.store.retryManagedResourceTransfer(.serverImport(id)) }
        try await f.store.releaseResourceImportExecution(id, owner: nextOwner)
        #expect(try await f.store.dueResourceImports(now: .distantFuture).isEmpty)
        try await f.store.recoverResourceImportExecutions(owner: nextOwner)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.actions == [.retry, .cancelUnbound])
        try await f.store.retryManagedResourceTransfer(.serverImport(id))
        #expect(try await f.store.claimResourceImport(id, owner: nextOwner))
        let request = try #require(try await f.store.resourceImport(id: id)?.request)
        let result = try V2ResourceImportStatus(locator: .init(home: .room(f.room), operationID: request.operationID),
            mediaID: request.targetMediaID, state: .processing, bindableUntil: nil)
        await #expect(throws: V2ResourceJournalError.conflict) { try await f.store.saveResourceImport(result, id: id, owner: firstOwner) }
        await #expect(throws: V2ResourceJournalError.conflict) { try await f.store.pauseResourceImport(id: id, owner: firstOwner, needsAttention: true) }
        try await f.store.saveResourceImport(result, id: id, owner: nextOwner)
        #expect(try await f.store.resourceImport(id: id)?.status == result)
        try await f.store.releaseResourceImportExecution(id, owner: nextOwner)
        try await f.close()
    }

    @Test func journalsShareUUIDWithoutCollidingAndPagingIgnoresStateChanges() async throws {
        let f = try Fixture(), shared = UUID(), stamp = Date(timeIntervalSince1970: 100)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.store.retryManagedResourceTransfer(.upload(shared)) }
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.store.retryManagedResourceTransfer(.serverImport(shared)) }
        _ = try await f.upload(id: shared, stamp: stamp)
        try await f.addImport(id: shared, stamp: stamp)
        _ = try await f.store.beginBackgroundDownload(id: shared, mediaID: .init(uuid: UUID()), message: nil, accountID: f.user)
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_download_jobs SET created_at=?", arguments: [stamp.timeIntervalSince1970]) }
        let first = try await f.store.managedResourceTransfers(.init(limit: 1))
        #expect(first.entries.map(\.id) == [.upload(shared)])
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_transfer_jobs SET stage='paused',needs_attention=1,last_error='budgetExhausted'") }
        let second = try await f.store.managedResourceTransfers(.init(before: #require(first.nextCursor), limit: 1))
        #expect(second.entries.map(\.id) == [.serverImport(shared)])
        let third = try await f.store.managedResourceTransfers(.init(before: #require(second.nextCursor), limit: 1))
        #expect(third.entries.map(\.id) == [.download(shared)] && third.nextCursor == nil)
        let all = try await f.store.managedResourceTransfers(.init())
        #expect(Set(all.entries.map(\.id)).count == 3)
        #expect(all.entries.first?.phase == .requiresAttention(.needsAttention))
        #expect(try await f.store.managedResourceTransfers(.init(group: .attention)).entries.map(\.id) == [.upload(shared)])
        try await f.close()
    }

    @Test func retryRevalidatesPhaseAndReconcilesSameSessionWithServerCooldown() async throws {
        let f = try Fixture(), id = UUID(), request = try await f.upload(id: id)
        let session = try V2ResourceUploadSession(locator: .init(home: .account(f.user), sessionID: .init(uuid: UUID())),
            mediaID: request.mediaID, generation: 1, state: .uploading, resourceState: .pending, expiresAt: .distantFuture,
            confirmedParts: [.init(number: 1, byteCount: 5)], retryNotBefore: Date(timeIntervalSince1970: 300))
        try await f.store.saveResourceSession(session, for: id)
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_transfer_jobs SET stage='paused',needs_attention=1,last_error='transport'") }
        let before = try await f.store.managedResourceTransfers(.init())
        #expect(before.entries.first?.actions == [.retry, .cancelUnbound])
        #expect(before.entries.first?.confirmedBytes == 5 && before.entries.first?.totalBytes == 16)
        try await f.store.retryManagedResourceTransfer(.upload(id))
        let job = try #require(try await f.store.resourceTransfer(id: id))
        #expect(!job.needsAttention && job.session?.locator == session.locator)
        #expect(job.nextAction == .status && job.retryAt == Date(timeIntervalSince1970: 300))
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.store.retryManagedResourceTransfer(.upload(id)) }
        // A stale UI action cannot restart a now completed/owned/cancelling job.
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_transfer_jobs SET needs_attention=1,execution_owner=?", arguments: [UUID().uuidString]) }
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.store.retryManagedResourceTransfer(.upload(id)) }
        try await f.close()
    }

    @Test func downloadNeverRevealsRevokedMetadataOrPretendsCancellationHasDrained() async throws {
        let f = try Fixture(), media = MediaID(uuid: UUID()), id = UUID()
        let location = V2MediaMessageLocation(roomID: f.room, messageID: .init(uuid: UUID()))
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(f.room), mediaID: media), revision: 1,
            displayName: .init("private.pdf"), contentType: "application/pdf", byteCount: 16,
            checksum: .init(value: String(repeating: "a", count: 64)), state: .ready)
        try await f.store.indexResource(descriptor, reference: .message(location, ordinal: 0), businessRevision: 1)
        _ = try await f.store.beginBackgroundDownload(id: id, mediaID: media, message: location, accountID: f.user)
        let visible = try await f.store.managedResourceTransfers(.init())
        #expect(visible.entries.first?.displayName == descriptor.displayName && visible.entries.first?.resource == descriptor.key)
        try await f.store.revokeResourceReference(.message(location, ordinal: 0), businessRevision: 2)
        try await f.store.cancelBackgroundDownload(id: id, accountID: f.user)
        let revoked = try await f.store.managedResourceTransfers(.init())
        #expect(revoked.entries.first?.displayName == nil && revoked.entries.first?.resource == nil)
        #expect(revoked.entries.first?.phase == .cancelling && revoked.entries.first?.group == .active)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.store.retryManagedResourceTransfer(.download(id)) }
        try await f.close()
    }

    @Test func serverImportRetryDoesNotAllocateNewResourceOrResetServerCooldown() async throws {
        let f = try Fixture(), id = UUID()
        try await f.addImport(id: id)
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_import_jobs SET attempts=5,server_retry_not_before=500") }
        let before = try #require(try await f.store.resourceImport(id: id))
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.actions == [.retry, .cancelUnbound])
        try await f.store.retryManagedResourceTransfer(.serverImport(id))
        let after = try #require(try await f.store.resourceImport(id: id))
        #expect(after.attempts == 0 && after.request == before.request && after.retryAt == Date(timeIntervalSince1970: 500))
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.actions == [.pause, .cancelUnbound])
        try await f.close()
    }

    @Test func accountStreamStartsLocallyObservesCommitAndEndsOnClose() async throws {
        let f = try Fixture(), id = UUID()
        let center = try await V2ResourceCenter.make(scope: .init(incarnation: UUID(), accountID: f.user,
            directory: f.root.appending(path: "account"), cacheDirectory: f.root.appending(path: "cache")), store: f.store)
        let stream = try await center.transferSnapshots(for: .init())
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .available(.init(entries: [], nextCursor: nil)))
        _ = try await f.upload(id: id)
        guard case .available(let page) = await iterator.next() else { Issue.record("Missing committed transfer snapshot"); return }
        #expect(page.entries.map(\.id) == [.upload(id)])
        await center.close()
        #expect(await iterator.next() == nil)
        await #expect(throws: V2ResourceStorageError.closed) { try await center.retryTransfer(.upload(id)) }
        try await f.close()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "managed-transfers-\(UUID())")
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let store: GRDBV2LocalSyncStore
        init() throws { store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user) }
        func upload(id: UUID, stamp: Date = Date()) async throws -> V2ResourceUploadRequest {
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .userAvatar,
                contentType: "image/png", byteCount: 16, checksum: .init(value: String(repeating: "a", count: 64)), displayName: .init("avatar.png"))
            _ = try await store.prepareMetadataResourceTransfer(id: id, request: request, localAssetID: .init(UUID()), now: stamp)
            return request
        }
        func addImport(id: UUID, stamp: Date = Date()) async throws {
            let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
            try await store.databasePool.write { try GRDBV2LocalSyncStore.prepareResourceImport(id: id, request: request, now: stamp, db: $0) }
        }
        func close() async throws { try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
