import Foundation
import CryptoKit
import GRDB
import Synchronization
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Persistent resource steps")
struct V2ResourceStepTests {
    @Test(arguments: [false, true])
    func immutableUploadConflictRequiresAuthoritativeFinalize(multipart: Bool) async throws {
        let f = try Fixture(multipart: multipart); defer { f.remove() }
        let control = try StepControl(request: f.request, multipart: multipart)
        let engine = V2ResourceTransferEngine(store: f.store, control: control,
            executor: SignatureDeniedExecutor(status: 409), directory: f.root)
        _ = try await engine.prepare(id: f.id, request: f.request)
        _ = try await engine.resume(id: f.id)
        if multipart {
            await #expect(throws: V2HTTPFailure.self) { _ = try await engine.resume(id: f.id) }
            #expect(try await f.store.resourceTransfer(id: f.id)?.needsAttention == true)
        } else {
            let uncertain = try await engine.resume(id: f.id)
            #expect(uncertain.nextAction == .finalize && uncertain.stage != .ready)
            #expect(await control.calls == ["create", "target"])
            let verified = try await engine.resume(id: f.id)
            #expect(verified.stage == .processing)
            #expect(await control.calls == ["create", "target", "finalize"])
        }
        await engine.close(); try await f.store.close()
    }

    @Test(arguments: [0, 401, 403, -403]) func expiredUploadTargetReconcilesOriginalSessionWithinPersistedBudget(status: Int) async throws {
        let f = try Fixture(); defer { f.remove() }
        let clock = Mutex(Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
        let control = try StepControl(request: f.request, expiredTarget: status == 0, denyTarget: status == -403)
        let executor: any V2ResourcePlanExecuting
        if status == 0 { executor = V2URLSessionResourcePlanExecutor() }
        else { executor = SignatureDeniedExecutor(status: abs(status)) }
        let engine = V2ResourceTransferEngine(store: f.store, control: control,
            executor: executor, directory: f.root, now: { clock.withLock { $0 } }, randomUnit: { 0 })
        _ = try await engine.prepare(id: f.id, request: f.request)
        _ = try await engine.resume(id: f.id)
        if status == 0 {
            await #expect(throws: V2ClientMediaTransferError.targetExpired) { _ = try await engine.resume(id: f.id) }
        } else {
            await #expect(throws: V2HTTPFailure.self) { _ = try await engine.resume(id: f.id) }
        }
        let failed = try #require(await f.store.resourceTransfer(id: f.id))
        if status == -403 {
            #expect(failed.needsAttention && failed.nextAction == .status)
            #expect(try await f.store.dueResourceTransfers(now: clock.withLock { $0 }).isEmpty)
            #expect(await control.calls == ["create", "target"])
            await engine.close(); try await f.store.close()
            return
        }
        #expect(!failed.needsAttention && failed.nextAction == .status)
        #expect(failed.session != nil && failed.actionAttempts == 1)
        clock.withLock { $0 = failed.retryAt.addingTimeInterval(0.001) }
        let reconciled = try await engine.resume(id: f.id)
        #expect(reconciled.nextAction == .upload && !reconciled.needsAttention)
        #expect(reconciled.session?.locator == failed.session?.locator)
        #expect(reconciled.roundDeadline == failed.roundDeadline && reconciled.actionAttempts == 2)
        #expect(await control.calls == ["create", "target", "status"])
        await engine.close(); try await f.store.close()
    }

    @Test func stepsReturnBeforePollAndProcessingCooldownSurvivesRestart() async throws {
        let f = try Fixture(); defer { f.remove() }
        let control = try StepControl(request:f.request)
        let executor = StepExecutor()
        let engine = V2ResourceTransferEngine(store:f.store,control:control,executor:executor,directory:f.root)
        _ = try await engine.prepare(id:f.id,request:f.request)
        let created = try await engine.resume(id:f.id)
        #expect(created.nextAction == .upload)
        #expect(await control.calls == ["create"])
        let uploaded = try await engine.resume(id:f.id)
        #expect(uploaded.nextAction == .finalize)
        #expect(await executor.calls == 1)
        let processing = try await engine.resume(id:f.id)
        #expect(processing.stage == .processing)
        #expect(processing.nextAction == .status)
        #expect(processing.retryAt > Date())
        #expect(processing.pollAttempts == 1)
        #expect(await control.calls == ["create","target","finalize"])
        await engine.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL:f.database,installationBinding:f.binding,userID:f.account)
        let next = try #require(await reopened.resourceTransfer(id:f.id))
        #expect(next.retryAt == processing.retryAt)
        #expect(next.totalAttempts == 3)
        #expect(try await reopened.dueResourceTransfers().isEmpty)
        try await reopened.close()
        try await f.store.close()
    }

    @Test func failedAttemptsAndDeadlineSurviveNewOwnerAndRequireExplicitRetry() async throws {
        let f = try Fixture(); defer { f.remove() }
        let control = FailingControl()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var engine = V2ResourceTransferEngine(store:f.store,control:control,executor:StepExecutor(),directory:f.root,now:{now},randomUnit:{0})
        _ = try await engine.prepare(id:f.id,request:f.request)
        for attempt in 1...5 {
            let activeEngine = engine
            await #expect(throws:V2HTTPFailure.self) { _ = try await activeEngine.resume(id:f.id) }
            let job = try #require(await f.store.resourceTransfer(id:f.id))
            #expect(job.actionAttempts == attempt)
            #expect(job.totalAttempts == attempt)
            if attempt == 2 {
                let deadline = job.roundDeadline
                await engine.close()
                engine = V2ResourceTransferEngine(store:f.store,control:control,executor:StepExecutor(),directory:f.root,now:{now},randomUnit:{0})
                #expect(try await f.store.resourceTransfer(id:f.id)?.roundDeadline == deadline)
            }
        }
        let exhausted = try #require(await f.store.resourceTransfer(id:f.id))
        #expect(exhausted.needsAttention)
        #expect(try await f.store.dueResourceTransfers(now:now).isEmpty)
        _ = try await engine.resume(id:f.id)
        #expect(await control.calls == 5)
        try await f.store.retryResourceTransfer(id:f.id)
        let retried = try #require(await f.store.resourceTransfer(id:f.id))
        #expect(!retried.needsAttention)
        #expect(retried.actionAttempts == 0)
        #expect(retried.totalAttempts == 5)
        await engine.close(); try await f.store.close()
    }

    @Test func interruptedClaimReconcilesAndCancelledObserverDoesNotRevokeJob() async throws {
        let f = try Fixture(); defer { f.remove() }
        let control = try StepControl(request:f.request)
        let initial = V2ResourceTransferEngine(store:f.store,control:control,executor:StepExecutor(),directory:f.root)
        _ = try await initial.prepare(id:f.id,request:f.request)
        _ = try await initial.resume(id:f.id)
        let oldOwner = UUID()
        let claim = try #require(await f.store.claimResourceStep(id:f.id,owner:oldOwner,now:Date()))
        #expect(claim.nextAction == .upload)
        let interrupted = try #require(await f.store.resourceTransfer(id:f.id))
        #expect(interrupted.nextAction == .status)
        let observer = Task {
            for try await _ in f.store.resourceTransferUpdates(id:f.id) { try Task.checkCancellation() }
        }
        observer.cancel(); _ = await observer.result
        #expect(try await f.store.resourceTransfer(id:f.id)?.cancellationRequested == false)
        await initial.close()
        let restarted = V2ResourceTransferEngine(store:f.store,control:control,executor:StepExecutor(),directory:f.root)
        let recovered = try await restarted.resume(id:f.id)
        #expect(recovered.nextAction == .upload)
        #expect(await control.calls == ["create","status"])
        #expect(recovered.totalAttempts == 3)
        await restarted.close(); try await f.store.close()
    }

    @Test func multipartAdvancesOnlyAfterAuthoritativeStatusAndDoesNotPersistLease() async throws {
        let f = try Fixture(multipart: true); defer { f.remove() }
        let control = try StepControl(request: f.request, multipart: true)
        let executor = StepExecutor()
        let engine = V2ResourceTransferEngine(store: f.store, control: control, executor: executor, directory: f.root)
        _ = try await engine.prepare(id: f.id, request: f.request)
        for _ in 0..<5 { _ = try await engine.resume(id: f.id) }
        let job = try #require(await f.store.resourceTransfer(id: f.id))
        #expect(job.stage == .processing)
        #expect(job.totalAttempts == 5)
        #expect(await executor.calls == 1)
        #expect(await control.calls == ["create", "target", "status", "target", "finalize"])
        let databaseBytes = try Data(contentsOf: f.database)
        #expect(!String(decoding: databaseBytes, as: UTF8.self).contains("provider.invalid"))
        await engine.close(); try await f.store.close()
    }

    @Test func boundedPartFileContainsOnlyRequestedSourceRange() async throws {
        let f = try Fixture(); defer { f.remove() }
        let source = f.root.appending(path: f.id.uuidString)
        let part = try await V2ResourcePartFile.create(source: source, lowerBound: 1, byteCount: 2)
        defer { try? FileManager.default.removeItem(at: part) }
        #expect(try Data(contentsOf: part) == Data("bc".utf8))
        await #expect(throws: V2ClientMediaTransferError.byteCountMismatch) {
            _ = try await V2ResourcePartFile.create(source: source, lowerBound: 2, byteCount: 2)
        }
        let leftover = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".part-") }
        #expect(leftover.map(\.lastPathComponent) == [part.lastPathComponent])
        try await f.store.close()
    }

    @Test func resourcePreparationAndSendFreezeCommitOrRollbackTogether() async throws {
        let f = try Fixture(); defer { f.remove() }
        let room = RoomID(uuid: UUID()), second = UUID()
        let request = try V2ResourceUploadRequest(operationID: f.request.operationID, mediaID: f.request.mediaID, usage: .messageAttachment(room), contentType: f.request.contentType, byteCount: f.request.byteCount, checksum: f.request.checksum)
        let first = try V2ResourcePreparedUpload(id: f.id, request: request, localFileToken: f.id.uuidString)
        let collision = try V2ResourcePreparedUpload(id: second, request: request, localFileToken: second.uuidString)
        let invalid = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "atomic", attachmentJobIDs: [f.id,second])
        do { try await f.store.freezeSendIntent(invalid, resources: [first,collision]); Issue.record("identity collision must roll back") } catch { }
        #expect(try await f.store.resourceTransfer(id: f.id) == nil)
        #expect(try await f.store.preparingSendIntents().isEmpty)
        let valid = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "atomic", attachmentJobIDs: [f.id])
        let engine = V2ResourceTransferEngine(store: f.store, control: FailingControl(), executor: StepExecutor(), directory: f.root)
        try await engine.prepareSend(valid, resources: [first])
        #expect(try await f.store.resourceTransfer(id: f.id)?.request == request)
        #expect(try await f.store.preparingSendIntents().map(\.id) == [valid.id])
        let plan = try await f.store.databasePool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT job_id FROM v2_resource_transfer_jobs WHERE stage NOT IN ('ready','cancelled','rejected','expired') AND needs_attention=0 AND next_action<>'awaitingBackground' AND execution_owner IS NULL AND retry_at<=? ORDER BY retry_at,created_at LIMIT 16", arguments: [Date().timeIntervalSince1970]).map { (row: Row) -> String in row["detail"] }
        }
        #expect(plan.contains { $0.contains("v2_resource_transfer_due") })
        await engine.close(); try await f.store.close()
    }

    @Test func accountActivityCancellationDrainsItsIndependentSharedStep() async throws {
        let f = try Fixture(); defer { f.remove() }
        let control = ResourceStepGate()
        let engine = V2ResourceTransferEngine(store: f.store, control: control, executor: StepExecutor(), directory: f.root)
        _ = try await engine.prepare(id: f.id, request: f.request)
        let returned = Mutex(false)
        let activity = Task {
            do { try await engine.runRecovery() } catch { }
            returned.withLock { $0 = true }
        }
        await control.entered()
        activity.cancel()
        await control.cancelled()
        #expect(!returned.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: f.root.appending(path: f.id.uuidString).path))
        await control.release()
        await activity.value
        #expect(returned.withLock { $0 })
        let job = try #require(await f.store.resourceTransfer(id: f.id))
        #expect(job.stage == .prepared && !job.cancellationRequested)
        #expect(job.totalAttempts == 1)
        await engine.close(); try await f.store.close()
    }

    private struct Fixture: Sendable {
        let root:URL, database:URL, id:UUID, binding:V2LocalInstallationBinding
        let account:UserID
        let store:GRDBV2LocalSyncStore, request:V2ResourceUploadRequest
        init(multipart: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appending(path:"resource-steps-\(UUID())")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            database = root.appending(path:"db.sqlite"); id = UUID(); binding = .init(value:UUID())
            account = .init(uuid:UUID())
            store = try .init(databaseURL:database,installationBinding:binding,userID:account)
            let bytes = Data("abc".utf8)
            try bytes.write(to:root.appending(path:id.uuidString))
            request = try .init(operationID:.init(id.uuidString),mediaID:.init(id.uuidString),usage:.userAvatar,contentType:"text/plain",byteCount:3,checksum:.init(value:SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()),clientModes:multipart ? [.httpPartPut] : [.httpPut])
        }
        func remove() { try? FileManager.default.removeItem(at:root) }
    }
}
private actor StepExecutor:V2ResourcePlanExecuting {
    var calls = 0
    func upload(fileURL:URL,plan:V2ResourceTransferPlan) { calls += 1 }
}
private actor FailingControl:V2ResourceUploadControlling {
    var calls = 0
    func create(_ request:V2ResourceUploadRequest) throws -> V2ResourceUploadSession { calls += 1; throw V2HTTPFailure(kind:.transport,service:"test") }
    func status(_ locator:V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw V2ResourceJournalError.conflict }
    func target(_ session:V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw V2ResourceJournalError.conflict }
    func finalize(_ session:V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ResourceJournalError.conflict }
    func cancel(_ session:V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ResourceJournalError.conflict }
}
private actor StepControl:V2ResourceUploadControlling {
    var calls:[String] = []
    let created:V2ResourceUploadSession, processing:V2ResourceUploadSession
    let multipart: Bool
    let expiredTarget: Bool
    let denyTarget: Bool
    var issued = false
    init(request:V2ResourceUploadRequest, multipart: Bool = false, expiredTarget: Bool = false, denyTarget: Bool = false) throws {
        self.multipart = multipart
        self.expiredTarget = expiredTarget
        self.denyTarget = denyTarget
        let locator = V2ResourceUploadLocator(home:.account(try UserID(UUID().uuidString)),sessionID:try .init(UUID().uuidString))
        created = try .init(locator:locator,mediaID:request.mediaID,generation:1,state:.created,resourceState:.pending,expiresAt:.now.addingTimeInterval(3600))
        processing = try .init(locator:locator,mediaID:request.mediaID,generation:1,state:.finalizing,resourceState:.scanning,expiresAt:.now.addingTimeInterval(3600))
    }
    func create(_ request:V2ResourceUploadRequest) -> V2ResourceUploadSession { calls.append("create"); return created }
    func status(_ locator:V2ResourceUploadLocator) throws -> V2ResourceUploadSession {
        calls.append("status")
        if multipart && issued {
            return try .init(locator:created.locator,mediaID:created.mediaID,generation:1,state:.uploading,resourceState:.pending,expiresAt:created.expiresAt,confirmedParts:[.init(number:1,byteCount:3,receipt:"stable-1")])
        }
        return created
    }
    func target(_ session:V2ResourceUploadSession) throws -> V2ResourceTransferPlan? {
        calls.append("target")
        if denyTarget { throw V2HTTPFailure(kind: .httpStatus, service: "resourceUpload", statusCode: 403, certainty: .responseReceived) }
        if multipart && !session.confirmedParts.isEmpty { return nil }
        issued = true
        return try V2ResourceTransferPlan(mode:multipart ? .httpPartPut : .httpPut,url:URL(string:"https://provider.invalid/upload?signature=secret")!,expiresAt:.now.addingTimeInterval(expiredTarget ? -1 : 60),expectedByteCount:3,byteRange:multipart ? .init(lowerBound:0,upperBound:2) : nil,partNumber:multipart ? 1 : nil)
    }
    func finalize(_ session:V2ResourceUploadSession) -> V2ResourceUploadSession { calls.append("finalize"); if multipart { #expect(session.confirmedParts.count == 1) }; return processing }
    func cancel(_ session:V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ResourceJournalError.conflict }
}

private actor ResourceStepGate: V2ResourceUploadControlling {
    private let starts = AsyncStream<Void>.makeStream()
    private let cancellations = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func create(_ request: V2ResourceUploadRequest) async throws -> V2ResourceUploadSession {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in self.continuation = continuation; starts.continuation.yield(()) }
        } onCancel: { cancellations.continuation.yield(()) }
        return try .init(locator: .init(home: .account(.init(uuid: UUID())), sessionID: .init(uuid: UUID())), mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready, expiresAt: .now.addingTimeInterval(600), bindableUntil: .now.addingTimeInterval(600))
    }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func cancelled() async { var iterator = cancellations.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw CancellationError() }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw CancellationError() }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
}

private struct SignatureDeniedExecutor: V2ResourcePlanExecuting {
    let status: Int
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws {
        throw V2HTTPFailure(kind: .httpStatus, service: "mediaProvider", statusCode: status, certainty: .responseReceived)
    }
}
