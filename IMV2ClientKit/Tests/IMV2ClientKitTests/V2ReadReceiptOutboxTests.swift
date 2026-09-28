import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Read receipt public work", .serialized)
struct V2ReadReceiptWorkTests {
    @Test("offline readings coalesce into one highest unfrozen intent")
    func coalescesHighest() async throws {
        let f=try ReceiptFixture()
        defer { f.remove() }
        for value in [1,8,4,12,12] { _ = try await f.service.enqueue(roomID:f.room,readThrough:UInt64(value)) }
        #expect(await f.remote.calls == 0)
        #expect(try await f.store.roomReadWatermark(roomID:f.room) == 12)
        #expect(try await f.store.databasePool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM v2_read_receipt_intents") } == 1)
        #expect(try await f.store.prepareNextReadReceiptIntent(accountID:f.account))
        let work=try await f.head(), command=try await f.store.readReceiptCommand(workID:work.id)
        #expect(command.readThroughRoomSequence == 12 && work.admissionDeadline == nil)
        #expect(try await f.store.prepareNextReadReceiptIntent(accountID:f.account) == false)
        try await f.store.close()
    }
    @Test("one frozen head and one max successor preserve the original identity")
    func frozenHeadAndSuccessor() async throws {
        let f=try ReceiptFixture(); defer { f.remove() }
        _ = try await f.service.enqueue(roomID:f.room,readThrough:2)
        _ = try await f.store.prepareNextReadReceiptIntent(accountID:f.account)
        let original=try await f.head()
        for value in [3,5,9] { _ = try await f.service.enqueue(roomID:f.room,readThrough:UInt64(value)) }
        #expect(try await f.store.prepareNextReadReceiptIntent(accountID:f.account) == false)
        #expect(try await f.store.readReceiptCommand(workID:original.id).readThroughRoomSequence == 2)
        try await f.service.execute(f.claim(original))
        #expect(try await f.store.prepareNextReadReceiptIntent(accountID:f.account))
        let next=try await f.head()
        #expect(next.id != original.id)
        #expect(try await f.store.readReceiptCommand(workID:next.id).readThroughRoomSequence == 9)
        try await f.store.close()
    }
    @Test("lost response survives process recreation and recovers without a new submission", arguments:[false,true])
    func lostResponseRecovers(currentProof:Bool) async throws {
        let f=try ReceiptFixture(); defer { f.remove() }
        await f.remote.loseResponse(useCurrentProof:currentProof)
        _ = try await f.service.enqueue(roomID:f.room,readThrough:7)
        _ = try await f.store.prepareNextReadReceiptIntent(accountID:f.account)
        let first=try await f.head(), frozen=try await f.store.readReceiptCommand(workID:first.id)
        try await f.service.execute(f.claim(first))
        #expect(try await f.store.operationWork(id:first.id)?.execution == .awaitingConfirmation)
        try await f.store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let service=V2ReadReceiptOperationService(accountID:f.account,store:reopened,client:f.remote)
        let due=try #require(try await reopened.operationWork(id:first.id))
        guard case .claimed(let claim)=try await reopened.claimOperationWork(id:due.id,ownerID:UUID(),action:due.nextAction,now:due.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        try await service.execute(claim)
        #expect(try await reopened.operationWork(id:first.id)?.execution == .committed)
        #expect(try await reopened.readReceiptCommand(workID:first.id) == frozen)
        #expect(try await reopened.roomReadWatermark(roomID:f.room) == 7)
        let calls = await f.remote.calls, recoveries = await f.remote.recoveries
        #expect(calls == 1 && recoveries == 1)
        let receipt=try await reopened.databasePool.read { try Data.fetchOne($0,sql:"SELECT terminal_receipt FROM v2_operation_work WHERE work_id=?",arguments:[first.id.uuidString]) }
        #expect(String(decoding:try #require(receipt),as:UTF8.self).contains(currentProof ? "watermarkProof" : "originalReceipt"))
        try await reopened.close()
    }
    @Test("current permission unavailability preserves unknown instead of inventing a rejection")
    func unavailableKeepsUnknown() async throws {
        let f=try ReceiptFixture(); defer { f.remove() }
        await f.remote.loseResponse(useCurrentProof:false)
        _ = try await f.service.enqueue(roomID:f.room,readThrough:3)
        _ = try await f.store.prepareNextReadReceiptIntent(accountID:f.account)
        let first=try await f.head()
        try await f.service.execute(f.claim(first))
        await f.remote.setUnavailable()
        let pending=try #require(try await f.store.operationWork(id:first.id))
        try await f.service.execute(f.claim(pending))
        let work=try #require(try await f.store.operationWork(id:first.id))
        #expect(work.execution == .awaitingConfirmation && work.scheduling == .needsAttention)
        #expect(work.identity == first.identity && work.fingerprint == first.fingerprint)
        _ = try await f.service.enqueue(roomID:f.room,readThrough:5)
        #expect(try await f.store.operationWork(id:first.id)?.scheduling == .needsAttention)
        try await f.service.resumeConfirmation(roomID:f.room)
        let retry = try #require(try await f.store.operationWork(id:first.id))
        #expect(retry.scheduling == .ready && retry.nextAction == .reconcile && retry.reconciliationRoundAttempts == 0)
        #expect(try await f.store.prepareNextReadReceiptIntent(accountID:f.account) == false)
        try await f.store.close()
    }
    @Test("draft capacity shares profile and preference reservations and transfers at the exact limit")
    func sharedCapacity() async throws {
        let f=try ReceiptFixture(); defer { f.remove() }
        let limits=V2OperationWorkLimits(maximumActiveCount:1,maximumPayloadBytes:4096)
        _ = try await f.store.enqueueReadReceiptIntent(accountID:f.account,roomID:f.room,readThrough:1,limits:limits)
        await #expect(throws:V2OperationWorkError.capacityExceeded) {
            try await f.store.databasePool.write { try GRDBV2LocalSyncStore.requireOperationCapacity(adding:1,limits:limits,db:$0) }
        }
        #expect(try await f.store.prepareNextReadReceiptIntent(accountID:f.account,limits:limits))
        #expect(try await f.store.databasePool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM v2_read_receipt_intents") } == 0)
        #expect(try await f.store.dueOperationWork(now:.now,kinds:[.readReceipt]).count == 1)
        try await f.store.close()
    }
    @Test("cancellation retains the claim identity and moves to confirmation")
    func cancelledStepRetainsIntent() async throws {
        let f=try ReceiptFixture(); defer { f.remove() }
        _ = try await f.service.enqueue(roomID:f.room,readThrough:1)
        _ = try await f.store.prepareNextReadReceiptIntent(accountID:f.account)
        let work=try await f.head(), claim=try await f.claim(work)
        await f.remote.cancelSubmission()
        await #expect(throws:CancellationError.self) { try await f.service.execute(claim) }
        let pending=try #require(try await f.store.operationWork(id:work.id))
        #expect(pending.identity == work.identity && pending.submissionStarted && pending.nextAction == .reconcile)
        try await f.store.close()
    }
    @Test("archived original query survives ordinary capacity and transfers only after space is released")
    func controlRecoveryAtOrdinaryCapacity() async throws {
        let f=try ReceiptFixture(); defer { f.remove() }
        let original=try await f.archiveUnknown(room:f.room)
        // A real ordinary work reservation occupies the complete byte budget.
        let blocker=try await f.store.databasePool.write { db in
            let id=UUID(), command=try V2RecordReadReceiptCommand(roomID:.init(uuid:UUID()),actorUserID:f.account,operationID:.init(uuid:id),readThroughRoomSequence:1)
            return try GRDBV2LocalSyncStore.insertOperationWork(.init(id:id,intentID:id,identity:command.identity,fingerprint:command.fingerprint,orderingKey:"capacity-blocker",payloadBytes:32*1024*1024,admissionDeadline:nil),now:Date(),db:db).id
        }
        try await f.store.restoreReadReceiptArchive(id:original.id,accountID:f.account)
        let restored=try #require(try await f.store.operationWork(id:original.id))
        #expect(restored.identity == original.identity && restored.fingerprint == original.fingerprint)
        guard case .unavailable = try await f.store.claimOperationWork(id:restored.id,ownerID:UUID(),action:.submit,now:.distantFuture) else { Issue.record("control reservation granted submit"); return }
        await f.remote.setUnresolved()
        try await f.service.execute(f.claim(restored))
        let paused=try #require(try await f.store.operationWork(id:original.id))
        #expect(paused.scheduling == .needsAttention && paused.nextAction == .reconcile)
        #expect(paused.lastErrorCode == "READ_RECEIPT_CONTROL_CAPACITY_REQUIRED")
        #expect(await f.remote.calls == 1)
        try await f.store.databasePool.write { try $0.execute(sql:"DELETE FROM v2_operation_work WHERE work_id=?",arguments:[blocker.uuidString]) }
        try await f.service.resumeConfirmation(roomID:f.room)
        try await f.service.execute(f.claim(try #require(try await f.store.operationWork(id:original.id))))
        let ordinary=try #require(try await f.store.operationWork(id:original.id))
        #expect(ordinary.id == original.id && ordinary.nextAction == .submit)
        #expect(try await f.store.readReceiptUsesControlAdmission(workID:original.id) == false)
        #expect(await f.remote.calls == 1)
        try await f.store.close()
    }
    @Test("control byte capacity and failed archive transfer leave original metadata intact")
    func controlCapacityAndArchiveAtomicity() async throws {
        let f=try ReceiptFixture(); defer { f.remove() }
        var restored:[UUID]=[]
        for _ in 0..<16 {
            let original=try await f.archiveUnknown(room:.init(uuid:UUID()))
            do { try await f.store.restoreReadReceiptArchive(id:original.id,accountID:f.account); restored.append(original.id) }
            catch V2OperationWorkError.capacityExceeded {
                #expect(restored.count > 0 && restored.count < 64)
                #expect(try await f.store.operationWork(id:original.id) == nil)
                #expect(try await f.store.databasePool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM v2_read_receipt_archives WHERE work_id=?",arguments:[original.id.uuidString]) } == 1)
                break
            }
        }
        let id=try #require(restored.first)
        try await f.store.databasePool.write { db in
            try db.execute(sql:"UPDATE v2_operation_work SET scheduling_state='needsAttention',last_error_code='READ_RECEIPT_CONTROL_CAPACITY_REQUIRED' WHERE work_id=?",arguments:[id.uuidString])
            try db.execute(sql:"CREATE TRIGGER reject_archive BEFORE INSERT ON v2_read_receipt_archives BEGIN SELECT RAISE(ABORT,'injected archive failure'); END")
        }
        do { try await f.store.archiveReadReceiptWork(id:id,accountID:f.account); Issue.record("injected archive failure was ignored") } catch {}
        #expect(try await f.store.readReceiptUsesControlAdmission(workID:id))
        try await f.store.databasePool.write { try $0.execute(sql:"DROP TRIGGER reject_archive") }
        try await f.store.archiveReadReceiptWork(id:id,accountID:f.account)
        #expect(try await f.store.operationWork(id:id) == nil)
        try await f.store.restoreReadReceiptArchive(id:id,accountID:f.account)
        #expect(try await f.store.readReceiptUsesControlAdmission(workID:id))
        try await f.store.close()
    }
    @Test("different rooms have independent claims while the same room stays serialized")
    func independentRooms() async throws {
        let f=try ReceiptFixture(); defer { f.remove() }
        _ = try await f.service.enqueue(roomID:f.room,readThrough:1)
        _ = try await f.service.enqueue(roomID:.init(uuid:UUID()),readThrough:2)
        while try await f.store.prepareNextReadReceiptIntent(accountID:f.account) {}
        let due=try await f.store.dueOperationWork(now:.now,kinds:[.readReceipt])
        #expect(due.count == 2)
        let first=try await f.claim(due[0]), second=try await f.claim(due[1])
        #expect(first.work.orderingKey != second.work.orderingKey)
        try await f.service.execute(first); try await f.service.execute(second)
        #expect(await f.remote.calls == 2)
        try await f.store.close()
    }
}
private struct ReceiptFixture {
    let url:URL, binding=V2LocalInstallationBinding(value:UUID()), account=UserID(uuid:UUID()), room=RoomID(uuid:UUID())
    let store:GRDBV2LocalSyncStore, remote=ReceiptWorkRemote(), service:V2ReadReceiptOperationService
    init() throws {
        url=FileManager.default.temporaryDirectory.appending(path:"read-work-"+UUID().uuidString).appending(path:"state.sqlite")
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
        service = .init(accountID:account,store:store,client:remote)
    }
    func archiveUnknown(room:RoomID) async throws -> V2OperationWork {
        await remote.loseResponse(useCurrentProof:false)
        _ = try await service.enqueue(roomID:room,readThrough:1)
        _ = try await store.prepareNextReadReceiptIntent(accountID:account)
        let work=try #require(try await store.dueOperationWork(now:.distantFuture,kinds:[.readReceipt]).first { $0.identity.scope == .room(room) })
        try await service.execute(claim(work))
        await remote.setUnavailable()
        try await service.execute(claim(try #require(try await store.operationWork(id:work.id))))
        try await store.archiveReadReceiptWork(id:work.id,accountID:account)
        return work
    }
    func head() async throws -> V2OperationWork { try #require(try await store.dueOperationWork(now:.distantFuture,kinds:[.readReceipt]).first) }
    func claim(_ work:V2OperationWork) async throws -> V2OperationWorkClaim {
        guard case .claimed(let value)=try await store.claimOperationWork(id:work.id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        return value
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
private actor ReceiptWorkRemote:V2ReadReceiptOperationClient {
    var calls=0, recoveries=0
    private var lost=false, proof=false, unavailable=false, cancelled=false
    private var original:V2ReadReceiptOperationReceipt?
    func loseResponse(useCurrentProof:Bool) { lost=true;proof=useCurrentProof }
    func setUnavailable() { unavailable=true }
    func setUnresolved() { unavailable=false; original=nil }
    func cancelSubmission() { cancelled=true }
    func submit(_ command:V2RecordReadReceiptCommand) async throws -> V2ReadReceiptOperationReceipt {
        calls += 1
        if cancelled { throw CancellationError() }
        let result=try V2ReadReceiptOperationReceipt(command:command,receipt:.init(roomID:command.roomID,userID:command.actorUserID,readThroughRoomSequence:command.readThroughRoomSequence,recordedAt:Date()))
        original=result
        if lost { throw URLError(.networkConnectionLost) }
        return result
    }
    func recover(_ request:V2ReadReceiptRecoveryRequest) async throws -> V2ReadReceiptRecoveryResult {
        recoveries += 1
        if unavailable { return .currentUnavailable(.permissionDenied) }
        guard let original else { return .unresolved }
        return proof ? .watermarkProof(try .init(command:request.command,watermark:original.receipt)) : .originalReceipt(original)
    }
}
