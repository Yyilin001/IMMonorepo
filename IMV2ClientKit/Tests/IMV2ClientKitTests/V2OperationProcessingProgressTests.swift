import Foundation
import GRDB
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Verified processing progress fences")
struct V2OperationProcessingProgressTests {
    @Test("processing preserves admission certainty, rounds, and durable server floor")
    func certaintyAndFloor() async throws {
        let f=try ProcessingWorkFixture();defer { f.remove() }
        let claim=try await f.claim(action:.submit,now:f.now)
        let proof=try V2VerifiedOperationProgress(identity:f.input.identity,fingerprint:f.input.fingerprint,proof:"bound-progress")
        let floor=f.now.addingTimeInterval(120)
        try await f.store.databasePool.write { db in try GRDBV2LocalSyncStore.recordProcessingProgress(proof,claim:claim,until:floor,db:db) }
        var work=try #require(try await f.store.operationWork(id:f.input.id))
        #expect(work.execution == .processing && work.nextAction == .reconcile)
        #expect(work.attemptCount==claim.work.attemptCount && work.submissionRoundDeadline==claim.work.submissionRoundDeadline)
        try await f.store.retryOperationWorkByUser(id:work.id,now:f.now.addingTimeInterval(1))
        #expect(try await f.store.operationWork(id:work.id)?.nextActionAt==floor)
        let recovering=try await f.claim(action:.reconcile,now:floor)
        try await f.store.deferOperationWork(recovering,until:floor.addingTimeInterval(1),code:"READ_FAILED")
        work=try #require(try await f.store.operationWork(id:work.id))
        #expect(work.execution == .processing)
        let second=try await f.claim(action:.reconcile,now:work.nextActionAt)
        try await f.store.recoverOperationClaims(forNewOwner:UUID(),now:work.nextActionAt)
        #expect(try await f.store.operationWork(id:work.id)?.execution == .processing)
        await #expect(throws:V2OperationWorkError.staleClaim) {
            try await f.store.databasePool.write { db in try GRDBV2LocalSyncStore.recordProcessingProgress(proof,claim:second,until:floor,db:db) }
        }
        try await f.store.close()
    }
    @Test("matched terminal authority prevents stale progress rollback")
    func terminalWins() async throws {
        let f=try ProcessingWorkFixture();defer { f.remove() }
        let claim=try await f.claim(action:.submit,now:f.now)
        try await f.store.completeOperationWork(.init(identity:f.input.identity,fingerprint:f.input.fingerprint,state:.committed,receipt:"bound-terminal"),now:f.now)
        let proof=try V2VerifiedOperationProgress(identity:f.input.identity,fingerprint:f.input.fingerprint,proof:"older-processing")
        let changed=try await f.store.databasePool.write { db in try GRDBV2LocalSyncStore.recordProcessingProgress(proof,claim:claim,until:f.now.addingTimeInterval(10),db:db) }
        #expect(!changed)
        #expect(try await f.store.operationWork(id:f.input.id)?.execution == .committed)
        try await f.store.close()
    }
}
private struct ProcessingWorkFixture:Sendable {
    let url:URL,store:GRDBV2LocalSyncStore,input:V2NewOperationWork
    let now=Date(timeIntervalSince1970:1_800_000_000)
    init() throws {
        url=FileManager.default.temporaryDirectory.appending(path:"processing-work-"+UUID().uuidString).appending(path:"state.sqlite")
        let user=UserID(uuid:UUID())
        store=try .init(databaseURL:url,installationBinding:.init(value:UUID()),userID:user)
        input=try .init(intentID:UUID(),identity:.init(accountID:user,scope:.account(user),operation:.profileUpdate(.init(uuid:UUID()))),fingerprint:.init(kind:.profileUpdate,fields:[.init("name",.text("frozen"))]),orderingKey:"profile",payloadBytes:100,admissionDeadline:nil)
    }
    func claim(action:V2OperationWorkAction,now:Date) async throws -> V2OperationWorkClaim {
        if try await store.operationWork(id:input.id)==nil {
            try await store.databasePool.write { db in _ = try GRDBV2LocalSyncStore.insertOperationWork(input,now:now,db:db) }
        }
        guard case .claimed(let claim)=try await store.claimOperationWork(id:input.id,ownerID:UUID(),action:action,now:now) else { throw V2OperationWorkError.invalidTransition };return claim
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
