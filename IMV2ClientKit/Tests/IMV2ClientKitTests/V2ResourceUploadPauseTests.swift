import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Durable user upload pause", .timeLimit(.minutes(1)))
struct V2ResourceUploadPauseTests {
    @Test func preCancelledPauseCannotCommitControl() async throws {
        let f = try await Fixture()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await f.center.pauseTransfer(.upload(f.id))
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(try await f.store.resourceTransfer(id: f.id)?.control == .run)
        try await f.close()
    }

    @Test func offlinePauseSurvivesReopenAndPreservesOriginalOperationAndCooldown() async throws {
        let f = try await Fixture()
        let original = try #require(try await f.store.resourceTransfer(id: f.id))
        try await f.center.pauseTransfer(.upload(f.id))
        #expect(try await f.store.dueResourceTransfers(now: .distantFuture).isEmpty)
        #expect(try await f.store.nextResourceAttempt(excluding: []) == nil)
        #expect(try await f.store.claimResourceStep(id: f.id, owner: UUID(), now: .distantFuture) == nil)
        let row = try #require(try await f.store.managedResourceTransfers(.init(group: .attention)).entries.first)
        #expect(row.phase == .paused && row.actions == [.resume, .cancel])
        let floor = Date().addingTimeInterval(3600).timeIntervalSince1970
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_transfer_jobs SET server_retry_not_before=? WHERE job_id=?", arguments: [floor, f.id.uuidString]) }
        await f.center.close(); try await f.store.close()
        let store = try GRDBV2LocalSyncStore(databaseURL: f.root.appending(path: "V2.sqlite"), installationBinding: f.binding, userID: f.user)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: store)
        #expect(try await store.resourceTransfer(id: f.id)?.control == .pause)
        #expect(try await store.preparingSendIntents().count == 1)
        #expect(try await center.localAsset(f.asset)?.availability == .local)
        try await center.resumeTransfer(.upload(f.id))
        let resumed = try #require(try await store.resourceTransfer(id: f.id))
        #expect(resumed.control == .run && resumed.request == original.request && resumed.localAssetID == original.localAssetID)
        #expect(resumed.nextAction == .create && resumed.retryAt.timeIntervalSince1970 == floor)
        #expect(try await store.dueResourceTransfers().isEmpty)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await center.resumeTransfer(.upload(f.id)) }
        await center.close(); try await store.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test func pauseWaitsForActualWriterAfterPageLeavesAndContinueReconcilesSameSession() async throws {
        let f = try await Fixture(), gate = UploadPauseGate()
        let engine = V2ResourceTransferEngine(store: f.store, control: gate, executor: gate, resources: f.center)
        try await f.center.attachUploads(engine)
        let created = try await engine.resume(id: f.id)
        let locator = try #require(created.session?.locator)
        let writer = Task { try await engine.resume(id: f.id) }
        await gate.entered()
        let pause = Task { try await f.center.pauseTransfer(.upload(f.id)) }
        await gate.cancelled()
        let pausing = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(pausing.phase == .pausing && !pausing.actions.contains(.resume))
        #expect(try await f.store.dueResourceTransfers(now: .distantFuture).isEmpty)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.resumeTransfer(.upload(f.id)) }
        pause.cancel()
        await #expect(throws: CancellationError.self) { try await pause.value }
        #expect(try await f.store.resourceTransfer(id: f.id)?.control == .pause)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await writer.value }
        try await waitUntil { try await f.store.managedResourceTransfers(.init(group: .attention)).entries.first?.phase == .paused }
        #expect(try await f.center.localAsset(f.asset)?.availability == .local)
        try await f.center.resumeTransfer(.upload(f.id))
        let continued = try #require(try await f.store.resourceTransfer(id: f.id))
        #expect(continued.nextAction == .status && continued.session?.locator == locator)
        for _ in 0..<4 { _ = try await engine.resume(id: f.id) }
        let complete = try #require(try await f.store.resourceTransfer(id: f.id))
        #expect(complete.stage == .ready && complete.request == created.request)
        #expect(await gate.createdCount == 1)
        #expect(await gate.cancelCount == 0)
        #expect(await gate.statusLocators == [locator])
        #expect(await gate.uploadCount == 2)
        #expect(try await f.store.preparingSendIntents().count == 1)
        try await f.close()
    }

    @Test func cancellationSupersedesPauseAndNeverResumesWithdrawnMessage() async throws {
        let f = try await Fixture()
        try await f.center.pauseTransfer(.upload(f.id))
        let plan = try await f.center.planPreparationCancellation(.upload(f.id))
        try await f.center.cancelPreparation(plan)
        let job = try #require(try await f.store.resourceTransfer(id: f.id))
        #expect(job.control == .run && job.cancellationRequested && job.nextAction == .cancel)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.resumeTransfer(.upload(f.id)) }
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(try await f.store.dueResourceTransfers().contains(f.id))
        try await f.close()
    }

    @Test func authoritativeReadyWinsBeforePauseAndStalePauseCannotReopenIt() async throws {
        let f = try await Fixture(), gate = UploadPauseGate(block: false)
        let engine = V2ResourceTransferEngine(store: f.store, control: gate, executor: gate, resources: f.center)
        try await f.center.attachUploads(engine)
        for _ in 0..<3 { _ = try await engine.resume(id: f.id) }
        #expect(try await f.store.resourceTransfer(id: f.id)?.stage == .ready)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.pauseTransfer(.upload(f.id)) }
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.resumeTransfer(.upload(f.id)) }
        #expect(try await f.store.resourceTransfer(id: f.id)?.control == .run)
        try await f.close()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-pause-\(UUID())")
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), id = UUID()
        let binding = V2LocalInstallationBinding(value: UUID())
        let store: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        let scope: V2AccountStorageScope
        let asset: V2LocalResourceAssetID
        init() async throws {
            scope = .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache"))
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: binding, userID: user)
            center = try await .make(scope: scope, store: store)
            let imported = try await center.importLocal(data: Data("original".utf8), displayName: .init("message.txt"), contentType: .init("text/plain"), purpose: .messageDraft(room))
            asset = imported.id
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .messageAttachment(room), contentType: imported.contentType.value,
                byteCount: imported.byteCount, checksum: imported.checksum, displayName: imported.displayName)
            _ = try await store.prepareResourceTransfer(id: id, request: request, localAssetID: asset)
            let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "preserve frozen message", attachmentJobIDs: [id])
            try await store.freezeSendIntent(intent)
        }
        func close() async throws { await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while try await !predicate() { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(5)) }
    }
}

private actor UploadPauseGate: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    private var block: Bool
    private var original: V2ResourceUploadSession?
    private var request: V2ResourceUploadRequest?
    private let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let cancellations = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var drain: CheckedContinuation<Void, Never>?
    private(set) var createdCount = 0
    private(set) var cancelCount = 0
    private(set) var uploadCount = 0
    private(set) var statusLocators: [V2ResourceUploadLocator] = []
    init(block: Bool = true) { self.block = block }
    func entered() async { for await _ in starts.stream { return } }
    func cancelled() async { for await _ in cancellations.stream { return } }
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession {
        guard case .messageAttachment(let room) = request.usage else { throw V2ResourceJournalError.invalidRecord }
        createdCount += 1; self.request = request
        let session = try V2ResourceUploadSession(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())), mediaID: request.mediaID, generation: 1, state: .created, resourceState: .pending, expiresAt: .distantFuture)
        original = session; return session
    }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession {
        let session = try #require(original); #expect(session.locator == locator)
        statusLocators.append(locator); return session
    }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? {
        let request = try #require(request)
        return try .init(mode: .httpPut, url: #require(URL(string: "https://bytes.invalid/upload")), expiresAt: .distantFuture, expectedByteCount: request.byteCount, checksum: request.checksum)
    }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws {
        uploadCount += 1
        #expect(try Data(contentsOf: fileURL) == Data("original".utf8))
        if block {
            await withTaskCancellationHandler {
                await withCheckedContinuation { drain = $0; starts.continuation.yield(()) }
            } onCancel: { Task { await self.noteCancellation() } }
            try Task.checkCancellation()
        }
    }
    private func noteCancellation() { cancellations.continuation.yield(()) }
    func release() { block = false; drain?.resume(); drain = nil }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession {
        try .init(locator: session.locator, mediaID: session.mediaID, generation: 1, state: .completed, resourceState: .ready, expiresAt: .distantFuture, bindableUntil: .distantFuture)
    }
    func cancel(_ session: V2ResourceUploadSession) -> V2ResourceUploadSession { cancelCount += 1; Issue.record("User pause must not abort the remote resource"); return session }
}
