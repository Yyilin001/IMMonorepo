import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Reviewed unbound resource cancellation", .timeLimit(.minutes(1)))
struct V2ResourceUnboundCancellationTests {
    @Test(arguments: [false, true]) func uploadCancellationUsesOriginalIdentityAndReleasesSourceOnlyAfterAuthority(completionWins: Bool) async throws {
        let f = try await Fixture(), upload = try await f.upload(), gate = UnboundUploadControl(completionWins: completionWins)
        let engine = V2ResourceTransferEngine(store: f.store, control: gate, executor: gate, resources: f.center)
        try await f.center.attachUploads(engine)
        let row = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(row.actions.contains(.cancelUnbound) && !row.actions.contains(.cancel))
        let plan = try await f.center.planUnboundCancellation(.upload(upload.id))
        #expect(try await f.store.resourceTransfer(id: upload.id)?.cancellationRequested == false)
        try await f.center.cancelUnbound(plan)
        #expect(try await f.store.releasableResourceAssetID(id: upload.id) == nil)
        #expect(try await f.center.localAsset(upload.localAssetID)?.availability == .local)
        let terminal = try await engine.resume(id: upload.id)
        #expect(terminal.stage == (completionWins ? .ready : .cancelled))
        #expect(terminal.cancellationRequested && terminal.request == upload.request)
        #expect(await gate.created == [upload.request.operationID])
        #expect(await gate.cancelled == [try #require(terminal.session?.locator)])
        #expect(try await f.store.releasableResourceAssetID(id: upload.id) == upload.localAssetID)
        try await engine.releaseFinishedSources(id: upload.id)
        #expect(try await f.store.releasableResourceAssetID(id: upload.id) == nil)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.cancelUnbound(plan) }
        try await f.close()
    }

    @Test(arguments: [false, true]) func newMessageConsumerInvalidatesReviewedPlanWithoutPartialCancellation(imported: Bool) async throws {
        let f = try await Fixture(), transfer = try await f.transfer(imported: imported)
        let plan = try await f.center.planUnboundCancellation(transfer)
        try await f.store.freezeSendIntent(.init(id: UUID(), roomID: f.room, clientMessageID: .init(uuid: UUID()), text: "new consumer", attachmentJobIDs: [transfer.value]))
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.cancelUnbound(plan) }
        #expect(try await f.store.preparingSendIntents().count == 1)
        if imported { #expect(try await f.store.resourceImport(id: transfer.value)?.cancellationRequested == false) }
        else { #expect(try await f.store.resourceTransfer(id: transfer.value)?.cancellationRequested == false) }
        let row = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(row.actions.contains(.cancel) && !row.actions.contains(.cancelUnbound))
        try await f.close()
    }

    @Test func personalAvatarSourceCannotBeCancelledThroughEitherUnboundOrLegacyEntry() async throws {
        let f = try await Fixture(), id = UUID()
        let asset = try await f.center.importLocal(data: Data("avatar".utf8), displayName: .init("avatar.png"), contentType: .init("image/png"), purpose: .personalAvatar)
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: asset.id, displayName: asset.displayName.value, contentType: asset.contentType.value, byteCount: asset.byteCount)
        let intent = try await f.store.enqueueProfileIntent(accountID: f.user, expectedRevision: .init(rawValue: 1)!, patch: .init(avatar: .set(.init(mediaID: .init(uuid: id)))), avatarUpload: source)
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: id), mediaID: .init(uuid: id), usage: .userAvatar, contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
        _ = try await f.store.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
        #expect(try await f.store.requestResourceCancellation(id: id) == nil)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.planUnboundCancellation(.upload(id)) }
        #expect(try await f.store.resourceTransfer(id: id)?.cancellationRequested == false)
        try await f.store.discardProfileIntentSource(id: intent.id)
        #expect(try await f.store.resourceTransfer(id: id)?.cancellationRequested == true)
        #expect(try await f.store.resourceTransfer(id: id)?.nextAction == .cancel)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.planUnboundCancellation(.upload(id)) }
        try await f.close()
    }

    @Test func closedGroupDecisionRetainsDomainOwnershipUntilExplicitAbandonment() async throws {
        let f = try await Fixture(), upload = try await f.upload(usage: .groupAvatar(f.room)), device = DeviceID(uuid: UUID())
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: f.room, expectedRevision: 0, mutation: .set(upload.request.mediaID))
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.user, command: command, uploadJobID: upload.id)
        try await f.store.requestGroupAvatarRecovery(command.operationID, action: .closeIfAbsent)
        let claim = try await f.store.claimGroupAvatarSubmission(command.operationID, now: Date())
        let proof = try V2GroupAvatarRecoveryResponse(actorUserID: f.user, deviceID: device, request: .init(command: command, action: .closeIfAbsent), result: .closed)
        try await f.store.finishGroupAvatarRecovery(claim, response: proof, now: Date())
        #expect(try await f.store.groupAvatarIntent(command.operationID)?.closedDisposition == .awaitingDecision)
        #expect(try await f.store.requestResourceCancellation(id: upload.id) == nil)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.planUnboundCancellation(.upload(upload.id)) }
        // Only the group's explicit decision may initiate the original abort,
        // including when its upload previously exhausted a recovery budget.
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_transfer_jobs SET stage='paused',needs_attention=1 WHERE job_id=?", arguments: [upload.id.uuidString]) }
        try await f.store.abandonClosedGroupAvatarIntent(command.operationID)
        let cancelled = try #require(try await f.store.resourceTransfer(id: upload.id))
        #expect(cancelled.cancellationRequested && !cancelled.needsAttention && cancelled.nextAction == .cancel)
        #expect(try await f.store.dueResourceTransfers().contains(upload.id))
        try await f.close()
    }

    @Test func repeatedCancellationDoesNotReopenBudgetOrShortenServerCooldown() async throws {
        let f = try await Fixture(), upload = try await f.upload(), owner = UUID()
        _ = try await f.store.requestResourceCancellation(id: upload.id)
        _ = try await f.store.claimResourceStep(id: upload.id, owner: owner, now: Date())
        try await f.store.failResourceStep(id: upload.id, owner: owner, code: "transport", retryAt: nil, serverRetryNotBefore: Date().addingTimeInterval(3600))
        let before = try #require(try await f.store.resourceTransfer(id: upload.id))
        #expect(before.needsAttention && before.actionAttempts == 1)
        _ = try await f.store.requestResourceCancellation(id: upload.id)
        #expect(try await f.store.resourceTransfer(id: upload.id) == before)
        try await f.close()
    }

    @Test(arguments: [false, true]) func databaseReopenKeepsOriginalCancellationAndServerFloor(imported: Bool) async throws {
        let f = try await Fixture(), transfer = try await f.transfer(imported: imported)
        let plan = try await f.center.planUnboundCancellation(transfer)
        let table = imported ? "v2_resource_import_jobs" : "v2_resource_transfer_jobs", floor = Date().addingTimeInterval(3600).timeIntervalSince1970
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET server_retry_not_before=? WHERE job_id=?", arguments: [floor, transfer.value.uuidString]) }
        try await f.center.cancelUnbound(plan)
        await f.center.close(); try await f.store.close()
        let store = try GRDBV2LocalSyncStore(databaseURL: f.root.appending(path: "V2.sqlite"), installationBinding: f.binding, userID: f.user)
        let identity = try await store.databasePool.read { try Bool.fetchOne($0, sql: "SELECT cancellation_requested=1 AND retry_at=? FROM \(table) WHERE job_id=?", arguments: [floor, transfer.value.uuidString]) }
        #expect(identity == true)
        #expect(try await store.preparingSendIntents().isEmpty)
        if imported { #expect(try await store.dueResourceImports().isEmpty) }
        else { #expect(try await store.dueResourceTransfers().isEmpty) }
        try await store.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test func foreignOwnerAndFailedTransactionCannotCancelTask() async throws {
        let f = try await Fixture(), upload = try await f.upload()
        let plan = try await f.center.planUnboundCancellation(.upload(upload.id))
        let cancelledCaller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await f.center.cancelUnbound(plan)
        }
        await #expect(throws: CancellationError.self) { try await cancelledCaller.value }
        #expect(try await f.store.resourceTransfer(id: upload.id)?.cancellationRequested == false)
        let foreign = try await V2ResourceCenter.make(scope: .init(incarnation: UUID(), accountID: f.user, directory: f.root.appending(path: "other"), cacheDirectory: f.root.appending(path: "other-cache")), store: f.store)
        await #expect(throws: V2AccountStorageError.scopeMismatch) { try await foreign.cancelUnbound(plan) }
        await foreign.close()
        try await f.store.databasePool.write { try $0.execute(sql: "CREATE TRIGGER reject_unbound BEFORE UPDATE OF cancellation_requested ON v2_resource_transfer_jobs BEGIN SELECT RAISE(ABORT,'injected cancellation failure'); END") }
        await #expect(throws: DatabaseError.self) { try await f.center.cancelUnbound(plan) }
        #expect(try await f.store.resourceTransfer(id: upload.id)?.cancellationRequested == false)
        try await f.store.databasePool.write { try $0.execute(sql: "DROP TRIGGER reject_unbound") }
        try await f.center.cancelUnbound(plan)
        #expect(try await f.store.resourceTransfer(id: upload.id)?.cancellationRequested == true)
        try await f.close()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "unbound-cancel-\(UUID())")
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let binding = V2LocalInstallationBinding(value: UUID())
        let store: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        init() async throws {
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: binding, userID: user)
            center = try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache")), store: store)
        }
        func upload(usage: V2ResourceUsage? = nil) async throws -> V2ResourcePreparedUpload {
            let usage = usage ?? .messageAttachment(room)
            let purpose: V2LocalResourceAssetPurpose = switch usage { case .messageAttachment(let room): .messageDraft(room); case .groupAvatar(let room): .groupAvatar(room); case .userAvatar: .personalAvatar }
            let asset = try await center.importLocal(data: Data("source".utf8), displayName: .init("original.bin"), contentType: .init("application/octet-stream"), purpose: purpose)
            let id = UUID(), request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: usage, contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
            _ = try await store.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
            return try .init(id: id, request: request, localAssetID: asset.id)
        }
        func transfer(imported: Bool) async throws -> V2ManagedResourceTransferID {
            if !imported { return .upload(try await upload().id) }
            let id = UUID(), request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
            try await store.prepareResourceImport(id: id, request: request); return .serverImport(id)
        }
        func close() async throws { await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}

private actor UnboundUploadControl: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    let completionWins: Bool
    private(set) var created: [MediaUploadOperationID] = []
    private(set) var cancelled: [V2ResourceUploadLocator] = []
    init(completionWins: Bool) { self.completionWins = completionWins }
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession {
        created.append(request.operationID)
        guard case .messageAttachment(let room) = request.usage else { throw V2ResourceJournalError.invalidRecord }
        return try .init(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())), mediaID: request.mediaID, generation: 1, state: .created, resourceState: .pending, expiresAt: .distantFuture)
    }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession {
        cancelled.append(session.locator)
        return try .init(locator: session.locator, mediaID: session.mediaID, generation: 1, state: completionWins ? .completed : .cancelled, resourceState: completionWins ? .ready : .pending, expiresAt: .distantFuture, bindableUntil: completionWins ? .distantFuture : nil)
    }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { Issue.record("Cancelled task cannot start byte upload"); throw V2ResourceJournalError.invalidRecord }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ResourceJournalError.invalidRecord }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw V2ResourceJournalError.invalidRecord }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { Issue.record("Cancelled task cannot upload bytes") }
}
