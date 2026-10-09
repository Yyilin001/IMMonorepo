import CryptoKit
import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Account-owned background download lifecycle", .timeLimit(.minutes(1)))
struct V2BackgroundDownloadCoordinatorTests {
    @Test func suspendedTaskResumesOnlyAfterMappingAndPublishesAfterFreshAuthorization() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = try f.owner()
        let activity = Task { try await owner.run() }
        let request = Task { try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target) }
        try await f.driver.waitForResume()
        #expect(await f.driver.durableBeforeResume)
        #expect(await f.scheduler.snapshot().active == 1)
        try await f.driver.finish()
        let file = try await request.value
        #expect(try Data(contentsOf: file.fileURL) == Fixture.bytes)
        #expect(await f.resolver.calls == 1)
        #expect(await f.scheduler.snapshot().active == 0)
        let cached = f.root.appendingPathComponent("cache")
        try FileManager.default.moveItem(at: file.fileURL, to: cached)
        try await owner.didPublish(file)
        #expect(try await f.store.backgroundDownloads(accountID: f.account).isEmpty)
        await owner.close(); _ = await activity.result; try await f.store.close()
    }

    @Test func completedBytesCannotBePublishedAfterPermissionRevocation() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = try f.owner(), activity = Task { try await owner.run() }
        let request = Task { try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target) }
        try await f.driver.waitForResume()
        await f.resolver.deny()
        try await f.driver.finish()
        await #expect(throws: V2ClientMediaTransferError.authorizationDenied) { _ = try await request.value }
        #expect(try await f.store.backgroundDownloads(accountID: f.account).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: f.inbox.directory.appendingPathComponent("files"), includingPropertiesForKeys: nil).isEmpty)
        await owner.close(); _ = await activity.result; try await f.store.close()
    }

    @Test func coldOwnerAdoptsTheOriginalTaskAndWaiterDoesNotCreateAnotherAttempt() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let jobID = UUID(), mappingID = UUID()
        _ = try await f.store.beginBackgroundDownload(id: jobID, mediaID: f.media, message: f.message, accountID: f.account)
        let identifier = try await f.driver.create(target: f.target, mappingID: mappingID)
        let grant = try #require(f.target.backgroundDownloadAuthorization)
        let mapping = try V2BackgroundDownloadTask(id: mappingID, sessionID: f.session, identifier: identifier,
            grantID: grant.id, expectedByteCount: f.target.expectedByteCount, checksum: f.target.checksum,
            originDigest: #require(V2BackgroundResultInbox.originDigest(f.target.url)), expiresAtMilliseconds: grant.expiresAtMilliseconds)
        try await f.store.installBackgroundDownloadTask(id: jobID, task: mapping, accountID: f.account)
        try await f.driver.resume(identifier)
        let owner = try f.owner()
        try await owner.initialize()
        #expect(await f.scheduler.snapshot().active == 1)
        let activity = Task { try await owner.run() }
        let request = Task { try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target) }
        try await f.driver.finish()
        let file = try await request.value
        #expect(await f.driver.createCount == 1)
        let persisted = try #require(try await f.store.backgroundDownloads(accountID: f.account).first)
        #expect(persisted.id == jobID && persisted.state == .downloaded(mapping))
        #expect(file.fileURL.lastPathComponent == mappingID.uuidString)
        await owner.close(); _ = await activity.result; try await f.store.close()
    }

    @Test func cancellationKeepsThePhysicalSlotUntilTheRealDriverDrain() async throws {
        let f = try Fixture(autoDrain: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = try f.owner(), activity = Task { try await owner.run() }
        let request = Task { try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target) }
        try await f.driver.waitForResume()
        let cancellation = Task { try await owner.cancel(mediaID: f.media) }
        try await f.driver.waitForCancellation()
        #expect(await f.scheduler.snapshot().active == 1)
        await f.driver.finishDrain()
        try await cancellation.value
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(await f.scheduler.snapshot().active == 0)
        #expect(try await f.store.backgroundDownloads(accountID: f.account).isEmpty)
        await owner.close(); _ = await activity.result; try await f.store.close()
    }

    private struct Fixture {
        static let bytes = Data("background-file".utf8)
        let root: URL, session: UUID, account: UserID, media: MediaID, message: V2MediaMessageLocation
        let store: GRDBV2LocalSyncStore, scheduler: V2AccountWorkScheduler
        let target: V2ClientMediaTransferTarget, resolver: DownloadResolver, driver: DownloadDriver
        let inbox: V2BackgroundResultInbox
        init(autoDrain: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            session = UUID(); account = .init(uuid: UUID()); media = .init(uuid: UUID())
            message = .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
            store = try .init(databaseURL: root.appendingPathComponent("db.sqlite"), installationBinding: .init(value: UUID()), userID: account)
            scheduler = .init(configuration: .init(byteTransferLimit: 1))
            let now = Date(), expiry = now.addingTimeInterval(60)
            let digest = try V2ResourceChecksum(value: SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined())
            target = try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://objects.invalid/download?cap=private")!,
                expiresAt: expiry, expectedByteCount: Int64(Self.bytes.count), checksum: digest,
                backgroundDownloadAuthorization: .init(id: UUID(), expectedByteCount: Int64(Self.bytes.count), checksum: digest, issuedAt: now, expiresAt: expiry)))
            inbox = try .init(root: root.appendingPathComponent("downloads"), sessionID: session)
            resolver = .init(target: target)
            let boundStore = store, boundAccount = account, boundMedia = media
            driver = .init(inbox: inbox, autoDrain: autoDrain, bytes: Self.bytes) { id, task in
                guard let job = try? await boundStore.backgroundDownloads(accountID: boundAccount).first(where: {
                    if case .transferring(let value) = $0.state { return value.id == id && value.identifier == task }; return false
                }) else { return false }
                return job.mediaID == boundMedia
            }
        }
        func owner() throws -> V2BackgroundDownloadCoordinator {
            try .init(sessionID: session, accountID: account, store: store, scheduler: scheduler, resolver: resolver, driver: driver, root: root)
        }
    }
}


private actor DownloadResolver: V2ClientMediaDownloadTargetResolver {
    let target: V2ClientMediaTransferTarget
    var calls = 0, allowed = true
    init(target: V2ClientMediaTransferTarget) { self.target = target }
    func deny() { allowed = false }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        calls += 1
        guard allowed else { throw V2ClientMediaTransferError.authorizationDenied }
        return target
    }
}

private actor DownloadDriver: V2BackgroundDownloadSessionDriving {
    let inbox: V2BackgroundResultInbox
    let autoDrain: Bool, bytes: Data
    let durable: @Sendable (UUID, Int) async -> Bool
    var actual: [V2BackgroundSystemTask] = []
    var wake: @Sendable () async -> Void = {}
    var createCount = 0, durableBeforeResume = false, resumed = false, cancelling = false
    let resumedEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let cancelEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let drainEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var origin: String?
    init(inbox: V2BackgroundResultInbox, autoDrain: Bool, bytes: Data, durable: @escaping @Sendable (UUID, Int) async -> Bool) {
        self.inbox = inbox; self.autoDrain = autoDrain; self.bytes = bytes; self.durable = durable
    }
    func tasks() -> [V2BackgroundSystemTask] { actual }
    func installWake(_ wake: @escaping @Sendable () async -> Void) { self.wake = wake }
    func create(target: V2ClientMediaTransferTarget, mappingID: UUID) throws -> Int {
        _ = try V2BackgroundDownloadRequest.make(target: target)
        createCount += 1; origin = V2BackgroundResultInbox.originDigest(target.url)
        actual.append(.init(identifier: createCount, mappingID: mappingID, suspended: true)); return createCount
    }
    func resume(_ identifier: Int) async throws {
        guard let task = actual.first(where: { $0.identifier == identifier }), let id = task.mappingID else { throw V2BackgroundTransferError.mappingConflict }
        durableBeforeResume = await durable(id, identifier)
        guard durableBeforeResume else { throw V2BackgroundTransferError.mappingConflict }
        actual = actual.map { $0.identifier == identifier ? .init(identifier: identifier, mappingID: id, suspended: false) : $0 }
        resumed = true; resumedEvents.continuation.yield(())
    }
    func waitForResume() async throws {
        var iterator = resumedEvents.stream.makeAsyncIterator()
        while !resumed { guard await iterator.next() != nil else { throw CancellationError() } }
    }
    func waitForCancellation() async throws {
        var iterator = cancelEvents.stream.makeAsyncIterator()
        while !cancelling { guard await iterator.next() != nil else { throw CancellationError() } }
    }
    func finish() async throws {
        let tasks = actual; actual.removeAll()
        for task in tasks {
            let id = try #require(task.mappingID), file = inbox.directory.appendingPathComponent("files").appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            try inbox.write(.init(mappingID: id, taskIdentifier: task.identifier, statusCode: 200, errorCode: nil, sentBytes: 0,
                originDigest: origin, receivedBytes: Int64(bytes.count)))
        }
        await wake()
    }
    func finishDrain() { drainEvents.continuation.yield(()) }
    func cancelAndDrain(_ identifiers: [Int]) async {
        guard actual.contains(where: { identifiers.contains($0.identifier) }) else { return }
        cancelling = true; cancelEvents.continuation.yield(())
        if !autoDrain { var iterator = drainEvents.stream.makeAsyncIterator(); _ = await iterator.next() }
        actual.removeAll { identifiers.contains($0.identifier) }
        await wake()
    }
}
