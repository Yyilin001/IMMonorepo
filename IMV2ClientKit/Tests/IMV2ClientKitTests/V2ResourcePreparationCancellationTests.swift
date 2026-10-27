import Foundation
import GRDB
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Dependency-aware preparation cancellation", .timeLimit(.minutes(1)))
struct V2ResourcePreparationCancellationTests {
    @Test func alreadyCancelledCallerCannotStartAWithdrawalCommand() async throws {
        let f = try await Fixture(), imported = try await f.addImport()
        _ = try await f.freeze([imported])
        let plan = try await f.center.planPreparationCancellation(.serverImport(imported))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await f.center.cancelPreparation(plan)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await f.store.preparingSendIntents().count == 1)
        #expect(try await f.store.resourceImport(id: imported)?.cancellationRequested == false)
        try await f.close()
    }

    @Test(arguments: [false, true]) func resourceBecomingReadyBeforeConfirmationDoesNotPreventWithdrawingUnsubmittedMessage(imported: Bool) async throws {
        let f = try await Fixture()
        let id = imported ? try await f.addImport() : try await f.upload()
        _ = try await f.freeze([id])
        let plan = try await f.center.planPreparationCancellation(imported ? .serverImport(id) : .upload(id))
        if imported {
            let job = try #require(try await f.store.resourceImport(id: id))
            let ready = try V2ResourceImportStatus(locator: .init(home: .room(f.room), operationID: job.request.operationID),
                mediaID: job.request.targetMediaID, state: .ready, bindableUntil: .distantFuture)
            try await f.store.seedResourceImportStatus(ready, id: id)
        } else {
            let job = try #require(try await f.store.resourceTransfer(id: id))
            let ready = try V2ResourceUploadSession(locator: .init(home: .room(f.room), sessionID: .init(uuid: UUID())), mediaID: job.request.mediaID,
                generation: 1, state: .completed, resourceState: .ready, expiresAt: .distantFuture, bindableUntil: .distantFuture)
            try await f.store.saveResourceSession(ready, for: id)
        }
        try await f.center.cancelPreparation(plan)
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(try await f.store.resourceSendPayloads().isEmpty)
        if imported { #expect(try await f.store.resourceImport(id: id)?.status?.state == .ready) }
        else { #expect(try await f.store.resourceTransfer(id: id)?.stage == .ready) }
        try await f.close()
    }

    @Test(arguments: [false, true]) func originalUploadCancellationOutcomeNeverReactivatesWithdrawnParents(completionWins: Bool) async throws {
        let f = try await Fixture(), upload = try await f.upload(), gate = PreparationUploadGate(completionWins: completionWins)
        _ = try await f.freeze([upload])
        let engine = f.engine(gate)
        try await f.center.attachUploads(engine)
        let created = try await engine.resume(id: upload)
        let locator = try #require(created.session?.locator)
        let plan = try await f.center.planPreparationCancellation(.upload(upload))
        try await f.center.cancelPreparation(plan)
        let terminal = try await engine.resume(id: upload)
        #expect(terminal.stage == (completionWins ? .ready : .cancelled))
        #expect(terminal.session?.locator == locator)
        #expect(terminal.request == created.request && terminal.cancellationRequested)
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(try await f.store.resourceSendPayloads().isEmpty)
        try await f.close()
    }

    @Test func cancellingOneMessageCannotCancelAnImportStillUsedByAnother() async throws {
        let f = try await Fixture(), imported = try await f.addImport()
        let first = try await f.freeze([imported]), second = try await f.freeze([imported])
        try await f.store.cancelSendIntent(first.id)
        try await f.store.requestImportCancellation(id: imported)
        #expect(try await f.store.resourceImport(id: imported)?.cancellationRequested == false)
        #expect(try await f.store.preparingSendIntent(id: second.id) != nil)
        try await f.store.cancelSendIntent(second.id)
        try await f.store.requestImportCancellation(id: imported)
        #expect(try await f.store.resourceImport(id: imported)?.cancellationRequested == true)
        try await f.close()
    }

    @Test func rejectedUploadCanWithdrawItsMessageWithoutRewritingTheTerminalResourceFact() async throws {
        let f = try await Fixture(), upload = try await f.upload()
        _ = try await f.freeze([upload])
        let job = try #require(try await f.store.resourceTransfer(id: upload))
        let rejected = try V2ResourceUploadSession(locator: .init(home: .room(f.room), sessionID: .init(uuid: UUID())),
            mediaID: job.request.mediaID, generation: 1, state: .failed, resourceState: .rejected, expiresAt: .distantFuture)
        try await f.store.saveResourceSession(rejected, for: upload)
        let plan = try await f.center.planPreparationCancellation(.upload(upload))
        try await f.center.cancelPreparation(plan)
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(try await f.store.resourceTransfer(id: upload)?.stage == .rejected)
        #expect(try await f.store.resourceTransfer(id: upload)?.cancellationRequested == false)
        try await f.close()
    }

    @Test func offlineWithdrawalSurvivesDatabaseReopenWithTheSameImportOperation() async throws {
        let f = try await Fixture(), imported = try await f.addImport()
        _ = try await f.freeze([imported])
        let original = try #require(try await f.store.resourceImport(id: imported))
        try await f.center.cancelPreparation(try await f.center.planPreparationCancellation(.serverImport(imported)))
        await f.center.close(); try await f.store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: f.root.appending(path: "V2.sqlite"), installationBinding: f.binding, userID: f.user)
        #expect(try await reopened.preparingSendIntents().isEmpty)
        #expect(try await reopened.pendingImportCancellations() == [imported])
        #expect(try await reopened.resourceImport(id: imported)?.request == original.request)
        #expect(try await reopened.resourceSendPayloads().isEmpty)
        try await reopened.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test(arguments: [false, true]) func mixedFrozenMessageCancelsBothJournalsWithoutSubmitting(importSelected: Bool) async throws {
        let f = try await Fixture(), upload = try await f.upload(), imported = try await f.addImport()
        let intent = try await f.freeze([upload, imported])
        let id: V2ManagedResourceTransferID = importSelected ? .serverImport(imported) : .upload(upload)
        let snapshot = try #require(try await f.store.managedResourceTransfers(.init()).entries.first { $0.id == id })
        #expect(snapshot.actions.contains(.cancel) && snapshot.cancellableMessageCount == 1)
        let plan = try await f.center.planPreparationCancellation(id)
        #expect(plan.messageCount == 1)
        try await f.center.cancelPreparation(plan)
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(try await f.store.resourceTransfer(id: upload)?.cancellationRequested == true)
        #expect(try await f.store.pendingImportCancellations() == [imported])
        #expect(try await f.store.resourceSendPayloads().isEmpty)
        #expect(try await f.store.databasePool.read { try String.fetchOne($0, sql: "SELECT text FROM v2_send_intents WHERE intent_id=? AND stage='cancelled'", arguments: [intent.id.uuidString]) } == intent.text)
        await #expect(throws: V2ResourceJournalError.conflict) { try await f.freeze([imported]) }
        try await f.close()
    }

    @Test func allReviewedParentsCancelButTheirSharedSiblingRemainsForAnotherMessage() async throws {
        let f = try await Fixture(), target = try await f.upload(), sibling = try await f.upload()
        let a = try await f.freeze([target, sibling]), b = try await f.freeze([target]), other = try await f.freeze([sibling])
        let plan = try await f.center.planPreparationCancellation(.upload(target))
        #expect(plan.messageCount == 2)
        try await f.center.cancelPreparation(plan)
        #expect(try await f.store.preparingSendIntents().map(\.id) == [other.id])
        #expect(try await f.store.resourceTransfer(id: target)?.cancellationRequested == true)
        #expect(try await f.store.resourceTransfer(id: sibling)?.cancellationRequested == false)
        #expect(try await f.store.preparingSendIntent(id: a.id) == nil)
        #expect(try await f.store.preparingSendIntent(id: b.id) == nil)
        try await f.close()
    }

    @Test func changedConfirmationScopeAndHandoffRaceRejectWithoutPartialWithdrawal() async throws {
        let f = try await Fixture(), target = try await f.upload()
        let original = try await f.freeze([target]), plan = try await f.center.planPreparationCancellation(.upload(target))
        _ = try await f.freeze([target])
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.cancelPreparation(plan) }
        #expect(try await f.store.preparingSendIntents().count == 2)
        #expect(try await f.store.resourceTransfer(id: target)?.cancellationRequested == false)
        let reviewed = try await f.center.planPreparationCancellation(.upload(target))
        let job = try #require(try await f.store.resourceTransfer(id: target))
        let ready = try V2ResourceUploadSession(locator: .init(home: .room(f.room), sessionID: .init(uuid: UUID())),
            mediaID: job.request.mediaID, generation: 1, state: .completed, resourceState: .ready,
            expiresAt: .distantFuture, bindableUntil: .distantFuture)
        try await f.store.saveResourceSession(ready, for: target)
        _ = try await f.store.handOffSendIntent(original.id)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.cancelPreparation(reviewed) }
        #expect(try await f.store.resourceSendPayloads().count == 1)
        #expect(try await f.store.preparingSendIntents().count == 1)
        try await f.close()
    }

    @Test func failedCancellationTransactionRollsBackParentsAndBothJournals() async throws {
        let f = try await Fixture(), upload = try await f.upload(), imported = try await f.addImport()
        _ = try await f.freeze([upload, imported])
        let plan = try await f.center.planPreparationCancellation(.upload(upload))
        try await f.store.databasePool.write { try $0.execute(sql: "CREATE TRIGGER reject_preparation_cancel BEFORE UPDATE OF cancellation_requested ON v2_resource_import_jobs BEGIN SELECT RAISE(ABORT,'fixture cancellation failure'); END") }
        await #expect(throws: DatabaseError.self) { try await f.center.cancelPreparation(plan) }
        #expect(try await f.store.preparingSendIntents().count == 1)
        #expect(try await f.store.resourceTransfer(id: upload)?.cancellationRequested == false)
        #expect(try await f.store.pendingImportCancellations().isEmpty)
        try await f.store.databasePool.write { try $0.execute(sql: "DROP TRIGGER reject_preparation_cancel") }
        try await f.center.cancelPreparation(plan)
        #expect(try await f.store.preparingSendIntents().isEmpty)
        try await f.close()
    }

    @Test func foreignCenterCannotExecuteAPlanOrAttachAnUnrelatedUploadOwner() async throws {
        let f = try await Fixture(), other = try await Fixture(), upload = try await f.upload()
        _ = try await f.freeze([upload])
        let plan = try await f.center.planPreparationCancellation(.upload(upload))
        await #expect(throws: V2AccountStorageError.scopeMismatch) { try await other.center.cancelPreparation(plan) }
        let engine = f.engine()
        await #expect(throws: V2AccountStorageError.scopeMismatch) { try await other.center.attachUploads(engine) }
        try await f.center.attachUploads(engine)
        try await f.center.attachUploads(engine)
        #expect(try await f.store.preparingSendIntents().count == 1)
        try await f.close(); try await other.close()
    }

    @Test(arguments: [false, true]) func confirmedCancellationOutlivesItsPageAndCloseWaitsForPhysicalUploadDrain(unbound: Bool) async throws {
        let f = try await Fixture(), upload = try await f.upload(), gate = PreparationUploadGate()
        if !unbound { _ = try await f.freeze([upload]) }
        let engine = f.engine(gate)
        try await f.center.attachUploads(engine)
        _ = try await engine.resume(id: upload) // create original session
        let writer = Task { try await engine.resume(id: upload) }
        await gate.entered()
        let cancellation = Task {
            if unbound { try await f.center.cancelUnbound(try await f.center.planUnboundCancellation(.upload(upload))) }
            else { try await f.center.cancelPreparation(try await f.center.planPreparationCancellation(.upload(upload))) }
        }
        await gate.cancelled()
        #expect(try await f.store.preparingSendIntents().isEmpty)
        cancellation.cancel()
        await #expect(throws: CancellationError.self) { try await cancellation.value }
        let finished = Mutex(false)
        let close = Task { await f.center.close(); finished.withLock { $0 = true } }
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            do { _ = try await f.center.transferSnapshots(for: .init()) }
            catch V2ResourceStorageError.closed { break }
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!finished.withLock { $0 })
        await gate.release()
        _ = await writer.result; await close.value
        #expect(finished.withLock { $0 })
        try await f.store.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test(arguments: [false, true]) func failedCancellationCanConfirmOriginalUploadWithoutReactivatingMessage(completionWins: Bool) async throws {
        let f = try await Fixture(), id = try await f.upload()
        let gate = PreparationUploadGate(completionWins: completionWins, failCancellation: true)
        let engine = f.engine(gate)
        try await f.center.attachUploads(engine)
        _ = try await f.freeze([id])
        let created = try await engine.resume(id: id)
        let locator = try #require(created.session?.locator)
        try await f.center.cancelPreparation(try await f.center.planPreparationCancellation(.upload(id)))
        await #expect(throws: V2ResourceJournalError.invalidRecord) { try await engine.resume(id: id) }
        let stalled = try #require(try await f.store.managedResourceTransfers(.init(group: .attention)).entries.first)
        #expect(stalled.phase == .requiresAttention(.cancellationUnconfirmed))
        #expect(stalled.actions == [.retryCancellation])
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.retryTransfer(.upload(id)) }
        await gate.allowCancellation()
        try await f.center.retryCancellation(.upload(id))
        let retry = try #require(try await f.store.resourceTransfer(id: id))
        #expect(retry.cancellationRequested && retry.nextAction == .cancel && retry.request == created.request)
        #expect(retry.session?.locator == locator)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.retryCancellation(.upload(id)) }
        let terminal = try await engine.resume(id: id)
        #expect(terminal.stage == (completionWins ? .ready : .cancelled))
        #expect(await gate.cancelledLocators == [locator, locator])
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(try await f.store.resourceSendPayloads().isEmpty)
        try await f.close()
    }

    @Test(arguments: [false, true]) func cancellationRetryHonorsOwnerCooldownAndColdRecovery(imported: Bool) async throws {
        let f = try await Fixture(), id = try await (imported ? f.addImport() : f.upload())
        _ = try await f.freeze([id])
        let transfer: V2ManagedResourceTransferID = imported ? .serverImport(id) : .upload(id)
        try await f.center.cancelPreparation(try await f.center.planPreparationCancellation(transfer))
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let table = imported ? "v2_resource_import_jobs" : "v2_resource_transfer_jobs"
        try await f.store.databasePool.write { db in
            let columns = imported ? "attempts=5" : "stage='paused',needs_attention=1,action_attempts=5"
            try db.execute(sql: "UPDATE \(table) SET \(columns),server_retry_not_before=?,execution_owner=? WHERE job_id=?", arguments: [future, UUID().uuidString, id.uuidString])
        }
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.retryCancellation(transfer) }
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET execution_owner=NULL WHERE job_id=?", arguments: [id.uuidString]) }
        await f.center.close(); try await f.store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: f.root.appending(path: "V2.sqlite"), installationBinding: f.binding, userID: f.user)
        let center = try await V2ResourceCenter.make(scope: .init(incarnation: UUID(), accountID: f.user,
            directory: f.root.appending(path: "account"), cacheDirectory: f.root.appending(path: "cache")), store: reopened)
        let stalled = try #require(try await reopened.managedResourceTransfers(.init(group: .attention)).entries.first)
        #expect(stalled.phase == .requiresAttention(.cancellationUnconfirmed) && stalled.actions == [.retryCancellation])
        try await center.retryCancellation(transfer)
        if imported {
            let job = try #require(try await reopened.resourceImport(id: id))
            #expect(job.cancellationRequested && job.attempts == 0 && job.retryAt.timeIntervalSince1970 == future)
            #expect(try await reopened.dueResourceImports().isEmpty)
        } else {
            let job = try #require(try await reopened.resourceTransfer(id: id))
            #expect(job.cancellationRequested && !job.needsAttention && job.nextAction == .cancel && job.retryAt.timeIntervalSince1970 == future)
            #expect(try await reopened.dueResourceTransfers().isEmpty)
        }
        #expect(try await reopened.preparingSendIntents().isEmpty)
        #expect(try await reopened.resourceSendPayloads().isEmpty)
        await center.close(); try await reopened.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test(arguments: [false, true]) func exhaustedCancellationBudgetStopsAndOnlyExplicitConfirmationReopensIt(imported: Bool) async throws {
        let f = try await Fixture(), id = try await (imported ? f.addImport() : f.upload()), owner = UUID()
        _ = try await f.freeze([id])
        let transfer: V2ManagedResourceTransferID = imported ? .serverImport(id) : .upload(id)
        try await f.center.cancelPreparation(try await f.center.planPreparationCancellation(transfer))
        for _ in 0..<V2NetworkWorkPolicy.commandRecovery.maximumAttempts {
            if imported {
                let job = try #require(try await f.store.resourceImport(id: id))
                #expect(try await f.store.claimResourceImport(id, owner: owner, now: max(Date(), job.retryAt)))
                try await f.store.releaseResourceImportExecution(id, owner: owner)
            } else {
                let claimed = try #require(try await f.store.claimResourceStep(id: id, owner: owner, now: Date()))
                #expect(claimed.cancellationRequested && claimed.nextAction == .cancel)
                try await f.store.failResourceStep(id: id, owner: owner, code: "transport", retryAt: Date())
            }
        }
        if imported { #expect(try await f.store.claimResourceImport(id, owner: owner, now: .distantFuture) == false) }
        else { #expect(try await f.store.claimResourceStep(id: id, owner: owner, now: Date()) == nil) }
        let stalled = try #require(try await f.store.managedResourceTransfers(.init(group: .attention)).entries.first)
        #expect(stalled.phase == .requiresAttention(.cancellationUnconfirmed) && stalled.actions == [.retryCancellation])
        try await f.center.retryCancellation(transfer)
        if imported {
            #expect(try await f.store.claimResourceImport(id, owner: owner))
            try await f.store.releaseResourceImportExecution(id, owner: owner)
        } else {
            let claimed = try #require(try await f.store.claimResourceStep(id: id, owner: owner, now: Date()))
            #expect(claimed.cancellationRequested && claimed.nextAction == .cancel && claimed.actionAttempts == 1)
            try await f.store.failResourceStep(id: id, owner: owner, code: "transport", retryAt: nil)
        }
        #expect(try await f.store.preparingSendIntents().isEmpty)
        try await f.close()
    }

    @Test(arguments: [false, true]) func retryCannotBypassActiveNativeMapping(cancelRequested: Bool) async throws {
        let f = try await Fixture(), id = try await f.upload(), engine = f.engine(), owner = UUID()
        _ = try await f.freeze([id])
        _ = try await engine.resume(id: id)
        #expect(try await f.store.claimResourceStep(id: id, owner: owner, now: Date()) != nil)
        let mapping = V2BackgroundTaskMapping(id: UUID(), sessionID: UUID(), jobID: id, activationID: UUID(), sourceToken: UUID(),
            taskIdentifier: 7, partNumber: 1, expectedBytes: 4, expiresAt: .distantFuture, originDigest: "controlled")
        try await f.store.installBackgroundMapping(mapping, resourceOwner: owner)
        if cancelRequested { try await f.center.cancelPreparation(try await f.center.planPreparationCancellation(.upload(id))) }
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_transfer_jobs SET stage='paused',needs_attention=1 WHERE job_id=?", arguments: [id.uuidString]) }
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.actions.contains(.retry) == false)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.actions.contains(.retryCancellation) == false)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.retryCancellation(.upload(id)) }
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.retryTransfer(.upload(id)) }
        #expect(try await f.store.completeBackgroundMapping(mapping, result: nil))
        await engine.close(); try await f.close()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "preparation-cancel-\(UUID())")
        let room = RoomID(uuid: UUID())
        let user = UserID(uuid: UUID())
        let binding = V2LocalInstallationBinding(value: UUID())
        let store: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        init() async throws {
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: binding, userID: user)
            center = try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache")), store: store)
        }
        func engine(_ gate: PreparationUploadGate = .init()) -> V2ResourceTransferEngine { .init(store: store, control: gate, executor: gate, resources: center) }
        func upload() async throws -> UUID {
            let asset = try await center.importLocal(data: Data("original".utf8), displayName: .init("message.txt"), contentType: .init("text/plain"), purpose: .messageDraft(room))
            let id = UUID(), request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .messageAttachment(room), contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
            _ = try await store.prepareResourceTransfer(id: id, request: request, localAssetID: asset.id)
            return id
        }
        func addImport() async throws -> UUID {
            let id = UUID(), request = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
                source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
            try await store.prepareResourceImport(id: id, request: request)
            return id
        }
        @discardableResult func freeze(_ ids: [UUID]) async throws -> V2SendIntent {
            let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "frozen original message", attachmentJobIDs: ids)
            try await store.freezeMetadataSendIntent(intent)
            return intent
        }
        func close() async throws { await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}

private actor PreparationUploadGate: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    let completionWins: Bool
    private var failCancellation: Bool
    private(set) var cancelledLocators: [V2ResourceUploadLocator] = []
    init(completionWins: Bool = false, failCancellation: Bool = false) { self.completionWins = completionWins; self.failCancellation = failCancellation }
    func allowCancellation() { failCancellation = false }
    private var sessions: [V2ResourceUploadLocator: V2ResourceUploadSession] = [:]
    private var requests: [V2ResourceUploadLocator: V2ResourceUploadRequest] = [:]
    private let starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let cancellations = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var drain: CheckedContinuation<Void, Never>?
    func entered() async { for await _ in starts.stream { return } }
    func cancelled() async { for await _ in cancellations.stream { return } }
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession {
        guard case .messageAttachment(let room) = request.usage else { throw V2ResourceJournalError.invalidRecord }
        let session = try V2ResourceUploadSession(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())), mediaID: request.mediaID,
            generation: 1, state: .created, resourceState: .pending, expiresAt: .distantFuture)
        sessions[session.locator] = session; requests[session.locator] = request
        return session
    }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? {
        let request = try #require(requests[session.locator])
        return try .init(mode: .httpPut, url: #require(URL(string: "https://bytes.invalid/upload")), expiresAt: .distantFuture,
            expectedByteCount: request.byteCount, checksum: request.checksum)
    }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { drain = $0; starts.continuation.yield(()) }
        } onCancel: { Task { await self.noteCancellation() } }
        try Task.checkCancellation()
    }
    private func noteCancellation() { cancellations.continuation.yield(()) }
    func release() { drain?.resume(); drain = nil }
    func finalize(_ session: V2ResourceUploadSession) -> V2ResourceUploadSession { session }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { try #require(sessions[locator]) }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession {
        cancelledLocators.append(session.locator)
        if failCancellation { throw V2ResourceJournalError.invalidRecord }
        return try .init(locator: session.locator, mediaID: session.mediaID, generation: 1,
            state: completionWins ? .completed : .cancelled, resourceState: completionWins ? .ready : .pending,
            expiresAt: .distantFuture, bindableUntil: completionWins ? .distantFuture : nil)
    }
}
