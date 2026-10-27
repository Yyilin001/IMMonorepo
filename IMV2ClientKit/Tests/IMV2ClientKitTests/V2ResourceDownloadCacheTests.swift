import Crypto
import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing
import Synchronization

@Suite("Unified account download ownership", .timeLimit(.minutes(1)))
struct V2ResourceDownloadCacheTests {
    @Test func previewHasSeparateBytesDoesNotCompleteOriginalDemandAndHonorsRevocation() async throws {
        let f = try Fixture(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let location = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: location, contentType: "image/png")
        let resolver = PreviewCacheResolver(), bytes = PreviewCacheBytes()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let originalDemand = try await center.prepareMessageDownload(mediaID: media.mediaID, message: location)
        guard case .queued = originalDemand else { Issue.record("Expected original demand"); return }
        let file = try await cache.imagePreview(media, message: location)
        let lease = try await file.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == PreviewCacheBytes.payload)
        await lease.release()
        _ = try await cache.imagePreview(media, message: location)
        #expect(await bytes.calls == 1)
        #expect(await resolver.previewCalls == 1)
        #expect(try await center.prepareMessageDownload(mediaID: media.mediaID, message: location) == originalDemand)
        #expect(await resolver.originalCalls == 0)
        #expect(try await cache.cachedFile(media, message: location) == nil)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_message_tombstones(message_id,source_event_id,room_id,message_revision) VALUES(?,?,?,2)",
                arguments: [location.messageID.rawValue, UUID().uuidString, location.roomID.rawValue])
        }
        await #expect(throws: V2ResourceStorageError.unavailable) { try await file.borrowFile() }
        await center.close(); try await f.remove()
    }

    @Test func warmPreviewRemainsAvailableOfflineButCannotSurviveDiscardOrScopeClose() async throws {
        let f = try Fixture(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let location = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: location, contentType: "image/png")
        let resolver = PreviewCacheResolver(), bytes = PreviewCacheBytes()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        #expect(try await cache.cachedImagePreview(media, message: location, size: .large) == nil)
        #expect(await resolver.previewCalls == 0)
        // Drop the view's handle; account authorization metadata must not depend
        // on a live row retaining its old handle or downloading the original.
        let firstHandleID: UUID
        do {
            let first = try await cache.imagePreview(media, message: location, size: .large)
            firstHandleID = first.id
        }
        await resolver.goOffline()
        let snapshotHandle = try #require(try await cache.cachedImagePreview(media, message: location, size: .large))
        #expect(snapshotHandle.mediaID == media.mediaID)
        #expect(try await cache.cachedImagePreview(media, message: location, size: .thumbnail) == nil)
        let reopened = try await cache.imagePreview(media, message: location, size: .large)
        #expect(reopened.id != firstHandleID)
        let lease = try await reopened.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == PreviewCacheBytes.payload)
        await lease.release()
        #expect(await resolver.previewCalls == 1)
        #expect(await bytes.calls == 1)
        // Authorization is scoped to both message and rendition.
        await #expect(throws: (any Error).self) { try await cache.imagePreview(media, message: location, size: .thumbnail) }
        try await f.store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_access_generation SET token=randomblob(16) WHERE singleton=1")
        }
        #expect(try await cache.cachedImagePreview(media, message: location, size: .large) == nil)
        await #expect(throws: (any Error).self) { try await cache.imagePreview(media, message: location, size: .large) }
        try await cache.discard(media.mediaID)
        await #expect(throws: (any Error).self) { try await cache.imagePreview(media, message: location, size: .large) }
        await #expect(throws: V2ResourceStorageError.unavailable) { try await reopened.borrowFile() }
        await center.close()
        await #expect(throws: CancellationError.self) { try await cache.imagePreview(media, message: location, size: .large) }
        try await f.remove()
    }

    @Test func cachedHandlesReopenWithoutDownloadingAndStillHonorRevocation() async throws {
        let f = try Fixture(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let location = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: location)
        let binding = try await f.store.boundInstallationBinding()
        let resolver = CacheResolver(), bytes = CacheBytes()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        #expect(try await cache.cachedFile(media, message: location) == nil)
        #expect(await bytes.calls == 0)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        _ = try await cache.download(media, message: location)
        let jobs = try await f.store.managedResourceTransfers(.init()).entries.map(\.id)
        await center.close(); try await f.store.close()
        let database = try GRDBV2LocalSyncStore(databaseURL: f.directory.appendingPathComponent("V2.sqlite"), installationBinding: binding, userID: f.scope.accountID)
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: database)
        let restoredCache = try await restored.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let file = try #require(try await restoredCache.cachedFile(media, message: location))
        let lease = try await file.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == CacheBytes.payload)
        await lease.release()
        #expect(await bytes.calls == 1)
        #expect(try await database.managedResourceTransfers(.init()).entries.map(\.id) == jobs)
        try await database.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_message_tombstones(message_id,source_event_id,room_id,message_revision) VALUES(?,?,?,2)",
                arguments: [location.messageID.rawValue, UUID().uuidString, location.roomID.rawValue])
        }
        await #expect(throws: V2ResourceStorageError.unavailable) { try await restoredCache.cachedFile(media, message: location) }
        await #expect(throws: V2ResourceStorageError.unavailable) { try await file.borrowFile() }
        #expect(await bytes.calls == 1)
        await restored.close(); try await database.close(); try await f.remove()
    }

    @Test func automaticAdmissionLeavesRoomForExplicitUserDownloadsWhileOffline() async throws {
        let f = try Fixture(), center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        var sources: [(V2MediaReference, V2MediaMessageLocation)] = []
        for index in 0..<20 {
            let media = V2MediaReference(mediaID: .init(uuid: UUID())), location = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
            try await f.index(media, message: location, payload: Data([UInt8(index),7,8,9]), contentType: "image/png")
            sources.append((media, location))
        }
        try await center.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.image], maximumByteCount: 64)))
        let journal = await f.store.resourceFileJournal()
        for _ in 0..<10 { try journal.enqueueAutomaticDownloads() }
        let automatic = try await f.store.managedResourceTransfers(.init()).entries
        #expect(automatic.count == 12)
        let admitted = Set(automatic.map(\.mediaID)), explicit = sources.filter { !admitted.contains($0.0.mediaID) }
        for item in explicit.prefix(4) {
            guard case .queued = try await center.prepareMessageDownload(mediaID: item.0.mediaID, message: item.1) else { Issue.record("No room for user intent"); return }
        }
        #expect(try await f.store.managedResourceTransfers(.init()).entries.count == 16)
        await #expect(throws: V2ResourceStorageError.capacityExceeded) { try await center.prepareMessageDownload(mediaID: explicit[4].0.mediaID, message: explicit[4].1) }
        await center.close(); try await f.remove()
    }

    @Test func automaticQueueExplainsNetworkRestrictionsAndKeepsItsOriginalTask() async throws {
        let f = try Fixture(), feed = AutomaticNetworkFeed(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message, contentType: "image/png")
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        try await center.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.image], maximumByteCount: 64)))
        let journal = await f.store.resourceFileJournal()
        try journal.enqueueAutomaticDownloads()
        let original = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        let resolver = CacheResolver(), bytes = CacheBytes()
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes), automaticNetwork: feed.source)
        let stream = try await center.transferSnapshots(for: .init()), seen = Mutex<V2ResourceTransferWaitingReason?>(nil)
        let observer = Task { for await snapshot in stream { if case .available(let page) = snapshot { seen.withLock { $0 = page.entries.first?.waitingReason } } } }
        let worker = Task { try await cache.runRecovery() }
        let deadline = ContinuousClock.now + .seconds(10)
        while seen.withLock({ $0 }) != .network { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        feed.send(.init(available: true, cellular: true))
        while seen.withLock({ $0 }) != .networkPolicy { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        #expect(await resolver.calls == 0)
        #expect(await bytes.calls == 0)
        feed.send(.unrestricted)
        try await f.waitForPhase(original.id, .completed)
        let final = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(final.id == original.id && final.createdAt == original.createdAt && final.confirmedBytes == 4)
        #expect(await bytes.calls == 1)
        worker.cancel(); _ = await worker.result; observer.cancel(); await observer.value
        await center.close(); try await f.remove()
    }

    @Test func durableDirectReadShowsCapacityWaitUntilAnActualWriterDrains() async throws {
        let f = try Fixture(), media = (0..<5).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        let messages = media.map { _ in V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())) }
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.map(\.mediaID)))
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        for i in 0..<5 { try await f.index(media[i], message: messages[i], payload: try #require(payloads[media[i].mediaID])); _ = try await center.prepareMessageDownload(mediaID: media[i].mediaID, message: messages[i]) }
        let cache = try await center.downloadCache(using: .init(targetResolver: ParallelRecoveryResolver(payloads: payloads), byteTransfer: bytes))
        var reads: [Task<V2ResourceCachedFile, any Error>] = []
        let deadline = ContinuousClock.now + .seconds(10)
        for i in 0..<4 { reads.append(Task { try await cache.download(media[i], message: messages[i]) }) }
        while await bytes.started.count != 4 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        reads.append(Task { try await cache.download(media[4], message: messages[4]) })
        while await cache.admissionCounts.waiting != 1 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        let stream = try await center.transferSnapshots(for: .init()), seen = Mutex(false)
        let observer = Task { for await snapshot in stream { if case .available(let page) = snapshot, page.entries.contains(where: { $0.mediaID == media[4].mediaID && $0.waitingReason == .transferSlot }) { seen.withLock { $0 = true }; return } } }
        while !seen.withLock({ $0 }) { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        #expect(await bytes.started.count == 4)
        await bytes.release(media[0].mediaID)
        while !(await bytes.started.contains(media[4].mediaID)) { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        await bytes.releaseAll()
        for read in reads { _ = try await read.value }
        #expect(try await f.store.managedResourceTransfers(.init()).entries.count == 5)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.allSatisfy { $0.phase == .completed })
        observer.cancel(); await observer.value
        await center.close(); try await f.remove()
    }

    @Test func unresolvedDemandRevokedBeforeRecoveryDoesNotAuthorizeOrDownload() async throws {
        let f = try Fixture(), center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let media = MediaID(uuid: UUID()), message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        guard case .queued(let transfer) = try await center.prepareMessageDownload(mediaID: media, message: message) else { Issue.record("Missing demand"); return }
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_message_tombstones(message_id,source_event_id,room_id,message_revision) VALUES(?,?,?,2)",
                arguments: [message.messageID.rawValue,UUID().uuidString,message.roomID.rawValue])
        }
        let resolver = CacheResolver(), bytes = CacheBytes()
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let worker = Task { try await cache.runRecovery() }
        try await f.waitForPhase(transfer, .requiresAttention(.sourceUnavailable))
        #expect(await resolver.calls == 0)
        #expect(await bytes.calls == 0)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await center.prepareMessageDownload(mediaID: media, message: message) }
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test func unresolvedSourcesShareBytesAndKeepTheirOriginalTaskIdentities() async throws {
        let f = try Fixture(), center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let media = [V2MediaReference(mediaID: .init(uuid: UUID())), V2MediaReference(mediaID: .init(uuid: UUID()))]
        let locations = [V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())),
                         V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))]
        var ids: Set<V2ManagedResourceTransferID> = []
        for i in 0..<2 {
            guard case .queued(let id) = try await center.prepareMessageDownload(mediaID: media[i].mediaID, message: locations[i]) else { Issue.record("Missing demand"); return }
            ids.insert(id)
        }
        let before = try await f.store.managedResourceTransfers(.init()).entries
        #expect(before.count == 2 && before.allSatisfy { $0.phase == .resolvingMetadata && $0.totalBytes == nil })
        let bytes = CacheBytes(), resolver = CacheResolver()
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let worker = Task { try await cache.runRecovery() }
        for id in ids { try await f.waitForPhase(id, .completed) }
        let history = try await f.store.managedResourceTransfers(.init()).entries
        #expect(Set(history.map(\.id)) == ids && history.allSatisfy { $0.confirmedBytes == 4 })
        #expect(await bytes.calls == 1)
        #expect(await resolver.calls >= 2)
        for i in 0..<2 { #expect(try await center.prepareMessageDownload(mediaID: media[i].mediaID, message: locations[i]) == .local) }
        #expect(try await f.store.managedResourceTransfers(.init()).entries.count == 2)
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test func unresolvedDemandSupportsPauseResumeAndCancelWithoutNetworkMetadata() async throws {
        let f = try Fixture(), center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let media = MediaID(uuid: UUID()), message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        guard case .queued(let transfer) = try await center.prepareMessageDownload(mediaID: media, message: message), case .download(let id) = transfer else { Issue.record("Missing demand"); return }
        let journal = await f.store.resourceFileJournal()
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.actions.contains(.pause) == true)
        _ = try journal.requestForegroundDownloadControl(id, control: .pause, liveOwner: nil)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .paused)
        await #expect(throws: V2ResourceDownloadControlError.paused) { try await center.prepareMessageDownload(mediaID: media, message: message) }
        try await f.store.resumeManagedResourceTransfer(transfer)
        #expect(try await center.prepareMessageDownload(mediaID: media, message: message) == .queued(transfer))
        _ = try journal.requestForegroundDownloadControl(id, control: .cancel, liveOwner: nil)
        try await center.files.cancelForegroundDownload(id)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .cancelled)
        await center.close(); try await f.remove()
    }

    @Test func publishedUnboundBytesDoNotCreateAnotherReadTask() async throws {
        let f = try Fixture(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let key = V2ResourceKey(home: .room(message.roomID), mediaID: media.mediaID)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let journal = await f.store.resourceFileJournal(), owner = UUID()
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: CacheBytes.payload).map { String(format: "%02x", $0) }.joined())
        let id = try journal.beginForegroundDownload(identity: checksum.value + ":4", mediaID: media.mediaID,
            message: message, bytes: 4, checksum: checksum, owner: owner)
        try journal.foregroundDownloadAwaitingVerification(id, owner: owner)
        let source = f.directory.appending(path: "published-before-binding")
        try CacheBytes.payload.write(to: source)
        let file = try await center.files.publishCopy(of: source, byteCount: 4, checksum: checksum, retention: .cache)
        try journal.completeForegroundDownload(id, owner: owner, fileID: file)
        let variant = try #require(try await center.files.variantSnapshots(for: key).first)
        #expect(variant.localState == .needsDownload)
        #expect(try await center.prepareMessageDownload(mediaID: media.mediaID, message: message) == .local)
        let bytes = CacheBytes(), resolver = CacheResolver()
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        _ = try await cache.download(media, message: message)
        #expect(await bytes.calls == 0)
        #expect(await resolver.calls > 0)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.map(\.id) == [.download(id)])
        await center.close(); try await f.remove()
    }

    @Test func messageReadPreparationUsesExactSourceAndOnlyQueuesMissingKnownBytes() async throws {
        let f = try Fixture(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let room = RoomID(uuid: UUID())
        let message = try V2MediaMessageLocation(roomID: room, messageID: .init(room.rawValue))
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let pending = try await center.prepareMessageDownload(mediaID: media.mediaID, message: message)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .resolvingMetadata)
        let avatarOnly = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: media.mediaID), revision: 1,
            displayName: .init("recover.bin"), contentType: "application/octet-stream", byteCount: 4,
            checksum: .init(value: SHA256.hash(data: CacheBytes.payload).map { String(format: "%02x", $0) }.joined()), state: .ready)
        try await f.store.indexResource(avatarOnly, reference: .groupAvatar(room), businessRevision: 1)
        #expect(try await center.prepareMessageDownload(mediaID: media.mediaID, message: message) == pending)
        try await f.index(media, message: message)
        let result = try await center.prepareMessageDownload(mediaID: media.mediaID, message: message)
        guard case .queued(let id) = result else { Issue.record("Missing durable admission"); return }
        #expect(try await center.prepareMessageDownload(mediaID: media.mediaID, message: message) == result)
        #expect(result == pending)
        let cache = try await center.downloadCache(using: .init(targetResolver: CacheResolver(), byteTransfer: CacheBytes()))
        _ = try await cache.download(media, message: message)
        #expect(try await center.prepareMessageDownload(mediaID: media.mediaID, message: message) == .local)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.map(\.id) == [id])
        try await f.store.revokeResourceReference(.message(message, ordinal: 0), businessRevision: 2)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await center.prepareMessageDownload(mediaID: media.mediaID, message: message) }
        await center.close(); try await f.remove()
    }

    @Test func userQueuePromotionPreservesRetryFloorAndChargedAttempts() async throws {
        let f = try Fixture(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let key = V2ResourceKey(home: .room(message.roomID), mediaID: media.mediaID)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let detail = try #require(try await center.details(for: key)), source = try #require(detail.sources.first)
        let transfer = try await center.enqueueDownload(key, source: source)
        guard case .download(let id) = transfer else { Issue.record("Expected canonical download"); return }
        let floorMilliseconds = Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000)
        let floor = Date(timeIntervalSince1970: Double(floorMilliseconds) / 1000)
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_download_jobs SET work_priority=3,attempt_count=3,retry_at_milliseconds=? WHERE job_id=?", arguments: [floorMilliseconds,id.uuidString]) }
        #expect(try await center.enqueueDownload(key, source: source) == transfer)
        let journal = await f.store.resourceFileJournal()
        #expect(try journal.requestedDownloads().isEmpty)
        #expect(try journal.claimDownloadResume(id, owner: UUID()) == nil)
        #expect(try await journal.downloadResumeSchedule().nextAttemptAt() == floor)
        #expect(try journal.requestedDownloads(now: floor) == [id])
        let facts = try await f.store.databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT work_priority,attempt_count,retry_at_milliseconds FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) else { throw V2ResourceStorageError.unavailable }
            return (row["work_priority"] as Int, row["attempt_count"] as Int, row["retry_at_milliseconds"] as Int64)
        }
        #expect(facts.0 == V2NetworkWorkPriority.interactive.rawValue)
        #expect(facts.1 == 3)
        #expect(facts.2 == floorMilliseconds)
        await center.close(); try await f.remove()
    }

    @Test func manualDownloadIsPersistedBeforeNetworkAndColdRecoveryUsesSameJob() async throws {
        let f = try Fixture(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let key = V2ResourceKey(home: .room(message.roomID), mediaID: media.mediaID)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let detail = try #require(try await center.details(for: key))
        let source = try #require(detail.sources.first)
        let id = try await center.enqueueDownload(key, source: source)
        #expect(try await center.enqueueDownload(key, source: source) == id)
        let queued = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(queued.id == id && queued.phase == .queued && queued.confirmedBytes == nil)
        await center.close()
        let reopened = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .queued)
        let resolver = CacheResolver(), bytes = CacheBytes()
        let cache = try await reopened.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let worker = Task { try await cache.runRecovery() }
        try await f.waitForPhase(id, .completed)
        let completed = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(completed.id == id && completed.createdAt == queued.createdAt && completed.confirmedBytes == 4)
        #expect(await bytes.calls == 1)
        #expect(await bytes.priorities == [.interactive])
        worker.cancel(); _ = await worker.result
        await reopened.close(); try await f.remove()
    }

    @Test func queuedDownloadRevalidatesRevocationAndRepeatedClickCannotResumeUserPause() async throws {
        let f = try Fixture(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let key = V2ResourceKey(home: .room(message.roomID), mediaID: media.mediaID)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let detail = try #require(try await center.details(for: key)), source = try #require(detail.sources.first)
        let id = try await center.enqueueDownload(key, source: source)
        try await center.pauseTransfer(id)
        await #expect(throws: V2ResourceDownloadControlError.paused) { try await center.enqueueDownload(key, source: source) }
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .paused)
        try await center.resumeTransfer(id)
        try await f.store.revokeResourceReference(.message(message, ordinal: 0), businessRevision: 2)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await center.enqueueDownload(key, source: source) }
        let resolver = CacheResolver(), bytes = CacheBytes()
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let worker = Task { try await cache.runRecovery() }
        try await f.waitForPhase(id, .requiresAttention(.sourceUnavailable))
        #expect(await bytes.calls == 0)
        #expect(await resolver.calls == 0)
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test func actualRangeProgressUsesCanonicalJobAndPauseHidesItBeforeWriterDrain() async throws {
        let f = try Fixture(), resolver = CacheResolver(), gate = CacheRangeProgressGate()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver,
            byteTransfer: V2URLSessionMediaByteTransfer(transport: gate, chunkBytes: 4)))
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let request = Task { try await cache.download(media, message: message) }
        await gate.entered()
        var updates = try await center.transferSnapshots(for: .init()).makeAsyncIterator()
        let row: V2ManagedResourceTransfer
        guard case .available(let page) = await updates.next(), let first = page.entries.first else {
            Issue.record("Missing canonical download task")
            await gate.release(); _ = await request.result; await center.close(); try await f.remove(); return
        }
        row = first
        #expect(row.attemptProgress?.transferredBytes == 2 && row.attemptProgress?.expectedBytes == 4)
        #expect(row.phase == .transferring && row.confirmedBytes == nil)
        let pause = Task { try await center.pauseTransfer(row.id) }
        await gate.cancelled()
        while let update = await updates.next() {
            if case .available(let page) = update, let current = page.entries.first, current.phase == .pausing {
                #expect(current.attemptProgress == nil); break
            }
        }
        #expect(await gate.liveProgress()?.transferredBytes == 2)
        await gate.release()
        try await pause.value; _ = await request.result
        #expect(await gate.liveProgress() == nil)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .paused)
        try await center.resumeTransfer(row.id)
        let recovery = Task { try await cache.runRecovery() }
        try await f.waitForPhase(row.id, .completed)
        let completed = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(completed.id == row.id && completed.createdAt == row.createdAt && completed.confirmedBytes == 4)
        #expect(await gate.ranges == ["bytes=0-3", "bytes=2-3"])
        recovery.cancel(); _ = await recovery.result
        await center.close(); try await f.remove()
    }

    @Test func cachedOnlyReadAuthorizesProtectsCleanupAndNeverDownloadsOnMissOrVersionChange() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes()
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message, contentType: "image/png")
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        #expect(try await f.store.resourceDirectory().entries.first?.localState == .needsDownload)
        #expect(try await cache.borrowCached(media, message: message) == nil)
        #expect(await bytes.calls == 0)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        _ = try await cache.download(media, message: message)
        #expect(try await f.store.resourceDirectory().entries.first?.localState == .available)
        let borrowed = try #require(try await cache.borrowCached(media, message: message))
        #expect(try Data(contentsOf: borrowed.fileURL) == CacheBytes.payload)
        #expect(try await center.planCleanup().fileIDs.isEmpty)
        await resolver.changeVersion()
        await #expect(throws: V2ResourceStorageError.integrityMismatch) { try await cache.borrowCached(media, message: message) }
        #expect(await bytes.calls == 1)
        await resolver.deny(media.mediaID)
        await #expect(throws: V2ClientMediaTransferError.serverStatus(403)) { try await cache.borrowCached(media, message: message) }
        await borrowed.release()
        let plan = try await center.planCleanup()
        #expect(plan.fileIDs.count == 1)
        _ = try await center.commitCleanup(plan)
        #expect(try await f.store.resourceDirectory().entries.first?.localState == .needsDownload)
        await center.close(); try await f.remove()
    }

    @Test func fullDirectRequestAdmissionStillLetsDurableRecoveryWaitWithoutAFalseFailure() async throws {
        let f = try Fixture(), media = (0..<17).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.prefix(4).map(\.mediaID)))
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: ParallelRecoveryResolver(payloads: payloads), byteTransfer: bytes))
        let active = media.prefix(4).map { item in Task { try await cache.download(item) } }
        let deadline = ContinuousClock.now + .seconds(15)
        while await bytes.started.count < 4 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        var queued: [Task<V2ResourceCachedFile, any Error>] = []
        for index in 4..<16 {
            queued.append(Task { try await cache.download(media[index]) })
            while await cache.admissionCounts.waiting != index - 3 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        }
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        let payload = try #require(payloads[media[16].mediaID])
        try await f.index(media[16], message: message, payload: payload)
        let journal = await f.store.resourceFileJournal(), owner = UUID()
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let job = try journal.beginForegroundDownload(identity: checksum.value + ":4", mediaID: media[16].mediaID,
            message: message, bytes: 4, checksum: checksum, owner: owner)
        _ = try journal.pauseForegroundDownload(job, owner: owner, issue: .interrupted)
        try await center.retryTransfer(.download(job))
        let worker = Task { try await cache.runRecovery() }
        while await cache.admissionCounts.waiting != 13 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        let before = try #require(try await f.store.managedResourceTransfers(.init()).entries.first { $0.id == .download(job) })
        #expect(before.phase == .preparing)
        #expect(!(await bytes.started.contains(media[16].mediaID)))
        for request in queued { request.cancel() }
        for request in queued { _ = await request.result }
        await bytes.release(media[0].mediaID)
        try await f.waitForPhase(.download(job), .completed)
        #expect(await bytes.started.contains(media[16].mediaID))
        #expect(await bytes.maximumActive == 4)
        worker.cancel(); _ = await worker.result
        await bytes.releaseAll()
        for request in active { _ = await request.result }
        await center.close(); try await f.remove()
    }

    @Test func directUserAdmissionPrecedesQueuedAutomaticWorkWithoutDuplicatingWriters() async throws {
        let f = try Fixture(), media = (0..<6).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        try await f.enableAutomaticImages()
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.map(\.mediaID)))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media[4], message: message, payload: #require(payloads[media[4].mediaID]), contentType: "image/png")
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: ParallelRecoveryResolver(payloads: payloads), byteTransfer: bytes))
        let active = media.prefix(4).map { item in Task { try await cache.download(item) } }
        let deadline = ContinuousClock.now + .seconds(10)
        while await bytes.started.count < 4 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        let automatic = Task {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .background)) {
                try await cache.download(media[4], message: message)
            }
        }
        while await cache.admissionCounts.waiting != 1 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        let user = Task { try await cache.download(media[5]) }
        while await cache.admissionCounts.waiting != 2 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        await bytes.release(media[0].mediaID)
        while !(await bytes.started.contains(media[5].mediaID)) { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        #expect(!(await bytes.started.contains(media[4].mediaID)))
        await bytes.release(media[1].mediaID)
        while !(await bytes.started.contains(media[4].mediaID)) { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        #expect(await bytes.maximumActive == 4)
        await bytes.releaseAll()
        for request in active { _ = await request.result }
        _ = try await user.value; _ = try await automatic.value
        await center.close(); try await f.remove()
    }

    @Test func actualAvatarAndMessageDownloadsClassifyOneSharedPhysicalFile() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let avatar = MediaID(uuid: UUID()), target = try await resolver.resolveDownloadTarget(mediaID: avatar, message: nil)
        let access = try V2ResourceAvatarAccess(mediaID: avatar, variantID: .init(uuid: UUID()), version: 1, checksum: target.checksum,
            plan: .init(mode: .httpGet, url: target.url, expiresAt: target.expiresAt, expectedByteCount: target.expectedByteCount, checksum: target.checksum))
        let first = try await cache.avatar(access, home: .account(f.scope.accountID))
        let avatarLease = try await first.borrowFile()
        #expect(try Data(contentsOf: avatarLease.fileURL) == CacheBytes.payload)
        await avatarLease.release()
        let initial = try await center.storageSnapshot()
        #expect(initial.avatarCacheBytes > 0 && initial.otherCacheBytes == 0 && initial.avatarCacheBytes == initial.totalBytes)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let second = try await cache.download(media, message: message)
        let messageLease = try await second.borrowFile()
        #expect(try Data(contentsOf: messageLease.fileURL) == CacheBytes.payload)
        await messageLease.release()
        let shared = try await center.storageSnapshot()
        #expect(shared.avatarCacheBytes == 0 && shared.otherCacheBytes == initial.totalBytes && shared.totalBytes == initial.totalBytes)
        #expect(shared.files.count == 1)
        #expect(await bytes.calls == 1)
        await center.close(); try await f.remove()
    }

    @Test func queuedAvatarCannotRebaseAnInvalidatedPlanAfterAdmission() async throws {
        let f = try Fixture(), media = (0..<5).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.prefix(4).map(\.mediaID)))
        let resolver = ParallelRecoveryResolver(payloads: payloads)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let active = media.prefix(4).map { item in Task { try await cache.download(item) } }
        let deadline = ContinuousClock.now + .seconds(10)
        while await bytes.started.count < 4 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        let target = try resolver.resolveDownloadTarget(mediaID: media[4].mediaID, message: nil)
        let access = try V2ResourceAvatarAccess(mediaID: media[4].mediaID, variantID: .init(uuid: UUID()), version: 1, checksum: target.checksum,
            plan: .init(mode: .httpGet, url: target.url, expiresAt: target.expiresAt, expectedByteCount: target.expectedByteCount, checksum: target.checksum))
        let queued = Task { try await cache.avatar(access, home: .account(f.scope.accountID)) }
        while await cache.admissionCounts.waiting != 1 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        try await cache.discard(media[4].mediaID)
        await bytes.release(media[0].mediaID)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await queued.value }
        #expect(!(await bytes.started.contains(media[4].mediaID)))
        #expect(await cache.admissionCounts.reserved == 0)
        await bytes.releaseAll()
        for request in active { _ = await request.result }
        await center.close(); try await f.remove()
    }

    @Test(arguments: [false, true]) func cancellationAndAccountCloseReleaseReservedReauthorizationOnlyAfterOwnedWorkDrains(closeAccount: Bool) async throws {
        let f = try Fixture(), media = (0..<6).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.map(\.mediaID)))
        let resolver = QueuedAccessResolver(payloads: payloads)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let active = media.prefix(4).map { item in Task { try await cache.download(item) } }
        let deadline = ContinuousClock.now + .seconds(10)
        while await bytes.started.count < 4 {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        await resolver.holdSecond(media[4].mediaID)
        let queued = Task { try await cache.download(media[4]) }
        while await cache.admissionCounts.waiting != 1 {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        await bytes.release(media[0].mediaID)
        while !(await resolver.isHeld(media[4].mediaID)) {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await cache.admissionCounts.reserved == 1)
        let next = Task { try await cache.download(media[5]) }
        while await cache.admissionCounts.waiting != 1 {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!(await bytes.started.contains(media[5].mediaID)))
        if closeAccount {
            let finished = Mutex(false)
            let closing = Task { await center.close(); finished.withLock { $0 = true } }
            while await cache.admissionCounts.reserved != 0 {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await cache.admissionCounts.waiting == 0)
            #expect(!finished.withLock { $0 })
            await resolver.release(media[4].mediaID); await bytes.releaseAll()
            _ = await queued.result; _ = await next.result
            for request in active { _ = await request.result }
            await closing.value
            #expect(finished.withLock { $0 })
        } else {
            queued.cancel(); await resolver.release(media[4].mediaID)
            await #expect(throws: CancellationError.self) { try await queued.value }
            while !(await bytes.started.contains(media[5].mediaID)) {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
            await bytes.releaseAll()
            _ = await next.result; for request in active { _ = await request.result }
            await center.close()
        }
        #expect(!(await bytes.started.contains(media[4].mediaID)))
        #expect(await cache.admissionCounts.reserved == 0)
        #expect(await cache.admissionCounts.waiting == 0)
        #expect(await bytes.maximumActive == 4)
        try await f.remove()
    }

    @Test func directRequestsQueueInOrderCancelIndependentlyAndBoundAdmission() async throws {
        let f = try Fixture()
        let media = (0..<17).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.map(\.mediaID)))
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: ParallelRecoveryResolver(payloads: payloads), byteTransfer: bytes))
        var requests: [Task<V2ResourceCachedFile, any Error>] = []
        do {
            let deadline = ContinuousClock.now + .seconds(15)
            for index in 0..<4 { requests.append(Task { try await cache.download(media[index]) }) }
            while await bytes.started.count != 4 {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
            for index in 4..<16 {
                requests.append(Task { try await cache.download(media[index]) })
                while await cache.admissionCounts.waiting != index - 3 {
                    try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
                }
            }
            await #expect(throws: V2ResourceOperationScopeError.busy) { try await cache.download(media[16]) }
            #expect(await bytes.started.count == 4)
            #expect(await cache.admissionCounts.reserved == 0)
            requests[4].cancel()
            await #expect(throws: CancellationError.self) { try await requests[4].value }
            #expect(await cache.admissionCounts.waiting == 11)
            await bytes.release(media[0].mediaID)
            while !(await bytes.started.contains(media[5].mediaID)) {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!(await bytes.started.contains(media[4].mediaID)))
            #expect(!(await bytes.started.contains(media[6].mediaID)))
            #expect(await bytes.maximumActive == 4)
            for request in requests { request.cancel() }
            for request in requests { _ = await request.result }
            #expect(await cache.admissionCounts.waiting == 0)
            #expect(await cache.admissionCounts.reserved == 0)
        } catch {
            for request in requests { request.cancel() }
            await bytes.releaseAll()
            for request in requests { _ = await request.result }
            await center.close(); try await f.remove(); throw error
        }
        await bytes.releaseAll()
        await center.close(); try await f.remove()
    }

    @Test func queuedRequestReauthorizesAndCannotStartBytesAfterItsReferenceIsRevoked() async throws {
        let f = try Fixture(), media = (0..<5).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.prefix(4).map(\.mediaID)))
        let resolver = QueuedAccessResolver(payloads: payloads)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let active = media.prefix(4).map { item in Task { try await cache.download(item) } }
        let deadline = ContinuousClock.now + .seconds(10)
        while await bytes.started.count < 4 {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        let queued = Task { try await cache.download(media[4]) }
        while await cache.admissionCounts.waiting != 1 {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        await resolver.revoke(media[4].mediaID)
        await bytes.release(media[0].mediaID)
        await #expect(throws: V2ClientMediaTransferError.authorizationDenied) { try await queued.value }
        #expect(await resolver.calls[media[4].mediaID] == 2)
        #expect(!(await bytes.started.contains(media[4].mediaID)))
        #expect(await cache.admissionCounts.waiting == 0)
        #expect(await cache.admissionCounts.reserved == 0)
        await bytes.releaseAll()
        for request in active { _ = await request.result }
        await center.close(); try await f.remove()
    }

    @Test func interactiveReaderPromotesSharedAutomaticFlightAndPreservesItsOriginalJournal() async throws {
        let f = try Fixture(), resolver = CacheResolver(), scheduler = V2AccountWorkScheduler(), gate = CanonicalDownloadGate()
        try await f.enableAutomaticImages()
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message, contentType: "image/png")
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: ScheduledDownloadGate(scheduler: scheduler, gate: gate)))
        let occupied = try await scheduler.acquire(.init(service: "mediaProvider", priority: .background, kind: .byteTransfer(.download)))
        let automatic = Task {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .background)) {
                try await cache.download(media, message: message)
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while await scheduler.snapshot().waitingByteTransfers != 1 {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        let original = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        let user = Task { try await cache.download(media, message: message) }
        await gate.entered() // This requires promotion into the reserved user slot.
        let persistedPriority = try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT work_priority FROM v2_resource_download_jobs WHERE job_id=?", arguments: [original.id.value.uuidString]) }
        #expect(persistedPriority == V2NetworkWorkPriority.interactive.rawValue)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.map(\.id) == [original.id])
        #expect(await resolver.calls == 2)
        automatic.cancel()
        await #expect(throws: CancellationError.self) { try await automatic.value }
        #expect(await scheduler.snapshot().activeDownloads == 2)
        await gate.release()
        let result = try await user.value, lease = try await result.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == CacheBytes.payload)
        await lease.release()
        #expect(await gate.calls == 1)
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.map(\.id) == [original.id])
        #expect(await scheduler.snapshot().activeDownloads == 1)
        _ = await scheduler.release(occupied)
        await center.close(); await scheduler.closeAndDrain(); try await f.remove()
    }

    @Test(arguments: [V2ClientMediaTransferError.checksumMismatch, .authorizationDenied])
    func networkChangesNeverRetryPermanentAutomaticFailures(failure: V2ClientMediaTransferError) async throws {
        let f = try Fixture(), feed = AutomaticNetworkFeed(), bytes = AutomaticPermanentFailureBytes(failure: failure)
        try await f.enableAutomaticImages()
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        try await f.index(media, message: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())), contentType: "image/png")
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: CacheResolver(), byteTransfer: bytes), automaticNetwork: feed.source)
        feed.send(.unrestricted)
        let worker = Task { try await cache.runRecovery() }
        do {
            let deadline = ContinuousClock.now + .seconds(10)
            while try await f.store.managedResourceTransfers(.init()).entries.first?.phase != .requiresAttention(failure == .checksumMismatch ? .integrity : .sourceUnavailable) {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
            feed.send(.unavailable); feed.send(.unrestricted)
            let journal = await f.store.resourceFileJournal()
            try journal.requeueRecoverableAutomaticDownloads()
            #expect(try journal.requestedDownloads().isEmpty)
            #expect(try journal.nextRequestedDownloadAttempt(excluding: [], allowingAutomatic: true) == nil)
            #expect(try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT automatic_retry_allowed FROM v2_resource_download_jobs LIMIT 1") } == 0)
            #expect(await bytes.calls == 1)
        } catch {
            worker.cancel(); _ = await worker.result
            await center.close(); try await f.remove(); throw error
        }
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test func explicitPauseAndCancellationCannotBeUndoneByAutomaticNetworkRecovery() async throws {
        let f = try Fixture(), feed = AutomaticNetworkFeed(), bytes = AutomaticRetryBytes(failures: 100)
        try await f.enableAutomaticImages()
        let clock = Mutex(Date())
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        try await f.index(media, message: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())), contentType: "image/png")
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: CacheResolver(), byteTransfer: bytes), automaticNetwork: feed.source, recoveryNow: { clock.withLock { $0 } })
        feed.send(.unrestricted)
        let worker = Task { try await cache.runRecovery() }
        do {
            let deadline = ContinuousClock.now + .seconds(10)
            while try await f.store.databasePool.read({ try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_resource_download_jobs WHERE automatic_retry_allowed=1 AND resume_requested=1 AND execution_owner IS NULL") }) != 1 {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
            let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
            try await center.pauseTransfer(job.id)
            clock.withLock { $0 = $0.addingTimeInterval(1000) }
            feed.send(.unavailable); feed.send(.unrestricted)
            try await f.store.resourceFileJournal().requeueRecoverableAutomaticDownloads()
            #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .paused)
            #expect(await bytes.calls == 1)
            try await center.cancelTransfer(job.id)
            try await f.waitForPhase(job.id, .cancelled)
            try await f.store.resourceFileJournal().requeueRecoverableAutomaticDownloads()
            #expect(try await f.store.resourceFileJournal().requestedDownloads().isEmpty)
            #expect(await bytes.calls == 1)
        } catch {
            worker.cancel(); _ = await worker.result
            await center.close(); try await f.remove(); throw error
        }
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test func automaticRetryAfterSurvivesJournalRoundTripAndCannotBeClaimedEarly() async throws {
        let f = try Fixture()
        try await f.enableAutomaticImages()
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message, contentType: "image/png")
        let journal = await f.store.resourceFileJournal(), now = Date(), owner = UUID()
        try journal.enqueueAutomaticDownloads()
        let id = try #require(try journal.requestedDownloads().first)
        _ = try #require(try journal.claimDownloadResume(id, owner: owner, now: now))
        _ = try journal.pauseForegroundDownload(id, owner: owner, issue: .network)
        try journal.recordAutomaticDownloadFailure(id, issue: .network, now: now, retryAfter: now.addingTimeInterval(120))
        try journal.requeueRecoverableAutomaticDownloads()
        #expect(try journal.requestedDownloads(now: now.addingTimeInterval(119)).isEmpty)
        #expect(try journal.claimDownloadResume(id, owner: UUID(), now: now.addingTimeInterval(119)) == nil)
        #expect(try journal.requestedDownloads(now: now.addingTimeInterval(121)) == [id])
        let claimed = try #require(try journal.claimDownloadResume(id, owner: owner, now: now.addingTimeInterval(121)))
        #expect(claimed.id == id)
        _ = try journal.pauseForegroundDownload(id, owner: owner, issue: .network)
        try await f.remove()
    }

    @Test func policyRestrictedAutomaticTaskResumesOriginalJobOnlyWhenPolicyAndNetworkAllowIt() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(), feed = AutomaticNetworkFeed()
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let journal = await f.store.resourceFileJournal(), owner = UUID()
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: CacheBytes.payload).map { String(format: "%02x", $0) }.joined())
        let id = try journal.beginForegroundDownload(identity: checksum.value + ":4", mediaID: media.mediaID,
            message: message, bytes: 4, checksum: checksum, owner: owner, priority: .background)
        // Recover an already-admitted automatic intent under now-disabled file policy.
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes), automaticNetwork: feed.source)
        feed.send(.unrestricted)
        let worker = Task { try await cache.runRecovery() }
        do {
            try await f.waitForPhase(.download(id), .requiresAttention(.automaticDownloadRestricted))
            #expect(await bytes.calls == 0)
            feed.send(.unavailable)
            let deadline = ContinuousClock.now + .seconds(5)
            while await cache.automaticNetworkConditions != .unavailable {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
            try await center.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.file], maximumByteCount: 1024)))
            #expect(await bytes.calls == 0)
            feed.send(.unrestricted)
            try await f.waitForPhase(.download(id), .completed)
            #expect(try await f.store.managedResourceTransfers(.init()).entries.map(\.id) == [.download(id)])
            #expect(await bytes.calls == 1)
            #expect(try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT attempt_count FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) } == 2)
        } catch {
            worker.cancel(); _ = await worker.result
            await center.close(); try await f.remove(); throw error
        }
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test(arguments: [false, true])
    func automaticRecoveryWaitsForNetworkAndKeepsOriginalIdentityAndFiniteBudget(succeeds: Bool) async throws {
        let f = try Fixture(), feed = AutomaticNetworkFeed(), resolver = CacheResolver()
        try await f.enableAutomaticImages()
        let bytes = AutomaticRetryBytes(failures: succeeds ? 4 : 100)
        let clock = Mutex(Date())
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        try await f.index(media, message: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())), contentType: "image/png")
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes),
            automaticNetwork: feed.source, recoveryNow: { clock.withLock { $0 } })
        var worker = Task { try await cache.runRecovery() }
        func wait(_ predicate: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while try await !predicate() {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func change(_ value: V2ResourceAutomaticNetworkConditions) async throws {
            feed.send(value)
            try await wait { await cache.automaticNetworkConditions == value }
        }
        do {
            try await wait { feed.subscribers == 1 }
            try await change(.init(available: true, cellular: true))
            #expect(await bytes.calls == 0)
            try await wait { try await f.store.managedResourceTransfers(.init()).entries.count == 1 }
            #expect(await resolver.calls == 0)
            try await change(.init(available: true, constrained: true))
            #expect(await bytes.calls == 0)
            try await change(.unrestricted)
            var original: V2ManagedResourceTransferID?
            for attempt in 1...5 {
                if attempt < 5 {
                    try await wait {
                        let waiting = try await f.store.databasePool.read { db -> Bool in
                            guard let row = try Row.fetchOne(db, sql: "SELECT attempt_count,execution_owner,resume_requested,state,retry_at_milliseconds FROM v2_resource_download_jobs LIMIT 1") else { return false }
                            return row["attempt_count"] as Int == attempt && row["execution_owner"] as String? == nil
                                && row["resume_requested"] as Bool && row["state"] as String == "paused"
                                && row["retry_at_milliseconds"] as Int64 > Int64(clock.withLock { $0 }.timeIntervalSince1970 * 1000)
                        }
                        return await bytes.calls == attempt && waiting
                    }
                } else {
                    try await wait {
                        try await f.store.managedResourceTransfers(.init()).entries.first?.phase == (succeeds ? .completed : .requiresAttention(.network))
                    }
                }
                let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
                if let original { #expect(job.id == original) } else { original = job.id }
                if attempt == 2 {
                    worker.cancel(); _ = await worker.result
                    try await wait { feed.subscribers == 0 }
                    worker = Task { try await cache.runRecovery() }
                    try await wait { feed.subscribers == 1 }
                }
                try await change(.unavailable)
                clock.withLock { $0 = $0.addingTimeInterval(60) }
                #expect(await bytes.calls == attempt)
                try await change(.unrestricted)
            }
            #expect(await bytes.calls == 5)
            let attempts = try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT attempt_count FROM v2_resource_download_jobs LIMIT 1") }
            #expect(attempts == 5)
            #expect(try await f.store.managedResourceTransfers(.init()).entries.count == 1)
        } catch {
            worker.cancel(); _ = await worker.result
            await center.close(); try await f.remove(); throw error
        }
        worker.cancel(); _ = await worker.result
        try await wait { feed.subscribers == 0 }
        await center.close(); try await f.remove()
    }

    @Test func automaticProducerWakesForPolicyChangesAndDoesNotRefillEvictedHistory() async throws {
        let f = try Fixture()
        let image = V2MediaReference(mediaID: .init(uuid: UUID())), file = V2MediaReference(mediaID: .init(uuid: UUID()))
        let payloads = [image.mediaID: Data([1,7,8,9]), file.mediaID: Data([2,7,8,9])]
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: [])
        for item in [image, file] {
            try await f.index(item, message: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())),
                payload: try #require(payloads[item.mediaID]), contentType: item == image ? "image/png" : "application/octet-stream")
        }
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        try await center.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.image], maximumByteCount: 3)))
        let cache = try await center.downloadCache(using: .init(targetResolver: ParallelRecoveryResolver(payloads: payloads), byteTransfer: bytes), automaticNetwork: .unrestricted)
        let journal = await f.store.resourceFileJournal()
        try journal.enqueueAutomaticDownloads()
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        let worker = Task { try await cache.runRecovery() }
        func waitFor(_ media: MediaID) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while try await !f.store.managedResourceTransfers(.init(group: .finished)).entries.contains(where: { $0.mediaID == media && $0.phase == .completed }) {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        do {
            try await center.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.image], maximumByteCount: 4)))
            try await waitFor(image.mediaID)
            #expect(await bytes.started == [image.mediaID])
            try await center.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.image, .file], maximumByteCount: 4)))
            try await waitFor(file.mediaID)
            #expect(await bytes.started == [image.mediaID, file.mediaID])
        } catch {
            worker.cancel(); _ = await worker.result
            await center.close(); try await f.remove(); throw error
        }
        worker.cancel(); _ = await worker.result
        try await cache.discard(image.mediaID); try await cache.discard(file.mediaID)
        try await f.store.databasePool.write { try $0.execute(sql: "DELETE FROM v2_resource_download_jobs WHERE state='completed'") }
        try journal.enqueueAutomaticDownloads()
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        await center.close(); try await f.remove()
    }

    @Test func automaticRestrictionsDoNotPreventExplicitUserDownload() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes()
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        await #expect(throws: V2ResourceAutomaticDownloadError.policyRestricted) {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .background)) {
                try await cache.download(media, message: message)
            }
        }
        #expect(await bytes.calls == 0)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        _ = try await cache.download(media, message: message)
        #expect(await bytes.calls == 1)
        await center.close(); try await f.remove()
    }
    @Test func networkPreferencesPersistAndColdRetryUsesCurrentAccountSettings() async throws {
        let f = try Fixture(), resolver = CacheResolver(), interrupted = CacheBytes(interruptOnce: true)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let first = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        try await first.setDownloadNetworkPreferences(.init(allowsCellular: false, allowsConstrained: false))
        let cache = try await first.downloadCache(using: .init(targetResolver: resolver, byteTransfer: interrupted))
        await #expect(throws: URLError.self) { try await cache.download(media, message: message) }
        #expect(await interrupted.networkConstraints == [.init(allowsCellular: false, allowsExpensive: true, allowsConstrained: false)])
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        await first.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        #expect(try await restored.downloadNetworkPreferences() == .init(allowsCellular: false, allowsConstrained: false))
        try await restored.setDownloadNetworkPreferences(.init(allowsCellular: true, allowsConstrained: true))
        let bytes = CacheBytes(), fresh = try await restored.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        try await restored.retryTransfer(job.id)
        let worker = Task { try await fresh.runRecovery() }
        try await f.waitForPhase(job.id, .completed)
        #expect(await bytes.networkConstraints == [.unrestricted])
        worker.cancel(); _ = await worker.result
        await restored.close(); try await f.remove()
    }
    private struct Fixture {
        let directory: URL
        let scope: V2AccountStorageScope
        let store: GRDBV2LocalSyncStore
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("unified-download-\(UUID())")
            let user = UserID(uuid: UUID())
            store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
            scope = .init(incarnation: UUID(), accountID: user, directory: directory, cacheDirectory: directory.appending(path: "cache-scope"))
        }
        func enableAutomaticImages() async throws {
            let journal = await store.resourceFileJournal()
            try journal.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.image], maximumByteCount: 10 * 1024 * 1024)))
        }
        func remove() async throws { try await store.close(); try FileManager.default.removeItem(at: directory) }
        func index(_ media: V2MediaReference, message: V2MediaMessageLocation, payload: Data = CacheBytes.payload, contentType: String = "application/octet-stream") async throws {
            let descriptor = try V2ResourceDescriptor(key: .init(home: .room(message.roomID), mediaID: media.mediaID), revision: 1,
                displayName: .init("recover.bin"), contentType: contentType, byteCount: 4,
                checksum: .init(value: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()), state: .ready)
            try await store.indexResource(descriptor, reference: .message(message, ordinal: 0), businessRevision: 1)
        }
        func waitForPhase(_ id: V2ManagedResourceTransferID, _ phase: V2ManagedResourceTransferPhase) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                if try await store.managedResourceTransfers(.init()).entries.first(where: { $0.id == id })?.phase == phase { return }
                try #require(ContinuousClock.now < deadline, "Download did not reach expected phase")
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    @Test func recoveryReusesAFreeSlotWhileAnotherDownloadStillOwnsItsWriter() async throws {
        let f = try Fixture()
        let media = (0..<4).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.prefix(2).map(\.mediaID)))
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: ParallelRecoveryResolver(payloads: payloads), byteTransfer: bytes))
        let journal = await f.store.resourceFileJournal()
        func enqueue(_ index: Int) async throws -> UUID {
            let item = media[index], payload = try #require(payloads[item.mediaID])
            let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
            try await f.index(item, message: message, payload: payload)
            let checksum = try V2ResourceChecksum(value: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
            let owner = UUID()
            let id = try journal.beginForegroundDownload(identity: checksum.value + ":4", mediaID: item.mediaID,
                message: message, bytes: 4, checksum: checksum, owner: owner,
                now: Date(timeIntervalSince1970: Double(index)))
            _ = try journal.pauseForegroundDownload(id, owner: owner, issue: .interrupted)
            try await center.retryTransfer(.download(id))
            return id
        }
        _ = try await enqueue(0); _ = try await enqueue(1); let third = try await enqueue(2)
        let worker = Task { try await cache.runRecovery() }
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while await bytes.started.count < 2 {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await bytes.started.count == 2)
            await bytes.release(media[1].mediaID)
            try await f.waitForPhase(.download(third), .completed)
            #expect(await bytes.isBlocked(media[0].mediaID))
            let fourth = try await enqueue(3)
            try await f.waitForPhase(.download(fourth), .completed)
            #expect(await bytes.started.count == 4)
            #expect(await bytes.maximumActive == 2)
            #expect(await bytes.isBlocked(media[0].mediaID))
        } catch {
            worker.cancel(); await bytes.releaseAll(); _ = await worker.result
            await center.close(); try await f.remove(); throw error
        }
        worker.cancel(); await bytes.releaseAll(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test func recoveryWaitsForActualPhysicalCapacityInsteadOfPersistingSpaceFailure() async throws {
        let f = try Fixture()
        let media = (0..<5).map { _ in V2MediaReference(mediaID: .init(uuid: UUID())) }
        let payloads = Dictionary(uniqueKeysWithValues: media.enumerated().map { ($0.element.mediaID, Data([UInt8($0.offset + 1), 7, 8, 9])) })
        let bytes = ParallelRecoveryBytes(payloads: payloads, blocked: Set(media.prefix(4).map(\.mediaID)))
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: ParallelRecoveryResolver(payloads: payloads), byteTransfer: bytes))
        let direct = media.prefix(4).map { item in Task { try await cache.download(item) } }
        var worker: Task<Void, any Error>?
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while await bytes.started.count < 4 {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            let item = media[4], payload = try #require(payloads[item.mediaID])
            let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
            try await f.index(item, message: message, payload: payload)
            let checksum = try V2ResourceChecksum(value: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
            let journal = await f.store.resourceFileJournal(), owner = UUID()
            let id = try journal.beginForegroundDownload(identity: checksum.value + ":4", mediaID: item.mediaID,
                message: message, bytes: 4, checksum: checksum, owner: owner)
            _ = try journal.pauseForegroundDownload(id, owner: owner, issue: .interrupted)
            try await center.retryTransfer(.download(id))
            worker = Task { try await cache.runRecovery() }
            let claimDeadline = ContinuousClock.now + .seconds(5)
            while true {
                let claim = try await f.store.databasePool.read { db -> (attempts: Int, owned: Bool, state: String, issue: String?)? in
                    guard let row = try Row.fetchOne(db,
                        sql: "SELECT execution_owner,attempt_count,state,issue FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) else { return nil }
                    return (row["attempt_count"], (row["execution_owner"] as String?) != nil, row["state"], row["issue"])
                }
                if let claim, claim.attempts == 1 {
                    #expect(claim.owned)
                    #expect(claim.state == "preparing")
                    #expect(claim.issue == nil)
                    break
                }
                try #require(ContinuousClock.now < claimDeadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await bytes.started.count == 4)
            await bytes.release(media[0].mediaID)
            try await f.waitForPhase(.download(id), .completed)
            #expect(await bytes.started.count == 5)
            #expect(await bytes.maximumActive == 4)
        } catch {
            worker?.cancel(); for task in direct { task.cancel() }
            await bytes.releaseAll(); _ = await worker?.result
            for task in direct { _ = await task.result }
            await center.close(); try await f.remove(); throw error
        }
        worker?.cancel(); await bytes.releaseAll(); _ = await worker?.result
        for task in direct { _ = await task.result }
        await center.close(); try await f.remove()
    }

    @Test func everyCallerAuthorizesBeforeReusingOnePhysicalBlobIncludingColdRestart() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes()
        let network = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: bytes)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: network)
        let firstMedia = V2MediaReference(mediaID: .init(uuid: UUID())), secondMedia = V2MediaReference(mediaID: .init(uuid: UUID()))
        let first = try await cache.download(firstMedia)
        let second = try await cache.download(secondMedia)
        #expect(first.fileURL == second.fileURL)
        #expect(await bytes.calls == 1)
        #expect(await resolver.calls == 2)
        #expect(try await center.files.snapshot().files.count == 1)
        let history = try await f.store.managedResourceTransfers(.init(group: .finished))
        #expect(history.entries.count == 1 && history.entries.first?.phase == .completed)
        #expect(history.entries.first?.confirmedBytes == 4)
        let lease = try await second.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == CacheBytes.payload)
        await lease.release()
        await center.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let freshCache = try await restored.downloadCache(using: network)
        let third = try await freshCache.download(secondMedia)
        #expect(third.fileURL == first.fileURL)
        #expect(await bytes.calls == 1)
        #expect(await resolver.calls == 3)
        await resolver.deny(firstMedia.mediaID)
        await #expect(throws: V2ClientMediaTransferError.serverStatus(403)) { try await freshCache.download(firstMedia) }
        #expect(await bytes.calls == 1)
        await restored.close(); try await f.remove()
    }

    @Test func revokingOneContextKeepsTheOtherAuthorizedAndRetirementWaitsForBorrow() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let roomA = RoomID(uuid: UUID()), roomB = RoomID(uuid: UUID())
        let mediaA = V2MediaReference(mediaID: .init(uuid: UUID())), mediaB = V2MediaReference(mediaID: .init(uuid: UUID()))
        let first = try await cache.download(mediaA, message: .init(roomID: roomA, messageID: .init(uuid: UUID())))
        let second = try await cache.download(mediaB, message: .init(roomID: roomB, messageID: .init(uuid: UUID())))
        #expect(first.fileURL == second.fileURL)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_membership_states(room_id,membership_revision,source_event_id,is_member) VALUES(?,1,?,0)", arguments: [roomA.rawValue,UUID().uuidString])
        }
        await #expect(throws: V2ResourceStorageError.unavailable) { try await first.borrowFile() }
        let lease = try await second.borrowFile()
        try await cache.discard(mediaA.mediaID)
        #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        try await cache.discard(mediaB.mediaID)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await second.borrowFile() }
        #expect(try Data(contentsOf: lease.fileURL) == CacheBytes.payload)
        await lease.release()
        #expect(!FileManager.default.fileExists(atPath: second.fileURL.path))
        await center.close(); try await f.remove()
    }

    @Test func interruptedRangeUsesTheSameBudgetedStagingPathAfterRestart() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let network = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: bytes)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let first = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let firstCache = try await first.downloadCache(using: network)
        await #expect(throws: URLError.self) { try await firstCache.download(media) }
        let paused = try #require(try await f.store.managedResourceTransfers(.init(group: .attention)).entries.first)
        #expect(paused.phase == .requiresAttention(.network) && paused.actions == [.cancel])
        #expect(try await first.files.snapshot().transferReservedBytes == 8)
        await first.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let restoredCache = try await restored.downloadCache(using: network)
        let result = try await restoredCache.download(media)
        let lease = try await result.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == CacheBytes.payload)
        await lease.release()
        let paths = await bytes.paths
        #expect(paths.count == 2 && paths[0] == paths[1])
        #expect(await bytes.observedPartial)
        #expect(try await restored.files.snapshot().transferReservedBytes == 0)
        #expect(try await restored.files.snapshot().files.count == 1)
        let history = try await f.store.managedResourceTransfers(.init(group: .finished))
        #expect(history.entries.map(\.id) == [paused.id] && history.entries.first?.phase == .completed)
        await restored.close(); try await f.remove()
    }

    @Test func cancelPausedDownloadDiscardsOnlyItsInactiveCheckpointAndNewRequestGetsNewID() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        await #expect(throws: URLError.self) { try await cache.download(media) }
        let task = try #require(try await f.store.managedResourceTransfers(.init(group: .attention)).entries.first)
        #expect(try await center.files.snapshot().transferReservedBytes == 8)
        let keep = f.directory.appending(path: "keep-source")
        try Data([9,9,9,9]).write(to: keep)
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: Data([9,9,9,9])).map { String(format: "%02x", $0) }.joined())
        let protected = try await center.files.publishCopy(of: keep, byteCount: 4, checksum: checksum, retention: .retained)
        try await center.cancelTransfer(task.id)
        #expect(try await center.files.snapshot().transferReservedBytes == 0)
        #expect(try await center.files.snapshot().files.contains(where: { $0.id == protected && $0.retention == .retained }))
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.first?.phase == .cancelled)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await center.cancelTransfer(task.id) }
        _ = try await cache.download(media)
        let history = try await f.store.managedResourceTransfers(.init(group: .finished))
        #expect(history.entries.count == 2 && history.entries.first?.id != task.id)
        #expect(history.entries.first?.phase == .completed)
        await center.close(); try await f.remove()
    }

    @Test func publishedBytesCloseInterruptedTaskUnderFreshAuthorizationWithoutAnotherDownload() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let journal = await f.store.resourceFileJournal(), owner = UUID(), media = MediaID(uuid: UUID())
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: CacheBytes.payload).map { String(format: "%02x", $0) }.joined())
        let id = try journal.beginForegroundDownload(identity: checksum.value + ":4", mediaID: media, message: nil, bytes: 4, checksum: checksum, owner: owner)
        try journal.foregroundDownloadAwaitingVerification(id, owner: owner)
        let source = f.directory.appending(path: "verified-source")
        try CacheBytes.payload.write(to: source)
        _ = try await center.files.publishCopy(of: source, byteCount: 4, checksum: checksum, retention: .cache)
        // The previous producer never committed its task outcome. The actual
        // cache reauthorizes and verifies bytes, then closes that original UUID.
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        _ = try await cache.download(.init(mediaID: media))
        let byteCalls = await bytes.calls
        #expect(await resolver.calls == 1 && byteCalls == 0)
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.map(\.id) == [.download(id)])
        await center.close(); try await f.remove()
    }

    @Test func sharedForegroundTransferSurvivesOneCancelledConsumerAndOffersExplicitTaskControls() async throws {
        let f = try Fixture(), resolver = CacheResolver(), gate = CanonicalDownloadGate()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: gate))
        let first = Task { try await cache.download(.init(mediaID: .init(uuid: UUID()))) }
        await gate.entered()
        let second = Task { try await cache.download(.init(mediaID: .init(uuid: UUID()))) }
        let deadline = ContinuousClock.now + .seconds(10)
        while await resolver.calls < 2 { try #require(ContinuousClock.now < deadline); await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let live = try #require(try await f.store.managedResourceTransfers(.init(group: .active)).entries.first)
        #expect(live.phase == .transferring && live.actions == [.cancel])
        await gate.release()
        let result = try await second.value, lease = try await result.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == CacheBytes.payload)
        await lease.release()
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.map(\.id) == [live.id])
        #expect(await gate.calls == 1)
        await center.close(); try await f.remove()
    }

    @Test func sameOwnerCacheHitClosesACompletionClaimLeftByAnUnavailableDatabase() async throws {
        let f = try Fixture(), resolver = CacheResolver(), gate = CanonicalDownloadGate()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: gate))
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let work = Task { try await cache.download(media) }
        await gate.entered()
        let claim = try await f.store.databasePool.read { db -> (String, String) in
            let pending = try Row.fetchOne(db, sql: "SELECT job_id,execution_owner FROM v2_resource_download_jobs WHERE transport='foreground' AND finished_at IS NULL")
            let row = try #require(pending)
            return (row["job_id"],row["execution_owner"])
        }
        await gate.release()
        _ = try await work.value
        // Recreate only the durable state left if the final task commit and
        // claim release both failed while the protected DB was unavailable.
        try await f.store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_resource_download_jobs SET state='downloaded',finished_at=NULL,execution_owner=? WHERE job_id=?", arguments: [claim.1,claim.0])
        }
        _ = try await cache.download(media)
        #expect(try await f.store.managedResourceTransfers(.init(group: .active)).entries.isEmpty)
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.count == 1)
        #expect(await gate.calls == 1)
        await center.close(); try await f.remove()
    }

    @Test func managementRetrySurvivesRestartAndRestoresTheOriginalCheckpointAndUUID() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let network = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: bytes)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let first = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await first.downloadCache(using: network)
        await #expect(throws: URLError.self) { try await cache.download(media, message: message) }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(job.actions == [.retry, .cancel])
        try await first.retryTransfer(job.id)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .queued)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await first.retryTransfer(job.id) }
        await first.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let fresh = try await restored.downloadCache(using: network)
        let worker = Task { try await fresh.runRecovery() }
        try await f.waitForPhase(job.id, .completed)
        worker.cancel(); _ = await worker.result
        let paths = await bytes.paths
        #expect(paths.count == 2 && paths[0] == paths[1])
        #expect(await bytes.observedPartial)
        #expect(await resolver.calls == 2)
        let entries = try await f.store.managedResourceTransfers(.init()).entries
        #expect(entries.map(\.id) == [job.id] && entries.first?.confirmedBytes == 4)
        let handle = try await fresh.download(media, message: message), lease = try await handle.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == CacheBytes.payload)
        await lease.release()
        await restored.close(); try await f.remove()
    }

    @Test func queuedRetryRechecksLocalReferenceBeforeAnyNetworkAuthorization() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        await #expect(throws: URLError.self) { try await cache.download(media, message: message) }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        try await center.retryTransfer(job.id)
        try await f.store.revokeResourceReference(.message(message, ordinal: 0), businessRevision: 2)
        let worker = Task { try await cache.runRecovery() }
        try await f.waitForPhase(job.id, .requiresAttention(.sourceUnavailable))
        #expect(await resolver.calls == 1)
        #expect(await bytes.calls == 1)
        let entry = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(entry.resource == nil && entry.displayName == nil && entry.actions == [.cancel])
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await center.retryTransfer(job.id) }
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test(arguments: [false, true]) func freshAuthorizationOrChangedVersionStopsBeforeReusingPartial(changedVersion: Bool) async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        await #expect(throws: URLError.self) { try await cache.download(media, message: message) }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        if changedVersion { await resolver.changeVersion() } else { await resolver.deny(media.mediaID) }
        try await center.retryTransfer(job.id)
        let worker = Task { try await cache.runRecovery() }
        try await f.waitForPhase(job.id, .requiresAttention(changedVersion ? .integrity : .sourceUnavailable))
        #expect(await resolver.calls == 2)
        #expect(await bytes.calls == 1)
        #expect(try await center.files.snapshot().files.isEmpty)
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test func recoveryWaiterCancellationDoesNotCancelOwnedBytesAndAccountCloseActuallyDrains() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        await #expect(throws: URLError.self) { try await cache.download(media, message: message) }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        await center.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store), gate = CanonicalDownloadGate()
        let fresh = try await restored.downloadCache(using: .init(targetResolver: resolver, byteTransfer: gate))
        try await restored.retryTransfer(job.id)
        let worker = Task { try await fresh.runRecovery() }
        await gate.entered()
        worker.cancel(); _ = await worker.result
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .transferring)
        let closed = RecoveryCloseWitness()
        let closing = Task { await restored.close(); await closed.finish() }
        // close() must first mark the cache closed, but it cannot finish while
        // this deliberately non-cooperative byte writer owns the checkpoint.
        await gate.cancelled()
        #expect(await closed.finished == false)
        await gate.release(); await closing.value
        #expect(await closed.finished)
        try await f.waitForPhase(job.id, .requiresAttention(.needsAttention))
        try await f.remove()
    }

    @Test(arguments: [1, 5]) func crashedClaimsRemainRecoverableButCannotLoopBeyondAttemptBudget(attempts: Int) async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let network = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: bytes)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let first = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await first.downloadCache(using: network)
        await #expect(throws: URLError.self) { try await cache.download(media, message: message) }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        guard case .download(let id) = job.id else { Issue.record("Expected a download job"); return }
        try await first.retryTransfer(job.id)
        let journal = await f.store.resourceFileJournal()
        // Crash injection at the durable claim boundary, before HTTP starts.
        // Each new owner adopts exactly the same persisted request and budget.
        for _ in 0..<attempts {
            let owner = UUID()
            try journal.recoverForegroundDownloads(owner: owner)
            #expect(try journal.claimDownloadResume(id, owner: owner)?.id == id)
        }
        await first.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let fresh = try await restored.downloadCache(using: network)
        let worker = Task { try await fresh.runRecovery() }
        defer { worker.cancel() }
        try await f.waitForPhase(job.id, attempts == 5 ? .requiresAttention(.needsAttention) : .completed)
        #expect(await bytes.calls == (attempts == 5 ? 1 : 2))
        #expect(await resolver.calls == (attempts == 5 ? 1 : 2))
        let count = try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT attempt_count FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) }
        #expect(count == (attempts == 5 ? 5 : 2))
        worker.cancel(); _ = await worker.result
        await restored.close(); try await f.remove()
    }

    @Test func failedRecoveryJournalWriteReachesAccountOwnerInsteadOfSilentlyStrandingTask() async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        await #expect(throws: URLError.self) { try await cache.download(media, message: message) }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        await resolver.deny(media.mediaID)
        try await center.retryTransfer(job.id)
        try await f.store.databasePool.write {
            try $0.execute(sql: "CREATE TRIGGER reject_download_pause BEFORE UPDATE OF state ON v2_resource_download_jobs WHEN NEW.state='paused' BEGIN SELECT RAISE(ABORT,'injected recovery journal failure'); END")
        }
        await #expect(throws: DatabaseError.self) { try await cache.runRecovery() }
        try await f.store.databasePool.write { try $0.execute(sql: "DROP TRIGGER reject_download_pause") }
        // Restart the same cache after the fault is removed. No account
        // recreation may be required to release its now-idle durable claim.
        let worker = Task { try await cache.runRecovery() }
        defer { worker.cancel() }
        try await f.waitForPhase(job.id, .requiresAttention(.sourceUnavailable))
        #expect(await bytes.calls == 1)
        worker.cancel(); _ = await worker.result
        await center.close(); try await f.remove()
    }

    @Test(arguments: [false, true]) func explicitTaskControlWaitsForPhysicalWriterAndPauseSurvivesColdStart(cancel: Bool) async throws {
        let f = try Fixture(), resolver = CacheResolver(), gate = CanonicalDownloadGate(checkpointOnEntry: true)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: resolver, byteTransfer: gate))
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let first = Task { try await cache.download(media, message: message) }
        await gate.entered()
        let second = Task { try await cache.download(media, message: message) }
        let deadline = ContinuousClock.now + .seconds(10)
        while await resolver.calls < 2 { try #require(ContinuousClock.now < deadline); await Task.yield() }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        if cancel { try await center.cancelTransfer(job.id) } else { try await center.pauseTransfer(job.id) }
        await gate.cancelled()
        let pending = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(pending.phase == (cancel ? .cancelling : .pausing))
        #expect(try await center.files.snapshot().transferReservedBytes == 8)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await center.resumeTransfer(job.id) }
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await center.pauseTransfer(job.id) }
        await gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        try await f.waitForPhase(job.id, cancel ? .cancelled : .paused)
        #expect(try await center.files.snapshot().transferReservedBytes == (cancel ? 0 : 8))
        #expect(try await center.files.snapshot().files.isEmpty)
        #expect(await gate.calls == 1)
        await center.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store), bytes = CacheBytes()
        let fresh = try await restored.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        if cancel {
            await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await restored.resumeTransfer(job.id) }
        } else {
            let paused = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
            #expect(paused.phase == .paused && paused.actions == [.resume, .cancel])
            #expect(try await f.store.resourceFileJournal().requestedDownloads().isEmpty)
            await #expect(throws: V2ResourceDownloadControlError.paused) { try await fresh.download(media, message: message) }
            #expect(await bytes.calls == 0)
            try await restored.resumeTransfer(job.id)
            let worker = Task { try await fresh.runRecovery() }
            defer { worker.cancel() }
            try await f.waitForPhase(job.id, .completed)
            #expect(await bytes.observedPartial)
            #expect(try await f.store.managedResourceTransfers(.init()).entries.map(\.id) == [job.id])
            worker.cancel(); _ = await worker.result
        }
        await restored.close(); try await f.remove()
    }

    @Test(arguments: [false, true]) func coldStartFinishesDurableControlLeftBeforeWriterAcknowledgement(cancel: Bool) async throws {
        let f = try Fixture(), owner = UUID(), media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let journal = await f.store.resourceFileJournal()
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: CacheBytes.payload).map { String(format: "%02x", $0) }.joined())
        let identity = checksum.value + ":4"
        let id = try journal.beginForegroundDownload(identity: identity, mediaID: media.mediaID, message: message, bytes: 4, checksum: checksum, owner: owner)
        let stage = try await center.files.reserveTransient(identity: identity, bytes: 4)
        try Data([1,2]).write(to: stage.fileURL.appendingPathExtension("range-part"))
        try await center.files.releaseTransient(stage.id, discard: false)
        #expect(try journal.requestForegroundDownloadControl(id, control: cancel ? .cancel : .pause, liveOwner: owner) == false)
        // Simulate process death after persisting control, before any byte
        // callback can acknowledge it. The next owner must honor that intent.
        await center.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let entry = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(entry.id == .download(id) && entry.phase == (cancel ? .cancelled : .paused))
        #expect(try await restored.files.snapshot().transferReservedBytes == (cancel ? 0 : 8))
        #expect(try journal.requestedDownloads().isEmpty)
        await restored.close(); try await f.remove()
    }

    @Test func pausingRecoveredTaskDoesNotStopAccountSchedulerFromContinuingItLater() async throws {
        let f = try Fixture(), resolver = CacheResolver(), initial = CacheBytes(interruptOnce: true)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let first = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let initialCache = try await first.downloadCache(using: .init(targetResolver: resolver, byteTransfer: initial))
        await #expect(throws: URLError.self) { try await initialCache.download(media, message: message) }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        await first.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store), bytes = PausingDownloadBytes()
        let cache = try await restored.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes))
        try await restored.retryTransfer(job.id)
        let ended = RecoveryCloseWitness()
        let worker = Task {
            do { try await cache.runRecovery() } catch is CancellationError { } catch { Issue.record(error) }
            await ended.finish()
        }
        await bytes.entered()
        try await restored.pauseTransfer(job.id)
        try await f.waitForPhase(job.id, .paused)
        #expect(await ended.finished == false)
        try await restored.resumeTransfer(job.id)
        try await f.waitForPhase(job.id, .completed)
        #expect(await ended.finished == false)
        #expect(await bytes.calls == 2)
        worker.cancel(); await worker.value
        await restored.close(); try await f.remove()
    }

    @Test(arguments: [false, true]) func queuedPauseWorksBeforeCacheConstructionAndResumeRechecksAuthority(revoke: Bool) async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes(interruptOnce: true)
        let network = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: bytes)
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let first = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await first.downloadCache(using: network)
        await #expect(throws: URLError.self) { try await cache.download(media, message: message) }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        await first.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        try await restored.retryTransfer(job.id)
        try await restored.pauseTransfer(job.id)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .paused)
        #expect(try await f.store.resourceFileJournal().requestedDownloads().isEmpty)
        if revoke {
            try await f.store.revokeResourceReference(.message(message, ordinal: 0), businessRevision: 2)
            await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await restored.resumeTransfer(job.id) }
            try await restored.cancelTransfer(job.id)
            #expect(try await restored.files.snapshot().transferReservedBytes == 0)
            #expect(await bytes.calls == 1)
        } else {
            try await restored.resumeTransfer(job.id)
            let fresh = try await restored.downloadCache(using: network)
            let worker = Task { try await fresh.runRecovery() }
            defer { worker.cancel() }
            try await f.waitForPhase(job.id, .completed)
            #expect(await bytes.observedPartial)
            worker.cancel(); _ = await worker.result
        }
        await restored.close(); try await f.remove()
    }

    @Test(arguments: [false, true]) func automaticPrioritySurvivesColdResumeAndOnlyExplicitUserContinuePromotesIt(promote: Bool) async throws {
        let f = try Fixture(), resolver = CacheResolver(), bytes = CacheBytes()
        let media = V2MediaReference(mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        try await f.index(media, message: message)
        let first = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        try await first.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.file], maximumByteCount: 1024)))
        let journal = await f.store.resourceFileJournal()
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: CacheBytes.payload).map { String(format: "%02x", $0) }.joined())
        let id = try journal.beginForegroundDownload(identity: checksum.value + ":4", mediaID: media.mediaID,
            message: message, bytes: 4, checksum: checksum, owner: UUID(), priority: .background)
        // Crash at durable admission, before a byte request. The subsequent
        // account worker must not turn automatic work into user priority.
        await first.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        if promote {
            try await restored.pauseTransfer(.download(id))
            try await restored.resumeTransfer(.download(id))
        }
        let cache = try await restored.downloadCache(using: .init(targetResolver: resolver, byteTransfer: bytes), automaticNetwork: .unrestricted)
        let worker = Task { try await cache.runRecovery() }
        defer { worker.cancel() }
        try await f.waitForPhase(.download(id), .completed)
        #expect(await bytes.priorities == [promote ? .interactive : .background])
        #expect(await bytes.networkConstraints == [V2ResourceDownloadNetworkPreferences().constraints(automatic: !promote)])
        let priority = try await f.store.databasePool.read { try Int.fetchOne($0, sql: "SELECT work_priority FROM v2_resource_download_jobs WHERE job_id=?", arguments: [id.uuidString]) }
        #expect(priority == (promote ? V2NetworkWorkPriority.interactive.rawValue : V2NetworkWorkPriority.background.rawValue))
        worker.cancel(); _ = await worker.result
        await restored.close(); try await f.remove()
    }
}

private actor PausingDownloadBytes: V2ClientMediaByteTransfer {
    private let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private(set) var calls = 0
    func entered() async { for await _ in signal.stream { return } }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        calls += 1
        if calls == 1 {
            signal.continuation.yield(())
            do { try await Task.sleep(for: .seconds(120)) }
            catch { throw URLError(.cancelled) }
        }
        try CacheBytes.payload.write(to: destinationURL)
    }
}

private actor RecoveryCloseWitness {
    private(set) var finished = false
    func finish() { finished = true }
}

private struct ScheduledDownloadGate: V2ClientMediaByteTransfer {
    let scheduler: V2AccountWorkScheduler
    let gate: CanonicalDownloadGate
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        try await scheduler.withPermit(.init(service: "mediaProvider", priority: V2NetworkWorkScope.context?.priority ?? .interactive, kind: .byteTransfer(.download))) { _ in
            try await gate.download(target: target, destinationURL: destinationURL)
        }
    }
}

private actor CanonicalDownloadGate: V2ClientMediaByteTransfer {
    private let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let cancellation = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    let checkpointOnEntry: Bool
    init(checkpointOnEntry: Bool = false) { self.checkpointOnEntry = checkpointOnEntry }
    func entered() async { for await _ in signal.stream { return } }
    func cancelled() async { for await _ in cancellation.stream { return } }
    private func noteCancellation() { cancellation.continuation.yield(()) }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        calls += 1
        if checkpointOnEntry { try Data([1,2]).write(to: destinationURL.appendingPathExtension("range-part")) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0; signal.continuation.yield(()) }
        } onCancel: { Task { await self.noteCancellation() } }
        try CacheBytes.payload.write(to: destinationURL)
    }
    func release() { continuation?.resume(); continuation = nil; signal.continuation.finish() }
}

private actor QueuedAccessResolver: V2ClientMediaDownloadTargetResolver {
    let payloads: [MediaID: Data]
    private var revoked: Set<MediaID> = []
    private(set) var calls: [MediaID: Int] = [:]
    private var heldMedia: Set<MediaID> = []
    private var held: [MediaID: CheckedContinuation<Void, Never>] = [:]
    init(payloads: [MediaID: Data]) { self.payloads = payloads }
    func revoke(_ id: MediaID) { revoked.insert(id) }
    func holdSecond(_ id: MediaID) { heldMedia.insert(id) }
    func isHeld(_ id: MediaID) -> Bool { held[id] != nil }
    func release(_ id: MediaID) { held.removeValue(forKey: id)?.resume() }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget {
        calls[mediaID, default: 0] += 1
        if heldMedia.contains(mediaID), calls[mediaID] == 2 { await withCheckedContinuation { held[mediaID] = $0 } }
        guard !revoked.contains(mediaID) else { throw V2ClientMediaTransferError.authorizationDenied }
        return try ParallelRecoveryResolver(payloads: payloads).resolveDownloadTarget(mediaID: mediaID, message: message)
    }
}

private struct ParallelRecoveryResolver: V2ClientMediaDownloadTargetResolver {
    let payloads: [MediaID: Data]
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        let payload = try #require(payloads[mediaID])
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        return try .init(downloadPlan: .init(mode: .httpGet,
            url: #require(URL(string: "https://bytes.invalid/\(mediaID.rawValue)")),
            expiresAt: .now.addingTimeInterval(120), expectedByteCount: 4, checksum: checksum))
    }
}

private actor ParallelRecoveryBytes: V2ClientMediaByteTransfer {
    let payloads: [MediaID: Data]
    let blocked: Set<MediaID>
    private var continuations: [MediaID: CheckedContinuation<Void, Never>] = [:]
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var started: Set<MediaID> = []
    init(payloads: [MediaID: Data], blocked: Set<MediaID>) { self.payloads = payloads; self.blocked = blocked }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        let media = try MediaID(target.url.lastPathComponent)
        let payload = try #require(payloads[media])
        started.insert(media); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if blocked.contains(media) {
            await withCheckedContinuation { continuations[media] = $0 }
        }
        try Task.checkCancellation()
        try payload.write(to: destinationURL)
    }
    func isBlocked(_ id: MediaID) -> Bool { continuations[id] != nil }
    func release(_ id: MediaID) { continuations.removeValue(forKey: id)?.resume() }
    func releaseAll() { let pending = Array(continuations.values); continuations.removeAll(); for c in pending { c.resume() } }
}

private final class AutomaticNetworkFeed: Sendable {
    private struct State {
        var value = V2ResourceAutomaticNetworkConditions.unavailable
        var waiters: [UUID: AsyncStream<V2ResourceAutomaticNetworkConditions>.Continuation] = [:]
    }
    private let state = Mutex(State())
    var subscribers: Int { state.withLock { $0.waiters.count } }
    var source: V2ResourceAutomaticNetworkSource {
        .init { [self] in
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let id = UUID()
                let initial = state.withLock { $0.waiters[id] = continuation; return $0.value }
                continuation.onTermination = { [self] _ in state.withLock { $0.waiters.removeValue(forKey: id) } }
                continuation.yield(initial)
            }
        }
    }
    func send(_ value: V2ResourceAutomaticNetworkConditions) {
        let waiters = state.withLock { $0.value = value; return Array($0.waiters.values) }
        for waiter in waiters { waiter.yield(value) }
    }
}
private actor AutomaticRetryBytes: V2ClientMediaByteTransfer {
    let failures: Int
    private(set) var calls = 0
    init(failures: Int) { self.failures = failures }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws {
        calls += 1
        if calls <= failures { throw URLError(.networkConnectionLost) }
        try CacheBytes.payload.write(to: destinationURL)
    }
}
private actor AutomaticPermanentFailureBytes: V2ClientMediaByteTransfer {
    let failure: V2ClientMediaTransferError
    private(set) var calls = 0
    init(failure: V2ClientMediaTransferError) { self.failure = failure }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws { calls += 1; throw failure }
}

private actor CacheRangeProgressGate: V2RangeDownloadTransport {
    private let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let stops = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var waiter: CheckedContinuation<Void, Never>?
    private var context: V2ResourceDownloadProgressContext?
    private(set) var ranges: [String] = []
    func entered() async { for await _ in starts.stream { return } }
    func cancelled() async { for await _ in stops.stream { return } }
    func release() { waiter?.resume(); waiter = nil }
    func liveProgress() -> V2ResourceTransferAttemptProgress? {
        guard let context else { return nil }; return context.hub.snapshot()[.download(context.job)]
    }
    func stream(_ request: URLRequest, maximumBytes: Int64, receiveResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                consume: @escaping @Sendable (Data) throws -> Void) async throws -> V2RangeDownloadResponse {
        let range = try #require(request.value(forHTTPHeaderField: "Range"))
        let url = try #require(request.url)
        ranges.append(range)
        context = V2ResourceDownloadProgressScope.context
        if ranges.count == 1 {
            try receiveResponse(try #require(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 0-3/4", "ETag": "\"stable\""])))
            try consume(Data([1,2]))
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0; starts.continuation.yield(()) }
            } onCancel: { Task { await self.signalCancellation() } }
            try Task.checkCancellation()
            throw URLError(.networkConnectionLost)
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Range": "bytes 2-3/4", "ETag": "\"stable\""]))
        try receiveResponse(response); try consume(Data([3,4])); return .init(response: response)
    }
    private func signalCancellation() { stops.continuation.yield(()) }
}

private actor CacheResolver: V2ClientMediaDownloadTargetResolver {
    var calls = 0
    var denied: Set<MediaID> = []
    var changedVersion = false
    func changeVersion() { changedVersion = true }
    func deny(_ id: MediaID) { denied.insert(id) }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        calls += 1
        if denied.contains(mediaID) { throw V2ClientMediaTransferError.serverStatus(403) }
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: changedVersion ? Data([4,3,2,1]) : CacheBytes.payload).map { String(format: "%02x", $0) }.joined())
        return try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://bytes.invalid/\(UUID())")),
            expiresAt: Date().addingTimeInterval(120), expectedByteCount: 4, checksum: checksum))
    }
}

private actor CacheBytes: V2ClientMediaByteTransfer {
    static let payload = Data([1,2,3,4])
    var calls = 0
    var paths: [URL] = []
    var observedPartial = false
    var priorities: [V2NetworkWorkPriority] = []
    var networkConstraints: [V2ResourceDownloadNetworkConstraints] = []
    let interruptOnce: Bool
    init(interruptOnce: Bool = false) { self.interruptOnce = interruptOnce }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws {
        calls += 1; paths.append(destinationURL)
        priorities.append(V2NetworkWorkScope.context?.priority ?? .interactive)
        networkConstraints.append(target.networkConstraints)
        let partial = destinationURL.appendingPathExtension("range-part")
        if interruptOnce && calls == 1 {
            try Data([1,2]).write(to: partial)
            throw URLError(.networkConnectionLost)
        }
        if FileManager.default.fileExists(atPath: partial.path) { observedPartial = try Data(contentsOf: partial) == Data([1,2]) }
        try Self.payload.write(to: destinationURL)
    }
}

private actor PreviewCacheResolver: V2ClientMediaDownloadTargetResolver {
    var originalCalls = 0
    var previewCalls = 0
    private var offline = false
    func goOffline() { offline = true }
    private let variantID = ResourceVariantID(uuid: UUID())
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        originalCalls += 1
        return try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://objects.invalid/original")!, expiresAt: .distantFuture,
            expectedByteCount: 4, checksum: .init(value: SHA256.hash(data: CacheBytes.payload).map { String(format: "%02x", $0) }.joined())))
    }
    func resolveImagePreviewTarget(mediaID: MediaID, message: V2MediaMessageLocation, size: V2MediaImagePreviewSize) throws -> V2ClientMediaTransferTarget {
        previewCalls += 1
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: PreviewCacheBytes.payload).map { String(format: "%02x", $0) }.joined())
        let variant = try V2ResourceVariantDescriptor(key: .init(resource: .init(home: .room(message.roomID), mediaID: mediaID),
            rendition: .derived(id: variantID, version: .init(1))), checksum: checksum, byteCount: 2)
        return try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://objects.invalid/preview")!, expiresAt: .distantFuture,
            expectedByteCount: 2, checksum: checksum), preview: variant)
    }
}
private actor PreviewCacheBytes: V2ClientMediaByteTransfer {
    static let payload = Data([7,8])
    var calls = 0
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws { calls += 1; try Self.payload.write(to: destinationURL) }
}
