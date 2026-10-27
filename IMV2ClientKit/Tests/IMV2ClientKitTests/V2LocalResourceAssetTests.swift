import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Durable local originals and atomic consumer handoff")
struct V2LocalResourceAssetTests {
    @Test("in-memory originals publish once, share verified bytes with files and survive a cold owner")
    func dataOriginalSharesOnePublicationAndRestores() async throws {
        let f = try await Fixture()
        let scope = V2AccountStorageScope(incarnation: UUID(), accountID: try f.journal.accountID(), directory: f.root,
            cacheDirectory: f.root.appending(path: "cache-scope"))
        let center = try await V2ResourceCenter.make(scope: scope, store: f.store)
        // Preserve non-zero Data indices across several bounded write chunks.
        let data = Data(repeating: 37, count: 150_000)[13..<149_983]
        let first = try await center.importLocal(data: data, displayName: .init("photo.jpg"), contentType: .init("image/jpeg"), purpose: .personalAvatar)
        try data.write(to: f.source)
        let second = try await center.importLocal(at: f.source, displayName: .init("second.jpg"), contentType: .init("image/jpeg"), purpose: .personalAvatar)
        #expect(first.fileID == second.fileID)
        let snapshot = try await center.storageSnapshot()
        #expect(snapshot.files.count == 1 && snapshot.transferReservedBytes == 0 && snapshot.transferAllocatedBytes == 0)
        let lease = try await center.borrowLocalSelection(first.id)
        #expect(try Data(contentsOf: lease.fileURL) == data)
        #expect(lease.fileURL.path.hasPrefix(scope.resourceFilesDirectory.path))
        await lease.release(); await center.close()
        try FileManager.default.removeItem(at: f.source)
        let restored = try await V2ResourceCenter.make(scope: scope, store: f.store)
        #expect(try await restored.selectedLocalAssets(purpose: .personalAvatar).count == 2)
        let cold = try await restored.borrowLocalSelection(first.id)
        #expect(try Data(contentsOf: cold.fileURL) == data)
        await cold.release(); await restored.close(); try await f.remove()
    }

    @Test("rejected in-memory input creates neither files nor phantom selections")
    func dataAdmissionIsBounded() async throws {
        let f = try await Fixture(), files = try f.files()
        for body in [Data(), Data(repeating: 7, count: 33)] {
            do {
                _ = try await files.importOriginal(data: body, id: .init(), displayName: .init("photo.jpg"), contentType: .init("image/jpeg"),
                    purpose: .personalAvatar, maximumBytes: 32, maximumSelections: 1)
                Issue.record("invalid data was admitted")
            } catch let error as V2ResourceStorageError { #expect(error == .invalidRecord || error == .capacityExceeded) }
        }
        #expect(try await files.snapshot().files.isEmpty)
        #expect(try await files.selectedAssets(purpose: .personalAvatar).isEmpty)
        _ = try await files.setStoragePolicy(.init(maximumCacheBytes: 1024, maximumOriginalBytes: 1))
        await #expect(throws: V2ResourceStorageError.capacityExceeded) {
            try await files.importOriginal(data: Data([1,2]), id: .init(), displayName: .init("photo.jpg"), contentType: .init("image/jpeg"),
                purpose: .personalAvatar, maximumBytes: 32, maximumSelections: 1)
        }
        #expect(try await files.snapshot().files.isEmpty)
        #expect(try await files.selectedAssets(purpose: .personalAvatar).isEmpty)
        await files.close(); try await f.remove()
    }

    @Test("in-memory original publication uses the existing interruption journal",
          arguments: V2ResourceFileStore.PublicationCheckpoint.allCases)
    func dataInterruptionRecovery(stage: V2ResourceFileStore.PublicationCheckpoint) async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), id = V2LocalResourceAssetID(), body = Data(repeating: 5, count: 4096)
        let files = try V2ResourceFileStore(root: f.root.appending(path: "resources"), journal: f.journal, policy: .standard) { checkpoint in
            if stage == checkpoint { throw Interrupted() }
        }
        await #expect(throws: Interrupted.self) {
            try await files.importOriginal(data: body, id: id, displayName: .init("photo.png"), contentType: .init("image/png"),
                purpose: .personalAvatar, maximumBytes: 4096, maximumSelections: 1)
        }
        await files.close()
        let restored = try f.files()
        try await restored.reconcileFiles()
        let asset = try #require(try f.journal.localAsset(id))
        if stage == .partialWritten {
            #expect(asset.availability == .unavailable)
            await #expect(throws: V2ResourceStorageError.unavailable) { try await restored.borrowSelection(id) }
        } else {
            #expect(asset.availability == .local && asset.selectionActive)
            let lease = try await restored.borrowSelection(id)
            #expect(try Data(contentsOf: lease.fileURL) == body)
            await lease.release()
        }
        #expect(try await restored.snapshot().transferReservedBytes == 0)
        await restored.close(); try await f.remove()
    }

    @Test("cancellation after data publication releases only the selection and leaves cleanable bytes")
    func cancelledDataPublicationCanBeCleaned() async throws {
        let f = try await Fixture()
        let files = try V2ResourceFileStore(root: f.root.appending(path: "resources"), journal: f.journal, policy: .standard) { checkpoint in
            if checkpoint == .published { throw CancellationError() }
        }
        await #expect(throws: CancellationError.self) {
            try await files.importOriginal(data: Data([4,5,6]), id: .init(), displayName: .init("photo.jpg"), contentType: .init("image/jpeg"),
                purpose: .personalAvatar, maximumBytes: 32, maximumSelections: 1)
        }
        await files.close()
        let restored = try f.files()
        try await restored.reconcileFiles()
        #expect(try await restored.selectedAssets(purpose: .personalAvatar).isEmpty)
        #expect(try await restored.snapshot().files.first?.retention == .cache)
        let cleanup = try await restored.planCleanup()
        #expect(try await restored.commitCleanup(cleanup).deletedCount == 1)
        await restored.close(); try await f.remove()
    }

    @Test("a cancelled selection release is idempotent and cannot release an independent upload")
    func cancelledSelectionCleanupPreservesOtherConsumer() async throws {
        let f = try await Fixture()
        let resources = try await makeResourceTestCenter(store: f.store, root: f.root)
        let selected = try await resources.importLocal(at: f.source, displayName: .init("picked.txt"), contentType: .init("text/plain"), purpose: .personalAvatar)
        let independent = try await resources.importLocal(at: f.source, displayName: .init("picked.txt"), contentType: .init("text/plain"), purpose: .personalAvatar)
        let jobID = UUID()
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .userAvatar,
            contentType: independent.contentType.value, byteCount: independent.byteCount, checksum: independent.checksum, displayName: independent.displayName)
        _ = try await f.store.prepareResourceTransfer(id: jobID, request: request, localAssetID: independent.id)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await resources.discardLocalSelection(selected.id)
            try await resources.discardLocalSelection(selected.id)
        }
        try await cancelled.value
        #expect(try await resources.selectedLocalAssets(purpose: .personalAvatar).isEmpty)
        let lease = try await resources.borrowLocalOriginal(for: .upload(jobID))
        #expect(try Data(contentsOf: lease.fileURL) == Data("original bytes".utf8))
        #expect(try await resources.planCleanup().fileIDs.isEmpty)
        await lease.release(); await resources.close(); try await f.remove()
    }

    private actor CloseWitness {
        private(set) var didClose = false
        func finish() { didClose = true }
    }
    @Test func accountCenterRestoresSelectionsAndCloseWaitsForTheirRealConsumers() async throws {
        let f = try await Fixture()
        let scope = V2AccountStorageScope(incarnation: UUID(), accountID: try f.journal.accountID(), directory: f.root, cacheDirectory: f.root.appending(path: "cache-scope"))
        let center = try await V2ResourceCenter.make(scope: scope, store: f.store)
        let room = RoomID(uuid: UUID())
        let asset = try await center.importLocal(at: f.source, displayName: .init("picked.txt"), contentType: .init("text/plain"), purpose: .messageDraft(room))
        let lease = try await center.borrowLocalSelection(asset.id)
        #expect(try await center.planCleanup().fileIDs.isEmpty)
        let witness = CloseWitness()
        let closing = Task { await center.close(); await witness.finish() }
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            do { _ = try await center.selectedLocalAssets(purpose: .messageDraft(room)) }
            catch V2ResourceStorageError.closed { break }
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        #expect(try Data(contentsOf: lease.fileURL) == Data("original bytes".utf8))
        #expect(await witness.didClose == false)
        await #expect(throws: V2ResourceStorageError.closed) { try await center.borrowLocalSelection(asset.id) }
        await lease.release(); await closing.value
        #expect(await witness.didClose)
        let restored = try await V2ResourceCenter.make(scope: scope, store: f.store)
        #expect(try await restored.selectedLocalAssets(purpose: .messageDraft(room)).map(\.id) == [asset.id])
        try await restored.discardLocalSelection(asset.id)
        let plan = try await restored.planCleanup()
        #expect(try await restored.commitCleanup(plan).deletedCount == 1)
        await restored.close(); try await f.remove()
    }

    private struct Fixture {
        let root: URL, source: URL
        let store: GRDBV2LocalSyncStore
        let journal: V2ResourceFileJournal
        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "resource-assets-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = root.appending(path: "picked.txt")
            try Data("original bytes".utf8).write(to: source)
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
            journal = await store.resourceFileJournal()
        }
        func files() throws -> V2ResourceFileStore { try .init(root: root.appending(path: "resources"), journal: journal, policy: .testBounded(1_048_576)) }
        func remove() async throws { try await store.close(); try FileManager.default.removeItem(at: root) }
        func importAsset(_ files: V2ResourceFileStore, id: V2LocalResourceAssetID = .init(), purpose: V2LocalResourceAssetPurpose = .personalAvatar, maximumSelections: Int = 64) async throws -> V2LocalResourceAsset {
            try await files.importOriginal(source: source, id: id, displayName: .init("../../picked.txt"), contentType: .init("text/plain"),
                purpose: purpose, maximumBytes: 1024, maximumSelections: maximumSelections)
        }
    }

    @Test func selectionsShareBytesWhileRetainingIndependentPurposeAndUserPin() async throws {
        let f = try await Fixture(), files = try f.files(), room = RoomID(uuid: UUID())
        let first = try await f.importAsset(files, purpose: .messageDraft(room))
        let second = try await f.importAsset(files)
        #expect(first.id != second.id && first.fileID == second.fileID)
        #expect(first.displayName.value == "picked.txt")
        #expect(first.availability == .local && first.selectionActive)
        #expect(try await files.snapshot().files.count == 1)
        let file = try #require(first.fileID)
        try await files.setRetained(true, fileID: file)
        #expect(try f.journal.record(file)?.isPinned == true)
        try await files.discardSelection(first.id)
        #expect(try f.journal.record(file)?.retention == .original)
        #expect(try await files.selectedAssets(purpose: .messageDraft(room)).isEmpty)
        #expect(try await files.selectedAssets(purpose: .personalAvatar).map(\.id) == [second.id])
        try await files.discardSelection(second.id)
        #expect(try f.journal.record(file)?.retention == .retained)
        #expect(try await files.planCleanup().fileIDs.isEmpty)
        try await files.setRetained(false, fileID: file)
        #expect(try f.journal.record(file)?.retention == .cache)
        let plan = try await files.planCleanup()
        #expect(try await files.commitCleanup(plan).deletedCount == 1)
        #expect(try f.journal.localAsset(first.id)?.availability == .unavailable)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        await files.close(); try await f.remove()
    }

    @Test func failedTransactionCannotDropDraftAndSameUUIDHandoffCannotDropUpload() async throws {
        struct Rollback: Error {}
        let f = try await Fixture(), files = try f.files()
        let room = RoomID(uuid: UUID())
        let asset = try await f.importAsset(files, purpose: .messageDraft(room)), file = try #require(asset.fileID)
        let consumer = V2LocalResourceOriginalConsumer.upload(asset.id.value)
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: asset.id.value), mediaID: .init(uuid: asset.id.value),
            usage: .messageAttachment(room), contentType: asset.contentType.value, byteCount: asset.byteCount,
            checksum: asset.checksum, displayName: asset.displayName)
        await #expect(throws: Rollback.self) {
            try await f.store.databasePool.write { db in
                _ = try GRDBV2LocalSyncStore.prepareResourceTransfer(id: asset.id.value, request: request,
                    localAssetID: asset.id, now: Date(), db: db)
                _ = try GRDBV2LocalSyncStore.bindLocalResourceAsset(asset.id, consumer: consumer, relinquishSelection: true, db: db)
                throw Rollback()
            }
        }
        #expect(try f.journal.localAsset(asset.id)?.selectionActive == true)
        #expect(try await f.store.resourceTransfer(id: asset.id.value) == nil)
        let lease = try await files.borrowSelection(asset.id)
        try await f.store.databasePool.write { db in
            _ = try GRDBV2LocalSyncStore.prepareResourceTransfer(id: asset.id.value, request: request,
                localAssetID: asset.id, now: Date(), db: db)
            _ = try GRDBV2LocalSyncStore.bindLocalResourceAsset(asset.id, consumer: consumer, relinquishSelection: true, db: db)
        }
        #expect(try await f.store.resourceTransfer(id: asset.id.value)?.stage == .prepared)
        #expect(try f.journal.localAsset(asset.id)?.selectionActive == false)
        #expect(try f.journal.record(file)?.retention == .original)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await files.borrowSelection(asset.id) }
        #expect(try await files.planCleanup().fileIDs.isEmpty)
        // Discarding the UI selection twice cannot remove the upload's claim.
        try await files.discardSelection(asset.id); try await files.discardSelection(asset.id)
        #expect(try f.journal.hasConsumers(file))
        try await f.store.databasePool.write { db in
            try GRDBV2LocalSyncStore.releaseLocalResourceAssetConsumer(asset.id, consumer: consumer, db: db)
        }
        #expect(try f.journal.record(file)?.retention == .cache)
        #expect(try await files.planCleanup().fileIDs.isEmpty)
        #expect(try Data(contentsOf: lease.fileURL) == Data("original bytes".utf8))
        await lease.release()
        let plan = try await files.planCleanup()
        #expect(try await files.commitCleanup(plan).deletedCount == 1)
        await files.close(); try await f.remove()
    }

    @Test(arguments: V2ResourceFileStore.PublicationCheckpoint.allCases)
    func interruptionRecoversAssetAndNeverInventsAReadyPartial(checkpoint: V2ResourceFileStore.PublicationCheckpoint) async throws {
        struct Interrupted: Error {}
        let f = try await Fixture(), assetID = V2LocalResourceAssetID()
        let files = try V2ResourceFileStore(root: f.root.appending(path: "resources"), journal: f.journal, policy: .testBounded(1_048_576)) { stage in
            if stage == checkpoint { throw Interrupted() }
        }
        await #expect(throws: Interrupted.self) { try await f.importAsset(files, id: assetID) }
        await files.close()
        let restored = try f.files()
        try await restored.reconcileFiles()
        let asset = try #require(try f.journal.localAsset(assetID))
        #expect(asset.selectionActive)
        if checkpoint == .partialWritten {
            #expect(asset.availability == .unavailable)
            await #expect(throws: V2ResourceStorageError.unavailable) { try await restored.borrowSelection(assetID) }
        } else {
            #expect(asset.availability == .local)
            let lease = try await restored.borrowSelection(assetID)
            #expect(try Data(contentsOf: lease.fileURL) == Data("original bytes".utf8))
            await lease.release()
            #expect(try await restored.snapshot().files.first?.retention == .original)
        }
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        await restored.close(); try await f.remove()
    }

    @Test func cancellationAfterCopyCannotLeaveAnUnownedProtectedOriginal() async throws {
        let f = try await Fixture(), id = V2LocalResourceAssetID()
        let files = try V2ResourceFileStore(root: f.root.appending(path: "resources"), journal: f.journal, policy: .testBounded(1_048_576)) { stage in
            if stage == .published { throw CancellationError() }
        }
        await #expect(throws: CancellationError.self) { try await f.importAsset(files, id: id) }
        await files.close()
        let restored = try f.files()
        try await restored.reconcileFiles()
        #expect(try await restored.selectedAssets(purpose: .personalAvatar).isEmpty)
        #expect(try await restored.snapshot().files.first?.retention == .cache)
        let plan = try await restored.planCleanup()
        #expect(try await restored.commitCleanup(plan).deletedCount == 1)
        await restored.close(); try await f.remove()
    }

    @Test func selectionAdmissionIsBoundedAndDiscardDoesNotReopenAnOldIdentity() async throws {
        let f = try await Fixture(), files = try f.files()
        let first = try await f.importAsset(files, maximumSelections: 1)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) { try await f.importAsset(files, maximumSelections: 1) }
        #expect(try await files.snapshot().files.count == 1)
        try await files.discardSelection(first.id)
        await #expect(throws: V2ResourceStorageError.conflict) { try await f.importAsset(files, id: first.id, maximumSelections: 1) }
        let second = try await f.importAsset(files, maximumSelections: 1)
        #expect(second.id != first.id && second.fileID == first.fileID)
        await files.close(); try await f.remove()
    }

    @Test func selectedDuplicateCannotReleaseAnIndependentOriginalOwner() async throws {
        let f = try await Fixture(), files = try f.files()
        let digest = try V2ResourceChecksum(value: V2ResourceFileDigest.sha256(fileURL: f.source, expectedByteCount: 14))
        let original = try await files.publishCopy(of: f.source, byteCount: 14, checksum: digest, retention: .original)
        let asset = try await f.importAsset(files)
        #expect(asset.fileID == original)
        try await files.discardSelection(asset.id)
        try await files.setRetained(false, fileID: original)
        #expect(try f.journal.record(original)?.retention == .original)
        #expect(try await files.planCleanup().fileIDs.isEmpty)
        await files.close(); try await f.remove()
    }

    @Test func catalogOwnershipWritesNeverInvalidateChatOrAvatarAuthority() async throws {
        let f = try await Fixture(), files = try f.files()
        let subscription = await f.store.projectionChanges()
        var changes = subscription.makeAsyncIterator()
        _ = await changes.next()
        let asset = try await f.importAsset(files)
        let change = try #require(await changes.next())
        #expect(change.scopes == .resources && !change.requiresImmediateRefresh)
        let file = try #require(asset.fileID)
        try await files.setRetained(true, fileID: file)
        #expect(await changes.next()?.scopes == .resources)
        try await files.discardSelection(asset.id)
        #expect(await changes.next()?.scopes == .resources)
        await files.close(); try await f.remove()
    }
}
