import Crypto
import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Logical variant retention and verified byte rebinding", .timeLimit(.minutes(1)))
struct V2ResourceRetentionTests {
    @Test(arguments: [false, true])
    func retentionWriteRechecksVisibilityWithoutBlockingRelease(alreadyRetained: Bool) async throws {
        let f = try Fixture()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        do {
            let room = RoomID(uuid: UUID())
            let key = V2ResourceVariantKey(resource: .init(home: .room(room), mediaID: .init(uuid: UUID())))
            let message = V2MediaMessageLocation(roomID: room, messageID: .init(uuid: UUID()))
            try await f.index(key.resource, message: message)
            if alreadyRetained { try await center.setRetained(true, variant: key) }
            // This is the center's successful preflight. Authority may change
            // before its queued FileStore operation reaches the write transaction.
            #expect(try await f.store.resourceIsVisible(key.resource))
            try await f.store.revokeResourceReference(.message(message, ordinal: 0), businessRevision: 2)
            let journal = await f.store.resourceFileJournal()
            let previous = try journal.unavailableRetentionSelections().values
            #expect(previous.count == (alreadyRetained ? 1 : 0))
            #expect(throws: V2ResourceStorageError.unavailable) {
                try journal.setVariantRetained(true, key: key, now: Date())
            }
            #expect(try journal.variant(key)?.isRetained == alreadyRetained)
            let current = try journal.unavailableRetentionSelections().values
            #expect(current.count == previous.count && current.first?.intentID == previous.first?.intentID)
            // Revocation must not strand an existing local retention intent.
            try journal.setVariantRetained(false, key: key, now: Date())
            #expect(try journal.variant(key)?.isRetained == false)
            #expect(try journal.unavailableRetentionSelections().values.isEmpty)
        } catch {
            await center.close(); try await f.store.close(); try f.remove(); throw error
        }
        await center.close(); try await f.store.close(); try f.remove()
    }

    @Test("interrupted retained publication recovers its logical claim before cold cache trimming")
    func retainedPublicationRecovery() async throws {
        struct Interrupted: Error {}
        let f = try Fixture()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store,
            policy: .init(maximumCacheBytes: 1))
        let key = V2ResourceVariantKey(resource: .init(home: .room(.init(uuid: UUID())), mediaID: .init(uuid: UUID())))
        guard case .room(let room) = key.resource.home else { return }
        try await f.index(key.resource, message: .init(roomID: room, messageID: .init(uuid: UUID())))
        try await center.setRetained(true, variant: key)
        await center.close()
        let journal = await f.store.resourceFileJournal()
        let files = try V2ResourceFileStore(root: f.scope.resourceFilesDirectory, cacheRoot: f.scope.resourceCacheDirectory,
            journal: journal, policy: .standard) { stage in
            if stage == .renamed { throw Interrupted() }
        }
        let source = f.root.appending(path: "download")
        try RetentionBytes.payload.write(to: source)
        let reservation = try await files.reserveTransient(identity: "retained-recovery", bytes: 4)
        await #expect(throws: Interrupted.self) {
            try await files.publishDownload(of: source, reservation: reservation, byteCount: 4, checksum: checksum(RetentionBytes.payload))
        }
        try await files.releaseTransient(reservation.id, discard: false)
        await files.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let variant = try #require(try await restored.variants(for: key.resource).first)
        #expect(variant.isRetained)
        guard case .available(storage: .persistent, allocatedBytes: _) = variant.localState else {
            Issue.record("retained publication did not recover to persistent storage"); return
        }
        #expect(try await restored.storageSnapshot().quota.cacheBytes == 0)
        #expect(try await restored.storageSnapshot().quota.retainedBytes >= 4)
        #expect(try await restored.planCleanup().fileIDs.isEmpty)
        await restored.close(); try await f.store.close(); try f.remove()
    }

    @Test("a logical retained download bypasses the cache cap without acquiring an irreversible physical pin")
    func retainedDownloadUsesItsOwnCategory() async throws {
        let f = try Fixture()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store,
            policy: .init(maximumCacheBytes: 1))
        let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID())
        let key = V2ResourceVariantKey(resource: .init(home: .room(room), mediaID: media))
        let message = V2MediaMessageLocation(roomID: room, messageID: .init(uuid: UUID()))
        try await f.index(key.resource, message: message)
        try await center.setRetained(true, variant: key)
        let cache = try await center.downloadCache(using: .init(targetResolver: RetentionResolver(), byteTransfer: RetentionBytes()))
        let handle = try await cache.download(.init(mediaID: media), message: message)
        let lease = try await handle.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == RetentionBytes.payload)
        #expect(lease.fileURL.path.hasPrefix(f.scope.resourceFilesDirectory.path))
        let snapshot = try await center.storageSnapshot()
        #expect(snapshot.quota.cacheBytes == 0 && snapshot.quota.retainedBytes >= 4)
        #expect(try await center.planCleanup().fileIDs.isEmpty)
        await lease.release()
        try await center.setRetained(false, variant: key)
        let plan = try await center.planCleanup()
        #expect(plan.fileIDs.count == 1)
        #expect(try await center.commitCleanup(plan).deletedCount == 1)
        #expect(try await center.variants(for: key.resource).first?.localState == .needsDownload)
        await center.close(); try await f.store.close(); try f.remove()
    }

    @Test("failed quota admissions release flight slots so a later valid download can proceed")
    func admissionFailureDoesNotLeakFlights() async throws {
        let f = try Fixture()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store, policy: .testBounded(8192))
        let cache = try await center.downloadCache(using: .init(targetResolver: OverBudgetRetentionResolver(), byteTransfer: RetentionBytes()))
        for _ in 0..<5 {
            await #expect(throws: V2ResourceStorageError.capacityExceeded) {
                try await cache.download(.init(mediaID: .init(uuid: UUID())))
            }
        }
        let good = try await cache.download(.init(mediaID: .init("small-retention-source")))
        let use = try await good.borrowFile()
        #expect(try Data(contentsOf: use.fileURL) == RetentionBytes.payload)
        await use.release(); await center.close(); try await f.store.close(); try f.remove()
    }

    @Test("published bytes cannot be cleaned while their caller reauthorizes before receiving a handle")
    func publicationHandoffIsProtected() async throws {
        let f = try Fixture(), transferGate = RetentionGate(), authorizationGate = RetentionGate()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID())
        let key = V2ResourceKey(home: .room(room), mediaID: media)
        let message = V2MediaMessageLocation(roomID: room, messageID: .init(uuid: UUID()))
        try await f.index(key, message: message)
        let cache = try await center.downloadCache(using: .init(targetResolver: RetentionResolver(recheck: authorizationGate), byteTransfer: RetentionBytes(gate: transferGate)))
        let download = Task { try await cache.download(.init(mediaID: media), message: message) }
        await transferGate.entered()
        // A real authority revision changes the access generation while still
        // allowing this member to read. That requires a post-download grant.
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_membership_states(room_id,membership_revision,source_event_id,is_member) VALUES(?,1,?,1)", arguments: [room.rawValue,UUID().uuidString])
        }
        await transferGate.release()
        await authorizationGate.entered()
        let plan = try await center.planCleanup()
        #expect(plan.fileIDs.isEmpty && plan.skippedCount == 1)
        #expect(try await center.commitCleanup(plan).deletedCount == 0)
        await authorizationGate.release()
        let result = try await download.value
        let lease = try await result.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == RetentionBytes.payload)
        await lease.release()
        // Once the handoff and actual preview have ended, an unpinned handle is
        // not a permanent file claim and may be selected for explicit cleanup.
        #expect(try await center.planCleanup().fileIDs.count == 1)
        await center.close(); try await f.store.close(); try f.remove()
    }

    @Test("retention writes do not invalidate authority and descriptor edits preserve the original intent")
    func metadataRevisionAndProjectionIsolation() async throws {
        let f = try Fixture()
        let room = RoomID(uuid: UUID()), key = V2ResourceKey(home: .room(room), mediaID: .init(uuid: UUID()))
        let message = V2MediaMessageLocation(roomID: room, messageID: .init(uuid: UUID()))
        try await f.index(key, message: message)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let journal = await f.store.resourceFileJournal()
        let before = try journal.currentAccessGeneration()
        var retainedPages = try await center.snapshots(for: .init(retainedOnly: true)).makeAsyncIterator()
        guard case .available(let empty)? = await retainedPages.next() else { Issue.record("missing initial directory"); return }
        #expect(empty.entries.isEmpty)
        let subscription = await f.store.projectionChanges()
        var changes = subscription.makeAsyncIterator()
        _ = await changes.next()
        let variant = V2ResourceVariantKey(resource: key)
        try await center.setRetained(true, variant: variant)
        let change = try #require(await changes.next())
        #expect(change.scopes == .resources && !change.requiresImmediateRefresh)
        #expect(try journal.currentAccessGeneration() == before)
        guard case .available(let retained)? = await retainedPages.next() else { Issue.record("retention was not published"); return }
        #expect(retained.entries.map(\.descriptor.key) == [key])
        #expect(retained.entries.first?.isRetained == true)
        try await f.store.indexResource(.init(key: key, revision: 2, displayName: .init("new-name.bin"), contentType: "application/octet-stream",
            byteCount: 4, checksum: checksum(RetentionBytes.payload), state: .ready), reference: .message(message, ordinal: 0), businessRevision: 1)
        #expect(try await center.variants(for: key).map(\.descriptor.key) == [variant])
        #expect(try await center.variants(for: key).first?.isRetained == true)
        #expect(try await f.store.resourceDirectory().entries.first?.descriptor.displayName.value == "new-name.bin")
        #expect(try await center.storageSnapshot().files.isEmpty)
        await center.close(); try await f.store.close(); try f.remove()
    }

    @Test("retention survives lost bytes and cold reopen without merging identities or bypassing revocation")
    func coldRedownloadAndIndependentHomes() async throws {
        let f = try Fixture(), bytes = RetentionBytes(), resolver = RetentionResolver()
        let network = V2ClientMediaDownloadService(targetResolver: resolver, byteTransfer: bytes)
        let first = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let media = MediaID(uuid: UUID()), a = RoomID(uuid: UUID()), b = RoomID(uuid: UUID())
        let aKey = V2ResourceVariantKey(resource: .init(home: .room(a), mediaID: media))
        let bKey = V2ResourceVariantKey(resource: .init(home: .room(b), mediaID: media))
        let aMessage = V2MediaMessageLocation(roomID: a, messageID: .init(uuid: UUID()))
        let bMessage = V2MediaMessageLocation(roomID: b, messageID: .init(uuid: UUID()))
        try await f.index(aKey.resource, message: aMessage)
        try await f.index(bKey.resource, message: bMessage)
        #expect(try await first.variants(for: aKey.resource).first?.localState == .needsDownload)
        try await first.setRetained(true, variant: bKey)
        #expect(try await first.variants(for: bKey.resource).first?.isRetained == true)
        #expect(try await first.variants(for: bKey.resource).first?.localState == .needsDownload)
        let cache = try await first.downloadCache(using: network)
        _ = try await cache.download(.init(mediaID: media), message: aMessage)
        let bFile = try await cache.download(.init(mediaID: media), message: bMessage)
        try await first.setRetained(true, variant: aKey)
        try await first.setRetained(false, variant: aKey)
        let journal = await f.store.resourceFileJournal()
        let oldID = try #require(try journal.variant(bKey)?.fileID)
        #expect(try journal.variant(aKey)?.fileID == oldID)
        #expect(try journal.record(oldID)?.retention == .retained && journal.record(oldID)?.isPinned == true)
        #expect(try await first.storageSnapshot().files.count == 1)
        let lease = try await bFile.borrowFile(), oldURL = lease.fileURL
        #expect(oldURL.path.hasPrefix(f.scope.resourceFilesDirectory.path))
        await lease.release()
        // Simulate an externally missing retained file. The logical request is
        // not a foreign key to this physical file and must outlive it.
        try FileManager.default.removeItem(at: oldURL)
        await first.close(); try await f.store.close()
        let reopened = try f.open()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: reopened)
        #expect(try await center.variants(for: bKey.resource).first?.isRetained == true)
        #expect(try await center.variants(for: bKey.resource).first?.localState == .needsDownload)
        let restoredCache = try await center.downloadCache(using: network)
        let restored = try await restoredCache.download(.init(mediaID: media), message: bMessage)
        let restoredJournal = await reopened.resourceFileJournal()
        let newID = try #require(try restoredJournal.variant(bKey)?.fileID)
        #expect(newID != oldID)
        #expect(try restoredJournal.record(newID)?.storage == .persistent)
        #expect(try restoredJournal.record(newID)?.retention == .retained)
        #expect(try await center.variants(for: aKey.resource).first?.isRetained == false)
        let transfers = await bytes.calls, authorizations = await resolver.calls
        #expect(transfers == 2 && authorizations == 3)
        let actual = try await restored.borrowFile()
        #expect(try Data(contentsOf: actual.fileURL) == RetentionBytes.payload)
        let protectedURL = actual.fileURL
        await actual.release()
        let obsolete = try await center.planCleanup(fileIDs: [oldID])
        #expect(try await center.commitCleanup(obsolete).deletedCount == 1)
        #expect(try restoredJournal.variant(aKey)?.fileID == nil)
        #expect(try restoredJournal.variant(bKey)?.fileID == newID)
        #expect(try restoredJournal.variant(bKey)?.isRetained == true)
        let deniedScan = try await reopened.beginResourceDirectoryScan(roomID: b, query: .init())
        try await reopened.denyResourceDirectory(scan: deniedScan)
        #expect(try await center.variants(for: bKey.resource).isEmpty)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await restored.borrowFile() }
        await #expect(throws: V2ResourceStorageError.unavailable) { try await restoredCache.download(.init(mediaID: media), message: bMessage) }
        #expect(FileManager.default.fileExists(atPath: protectedURL.path))
        // Removing one's own disk preference remains possible after access is
        // lost, but does not display metadata or obtain another grant.
        try await center.setRetained(false, variant: bKey)
        #expect(try restoredJournal.variant(bKey)?.isRetained == false)
        #expect(try await center.planCleanup().fileIDs.contains(newID))
        await center.close(); try await reopened.close(); try f.remove()
    }

    @Test("derived versions keep independent retention and cannot replace immutable byte facts")
    func independentDerivedVersions() async throws {
        let f = try Fixture(), bytes = RetentionBytes()
        let center = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let cache = try await center.downloadCache(using: .init(targetResolver: RetentionResolver(), byteTransfer: bytes))
        let room = RoomID(uuid: UUID())
        let resource = V2ResourceKey(home: .room(room), mediaID: .init(uuid: UUID()))
        // User retention is only admitted for a currently visible source.
        // Exercise derived avatar versions on the same message-backed resource.
        try await f.index(resource, message: .init(roomID: room, messageID: .init(uuid: UUID())))
        let id = ResourceVariantID(uuid: UUID())
        func access(_ version: Int64, payload: Data) throws -> V2ResourceAvatarAccess {
            let digest = try checksum(payload)
            return try .init(mediaID: resource.mediaID, variantID: id, version: version, checksum: digest,
                plan: .init(mode: .httpGet, url: #require(URL(string: "https://bytes.invalid/avatar/\(version)")), expiresAt: Date().addingTimeInterval(120),
                    expectedByteCount: Int64(payload.count), checksum: digest))
        }
        let v1 = try V2ResourceVariantKey(resource: resource, rendition: .derived(id: id, version: .init(1)))
        let v2 = try V2ResourceVariantKey(resource: resource, rendition: .derived(id: id, version: .init(2)))
        let first = try await cache.avatar(access(1, payload: RetentionBytes.payload), home: resource.home)
        let oldUse = try await first.borrowFile()
        try await center.files.setVariantRetained(true, key: v1)
        let next = try await cache.avatar(access(2, payload: RetentionBytes.alternate), home: resource.home)
        let records = try await center.files.variantSnapshots(for: resource)
        #expect(Set(records.map(\.descriptor.key)) == [V2ResourceVariantKey(resource: resource), v1, v2])
        #expect(records.first(where: { $0.descriptor.key.rendition == .original })?.isRetained == false)
        #expect(records.first(where: { $0.descriptor.key == v1 })?.isRetained == true)
        #expect(records.first(where: { $0.descriptor.key == v2 })?.isRetained == false)
        await #expect(throws: V2ResourceStorageError.unavailable) { try await first.borrowFile() }
        #expect(try Data(contentsOf: oldUse.fileURL) == RetentionBytes.payload)
        let journal = await f.store.resourceFileJournal()
        let originalID = try #require(try journal.variant(v1)?.fileID)
        await #expect(throws: V2ResourceStorageError.conflict) {
            try await f.store.databasePool.write { db in
                try GRDBV2LocalSyncStore.indexResourceVariant(.init(key: v1, checksum: checksum(RetentionBytes.alternate), byteCount: 4), db: db)
            }
        }
        #expect(try journal.variant(v1)?.fileID == originalID)
        try await center.files.setVariantRetained(false, key: v1)
        #expect(try await center.files.planCleanup(fileIDs: [originalID]).fileIDs.isEmpty)
        await oldUse.release()
        let plan = try await center.files.planCleanup(fileIDs: [originalID])
        #expect(plan.fileIDs == [originalID])
        #expect(try await center.commitCleanup(plan).deletedCount == 1)
        #expect(try journal.variant(v1)?.fileID == nil)
        let nextUse = try await next.borrowFile()
        #expect(try Data(contentsOf: nextUse.fileURL) == RetentionBytes.alternate)
        await nextUse.release(); await center.close(); try await f.store.close(); try f.remove()
    }

    private struct Fixture {
        let root: URL, scope: V2AccountStorageScope, store: GRDBV2LocalSyncStore
        let binding = V2LocalInstallationBinding(value: UUID())
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "variant-retention-\(UUID())")
            scope = .init(incarnation: UUID(), accountID: .init(uuid: UUID()), directory: root.appending(path: "support"), cacheDirectory: root.appending(path: "caches"))
            store = try .init(databaseURL: scope.database.primary, installationBinding: binding, userID: scope.accountID)
        }
        func open() throws -> GRDBV2LocalSyncStore { try .init(databaseURL: scope.database.primary, installationBinding: binding, userID: scope.accountID) }
        func index(_ key: V2ResourceKey, message: V2MediaMessageLocation) async throws {
            try await store.indexResource(.init(key: key, revision: 1, displayName: .init("retained.bin"), contentType: "application/octet-stream",
                byteCount: 4, checksum: checksum(RetentionBytes.payload), state: .ready), reference: .message(message, ordinal: 0), businessRevision: 1)
        }
        func remove() throws { try FileManager.default.removeItem(at: root) }
    }
}

private func checksum(_ bytes: Data) throws -> V2ResourceChecksum { try .init(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()) }

private actor RetentionResolver: V2ClientMediaDownloadTargetResolver {
    let recheck: RetentionGate?
    private(set) var calls = 0
    init(recheck: RetentionGate? = nil) { self.recheck = recheck }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget {
        calls += 1
        if calls == 2 { await recheck?.wait() }
        return try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://bytes.invalid/object")), expiresAt: Date().addingTimeInterval(120),
            expectedByteCount: 4, checksum: checksum(RetentionBytes.payload)))
    }
}

private struct OverBudgetRetentionResolver: V2ClientMediaDownloadTargetResolver {
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        let small = mediaID.rawValue == "small-retention-source"
        return try .init(downloadPlan: .init(mode: .httpGet, url: #require(URL(string: "https://bytes.invalid/object")), expiresAt: Date().addingTimeInterval(120),
            expectedByteCount: small ? 4 : 8193, checksum: checksum(small ? RetentionBytes.payload : Data(mediaID.rawValue.utf8))))
    }
}

private actor RetentionBytes: V2ClientMediaByteTransfer {
    static let payload = Data([1,2,3,4]), alternate = Data([4,3,2,1])
    let gate: RetentionGate?
    private(set) var calls = 0
    init(gate: RetentionGate? = nil) { self.gate = gate }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        calls += 1
        await gate?.wait()
        let body = target.checksum == (try checksum(Self.alternate)) ? Self.alternate : Self.payload
        let actual = try checksum(body)
        try #require(target.checksum == actual)
        try body.write(to: destinationURL)
    }
}

private actor RetentionGate {
    private let starts = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; starts.continuation.yield(()) } }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
}
