import Foundation
import GRDB
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Resource business owner routing and disposition", .timeLimit(.minutes(1)))
struct V2ResourceBusinessOwnerTests {
    @Test func uploadObservationsReachStableSnapshotsWithoutBecomingProviderReceipts() async throws {
        let f = try await Fixture()
        _ = try await f.profile(name: "live upload")
        let gate = ProfileOwnerWriterGate(user: f.user)
        let engine = V2ResourceTransferEngine(store: f.store, control: gate, executor: gate, resources: f.center)
        try await f.center.attachUploads(engine)
        var snapshots = try await f.center.transferSnapshots(for: .init()).makeAsyncIterator()
        guard case .available(let initial) = await snapshots.next() else { Issue.record("Missing initial task"); return }
        _ = try await engine.resume(id: f.job)
        let writer = Task { try await engine.resume(id: f.job) }
        await gate.entered()
        let reporter = try #require(await gate.uploadReporter())
        reporter.report(transferredBytes: 4); reporter.report(transferredBytes: 7)
        var observed: V2ManagedResourceTransfer?
        while let snapshot = await snapshots.next() {
            if case .available(let page) = snapshot, page.entries.first?.attemptProgress?.transferredBytes == 7 {
                observed = page.entries.first; break
            }
        }
        #expect(observed?.id == initial.entries.first?.id && observed?.createdAt == initial.entries.first?.createdAt)
        #expect(observed?.confirmedBytes == nil && observed?.phase == .transferring)
        #expect(try await f.store.resourceTransfer(id: f.job)?.stage != .ready)
        await gate.release(); _ = try await writer.value
        reporter.report(transferredBytes: 14)
        while let snapshot = await snapshots.next() {
            if case .available(let page) = snapshot, page.entries.first?.attemptProgress == nil { break }
        }
        #expect(try await f.store.resourceTransfer(id: f.job)?.nextAction == .finalize)
        try await f.close()
        // AsyncStream may deliver its single buffered snapshot after finish.
        // Drain that final frame before asserting terminal iteration.
        while await snapshots.next() != nil {}
        #expect(await snapshots.next() == nil)
        await #expect(throws: V2ResourceStorageError.closed) {
            try await f.center.beginUploadProgress(job: f.job, expectedBytes: 14)
        }
    }

    @Test func disposingProfileHeadWakesNextDraftEvenWhenItsDueTimeIsIdentical() async throws {
        let f = try await Fixture(), intent = try await f.profile(name: "first head")
        let next = try await f.store.enqueueProfileIntent(accountID: f.user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("same due, next identity")), avatarUpload: nil, now: f.time)
        let schedule = await f.store.profilePreparationSchedule(accountID: f.user)
        do {
            var wake = await schedule.updates().makeAsyncIterator()
            #expect(try await wake.next() != nil)
            let due = try await schedule.nextAttemptAt()
            try await f.center.commitProfileDisposition(try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id))
            #expect(try await wake.next() != nil)
            #expect(try await schedule.nextAttemptAt() == due)
            #expect(try await f.store.firstUnfinishedProfileIntent(accountID: f.user)?.id == next.id)
        }
        try await f.close()
    }

    @Test func profileDispositionOutlivesPageAndCloseDrainsOriginalWriter() async throws {
        let f = try await Fixture(), intent = try await f.profile(name: "stop exact draft"), gate = ProfileOwnerWriterGate(user: f.user)
        let engine = V2ResourceTransferEngine(store: f.store, control: gate, executor: gate, resources: f.center)
        try await f.center.attachUploads(engine)
        _ = try await engine.resume(id: f.job)
        let writer = Task { try await engine.resume(id: f.job) }
        await gate.entered()
        let plan = try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id)
        let disposal = Task { try await f.center.commitProfileDisposition(plan) }
        await gate.cancelled()
        #expect(try await f.center.containsBusinessOwner(.profileIntent(intent.id), transfer: .upload(f.job)) == false)
        #expect(try await f.store.releasableResourceAssetID(id: f.job) == nil)
        #expect(try await f.center.localAsset(f.asset.id)?.availability == .local)
        disposal.cancel()
        await #expect(throws: CancellationError.self) { try await disposal.value }
        let completed = Mutex(false)
        let close = Task { await f.center.close(); completed.withLock { $0 = true } }
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            do { _ = try await f.center.transferSnapshots(for: .init()) }
            catch V2ResourceStorageError.closed { break }
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!completed.withLock { $0 })
        await gate.release(); _ = await writer.result; await close.value
        #expect(completed.withLock { $0 })
        #expect(try await f.store.resourceTransfer(id: f.job)?.cancellationRequested == true)
        try await f.store.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test func ownerLookupUsesExactUploadAndPaginatesEqualCreationTimesWithoutDuplicates() async throws {
        let f = try await Fixture(), first = try await f.profile(name: "first")
        try await f.store.expireUnfrozenProfileIntent(id: first.id)
        let second = try await f.store.enqueueProfileIntent(accountID: f.user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("second"), avatar: .set(.init(mediaID: .init(uuid: f.job)))), avatarUpload: f.source, adoptingFromIntentID: first.id, now: f.time)
        _ = try await f.store.enqueueProfileIntent(accountID: f.user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("unrelated latest")), avatarUpload: nil, now: f.time.addingTimeInterval(1))
        let query = try V2ResourceBusinessOwnerQuery(transfer: .upload(f.job), limit: 1)
        let page = try await f.store.resourceBusinessOwners(query)
        let next = try await f.store.resourceBusinessOwners(.init(transfer: .upload(f.job), before: #require(page.nextCursor), limit: 1))
        #expect(Set((page.entries + next.entries).map(\.owner)) == [.profileIntent(first.id), .profileIntent(second.id)])
        #expect(next.nextCursor == nil && page.entries.first?.createdAt == f.time)
        #expect(try await f.center.containsBusinessOwner(.profileIntent(first.id), transfer: .upload(f.job)))
        #expect(try await f.center.containsBusinessOwner(.profileIntent(first.id), transfer: .upload(UUID())) == false)
        #expect(throws: V2ResourceStorageError.invalidRecord) { try V2ResourceBusinessOwnerQuery(transfer: .upload(UUID()), before: page.nextCursor) }
        let selected = try #require(page.entries.first)
        guard case .profileIntent(let selectedID) = selected.owner else { throw V2ResourceStorageError.invalidRecord }
        try await f.center.commitProfileDisposition(try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: selectedID))
        #expect(try await f.store.resourceTransfer(id: f.job)?.cancellationRequested == false)
        #expect(try await f.store.resourceBusinessOwners(.init(transfer: .upload(f.job), before: page.nextCursor, limit: 1)).entries == next.entries)
        try await f.close()
    }

    @Test func unsubmittedProfileDispositionWithdrawsWholeDraftAndRequestsOriginalUploadCancellation() async throws {
        let f = try await Fixture(), intent = try await f.profile(name: "frozen nickname")
        let before = try #require(try await f.store.resourceTransfer(id: f.job))
        let plan = try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id)
        #expect(plan.effect == .withdrawUnsubmittedChange)
        #expect(try await f.store.profileIntent(id: intent.id) == intent)
        try await f.center.commitProfileDisposition(plan)
        let after = try #require(try await f.store.resourceTransfer(id: f.job))
        #expect(after.cancellationRequested && after.request == before.request && after.localAssetID == before.localAssetID)
        #expect(try await f.store.firstUnfinishedProfileIntent(accountID: f.user) == nil)
        #expect(try await f.center.containsBusinessOwner(.profileIntent(intent.id), transfer: .upload(f.job)) == false)
        #expect(try await f.center.localAsset(f.asset.id)?.availability == .local)
        #expect(try await f.store.releasableResourceAssetID(id: f.job) == nil)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.commitProfileDisposition(plan) }
        try await f.close()
    }

    @Test func profileHandoffAfterReviewRejectsEntireDispositionAndCannotCancelPublishedWork() async throws {
        let f = try await Fixture(), intent = try await f.profile(name: "keep this")
        let plan = try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id)
        try await f.store.saveResourceSession(.init(locator: .init(home: .account(f.user), sessionID: .init(uuid: UUID())),
            mediaID: .init(uuid: f.job), generation: 1, state: .completed, resourceState: .ready,
            expiresAt: .distantFuture, bindableUntil: .distantFuture), for: f.job)
        let frozen = try await f.store.freezeProfileIntent(id: intent.id, avatar: .init(mediaID: .init(uuid: f.job)))
        #expect(frozen.workID != nil)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.commitProfileDisposition(plan) }
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id) }
        #expect(try await f.center.containsBusinessOwner(.profileIntent(intent.id), transfer: .upload(f.job)))
        #expect(try await f.store.resourceTransfer(id: f.job)?.cancellationRequested == false)
        try await f.close()
    }

    @Test(arguments: [false, true]) func finishedProfileReleasesOnlyRetainedSourceWithoutRewritingReceipt(committed: Bool) async throws {
        let f = try await Fixture(), intent = try await f.profile(name: "committed")
        try await f.store.saveResourceSession(.init(locator: .init(home: .account(f.user), sessionID: .init(uuid: UUID())), mediaID: .init(uuid: f.job), generation: 1,
            state: .completed, resourceState: .ready, expiresAt: .distantFuture, bindableUntil: .distantFuture), for: f.job)
        let frozen = try await f.store.freezeProfileIntent(id: intent.id, avatar: .init(mediaID: .init(uuid: f.job)))
        let workID = try #require(frozen.workID), command = try GRDBV2LocalSyncStore.profileCommand(intent: frozen)
        guard case .claimed = try await f.store.claimOperationWork(id: workID, ownerID: UUID(), action: .submit, now: Date()) else { throw V2OperationWorkError.invalidTransition }
        let receipt = try V2ProfileOperationReceipt(actorUserID: f.user, operationID: frozen.operationID, fingerprint: command.fingerprint,
            outcome: committed ? .committed(revision: .init(rawValue: 2)!, visibilityRevision: .init(rawValue: 2)!) : .rejected(.revisionConflict(current: .init(rawValue: 2)!)), resolvedAtMilliseconds: 1)
        try await f.store.completeProfileIntent(intent: frozen, result: .init(receipt: receipt, currentSnapshot: nil))
        let before = try await f.store.operationWork(id: workID)
        if committed {
            await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id) }
        } else {
            let plan = try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id)
            #expect(plan.effect == .releaseFinishedSource)
            try await f.center.commitProfileDisposition(plan)
        }
        #expect(try await f.store.operationWork(id: workID) == before)
        #expect(try await f.store.profileIntent(id: intent.id) == frozen)
        try await f.close()
    }

    @Test func failedAtomicDispositionRollsBackProfileConsumerAndUploadControl() async throws {
        let f = try await Fixture(), intent = try await f.profile(name: "atomic")
        let plan = try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id)
        try await f.store.databasePool.write { try $0.execute(sql: "CREATE TRIGGER reject_owner_cancel BEFORE UPDATE OF cancellation_requested ON v2_resource_transfer_jobs BEGIN SELECT RAISE(ABORT,'injected owner cancellation failure'); END") }
        await #expect(throws: DatabaseError.self) { try await f.center.commitProfileDisposition(plan) }
        #expect(try await f.center.containsBusinessOwner(.profileIntent(intent.id), transfer: .upload(f.job)))
        #expect(try await f.store.firstUnfinishedProfileIntent(accountID: f.user)?.id == intent.id)
        #expect(try await f.store.resourceTransfer(id: f.job)?.cancellationRequested == false)
        try await f.store.databasePool.write { try $0.execute(sql: "DROP TRIGGER reject_owner_cancel") }
        try await f.center.commitProfileDisposition(plan)
        #expect(try await f.center.containsBusinessOwner(.profileIntent(intent.id), transfer: .upload(f.job)) == false)
        try await f.close()
    }

    @Test func localOwnerStreamSeesProfileChangesAndSharesAccountSubscriptionLimit() async throws {
        let f = try await Fixture()
        let stream = try await f.center.businessOwnerSnapshots(for: .init(transfer: .upload(f.job)))
        var events = stream.makeAsyncIterator()
        guard case .available(let empty) = await events.next() else { throw V2ResourceStorageError.invalidRecord }
        #expect(empty.entries.isEmpty)
        let intent = try await f.profile(name: "observed")
        guard case .available(let owned) = await events.next() else { throw V2ResourceStorageError.invalidRecord }
        #expect(owned.entries.map(\.owner) == [.profileIntent(intent.id)])
        var retained: [AsyncStream<V2ResourceBusinessOwnerSnapshot>] = []
        for _ in 0..<15 { retained.append(try await f.center.businessOwnerSnapshots(for: .init(transfer: .upload(f.job)))) }
        await #expect(throws: V2ResourceStorageError.capacityExceeded) { try await f.center.transferSnapshots(for: .init()) }
        await f.center.close()
        #expect(await events.next() == nil)
        await #expect(throws: V2ResourceStorageError.closed) { try await f.center.containsBusinessOwner(.profileIntent(intent.id), transfer: .upload(f.job)) }
        #expect(retained.count == 15)
        try await f.store.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test func groupOwnershipRequiresExactRoomAndIncludesClosedAwaitingDecision() async throws {
        let f = try IntentFixture(), job = try await f.upload(ready: false), command = try f.command(media: job.request.mediaID)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: job.id)
        try await f.store.requestGroupAvatarRecovery(command.operationID, action: .closeIfAbsent)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: f.now)
        let proof = try V2GroupAvatarRecoveryResponse(actorUserID: f.actor, deviceID: f.device, request: .init(command: command, action: .closeIfAbsent), result: .closed)
        try await f.store.finishGroupAvatarRecovery(claim, response: proof, now: f.now)
        let page = try await f.store.resourceBusinessOwners(.init(transfer: .upload(job.id)))
        #expect(page.entries.map(\.owner) == [.groupAvatar(f.room, command.operationID)])
        #expect(try await f.store.resourceHasBusinessOwner(.groupAvatar(.init(uuid: UUID()), command.operationID), transfer: .upload(job.id)) == false)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.hasBusinessOwners == true)
        try await f.store.abandonClosedGroupAvatarIntent(command.operationID)
        #expect(try await f.store.resourceBusinessOwners(.init(transfer: .upload(job.id))).entries.isEmpty)
        try await f.store.close(); try f.removeFiles()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "resource-owner-\(UUID())")
        let user = UserID(uuid: UUID()), job = UUID()
        let time = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let store: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        let asset: V2LocalResourceAsset
        let source: V2ProfileAvatarUpload
        init() async throws {
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
            center = try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache")), store: store)
            asset = try await center.importLocal(data: Data("avatar original".utf8), displayName: .init("avatar.png"), contentType: .init("image/png"), purpose: .personalAvatar)
            source = try .init(id: job, localAssetID: asset.id, displayName: asset.displayName.value, contentType: asset.contentType.value, byteCount: asset.byteCount)
        }
        func profile(name: String) async throws -> V2ProfileIntent {
            let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set(name), avatar: .set(.init(mediaID: .init(uuid: job)))), avatarUpload: source, now: time)
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: job), mediaID: .init(uuid: job), usage: .userAvatar, contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
            _ = try await store.prepareResourceTransfer(id: job, request: request, localAssetID: asset.id, now: time)
            return intent
        }
        func close() async throws { await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}

private actor ProfileOwnerWriterGate: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    let user: UserID
    private var request: V2ResourceUploadRequest?
    private let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let cancellations = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var drain: CheckedContinuation<Void, Never>?
    private var reporter: V2ResourceTransferProgressReporter?
    init(user: UserID) { self.user = user }
    func entered() async { for await _ in starts.stream { return } }
    func cancelled() async { for await _ in cancellations.stream { return } }
    func release() { drain?.resume(); drain = nil }
    func uploadReporter() -> V2ResourceTransferProgressReporter? { reporter }
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession {
        self.request = request
        return try .init(locator: .init(home: .account(user), sessionID: .init(uuid: UUID())), mediaID: request.mediaID, generation: 1, state: .created, resourceState: .pending, expiresAt: .distantFuture)
    }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? {
        let input = try #require(request)
        return try .init(mode: .httpPut, url: #require(URL(string: "https://bytes.invalid/profile")), expiresAt: .distantFuture, expectedByteCount: input.byteCount, checksum: input.checksum)
    }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws {
        reporter = V2ResourceTransferProgressScope.reporter
        #expect(try Data(contentsOf: fileURL) == Data("avatar original".utf8))
        await withTaskCancellationHandler {
            await withCheckedContinuation { drain = $0; starts.continuation.yield(()) }
        } onCancel: { Task { await self.noteCancellation() } }
        try Task.checkCancellation()
    }
    private func noteCancellation() { cancellations.continuation.yield(()) }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ResourceStorageError.unavailable }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw V2ResourceStorageError.unavailable }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ResourceStorageError.unavailable }
}
