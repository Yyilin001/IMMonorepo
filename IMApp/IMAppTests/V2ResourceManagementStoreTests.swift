import CryptoKit
import Foundation
import GRDB
import IMV2Core
import Observation
import QuickLook
import Synchronization
import Testing
import UIKit
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Resource management page state", .timeLimit(.minutes(1)))
struct V2ResourceManagementStoreTests {
    @Test func storageReloadPublishesOnlyChangedFactsAndKeepsPreviousContentOnFailure() async throws {
        let f = try await Fixture()
        let page = V2ResourceStorageStore(service: f.service)
        await page.reload()
        let original = try #require(page.content.snapshot)
        let contentChanges = Mutex(0), networkChanges = Mutex(0)
        withObservationTracking { _ = page.content } onChange: { contentChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = page.downloadNetworkPreferences } onChange: { networkChanges.withLock { $0 += 1 } }
        await page.reload(); await page.reload()
        #expect(contentChanges.withLock { $0 } == 0)
        #expect(networkChanges.withLock { $0 } == 0)

        var network = try #require(page.downloadNetworkPreferences)
        network.allowsCellular.toggle()
        try await f.center.setDownloadNetworkPreferences(network)
        await page.reload()
        #expect(page.downloadNetworkPreferences == network)
        #expect(networkChanges.withLock { $0 } == 1)
        #expect(contentChanges.withLock { $0 } == 0)

        page.changeCacheLimit(128 * 1024 * 1024)
        await page.execute(try #require(page.command))
        #expect(contentChanges.withLock { $0 } == 1)
        let latest = try #require(page.content.snapshot)
        #expect(latest.quota.policy.maximumCacheBytes == 128 * 1024 * 1024)
        #expect(latest.files == original.files)

        await f.center.close()
        await page.reload()
        guard case .failed(let previous, _) = page.content else {
            Issue.record("Closed resource center must expose a failed read"); try await f.close(); return
        }
        #expect(previous == latest)
        let repeatedFailureChanges = Mutex(0)
        withObservationTracking { _ = page.content } onChange: { repeatedFailureChanges.withLock { $0 += 1 } }
        await page.reload()
        #expect(repeatedFailureChanges.withLock { $0 } == 0)
        #expect(page.content.snapshot == latest)
        try await f.close()
    }

    @Test func detailSourcesCannotUseAStalePageCursorOrRestartAtTheEnd() async throws {
        let f = try await Fixture(), resource = try await f.add(name: "many-sources.png")
        for _ in 0..<100 {
            try await f.local.indexResource(resource,
                reference: .message(.init(roomID: f.room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
        }
        let detail = V2ResourceDetailStore(key: resource.key, service: f.service)
        await detail.reload()
        let first = try #require(detail.content.snapshot)
        #expect(first.sources.count == 50)
        detail.nextSources(); await detail.reload()
        let second = try #require(detail.content.snapshot)
        #expect(second.sources.count == 50 && second.nextSourceCursor != nil)
        #expect(Set(first.sources).isDisjoint(with: second.sources))
        detail.firstSources()
        // The previous page is still displayed until the new local read ends.
        detail.nextSources()
        #expect(detail.sourceCursor == nil)
        await detail.reload()
        #expect(detail.content.snapshot?.sources == first.sources)
        detail.firstSources(); await detail.reload()
        detail.nextSources(); await detail.reload()
        detail.nextSources(); await detail.reload()
        let last = try #require(detail.content.snapshot)
        #expect(last.sources.count == 1 && last.nextSourceCursor == nil)
        #expect(Set(first.sources + second.sources + last.sources).count == 101)
        let terminalCursor = try #require(detail.sourceCursor)
        detail.nextSources()
        #expect(detail.sourceCursor == terminalCursor)
        try await f.close()
    }

    @Test func successfulCloudRequestNeedsANewCommandToAdvanceTheStoredCursor() async throws {
        let f = try await Fixture(), descriptor = try await f.add(name: "cloud-result.png")
        let directory = PagedDirectory(descriptor: descriptor)
        let service = V2ResourceManagementService(center: f.center, localStore: f.local, downloader: f.network, directory: directory)
        let page = V2ResourceLibraryStore(room: f.room, service: service)
        page.requestCloud(restart: true)
        let first = try #require(page.cloudRequest)
        await page.synchronize(first); await page.synchronize(first)
        guard case .available(let more) = page.cloud else { Issue.record("Missing first cloud result"); try await f.close(); return }
        #expect(more)
        #expect(await directory.calls == 1)
        page.requestCloud(restart: false)
        let next = try #require(page.cloudRequest)
        await page.synchronize(next); await page.synchronize(next)
        guard case .available(let remaining) = page.cloud else { Issue.record("Missing final cloud result"); try await f.close(); return }
        #expect(!remaining)
        #expect(await directory.calls == 2)
        #expect(try await f.local.resourceDirectoryScan(roomID: f.room)?.query.cursor == nil)
        try await f.close()
    }
    @Test func selectionCommandCannotBeReenteredWhileItsDatabaseRequestFails() async throws {
        let f = try await Fixture(), resource = try await f.add(name: "selected-once.png")
        let attempts = Mutex(0)
        try await f.local.databasePool.write { db in
            db.add(function: DatabaseFunction("selection_retention_attempt", argumentCount: 0, pure: false) { _ in
                attempts.withLock { $0 += 1 }; return 1
            })
            try db.execute(sql: "CREATE TRIGGER deny_selection_retention BEFORE INSERT ON v2_resource_retention_intents BEGIN SELECT selection_retention_attempt(); SELECT RAISE(ABORT,'controlled retention failure'); END")
        }
        let selection = V2ResourceSelectionStore(service: f.service)
        selection.toggleMode(); selection.toggle(resource.key); selection.retain(true)
        let request = try #require(selection.command)
        async let first: Void = selection.execute(request)
        async let duplicate: Void = selection.execute(request)
        _ = await (first, duplicate)
        await selection.execute(request)
        #expect(attempts.withLock { $0 } == 1)
        #expect(!selection.isBusy && selection.selected == [resource.key])
        try await f.local.databasePool.write { try $0.execute(sql: "DROP TRIGGER deny_selection_retention") }
        selection.retain(true); await selection.execute(try #require(selection.command))
        #expect(try await f.center.variants(for: resource.key).first?.isRetained == true)
        #expect(selection.selected == [])
        try await f.close()
    }

    @Test func batchTransferCommandCannotBeReenteredWhileItsDatabaseRequestFails() async throws {
        let f = try await Fixture(), upload = try await f.attentionUpload(), attempts = Mutex(0)
        try await f.local.databasePool.write { db in
            db.add(function: DatabaseFunction("batch_retry_attempt", argumentCount: 0, pure: false) { _ in
                attempts.withLock { $0 += 1 }; return 1
            })
            try db.execute(sql: "CREATE TRIGGER deny_reentrant_batch BEFORE UPDATE ON v2_resource_transfer_jobs WHEN OLD.job_id='\(upload.id.uuidString)' BEGIN SELECT batch_retry_attempt(); SELECT RAISE(ABORT,'controlled retry failure'); END")
        }
        let page = V2ResourceTransferStore(service: f.service)
        page.group = .attention
        let observation = Task { await page.observe() }
        try await eventually { page.canBeginBatchSelection }
        page.toggleBatchMode(); page.selectBatchPage(); page.requestBatch(.retry)
        let request = try #require(page.batchCommand)
        async let first: Void = page.executeBatch(request)
        async let duplicate: Void = page.executeBatch(request)
        _ = await (first, duplicate)
        await page.executeBatch(request)
        #expect(attempts.withLock { $0 } == 1)
        #expect(!page.isPerforming && page.batchSelection == [.upload(upload.id)])
        try await f.local.databasePool.write { try $0.execute(sql: "DROP TRIGGER deny_reentrant_batch") }
        page.requestBatch(.retry); await page.executeBatch(try #require(page.batchCommand))
        #expect(try await f.local.resourceTransfer(id: upload.id)?.needsAttention == false)
        observation.cancel(); await observation.value; try await f.close()
    }

    @Test func transferPagingCannotConsumeThePreviousGroupsCursor() async throws {
        let f = try await Fixture()
        for _ in 0..<51 {
            let work = try await f.importRequest(), owner = UUID()
            try #require(try await f.local.claimResourceImport(work.id, owner: owner))
            try await f.local.saveResourceImport(.init(locator: .init(home: .room(f.room), operationID: work.request.operationID),
                mediaID: work.request.targetMediaID, state: .cancelled, bindableUntil: nil), id: work.id, owner: owner)
            try await f.local.releaseResourceImportExecution(work.id, owner: owner)
        }
        _ = try await f.attentionUpload()
        let page = V2ResourceTransferStore(service: f.service)
        page.group = .finished
        let active = Task { await page.observe() }
        try await eventually { page.content.page?.nextCursor != nil }
        active.cancel(); await active.value
        page.group = .attention
        page.nextPage()
        #expect(page.before == nil && page.pageNumber == 1)
        // Continue positive checks independently if the old implementation accepted the stale cursor.
        page.group = .finished; page.group = .attention
        let attention = Task { await page.observe() }
        try await eventually { page.canBeginBatchSelection }
        #expect(page.content.page?.entries.count == 1 && page.content.page?.nextCursor == nil)
        attention.cancel(); await attention.value
        page.group = .finished
        let restored = Task { await page.observe() }
        try await eventually { page.content.page?.entries.count == 50 && page.content.page?.nextCursor != nil }
        restored.cancel(); await restored.value
        page.nextPage(); #expect(page.before != nil && page.pageNumber == 2)
        page.previousPage(); #expect(page.before == nil && page.pageNumber == 1)
        try await f.close()
    }

    @Test func transferReadFailureRetainsRowsButRetiredAccountClearsThem() async throws {
        let f = try await Fixture(), upload = try await f.attentionUpload()
        let page = V2ResourceTransferStore(service: f.service)
        page.group = .attention
        var observer = Task { await page.observe() }
        try await eventually { page.canBeginBatchSelection }
        let ids = try #require(page.content.page?.entries.map(\.id))
        observer.cancel(); await observer.value
        try await f.local.databasePool.write { try $0.execute(sql: "ALTER TABLE v2_resource_transfer_jobs RENAME TO temporarily_unreadable_transfers") }
        await page.observe()
        #expect(page.content.page?.entries.map(\.id) == ids)
        #expect(page.readFailure != nil && !page.hasCurrentPage)
        #expect(!page.canBeginBatchSelection && !page.canGoNextPage)
        page.retry(.upload(upload.id))
        #expect(page.command == nil)
        try await f.local.databasePool.write { try $0.execute(sql: "ALTER TABLE temporarily_unreadable_transfers RENAME TO v2_resource_transfer_jobs") }
        let observation = page.observationID
        page.retryRead()
        #expect(page.observationID != observation && !page.hasCurrentPage)
        observer = Task { await page.observe() }
        try await eventually { page.canBeginBatchSelection }
        #expect(page.readFailure == nil && page.hasCurrentPage)
        #expect(page.content.page?.entries.map(\.id) == ids)
        await f.center.close()
        await observer.value
        #expect(page.content.page == nil)
        #expect(await f.network.calls == 0)
        try await f.close()
    }

    @Test func detailReadFailureKeepsMetadataUntilRecoveryButNeverGrantsFileActions() async throws {
        let f = try await Fixture(), resource = try await f.add(name: "kept-details.png")
        let detail = V2ResourceDetailStore(key: resource.key, service: f.service)
        await detail.reload()
        let previous = try #require(detail.content.snapshot)
        // Fault a real local read without deleting metadata or inventing an
        // authorization response. Restoring the table restores the same facts.
        try await f.local.databasePool.write { try $0.execute(sql: "ALTER TABLE v2_resource_variants RENAME TO temporarily_unreadable_variants") }
        await detail.reload()
        #expect(detail.content.snapshot == previous)
        #expect(detail.readFailure != nil && !detail.hasCurrentDetails)
        detail.download(); detail.present(.preview); detail.setRetained(true)
        #expect(detail.command == nil)
        try await f.local.databasePool.write { try $0.execute(sql: "ALTER TABLE temporarily_unreadable_variants RENAME TO v2_resource_variants") }
        detail.retryRead()
        await detail.execute(try #require(detail.command))
        #expect(detail.content.snapshot == previous)
        #expect(detail.readFailure == nil && detail.hasCurrentDetails)
        detail.setRetained(true)
        await detail.execute(try #require(detail.command))
        #expect(detail.original?.isRetained == true)
        let source = try #require(detail.content.snapshot?.sources.first)
        try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        await detail.reload()
        #expect(detail.content.snapshot == nil && detail.presentation == nil)
        try await f.close()
    }

    @Test func detailAccountClosureCannotKeepThePreviousMetadata() async throws {
        let f = try await Fixture(), resource = try await f.add(name: "retired-account.png")
        let detail = V2ResourceDetailStore(key: resource.key, service: f.service)
        await detail.reload()
        #expect(detail.content.snapshot != nil)
        await f.center.close()
        await detail.reload()
        #expect(detail.content.snapshot == nil && detail.presentation == nil)
        try await f.close()
    }

    @Test func detailCommandReentryAndReplayDoNotRepeatTheRetentionRequest() async throws {
        let f = try await Fixture(), resource = try await f.add(name: "detail-once.png")
        let detail = V2ResourceDetailStore(key: resource.key, service: f.service)
        await detail.reload()
        try await f.local.databasePool.write { db in
            try db.execute(sql: "CREATE TABLE detail_retention_requests(value INTEGER NOT NULL)")
            try db.execute(sql: "CREATE TRIGGER record_detail_retention_request BEFORE INSERT ON v2_resource_retention_intents BEGIN INSERT INTO detail_retention_requests VALUES(1); END")
        }
        detail.setRetained(true)
        let command = try #require(detail.command)
        async let first: Void = detail.execute(command)
        async let duplicate: Void = detail.execute(command)
        _ = await (first, duplicate)
        await detail.execute(command)
        let attempts = try await f.local.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM detail_retention_requests") }
        #expect(attempts == 1)
        #expect(detail.original?.isRetained == true && !detail.isWorking)
        detail.setRetained(false); await detail.execute(try #require(detail.command))
        #expect(detail.original?.isRetained == false)
        try await f.close()
    }

    @Test func cloudDirectoryRequestCannotBeReenteredOrReplayedButCanBeRetried() async throws {
        let f = try await Fixture(), page = V2ResourceLibraryStore(room: f.room, service: f.service)
        page.requestCloud(restart: true)
        let request = try #require(page.cloudRequest)
        async let first: Void = page.synchronize(request)
        async let duplicate: Void = page.synchronize(request)
        _ = await (first, duplicate)
        await page.synchronize(request)
        let initialCalls = await f.network.calls
        #expect(initialCalls == 1)
        guard case .failed = page.cloud else { Issue.record("Controlled directory failure was not reported"); try await f.close(); return }
        page.requestCloud(restart: true)
        let retry = try #require(page.cloudRequest)
        #expect(retry.id != request.id)
        await page.synchronize(request)
        await page.synchronize(retry)
        let callsAfterRetry = await f.network.calls
        #expect(callsAfterRetry == 2)
        try await f.close()
    }

    @Test func changingDirectoryQueryCannotPageUsingThePreviousQueriesCursor() async throws {
        let f = try await Fixture()
        for number in 0..<51 { _ = try await f.add(name: "image-\(number).png") }
        let document = try await f.add(name: "latest-document.pdf", type: "application/pdf")
        let page = V2ResourceLibraryStore(room: nil, service: f.service)
        let first = Task { await page.observe() }
        try await eventually { page.content.page?.entries.count == 50 }
        let previousImage = try #require(page.content.page?.entries.first(where: { $0.descriptor.kind == .image })?.descriptor.key)
        #expect(page.content.page?.nextCursor != nil)
        page.nextPage(); page.nextPage()
        #expect(page.pageNumber == 2)
        page.previousPage()
        #expect(page.pageNumber == 1)
        page.category = .file
        #expect(!page.hasCurrentPage && !page.canGoNextPage)
        page.nextPage()
        #expect(page.pageNumber == 1 && page.before == nil)
        first.cancel(); await first.value
        let updated = Task { await page.observe() }
        try await eventually { page.content.page?.entries.count != 50 }
        #expect(page.content.page?.entries.map(\.descriptor.key) == [document.key])
        #expect(!page.isCurrentPageResource(previousImage) && page.isCurrentPageResource(document.key))
        #expect(await f.network.calls == 0)
        updated.cancel(); await updated.value
        try await f.close()
    }

    @Test func storageCommandReentryWritesTheRequestedPolicyOnlyOnce() async throws {
        let f = try await Fixture()
        let page = V2ResourceStorageStore(service: f.service)
        await page.reload()
        try await f.local.databasePool.write { db in
            try db.execute(sql: "CREATE TABLE storage_policy_writes(value INTEGER NOT NULL)")
            try db.execute(sql: "CREATE TRIGGER record_storage_policy_write AFTER UPDATE ON v2_resource_storage_policy BEGIN INSERT INTO storage_policy_writes VALUES(1); END")
        }
        let expectedLimit: Int64 = 128 * 1024 * 1024
        page.changeCacheLimit(expectedLimit)
        #expect(page.isBusy && page.isUpdatingPolicy)
        let command = try #require(page.command)
        async let first: Void = page.execute(command)
        async let repeated: Void = page.execute(command)
        _ = await (first, repeated)
        await page.execute(command)
        let writes = try await f.local.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM storage_policy_writes") }
        #expect(writes == 1)
        let confirmedLimit = try #require(page.content.snapshot?.quota.policy.maximumCacheBytes)
        #expect(confirmedLimit == expectedLimit)
        #expect(!page.isBusy && !page.isUpdatingPolicy)
        #expect(page.policyMessage == "缓存额度已更新。")
        try await f.close()
    }

    @Test(arguments: [false, true])
    func cancelledStoragePreviewAndCommitAllowANewReviewedCleanup(_ committing: Bool) async throws {
        let f = try await Fixture(), file = try await f.publish(byte: 6, retention: .cache)
        let page = V2ResourceStorageStore(service: f.service)
        await page.reload()
        page.previewCleanup()
        if committing {
            await page.execute(try #require(page.command))
            page.commitCleanup()
        }
        let cancelled = try #require(page.command)
        let task = Task { await page.execute(cancelled) }
        task.cancel()
        await task.value
        #expect(!page.isBusy && !page.cleanup.isCommitting)
        guard case .failed(let message) = page.cleanup else {
            Issue.record("Cancelled cleanup remained in a working phase"); try await f.close(); return
        }
        #expect(message == "操作已中断，请重新预览可清理内容。")
        #expect(try await f.center.storageSnapshot().files.first(where: { $0.id == file })?.state == .published)
        page.previewCleanup()
        #expect(page.command?.id != cancelled.id)
        await page.execute(try #require(page.command))
        #expect(page.cleanup.plan?.fileIDs == [file])
        page.commitCleanup(); await page.execute(try #require(page.command))
        guard case .finished(let result) = page.cleanup else {
            Issue.record("Fresh reviewed cleanup did not finish"); try await f.close(); return
        }
        #expect(result.deletedCount == 1 && result.releasedBytes > 0 && !page.isBusy)
        try await f.close()
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    func unsupportedResourceSchemaRejectsBothOpenModesWithoutErasingFacts(_ shape: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "resource-schema-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = V2LocalInstallationBinding(value: UUID()), user = UserID(uuid: UUID())
        let database = root.appending(path: "V2.sqlite")
        let original = root.appending(path: "pending-original")
        let store = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: user)
        let bytes = Data("unique pending original".utf8)
        try bytes.write(to: original)
        try await store.databasePool.write { db in
            try db.execute(sql: "CREATE TABLE schema_rejection_sentinel(value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO schema_rejection_sentinel VALUES('keep account facts')")
            switch shape {
            case 0...2:
                try db.execute(sql: "ALTER TABLE v2_resource_retention_intents DROP COLUMN intent_id")
                if shape == 1 { try db.execute(sql: "ALTER TABLE v2_resource_retention_intents ADD COLUMN intent_id TEXT") }
                if shape == 2 { try db.execute(sql: "ALTER TABLE v2_resource_retention_intents ADD COLUMN intent_id INTEGER NOT NULL DEFAULT 0") }
            case 3: try db.execute(sql: "DROP TABLE v2_resource_file_operations")
            case 4: try db.execute(sql: "DROP INDEX v2_resource_entries_type")
            case 5:
                try db.execute(sql: "DROP INDEX v2_resource_entries_type")
                try db.execute(sql: "CREATE INDEX v2_resource_entries_type ON v2_resource_entries(media_id)")
            case 6: try db.execute(sql: "ALTER TABLE v2_resource_entries ADD COLUMN legacy_marker TEXT")
            case 7:
                try db.execute(sql: "DROP TABLE v2_resource_file_operations")
                try db.execute(sql: "CREATE TABLE v2_resource_file_operations(file_id TEXT PRIMARY KEY REFERENCES v2_resource_files(file_id),kind TEXT NOT NULL,source_storage TEXT,target_storage TEXT)")
            case 8: try db.execute(sql: "DROP TRIGGER resource_access_message_revision")
            default: try db.execute(sql: "CREATE TABLE v2_resource_legacy_queue(id TEXT PRIMARY KEY)")
            }
        }
        try await store.close()
        await #expect(throws: V2ClientLocalStorageError.unsupportedResourceSchema) {
            let reopened = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: user)
            try await reopened.close()
        }
        await #expect(throws: V2ClientLocalStorageError.unsupportedResourceSchema) {
            let reopened = try GRDBV2LocalSyncStore(localReadOnlyDatabaseURL: database, installationBinding: binding, userID: user)
            try await reopened.close()
        }
        let retained = try DatabaseQueue(path: database.path)
        #expect(try await retained.read { try String.fetchOne($0, sql: "SELECT value FROM schema_rejection_sentinel") } == "keep account facts")
        #expect(try Data(contentsOf: original) == bytes)
        try retained.close()
    }

    @Test func unavailableRetentionReleasesOnlyFrozenInvisibleIntentsAndProtectsSharedBytes() async throws {
        let f = try await Fixture(), bytes = PreviewBytes()
        let gone = try await f.add(name: "private.png", checksum: bytes.checksum)
        let visible = try await f.add(name: "visible.png", checksum: bytes.checksum)
        let boundary = SelectionBytes(values: [gone.key.mediaID: bytes, visible.key.mediaID: bytes])
        let downloader = V2ForegroundConversationMediaDownloader(cache: try await f.center.downloadCache(using: .init(targetResolver: boundary, byteTransfer: boundary)), center: f.center)
        let source = try #require(try await f.center.details(for: gone.key)?.sources.first)
        let downloaded = try await downloader.download(.init(mediaID: gone.key.mediaID), message: source.location)
        let lease = try await downloaded.borrowFile()
        try await f.center.setRetained(true, variant: .init(resource: gone.key))
        try await f.center.setRetained(true, variant: .init(resource: visible.key))
        try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        #expect(try await f.center.details(for: gone.key) == nil)
        let store = V2ResourceStorageStore(service: f.service)
        await store.reload()
        store.previewUnavailableRetention()
        let pending = try #require(store.command)
        store.previewCleanup(); store.changeCacheLimit(1)
        #expect(store.command == pending)
        await store.execute(pending)
        #expect(store.retentionPlan?.count == 1 && !store.isManagingRetention)
        store.releaseUnavailableRetention(); await store.execute(try #require(store.command))
        #expect(store.retentionPlan == nil && store.retentionMessage?.contains("已解除 1 项保留") == true)
        let journal = await f.local.resourceFileJournal()
        #expect(try journal.variant(.init(resource: gone.key))?.isRetained == false)
        #expect(try journal.variant(.init(resource: visible.key))?.isRetained == true)
        let protected = try await f.center.planCleanup()
        #expect(protected.fileIDs.isEmpty)
        // Releasing retention does not invalidate an already-owned reader.
        #expect(try Data(contentsOf: lease.fileURL) == bytes.bytes)
        await lease.release()
        let sharedProtection = try await f.center.planCleanup()
        #expect(sharedProtection.fileIDs.isEmpty)
        #expect(try journal.variant(.init(resource: visible.key))?.fileID != nil)
        try await f.center.setRetained(false, variant: .init(resource: visible.key))
        let cleanup = try await f.center.commitCleanup(try await f.center.planCleanup())
        #expect(cleanup.deletedCount == 1 && cleanup.releasedBytes > 0)
        try await f.close()
    }

    @Test func unavailableRetentionRechecksRestoredAuthorityNewIntentAndAccountScope() async throws {
        let f = try await Fixture(), other = try await Fixture()
        let resource = try await f.add(name: "secret.png"), key = V2ResourceVariantKey(resource: resource.key)
        let source = try #require(try await f.center.details(for: resource.key)?.sources.first)
        let journal = await f.local.resourceFileJournal()
        let sameTime = Date(timeIntervalSince1970: 100)
        try journal.setVariantRetained(true, key: key, now: sameTime)
        try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        let plan = try await f.center.planUnavailableRetentionRelease()
        #expect(plan.count == 1)
        await #expect(throws: V2AccountStorageError.scopeMismatch) { try await other.center.releaseUnavailableRetention(plan) }
        try await f.local.indexResource(resource, reference: .message(source.location, ordinal: source.ordinal), businessRevision: 3)
        let restored = try await f.center.releaseUnavailableRetention(plan)
        #expect(restored.releasedCount == 0 && restored.skippedCount == 1)
        try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 4)
        try journal.setVariantRetained(false, key: key, now: sameTime)
        try await f.local.indexResource(resource, reference: .message(source.location, ordinal: source.ordinal), businessRevision: 5)
        try journal.setVariantRetained(true, key: key, now: sameTime)
        try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 6)
        let newer = try await f.center.releaseUnavailableRetention(plan)
        #expect(newer.releasedCount == 0 && newer.skippedCount == 1)
        #expect(try journal.variant(key)?.isRetained == true)
        let current = try await f.center.planUnavailableRetentionRelease()
        let expired = V2ResourceUnavailableRetentionPlan(id: current.id, count: current.count, hasMore: current.hasMore,
            expiresAt: Date.distantPast, scope: current.scope, selections: current.selections)
        await #expect(throws: V2ResourceStorageError.expiredCleanupPlan) { try await f.center.releaseUnavailableRetention(expired) }
        #expect(try await f.center.releaseUnavailableRetention(current).releasedCount == 1)
        #expect(try await f.center.releaseUnavailableRetention(current).skippedCount == 1)
        try await other.close(); try await f.close()
    }

    @Test func unavailableRetentionPlanIsBoundedAndHandlesMissingLocalBytes() async throws {
        let f = try await Fixture()
        let journal = await f.local.resourceFileJournal()
        for index in 0..<101 {
            let resource = try await f.add(name: "hidden-\(index).png")
            let source = try #require(try await f.center.details(for: resource.key)?.sources.first)
            try await f.center.setRetained(true, variant: .init(resource: resource.key))
            try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        }
        let first = try await f.center.planUnavailableRetentionRelease()
        #expect(first.count == 100 && first.hasMore)
        #expect(try await f.center.releaseUnavailableRetention(first).releasedCount == 100)
        let last = try await f.center.planUnavailableRetentionRelease()
        #expect(last.count == 1 && !last.hasMore)
        #expect(try journal.unavailableRetentionSelections().values.count == 1)
        #expect(try await f.center.releaseUnavailableRetention(last).releasedCount == 1)
        #expect(try await f.center.planUnavailableRetentionRelease().count == 0)
        try await f.close()
    }

    @Test func batchRetrySeparatesCancellationAndKeepsPausedWorkAndServerWait() async throws {
        let f = try await Fixture(), upload = try await f.attentionUpload()
        let cancelling = try await f.importRequest()
        try await f.local.freezeSendIntent(.init(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "cancelled", attachmentJobIDs: [cancelling.id]))
        try await f.center.cancelPreparation(try await f.center.planPreparationCancellation(.serverImport(cancelling.id)))
        try await f.local.pauseResourceImport(id: cancelling.id, needsAttention: true)
        let paused = try await f.importRequest()
        try await f.center.pauseTransfer(.serverImport(paused.id))
        let retryAfter = Date(timeIntervalSince1970: 2_000_000_000)
        try await f.local.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_import_jobs SET server_retry_not_before=? WHERE job_id=?", arguments: [retryAfter.timeIntervalSince1970, cancelling.id.uuidString])
        }
        let result = try await f.service.retryTransfers([.upload(upload.id), .upload(upload.id), .serverImport(cancelling.id), .serverImport(paused.id), .download(UUID())], action: .retry)
        #expect(result.items.count == 4 && result.requestedCount == 1 && result.skippedCount == 3 && result.failedIDs.isEmpty)
        #expect(try await f.local.resourceTransfer(id: upload.id)?.request == upload.request)
        #expect(try await f.local.resourceTransfer(id: upload.id)?.needsAttention == false)
        #expect(try await f.local.preparingSendIntents().isEmpty)
        let pending = try await f.local.managedResourceTransfers(.init(group: .attention)).entries
        #expect(pending.first(where: { $0.id == .serverImport(paused.id) })?.phase == .paused)
        #expect(pending.first(where: { $0.id == .serverImport(cancelling.id) })?.actions == [.retryCancellation])
        let confirmation = try await f.service.retryTransfers([.upload(upload.id), .serverImport(cancelling.id), .serverImport(paused.id)], action: .confirmCancellation)
        #expect(confirmation.requestedCount == 1 && confirmation.skippedCount == 2 && confirmation.failedIDs.isEmpty)
        let original = try #require(try await f.local.resourceImport(id: cancelling.id))
        #expect(original.cancellationRequested && original.request == cancelling.request && original.attempts == 0)
        let retryAt = try await f.local.databasePool.read { try Double.fetchOne($0, sql: "SELECT retry_at FROM v2_resource_import_jobs WHERE job_id=?", arguments: [cancelling.id.uuidString]) }
        #expect(retryAt == retryAfter.timeIntervalSince1970)
        #expect(try await f.local.preparingSendIntents().isEmpty)
        #expect(await f.network.calls == 0)
        try await f.close()
    }

    @Test func batchRetryReportsPartialDatabaseFailureAndLeavesOnlyFailedItemSelected() async throws {
        let f = try await Fixture(), first = try await f.attentionUpload(), second = try await f.attentionUpload()
        let page = V2ResourceTransferStore(service: f.service)
        page.group = .attention
        let observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.count == 2 }
        page.toggleBatchMode(); page.selectBatchPage()
        try await f.local.databasePool.write { db in
            try db.execute(sql: "CREATE TRIGGER deny_batch_item BEFORE UPDATE ON v2_resource_transfer_jobs WHEN OLD.job_id='\(first.id.uuidString)' BEGIN SELECT RAISE(ABORT,'controlled retry failure'); END")
        }
        page.requestBatch(.retry)
        await page.executeBatch(try #require(page.batchCommand))
        #expect(page.feedback == "已请求 1 项，跳过 0 项，失败 1 项。")
        #expect(page.batchSelection == [.upload(first.id)] && page.batchFailures.count == 1 && !page.isPerforming)
        #expect(try await f.local.resourceTransfer(id: first.id)?.needsAttention == true)
        #expect(try await f.local.resourceTransfer(id: second.id)?.needsAttention == false)
        try await f.local.databasePool.write { try $0.execute(sql: "DROP TRIGGER deny_batch_item") }
        page.requestBatch(.retry); await page.executeBatch(try #require(page.batchCommand))
        #expect(page.batchSelection == [] && page.feedback == "已请求 1 项，跳过 0 项，失败 0 项。")
        #expect(try await f.local.resourceTransfer(id: first.id)?.request == first.request)
        #expect(try await f.local.resourceTransfer(id: second.id)?.request == second.request)
        #expect(await f.network.calls == 0)
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func batchUsesFrozenIdentitiesAndClearsSelectionAfterAConcurrentGroupChange() async throws {
        let f = try await Fixture(), first = try await f.attentionUpload(), second = try await f.attentionUpload()
        let page = V2ResourceTransferStore(service: f.service)
        page.group = .attention
        let observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.count == 2 }
        page.toggleBatchMode(); page.selectBatchPage(); page.requestBatch(.retry)
        let request = try #require(page.batchCommand)
        try await f.center.retryTransfer(.upload(first.id))
        page.toggleBatchSelection(.upload(second.id)); page.retry(.upload(second.id))
        page.group = .active
        #expect(Set(request.transfers) == [.upload(first.id), .upload(second.id)] && page.batchCommand == request)
        await page.executeBatch(request)
        #expect(!page.isPerforming && page.batchSelection == nil)
        #expect(try await f.local.resourceTransfer(id: first.id)?.needsAttention == false)
        #expect(try await f.local.resourceTransfer(id: second.id)?.needsAttention == false)
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func pendingSingleCommandCannotBeOvertakenByBatchSelection() async throws {
        let f = try await Fixture(), upload = try await f.attentionUpload()
        let page = V2ResourceTransferStore(service: f.service)
        page.group = .attention
        let observer = Task { await page.observe() }
        try await eventually { page.canBeginBatchSelection }
        page.retry(.upload(upload.id)); let request = try #require(page.command)
        page.toggleBatchMode(); #expect(page.batchSelection == nil && page.isPerforming)
        await page.execute(request)
        #expect(!page.isPerforming && page.performing == nil)
        #expect(try await f.local.resourceTransfer(id: upload.id)?.needsAttention == false)
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func batchSelectionWaitsForTheCurrentGroupsLocalSnapshot() async throws {
        let f = try await Fixture()
        let active = try await f.attentionUpload(markAttention: false)
        _ = try await f.attentionUpload()
        let page = V2ResourceTransferStore(service: f.service)
        var observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.count == 1 }
        page.group = .attention; page.toggleBatchMode(); page.pause(.upload(active.id))
        #expect(page.batchSelection == nil && !page.canBeginBatchSelection && page.command == nil)
        observer.cancel(); await observer.value
        observer = Task { await page.observe() }
        try await eventually { page.canBeginBatchSelection }
        page.toggleBatchMode(); #expect(page.batchSelection == [])
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func cancelledBatchDoesNotResetOriginalRetryWork() async throws {
        let f = try await Fixture(), upload = try await f.attentionUpload()
        let task = Task { try await f.service.retryTransfers([.upload(upload.id)], action: .retry) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await f.local.resourceTransfer(id: upload.id)?.needsAttention == true)
        #expect(await f.network.calls == 0)
        try await f.close()
    }
    @Test func retentionBatchDeduplicatesAndRechecksVisibilityAndExistingIntent() async throws {
        let f = try await Fixture()
        let first = try await f.add(name: "first.txt", type: "text/plain")
        let unchanged = try await f.add(name: "unchanged.txt", type: "text/plain")
        let revoked = try await f.add(name: "revoked.txt", type: "text/plain")
        try await f.center.setRetained(true, variant: .init(resource: unchanged.key))
        let source = try #require(try await f.center.details(for: revoked.key)?.sources.first)
        try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        let result = try await f.service.setRetained(true, resources: [first.key, first.key, unchanged.key, revoked.key])
        #expect(result.items.count == 3 && result.changedCount == 1 && result.skippedCount == 2 && result.failedKeys.isEmpty)
        #expect(result.unchangedCount == 1 && result.unavailableCount == 1)
        #expect(try await f.center.variants(for: first.key).first?.isRetained == true)
        let journal = await f.local.resourceFileJournal()
        #expect(try journal.variant(.init(resource: revoked.key))?.isRetained == false)
        #expect(await f.network.calls == 0)
        try await f.close()
    }

    @Test func selectionFreezesCommandAndClearsWhenQueryChanges() async throws {
        let f = try await Fixture(), first = try await f.add(name: "first.png"), other = try await f.add(name: "other.png")
        let selection = V2ResourceSelectionStore(service: f.service)
        selection.toggleMode(); selection.toggle(first.key); selection.retain(true)
        let command = try #require(selection.command)
        selection.toggle(other.key); selection.toggleMode(); selection.resetForQueryChange()
        #expect(selection.isBusy && selection.selected == [first.key] && selection.command == command)
        await selection.execute(command)
        #expect(!selection.isBusy && !selection.isSelecting)
        #expect(try await f.center.variants(for: first.key).first?.isRetained == true)
        #expect(try await f.center.variants(for: other.key).first?.isRetained == false)
        selection.toggleMode(); selection.selectPage([first.key, other.key, first.key]); #expect(selection.selected == [first.key, other.key])
        selection.resetForQueryChange(); #expect(!selection.isSelecting)
        try await f.close()
    }

    @Test func selectionWithoutLocalBytesNeverExpandsToAccountCleanup() async throws {
        let f = try await Fixture(), missing = try await f.add(name: "not-downloaded.png")
        let unrelated = try await f.publish(byte: 3, retention: .cache)
        await #expect(throws: V2ResourceStorageError.invalidRecord) { try await f.center.planCleanup(resources: []) }
        let preview = try await f.center.planCleanup(resources: [missing.key, missing.key])
        #expect(preview.resourceCount == 1 && preview.absentResourceCount == 1 && preview.plan.fileIDs.isEmpty && preview.plan.transferStagingIDs.isEmpty)
        let result = try await f.center.commitCleanup(preview.plan)
        #expect(result.deletedCount == 0 && result.releasedBytes == 0)
        #expect(try await f.center.storageSnapshot().files.first(where: { $0.id == unrelated })?.state == .published)
        try await f.close()
    }

    @Test func selectedCleanupIncludesBytesBeyondTheDetailVariantPage() async throws {
        let f = try await Fixture(), resource = try await f.add(name: "many-versions.png")
        let older = try await f.publish(byte: 4, retention: .cache), newer = try await f.publish(byte: 5, retention: .cache)
        let records = try await f.center.storageSnapshot().files
        let oldRecord = try #require(records.first(where: { $0.id == older }))
        let newRecord = try #require(records.first(where: { $0.id == newer }))
        try await f.local.databasePool.write { db in
            for number in 1...130 {
                let record = number == 1 ? oldRecord : newRecord
                let variant = try V2ResourceVariantDescriptor(key: .init(resource: resource.key,
                    rendition: .derived(id: .init("thumbnail"), version: .init(Int64(number)))), checksum: record.checksum, byteCount: record.byteCount)
                try GRDBV2LocalSyncStore.bindResourceVariant(variant, fileID: record.id, db: db)
            }
        }
        #expect(try await f.center.variants(for: resource.key).count == 128)
        let preview = try await f.center.planCleanup(resources: [resource.key])
        #expect(Set(preview.plan.fileIDs) == [older, newer])
        try await f.close()
    }

    @Test func selectedCleanupHonorsBorrowAndRetentionRacesAndLeavesOtherBytes() async throws {
        let f = try await Fixture(), bytes = PreviewBytes(), otherBytes = PreviewBytes(byte: 9)
        let resource = try await f.add(name: "selected.png", checksum: bytes.checksum)
        let other = try await f.add(name: "other.png", checksum: otherBytes.checksum)
        let boundary = SelectionBytes(values: [resource.key.mediaID: bytes, other.key.mediaID: otherBytes])
        let selectedFiles = V2ForegroundConversationMediaDownloader(cache: try await f.center.downloadCache(using: .init(targetResolver: boundary, byteTransfer: boundary)), center: f.center)
        let source = try #require(try await f.center.details(for: resource.key)?.sources.first)
        let otherSource = try #require(try await f.center.details(for: other.key)?.sources.first)
        let downloaded = try await selectedFiles.download(.init(mediaID: resource.key.mediaID), message: source.location)
        let otherDownloaded = try await selectedFiles.download(.init(mediaID: other.key.mediaID), message: otherSource.location)
        let borrowed = try await downloaded.borrowFile()
        let inUse = try await f.center.planCleanup(resources: [resource.key])
        #expect(inUse.plan.fileIDs.isEmpty && inUse.plan.skippedCount == 1)
        await borrowed.release()
        let beforeRetention = try await f.center.planCleanup(resources: [resource.key])
        #expect(beforeRetention.plan.fileIDs.count == 1)
        try await f.center.setRetained(true, variant: .init(resource: resource.key))
        let protected = try await f.center.commitCleanup(beforeRetention.plan)
        #expect(protected.deletedCount == 0 && protected.skippedCount == 1)
        try await f.center.setRetained(false, variant: .init(resource: resource.key))
        let preview = try await f.center.planCleanup(resources: [resource.key])
        let result = try await f.center.commitCleanup(preview.plan)
        #expect(result.deletedCount == 1 && result.failedCount == 0)
        #expect(try await f.center.variants(for: resource.key).first?.localState == .needsDownload)
        let otherLease = try await otherDownloaded.borrowFile()
        #expect(try Data(contentsOf: otherLease.fileURL) == otherBytes.bytes)
        await otherLease.release()
        try await f.close()
    }

    @Test func measuredDurationIsReadableAndRoundsUpWithoutOverflow() {
        #expect(V2ResourceFormatting.duration(1) == "1 秒")
        #expect(V2ResourceFormatting.duration(2000) == "2 秒")
        #expect(V2ResourceFormatting.duration(60_001) == "1 分 1 秒")
        #expect(V2ResourceFormatting.duration(3_661_000) == "1 小时 1 分 1 秒")
        #expect(V2ResourceFormatting.duration(Int64.max) == "2562047788015 小时 12 分 56 秒")
    }
    @Test func avatarPickerOnlyAcceptsReadySupportedImagesWithLiveMessageSources() async throws {
        let f = try await Fixture(), png = try await f.add(name: "头像.png"), gif = try await f.add(name: "动画.gif", type: "image/gif")
        let chosen = try await f.service.avatarSelection(for: png.key)
        #expect(chosen.key == png.key && chosen.displayName == png.displayName.value)
        #expect(chosen.importSource == .message(location: chosen.source.location, mediaID: png.key.mediaID, variantID: nil))
        await #expect(throws: V2ResourceStorageError.unavailable) { try await f.service.avatarSelection(for: gif.key) }
        try await f.local.revokeResourceReference(.message(chosen.source.location, ordinal: chosen.source.ordinal), businessRevision: 2)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await f.service.avatarSelection(for: png.key) }
        #expect(try await f.local.managedResourceTransfers(.init()).entries.isEmpty)
        try await f.close()
    }
    @Test(arguments: [V2ResourcePresentation.Purpose.preview, .share])
    func presentationDemandPersistsBeforeAuthorizationAndSurvivesCanceledPage(purpose: V2ResourcePresentation.Purpose) async throws {
        let f = try await Fixture(), resource = try await f.add(name: "waiting.png"), boundary = PresentationAuthorizationGate()
        let service = V2ResourceManagementService(center: f.center, localStore: f.local, downloader: boundary, directory: f.network)
        let detail = V2ResourceDetailStore(key: resource.key, service: service)
        await detail.reload()
        var originalID: V2ManagedResourceTransferID?
        for _ in 0..<2 {
            detail.present(purpose)
            let command = try #require(detail.command)
            let page = Task { await detail.execute(command) }
            await boundary.entered()
            let tasks = try await f.local.managedResourceTransfers(.init()).entries
            #expect(tasks.count == 1 && tasks.first?.phase == .queued && detail.presentation == nil)
            if let originalID { #expect(tasks.first?.id == originalID) } else { originalID = tasks.first?.id }
            page.cancel(); await page.value
            #expect(!detail.isWorking && detail.presentation == nil)
            #expect(try await f.local.managedResourceTransfers(.init()).entries.first?.id == originalID)
        }
        try await f.center.pauseTransfer(try #require(originalID))
        detail.present(purpose); await detail.execute(try #require(detail.command))
        #expect(detail.feedback == "下载已暂停，请到传输任务中继续下载。")
        #expect(await boundary.calls == 2)
        try await f.close()
    }

    @Test func cachedPresentationReauthorizesWithoutCreatingAnotherTransferHistory() async throws {
        let boundary = PreviewBytes()
        let f = try await Fixture(), resource = try await f.add(name: "cached.png", checksum: boundary.checksum)
        let files = V2ForegroundConversationMediaDownloader(cache: try await f.center.downloadCache(using: .init(targetResolver: boundary, byteTransfer: boundary)), center: f.center)
        let service = V2ResourceManagementService(center: f.center, localStore: f.local, downloader: files, directory: f.network)
        let detail = try #require(try await f.center.details(for: resource.key)), source = try #require(detail.sources.first)
        _ = try await files.download(.init(mediaID: resource.key.mediaID), message: source.location)
        let before = try await f.local.managedResourceTransfers(.init()).entries.map(\.id)
        for _ in 0..<2 {
            let lease = try await service.borrow(resource.key, source: source, contentType: resource.contentType)
            #expect(try Data(contentsOf: lease.fileURL) == boundary.bytes)
            await lease.release()
        }
        #expect(before.count == 1)
        #expect(try await f.local.managedResourceTransfers(.init()).entries.map(\.id) == before)
        try await f.close()
    }

    @Test(arguments: [false, true])
    func thumbnailReadProtectsBytesUntilDecodeEndsAndRejectsCanceledOrRevokedResults(revoke: Bool) async throws {
        let boundary = PreviewBytes(), f = try await Fixture()
        let resource = try await f.add(name: "decoding.png", checksum: boundary.checksum)
        let files = V2ForegroundConversationMediaDownloader(cache: try await f.center.downloadCache(using: .init(targetResolver: boundary, byteTransfer: boundary)), center: f.center)
        let service = V2ResourceManagementService(center: f.center, localStore: f.local, downloader: files, directory: f.network)
        let source = try #require(try await f.center.details(for: resource.key)?.sources.first)
        _ = try await files.download(.init(mediaID: resource.key.mediaID), message: source.location)
        let scope = await f.center.scope, gate = ThumbnailReadGate()
        let cache = V2LocalMediaThumbnailCache(directories: [scope.resourceFilesDirectory, scope.resourceCacheDirectory]) { url, _ in
            await gate.decode(url)
        }
        var finished = false
        let read = Task {
            defer { finished = true }
            return try await service.thumbnail(resource.key, using: cache)
        }
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while await gate.opened == nil {
                try #require(!finished && ContinuousClock.now < deadline, "Thumbnail never reached its actual file consumer")
                try await Task.sleep(for: .milliseconds(10))
            }
            let opened = try #require(await gate.opened)
            #expect(try Data(contentsOf: opened) == boundary.bytes)
            #expect(try await f.center.planCleanup().fileIDs.isEmpty)
            if revoke {
                try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
            } else { read.cancel() }
            #expect(!finished)
            #expect(try Data(contentsOf: opened) == boundary.bytes)
            #expect(try await f.center.planCleanup().fileIDs.isEmpty)
            await gate.release()
            if revoke {
                await #expect(throws: V2ResourceStorageError.unavailable) { try await read.value }
            } else {
                await #expect(throws: CancellationError.self) { try await read.value }
            }
            #expect(finished)
            let cleanup = try await f.center.commitCleanup(try await f.center.planCleanup())
            #expect(cleanup.deletedCount == 1 && cleanup.releasedBytes > 0)
            #expect(!FileManager.default.fileExists(atPath: opened.path))
        } catch {
            await gate.release(); _ = await read.result
            await cache.close(); try await f.close()
            throw error
        }
        await cache.close(); try await f.close()
    }

    @Test func detailDownloadCreatesOneDurableCommandWithoutWaitingForNetworkOrPreview() async throws {
        let f = try await Fixture(), resource = try await f.add(name: "queued.png")
        let detail = V2ResourceDetailStore(key: resource.key, service: f.service)
        await detail.reload()
        detail.download(); await detail.execute(try #require(detail.command))
        let id = try #require(detail.queuedTransfer)
        #expect(detail.presentation == nil && !detail.isWorking)
        #expect(detail.feedback == "已保存下载请求，可在传输任务中查看状态或继续处理。")
        detail.download(); await detail.execute(try #require(detail.command))
        #expect(detail.queuedTransfer == id)
        let queued = try await f.local.managedResourceTransfers(.init()).entries
        #expect(queued.count == 1 && queued.first?.id == id && queued.first?.phase == .queued)
        #expect(await f.network.calls == 0)
        try await f.center.pauseTransfer(id)
        detail.download(); await detail.execute(try #require(detail.command))
        #expect(detail.feedback == "下载已暂停，请到传输任务中继续下载。")
        #expect(try await f.local.managedResourceTransfers(.init()).entries.first?.phase == .paused)
        try await f.close()
    }

    @Test func liveUploadProgressSurvivesPageReopenButNeverBecomesConfirmedBytes() async throws {
        let f = try await Fixture(), id = UUID(), owner = UUID()
        let asset = try await f.center.importLocal(data: Data(repeating: 0x61, count: 100), displayName: .init("进度.txt"), contentType: .init("text/plain"), purpose: .messageDraft(f.room))
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .messageAttachment(f.room), contentType: asset.contentType.value,
            byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
        _ = try await f.local.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
        _ = try #require(try await f.local.claimResourceStep(id: id, owner: owner, now: Date()))
        try await f.local.saveResourceSession(.init(locator: .init(home: .room(f.room), sessionID: .init(uuid: UUID())), mediaID: request.mediaID,
            generation: 1, state: .created, resourceState: .pending, expiresAt: .distantFuture), for: id)
        try await f.local.finishResourceStep(id: id, owner: owner, next: .upload, retryAt: Date())
        _ = try #require(try await f.local.claimResourceStep(id: id, owner: owner, now: Date()))
        let progress = try await f.center.beginUploadProgress(job: id, expectedBytes: 100)
        let page = V2ResourceTransferStore(service: f.service)
        var observer = Task { await page.observe() }
        progress.report(transferredBytes: 25)
        try await eventually { page.content.page?.entries.first?.attemptProgress?.transferredBytes == 25 }
        let initial = try #require(page.content.page?.entries.first)
        #expect(initial.phase == .transferring && initial.confirmedBytes == nil)
        #expect(try await f.local.resourceTransfer(id: id)?.nextAction == .status)
        observer.cancel(); await observer.value
        progress.report(transferredBytes: 75)
        observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.attemptProgress?.transferredBytes == 75 }
        #expect(page.content.page?.entries.first?.createdAt == initial.createdAt)
        progress.end()
        try await eventually { page.content.page?.entries.first?.attemptProgress == nil }
        #expect(page.content.page?.entries.first?.phase == .confirming)
        #expect(page.content.page?.entries.first?.confirmedBytes == nil)
        try await f.local.finishResourceStep(id: id, owner: owner, next: .status, retryAt: Date())
        #expect(await f.network.calls == 0)
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func unboundCancellationRequiresConfirmationAndRejectsNewConsumerAfterReview() async throws {
        let f = try await Fixture(), id = UUID()
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: f.room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .messageAttachment(f.room), targetMediaID: .init(uuid: UUID()))
        try await f.local.prepareResourceImport(id: id, request: request)
        let page = V2ResourceTransferStore(service: f.service), observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.actions.contains(.cancelUnbound) == true }
        page.cancelUnbound(.serverImport(id)); await page.execute(try #require(page.command))
        #expect(page.unboundCancellationPlan != nil)
        #expect(try await f.local.resourceImport(id: id)?.cancellationRequested == false)
        page.dismissUnboundCancellation()
        #expect(page.unboundCancellationPlan == nil)
        page.cancelUnbound(.serverImport(id)); await page.execute(try #require(page.command))
        let plan = try #require(page.unboundCancellationPlan)
        let parent = try V2SendIntent(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "acquired task", attachmentJobIDs: [id])
        try await f.local.freezeSendIntent(parent)
        page.confirmUnboundCancellation(plan); await page.execute(try #require(page.command))
        #expect(page.feedback == "任务状态已变化，当前无法执行此操作。")
        #expect(try await f.local.resourceImport(id: id)?.cancellationRequested == false)
        #expect(try await f.local.preparingSendIntents().count == 1)
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func importPauseUsesLocalFollowUpCommandAndKeepsFrozenMessage() async throws {
        let f = try await Fixture(), id = UUID()
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: f.room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .messageAttachment(f.room), targetMediaID: .init(uuid: UUID()))
        try await f.local.prepareResourceImport(id: id, request: request)
        try await f.local.freezeSendIntent(.init(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "copy", attachmentJobIDs: [id]))
        let page = V2ResourceTransferStore(service: f.service)
        var observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.actions == [.pause, .cancel] }
        page.pause(.serverImport(id)); await page.execute(try #require(page.command))
        #expect(page.feedback == "已请求暂停本机跟进，服务器仍可能继续处理。")
        observer.cancel(); await observer.value
        page.group = .attention; observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.actions == [.resume, .cancel] }
        page.resume(.serverImport(id)); await page.execute(try #require(page.command))
        #expect(page.feedback == "已请求继续跟进，将确认原导入操作。")
        #expect(try await f.local.resourceImport(id: id)?.request == request)
        #expect(try await f.local.preparingSendIntents().count == 1)
        #expect(await f.network.calls == 0)
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func uploadPauseAndContinueUseCanonicalControlWithoutIssuingNetworkRequests() async throws {
        let f = try await Fixture(), id = UUID()
        let asset = try await f.center.importLocal(data: Data("source".utf8), displayName: .init("附件.txt"), contentType: .init("text/plain"), purpose: .messageDraft(f.room))
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .messageAttachment(f.room), contentType: asset.contentType.value,
            byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
        _ = try await f.local.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
        try await f.local.freezeSendIntent(.init(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "preserved", attachmentJobIDs: [id]))
        let page = V2ResourceTransferStore(service: f.service)
        var observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.actions.contains(.pause) == true }
        page.pause(.upload(id)); await page.execute(try #require(page.command))
        #expect(page.feedback == "上传已请求暂停，原文件会保留。")
        observer.cancel(); await observer.value
        page.group = .attention; observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.actions == [.resume, .cancel] }
        #expect(try await f.local.pendingResourceSendSnapshot(in: f.room, page: 0).preparing.first?.isUserPaused == true)
        page.resume(.upload(id)); await page.execute(try #require(page.command))
        #expect(page.feedback == "已请求继续上传，将先确认原操作。")
        #expect(try await f.local.resourceTransfer(id: id)?.control == .run)
        #expect(try await f.local.resourceTransfer(id: id)?.request == request)
        #expect(try await f.center.localAsset(asset.id)?.availability == .local)
        #expect(await f.network.calls == 0)
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func cancelledImportOffersConfirmationRatherThanOrdinaryRetry() async throws {
        let f = try await Fixture(), id = UUID()
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
            source: .message(location: .init(roomID: f.room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
            targetUsage: .messageAttachment(f.room), targetMediaID: .init(uuid: UUID()))
        try await f.local.prepareResourceImport(id: id, request: request)
        try await f.local.requestImportCancellation(id: id)
        try await f.local.pauseResourceImport(id: id, needsAttention: true)
        let page = V2ResourceTransferStore(service: f.service)
        page.group = .attention
        let observer = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.actions == [.retryCancellation] }
        page.retry(.serverImport(id)); #expect(page.command == nil)
        page.retryCancellation(.serverImport(id)); await page.execute(try #require(page.command))
        #expect(page.feedback == "已请求继续确认取消，将遵守服务器的重试等待时间。")
        let job = try #require(try await f.local.resourceImport(id: id))
        #expect(job.cancellationRequested && job.request == request && job.attempts == 0)
        #expect(await f.network.calls == 0)
        observer.cancel(); await observer.value
        await f.center.close(); try await f.local.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test func messagePreparationCancellationRequiresReviewedScopeAndPreservesDismissal() async throws {
        let f = try await Fixture(), job = UUID()
        let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
            source: .message(location: .init(roomID: f.room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
            targetUsage: .messageAttachment(f.room), targetMediaID: .init(uuid: UUID()))
        try await f.local.prepareResourceImport(id: job, request: request)
        let first = try V2SendIntent(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "first", attachmentJobIDs: [job])
        try await f.local.freezeSendIntent(first)
        let page = V2ResourceTransferStore(service: f.service), observer = Task { await page.observe() }
        let deadline = ContinuousClock.now + .seconds(5)
        while page.content.page?.entries.first(where: { $0.id == .serverImport(job) }) == nil { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        page.cancel(.serverImport(job)); await page.execute(try #require(page.command))
        #expect(page.cancellationPlan?.messageCount == 1)
        #expect(try await f.local.preparingSendIntents().count == 1)
        #expect(try await f.local.resourceImport(id: job)?.cancellationRequested == false)
        page.dismissCancellation()
        #expect(page.cancellationPlan == nil)
        page.cancel(.serverImport(job)); await page.execute(try #require(page.command))
        let stale = try #require(page.cancellationPlan)
        let second = try V2SendIntent(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "second", attachmentJobIDs: [job])
        try await f.local.freezeSendIntent(second)
        page.confirmCancellation(stale); await page.execute(try #require(page.command))
        #expect(page.feedback == "任务状态已变化，当前无法执行此操作。")
        #expect(try await f.local.preparingSendIntents().count == 2)
        page.cancel(.serverImport(job)); await page.execute(try #require(page.command))
        let fresh = try #require(page.cancellationPlan)
        #expect(fresh.messageCount == 2)
        page.confirmCancellation(fresh); await page.execute(try #require(page.command))
        #expect(page.feedback == "已取消待发送消息，正在停止附件准备。")
        #expect(try await f.local.preparingSendIntents().isEmpty)
        #expect(try await f.local.resourceImport(id: job)?.cancellationRequested == true)
        #expect(await f.network.calls == 0)
        observer.cancel(); await observer.value
        await f.center.close(); try await f.local.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test func downloadNetworkSettingsPersistAndFailedSaveLeavesConfirmedValues() async throws {
        let f = try await Fixture()
        let page = V2ResourceStorageStore(service: f.service)
        await page.reload()
        #expect(page.downloadNetworkPreferences == .init())
        page.changeDownloadNetwork(.init(allowsCellular: false, allowsConstrained: true))
        #expect(page.isUpdatingNetwork)
        await page.execute(try #require(page.command))
        #expect(!page.isUpdatingNetwork)
        #expect(page.networkMessage == "下载网络设置已更新。")
        let reopened = V2ResourceStorageStore(service: f.service)
        await reopened.reload()
        #expect(reopened.downloadNetworkPreferences == .init(allowsCellular: false, allowsConstrained: true))
        page.changeAutomaticCategory(.video, enabled: true)
        await page.execute(try #require(page.command))
        page.changeAutomaticLimit(1024 * 1024)
        await page.execute(try #require(page.command))
        let confirmed = try #require(page.downloadNetworkPreferences)
        #expect(confirmed.automaticDownloads.categories == [.image, .video])
        #expect(confirmed.automaticDownloads.maximumByteCount == 1024 * 1024)
        #expect(!confirmed.allowsCellular && confirmed.allowsConstrained)
        try await f.local.databasePool.write {
            try $0.execute(sql: "CREATE TRIGGER deny_network_preferences BEFORE UPDATE ON v2_resource_download_network_preferences BEGIN SELECT RAISE(ABORT,'injected policy failure'); END")
        }
        page.changeDownloadNetwork(.init(allowsCellular: true, allowsConstrained: false))
        await page.execute(try #require(page.command))
        #expect(!page.isUpdatingNetwork)
        #expect(page.networkMessage != nil && page.networkMessage != "下载网络设置已更新。")
        #expect(page.downloadNetworkPreferences == confirmed)
        #expect(try await f.center.downloadNetworkPreferences() == page.downloadNetworkPreferences)
        try await f.local.databasePool.write { try $0.execute(sql: "DROP TRIGGER deny_network_preferences") }
        try await f.close()
    }

    @Test func nativeDownloadPageCancellationUsesRegisteredOwnerWithoutConstructingForegroundCache() async throws {
        let f = try await Fixture(), boundary = PreviewBytes(), id = UUID()
        let descriptor = try await f.add(name: "后台文件.bin", type: "application/octet-stream", checksum: boundary.checksum)
        let detail = try #require(try await f.center.details(for: descriptor.key))
        let source = try #require(detail.sources.first)
        _ = try await f.local.beginBackgroundDownload(id: id, mediaID: descriptor.key.mediaID, message: source.location, accountID: f.center.scope.accountID)
        let target = try boundary.resolveDownloadTarget(mediaID: descriptor.key.mediaID, message: source.location)
        try await f.local.bindBackgroundDownloadBytes(id: id, target: target, accountID: f.center.scope.accountID)
        for _ in 0..<5 { try await f.local.failBackgroundDownloadPreparation(id: id, accountID: f.center.scope.accountID) }
        let driver = IdleNativeDownloadDriver(), session = UUID(), scope = await f.center.scope
        let files = await f.center.files
        let native = try V2BackgroundDownloadCoordinator(sessionID: session, accountID: scope.accountID, store: f.local,
            scheduler: .init(), resolver: boundary, driver: driver, files: files, root: scope.backgroundDirectory)
        try await f.center.attachBackgroundDownloads(native)
        let activity = Task { try await native.run() }
        let page = V2ResourceTransferStore(service: f.service)
        page.group = .attention
        var observation = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.actions == [.retry, .cancel] }
        page.cancel(.download(id)); await page.execute(try #require(page.command))
        #expect(page.feedback == "已请求取消，传输停止后会清理断点暂存。")
        observation.cancel(); await observation.value
        page.group = .finished
        observation = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.phase == .cancelled }
        #expect(page.content.page?.entries.first?.id == .download(id))
        #expect(await driver.created == 0)
        #expect(await f.network.calls == 0)
        observation.cancel(); await observation.value
        await f.center.close(); _ = await activity.result
        try await f.close()
    }
    @Test func downloadRetryOnlyQueuesCommandAndAccountRecoveryFinishesAfterPageLeaves() async throws {
        let f = try await Fixture(), boundary = RecoveryBytes()
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: boundary.bytes).map { String(format: "%02x", $0) }.joined())
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let location = V2MediaMessageLocation(roomID: f.room, messageID: .init(uuid: UUID()))
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(f.room), mediaID: media.mediaID), revision: 1,
            displayName: .init("恢复下载.bin"), contentType: "application/octet-stream", byteCount: 42, checksum: checksum, state: .ready)
        try await f.local.indexResource(descriptor, reference: .message(location, ordinal: 0), businessRevision: 1)
        let files = V2ForegroundConversationMediaDownloader(cache: try await f.center.downloadCache(using: .init(targetResolver: boundary, byteTransfer: boundary)), center: f.center)
        await #expect(throws: URLError.self) { try await files.download(media, message: location) }
        let service = V2ResourceManagementService(center: f.center, localStore: f.local, downloader: files, directory: f.network)
        let page = V2ResourceTransferStore(service: service)
        page.group = .attention
        var observation = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.actions == [.retry, .cancel] }
        let id = try #require(page.content.page?.entries.first?.id)
        page.retry(id); await page.execute(try #require(page.command))
        try await eventually { page.content.page?.entries.isEmpty == true }
        #expect(await boundary.authorizations == 1)
        #expect(await boundary.transfers == 1)
        observation.cancel(); await observation.value
        let recovery = Task { try await files.runRecovery() }
        defer { recovery.cancel() }
        page.group = .finished
        observation = Task { await page.observe() }
        try await eventually { page.content.page?.entries.first?.phase == .completed }
        #expect(page.content.page?.entries.map(\.id) == [id])
        #expect(await boundary.authorizations == 2)
        #expect(await boundary.transfers == 2)
        let result = try await files.download(media, message: location), lease = try await result.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == boundary.bytes)
        await lease.release()
        observation.cancel(); await observation.value
        recovery.cancel(); _ = await recovery.result
        try await f.close()
    }
    @Test func transferPageCancelsPausedDownloadAndObservesItsClosedHistory() async throws {
        let f = try await Fixture(), owner = UUID()
        let journal = await f.local.resourceFileJournal()
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: Data([1,2,3,4])).map { String(format: "%02x", $0) }.joined())
        let identity = checksum.value + ":4"
        let id = try journal.beginForegroundDownload(identity: identity, mediaID: .init(uuid: UUID()), message: nil, bytes: 4, checksum: checksum, owner: owner)
        let stage = try await f.center.files.reserveTransient(identity: identity, bytes: 4)
        try Data([1,2]).write(to: stage.fileURL.appendingPathExtension("range-part"))
        try await f.center.files.releaseTransient(stage.id, discard: false)
        try journal.pauseForegroundDownload(id, owner: owner, issue: .network)
        let store = V2ResourceTransferStore(service: f.service)
        store.group = .attention
        var observation = Task { await store.observe() }
        try await eventually { store.content.page?.entries.first?.actions == [.cancel] }
        store.cancel(.download(id))
        await store.execute(try #require(store.command))
        try await eventually { store.content.page?.entries.isEmpty == true }
        #expect(store.performing == nil && store.feedback == "已请求取消，传输停止后会清理断点暂存。")
        #expect(try await f.center.files.snapshot().transferReservedBytes == 0)
        observation.cancel(); await observation.value
        store.group = .finished
        observation = Task { await store.observe() }
        try await eventually { store.content.page?.entries.first?.phase == .cancelled }
        #expect(store.content.page?.entries.first?.id == .download(id))
        observation.cancel(); await observation.value
        try await f.close()
    }

    @Test func transferPageUsesCanonicalRetryAndObservesGroupChanges() async throws {
        let f = try await Fixture(), bytes = Data(repeating: 7, count: 42), id = UUID()
        let asset = try await f.center.importLocal(data: bytes, displayName: .init("待处理头像.png"), contentType: .init("image/png"), purpose: .personalAvatar)
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .userAvatar,
            contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
        _ = try await f.local.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
        let store = V2ResourceTransferStore(service: f.service)
        var observation = Task { await store.observe() }
        try await eventually { store.content.page?.entries.map(\.id) == [.upload(id)] }
        try await f.local.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_transfer_jobs SET stage='paused',needs_attention=1,last_error='needsAttention'") }
        try await eventually { store.content.page?.entries.isEmpty == true }
        store.group = .attention
        observation.cancel(); await observation.value
        observation = Task { await store.observe() }
        try await eventually { store.content.page?.entries.first?.actions == [.retry, .cancelUnbound] }
        store.retry(.upload(id))
        await store.execute(try #require(store.command))
        try await eventually { store.content.page?.entries.isEmpty == true }
        #expect(store.performing == nil && store.feedback != nil)
        #expect(try await f.local.resourceTransfer(id: id)?.needsAttention == false)
        #expect(try await f.local.dueResourceTransfers().contains(id))
        #expect(await f.network.calls == 0)
        observation.cancel(); await observation.value
        try await f.close()
    }

    @Test func localPagingAndFiltersNeverNeedNetwork() async throws {
        let f = try await Fixture()
        for index in 0..<53 { _ = try await f.add(name: "photo_\(index).png") }
        let pdf = try await f.add(name: "说明.pdf", type: "application/pdf")
        let store = V2ResourceLibraryStore(room: nil, service: f.service)
        var observation = Task { await store.observe() }
        try await eventually { store.content.page?.entries.count == 50 }
        let first = try #require(store.content.page)
        store.nextPage()
        observation.cancel(); await observation.value
        observation = Task { await store.observe() }
        try await eventually { store.content.page?.entries.count == 4 }
        let second = try #require(store.content.page)
        #expect(Set((first.entries + second.entries).map(\.descriptor.key)).count == 54)
        #expect(store.pageNumber == 2)
        store.category = .file
        observation.cancel(); await observation.value
        observation = Task { await store.observe() }
        try await eventually { store.content.page?.entries.map(\.descriptor.key) == [pdf.key] }
        #expect(store.pageNumber == 1 && store.before == nil)
        store.search = "does-not-exist"
        observation.cancel(); await observation.value
        observation = Task { await store.observe() }
        try await eventually { store.content.page?.entries.isEmpty == true }
        #expect(await f.network.calls == 0)
        observation.cancel(); await observation.value
        try await f.close()
    }

    @Test func retainedMetadataUpdatesAndRevocationRemovesDetails() async throws {
        let f = try await Fixture(), resource = try await f.add(name: "image.png")
        let store = V2ResourceDetailStore(key: resource.key, service: f.service)
        let observation = Task { await store.observe() }
        try await eventually { store.original != nil }
        store.setRetained(true)
        await store.execute(try #require(store.command))
        #expect(store.original?.isRetained == true)
        #expect(store.original?.localState == .needsDownload)
        let source = try #require(store.content.snapshot?.sources.first)
        try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        try await eventually { if case .unavailable = store.content { true } else { false } }
        #expect(store.presentation == nil && store.original == nil)
        #expect(await f.network.calls == 0)
        observation.cancel(); await observation.value
        try await f.close()
    }

    @Test func cleanupCommitsPhysicalResultsAndPreservesRetainedFilesAndPolicy() async throws {
        let f = try await Fixture()
        let cache = try await f.publish(byte: 1, retention: .cache)
        let retained = try await f.publish(byte: 2, retention: .retained)
        let store = V2ResourceStorageStore(service: f.service)
        await store.reload(reconcile: true)
        let before = try #require(store.content.snapshot)
        #expect(before.files.count == 2 && before.totalBytes > 0)
        store.previewCleanup()
        await store.execute(try #require(store.command))
        let plan = try #require(store.cleanup.plan)
        #expect(plan.fileIDs == [cache] && plan.estimatedBytes > 0)
        store.commitCleanup()
        await store.execute(try #require(store.command))
        guard case .finished(let result) = store.cleanup else { Issue.record("Missing actual cleanup result"); return }
        store.dismissCleanup()
        guard case .finished = store.cleanup else { Issue.record("Sheet acknowledgement erased the cleanup receipt"); return }
        #expect(result.deletedCount == 1 && result.releasedBytes > 0 && result.failedCount == 0)
        let after = try #require(store.content.snapshot)
        #expect(after.files.filter { $0.state == .published }.map(\.id) == [retained])
        #expect(after.totalBytes == before.totalBytes - result.releasedBytes)
        store.changeCacheLimit(128 * 1_024 * 1_024)
        await store.execute(try #require(store.command))
        let policy = try #require(store.content.snapshot?.quota.policy)
        #expect(policy.maximumCacheBytes == 128 * 1_024 * 1_024)
        #expect(policy.maximumOriginalBytes == before.quota.policy.maximumOriginalBytes)
        #expect(policy.maximumTemporaryBytes == before.quota.policy.maximumTemporaryBytes)
        #expect(policy.maximumManagedBytes == before.quota.policy.maximumManagedBytes)
        #expect(try await f.center.storageSnapshot().quota.policy == policy)
        try await f.close()
    }

    @Test func quickLookControllerOwnsBorrowThroughDismissalAndAccountClose() async throws {
        let boundary = PreviewBytes()
        let f = try await Fixture(), resource = try await f.add(name: "preview.png", checksum: boundary.checksum)
        let files = V2ForegroundConversationMediaDownloader(cache: try await f.center.downloadCache(using: .init(targetResolver: boundary, byteTransfer: boundary)), center: f.center)
        let service = V2ResourceManagementService(center: f.center, localStore: f.local, downloader: files, directory: f.network)
        let store = V2ResourceDetailStore(key: resource.key, service: service)
        await store.reload()
        store.present(.preview)
        await store.execute(try #require(store.command))
        var coordinator: V2ResourceQuickLook.Coordinator? = .init(presentation: try #require(store.presentation))
        var controller: V2ResourceQuickLook.Controller? = V2ResourceQuickLook.Controller()
        controller?.owner = coordinator; controller?.dataSource = coordinator
        let source = try #require(store.content.snapshot?.sources.first)
        try await f.local.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        await store.reload()
        #expect(store.presentation == nil)
        // SwiftUI teardown must detach delegates without ending a UIKit
        // dismissal transition's remaining file use.
        V2ResourceQuickLook.dismantleUIViewController(try #require(controller), coordinator: try #require(coordinator))
        coordinator = nil
        var finished = false
        let closing = Task { await f.center.close(); finished = true }
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            do { _ = try await f.center.details(for: resource.key) }
            catch V2ResourceStorageError.closed { break }
            catch is CancellationError { /* close drained an admitted read */ }
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        #expect(!finished)
        controller = nil
        await closing.value
        #expect(finished)
        try await f.close()
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            try #require(ContinuousClock.now < deadline, "Page did not observe committed resource facts")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Fixture {
        let root: URL, local: GRDBV2LocalSyncStore, center: V2ResourceCenter
        let room = RoomID(uuid: UUID())
        let network = UnusedNetwork()
        var service: V2ResourceManagementService { .init(center: center, localStore: local, downloader: network, directory: network) }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "resource-management-store-\(UUID())")
            let user = UserID(uuid: UUID())
            local = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
            center = try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache")), store: local)
        }
        func attentionUpload(markAttention: Bool = true) async throws -> (id: UUID, request: V2ResourceUploadRequest) {
            let id = UUID()
            let asset = try await center.importLocal(data: Data(repeating: 7, count: 42), displayName: .init("待处理附件.png"), contentType: .init("image/png"), purpose: .personalAvatar)
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .userAvatar,
                contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
            _ = try await local.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
            if markAttention {
                try await local.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_transfer_jobs SET stage='paused',needs_attention=1,last_error='needsAttention' WHERE job_id=?", arguments: [id.uuidString]) }
            }
            return (id, request)
        }
        func importRequest() async throws -> (id: UUID, request: V2ResourceImportRequest) {
            let id = UUID()
            let request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
                source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
                targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
            try await local.prepareResourceImport(id: id, request: request)
            return (id, request)
        }
        func add(name: String, type: String = "image/png", checksum: V2ResourceChecksum? = nil) async throws -> V2ResourceDescriptor {
            let descriptor = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: .init(uuid: UUID())), revision: 1,
                displayName: .init(name), contentType: type, byteCount: 42, checksum: checksum ?? .init(value: String(repeating: "a", count: 64)), state: .ready)
            try await local.indexResource(descriptor, reference: .message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
            return descriptor
        }
        func publish(byte: UInt8, retention: V2ResourceFileRetention) async throws -> V2LocalResourceFileID {
            let bytes = Data(repeating: byte, count: 8192), source = root.appending(path: UUID().uuidString)
            try bytes.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let checksum = try V2ResourceChecksum(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            return try await center.files.publishCopy(of: source, byteCount: Int64(bytes.count), checksum: checksum, retention: retention)
        }
        func close() async throws { await center.close(); try await local.close(); try FileManager.default.removeItem(at: root) }
    }

    private actor ThumbnailReadGate {
        private(set) var opened: URL?
        private let finish = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func decode(_ url: URL) async -> V2SendableImage? {
            opened = url
            // Deliberately noncooperative, like an ImageIO decode already in progress.
            for await _ in finish.stream { break }
            return .init(image: UIImage())
        }
        func release() { finish.continuation.yield(()); finish.continuation.finish() }
    }

    private actor PresentationAuthorizationGate: V2ConversationMediaDownloading {
        private let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private(set) var calls = 0
        func entered() async { for await _ in starts.stream { return } }
    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia? { nil }
        func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) throws -> V2ConversationMediaFileLease? { nil }
        func download(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia {
            calls += 1
            let wait = AsyncStream<Void>.makeStream()
            starts.continuation.yield(())
            for await _ in wait.stream { }
            throw CancellationError()
        }
    }

    private actor PagedDirectory: V2RoomResourceDirectoryReading {
        let descriptor: V2ResourceDescriptor
        let message = MessageID(uuid: UUID())
        private(set) var calls = 0
        init(descriptor: V2ResourceDescriptor) { self.descriptor = descriptor }
        func query(roomID: RoomID, query: V2RoomResourceQuery) throws -> V2RoomResourcePage {
            calls += 1
            if query.cursor != nil { return try .init(items: [], snapshotUpperRoomSequence: 2, nextCursor: nil) }
            let item = try V2RoomResourceItem(messageID: message, messageRevision: 1,
                position: .init(roomSequence: 2, ordinal: 0, mediaID: descriptor.key.mediaID), createdAt: 1, descriptor: descriptor)
            return try .init(items: [item], snapshotUpperRoomSequence: 2, nextCursor: "next-page")
        }
    }

    private actor UnusedNetwork: V2ConversationMediaDownloading, V2RoomResourceDirectoryReading {
    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia? { nil }
        func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) throws -> V2ConversationMediaFileLease? { calls += 1; throw V2ResourceStorageError.unavailable }
        private(set) var calls = 0
        func download(_ media: V2MediaReference, message: V2MediaMessageLocation?) throws -> V2DownloadedConversationMedia {
            calls += 1; throw V2ResourceStorageError.unavailable
        }
        func query(roomID: RoomID, query: V2RoomResourceQuery) throws -> V2RoomResourcePage {
            calls += 1; throw V2ClientResourceDirectoryError.unavailable
        }
    }

    private struct SelectionBytes: V2ClientMediaDownloadTargetResolver, V2ClientMediaByteTransfer {
        let values: [MediaID: PreviewBytes]
        func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
            let value = try #require(values[mediaID])
            return try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://media.invalid/selection/" + mediaID.rawValue)),
                expiresAt: .distantFuture, expectedByteCount: Int64(value.bytes.count), checksum: value.checksum))
        }
        func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws {
            let value = try #require(values[MediaID(target.url.lastPathComponent)])
            try value.bytes.write(to: destinationURL)
        }
    }

    private struct PreviewBytes: V2ClientMediaDownloadTargetResolver, V2ClientMediaByteTransfer {
        let bytes: Data
        init(byte: UInt8 = 7) { bytes = Data(repeating: byte, count: 42) }
        var checksum: V2ResourceChecksum { get throws { try .init(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()) } }
        func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
            return try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://media.invalid/preview-owner")),
                expiresAt: .distantFuture, expectedByteCount: Int64(bytes.count), checksum: checksum))
        }
        func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws { try bytes.write(to: destinationURL) }
    }

    private actor RecoveryBytes: V2ClientMediaDownloadTargetResolver, V2ClientMediaByteTransfer {
        let bytes = Data(repeating: 6, count: 42)
        private(set) var authorizations = 0
        private(set) var transfers = 0
        func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
            authorizations += 1
            let checksum = try V2ResourceChecksum(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            return try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://media.invalid/recovery")),
                expiresAt: .distantFuture, expectedByteCount: Int64(bytes.count), checksum: checksum))
        }
        func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws {
            transfers += 1
            if transfers == 1 {
                try Data(bytes.prefix(10)).write(to: destinationURL.appendingPathExtension("range-part"))
                throw URLError(.networkConnectionLost)
            }
            try bytes.write(to: destinationURL)
        }
    }

    private actor IdleNativeDownloadDriver: V2BackgroundDownloadSessionDriving {
        private(set) var created = 0
        func tasks() -> [V2BackgroundSystemTask] { [] }
        func installWake(_ wake: @escaping @concurrent @Sendable () async -> Void) async { }
        func create(target: V2ClientMediaTransferTarget, mappingID: UUID) throws -> Int {
            created += 1; throw V2BackgroundTransferError.unsupported
        }
        func resume(_ identifier: Int) throws { throw V2BackgroundTransferError.unsupported }
        func cancelAndDrain(_ identifiers: [Int]) { }
    }
}
