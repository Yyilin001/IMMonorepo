import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Bound forward completion proofs")
struct V2ForwardChunkCompletionTests {
    @Test("frozen manifest rejects mismatched identity without creating additional work")
    func initialPlanShape() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open(),id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        let changed=try V2ForwardPlanOperationCommand(actorUserID:f.user,command:.init(operationID:f.command.operationID,sources:Array(f.command.command.sources.reversed()),targetRoomIDs:f.command.command.targetRoomIDs),firstSubmissionDeadlineMilliseconds:f.command.firstSubmissionDeadlineMilliseconds)
        await #expect(throws:V2OperationWorkError.identityConflict) { try await store.enqueueForwardPlanOperation(changed,now:f.now) }
        #expect(try await store.forwardPlanSnapshot(workID:id).command==f.command)
        try await store.close()
    }
    @Test("proof corruption fails before completing public work",arguments:["fingerprint","source","target","revision","empty"])
    func corruptedFrozenRecord(field:String) async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open(),id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        let changed:V2ForwardPlanOperationCommand
        if field=="empty" {
            try await store.databasePool.write { db in try db.execute(sql:"UPDATE v2_forward_plan_operations SET command=?",arguments:[Data("{}".utf8)]) }
        } else {
            let original=f.command.command
            let sources=field=="source" ? Array(original.sources.dropLast()) : field=="revision" ? try original.sources.map { try .init(roomID:$0.roomID,messageID:$0.messageID,revision:.init(42)) } : original.sources
            changed=try .init(actorUserID:f.user,command:.init(operationID:original.operationID,sources:sources,targetRoomIDs:field=="target" ? [.init(uuid:UUID())] : original.targetRoomIDs),firstSubmissionDeadlineMilliseconds:f.command.firstSubmissionDeadlineMilliseconds+(field=="fingerprint" ? 1 : 0))
            try await store.databasePool.write { db in try db.execute(sql:"UPDATE v2_forward_plan_operations SET command=?",arguments:[try JSONEncoder().encode(changed)]) }
        }
        await #expect(throws:(any Error).self) { try await store.forwardPlanSnapshot(workID:id) }
        #expect(try await store.operationWork(id:id)?.execution == .prepared)
        try await store.close()
    }
    @Test("terminal result replays once and rejects a different permanent result")
    func immutableCompletion() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open(),id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        _ = try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now)
        let result=try f.resolved(f.progress(resolvedCount:4))
        try await store.completeForwardPlan(result,workID:id,now:f.now)
        try await store.completeForwardPlan(result,workID:id,now:f.now)
        await #expect(throws:(any Error).self) { try await store.completeForwardPlan(f.resolved(f.progress(resolvedCount:4)),workID:id,now:f.now) }
        #expect(try await store.forwardPlanSnapshot(workID:id).succeeded==50)
        try await store.close()
    }
    @Test("a processing child cannot regress or become a cancellation-before-start")
    func progressCannotRegress() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open(),id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now) else { throw V2OperationWorkError.invalidTransition }
        let admitted=try V2ForwardPlanProgress(identity:f.command.identity,fingerprint:f.command.fingerprint,executionState:.processing,children:(0..<f.command.childCount).map { index in try .init(index:index,operationID:f.command.childCommand(index:index).operationID,state:index==0 ? .processing : .pending) })
        try await store.recordForwardPlanProgress(admitted,claim:claim,until:f.now,scheduling:.backingOff)
        guard case .claimed(let next)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.reconcile,now:f.now) else { throw V2OperationWorkError.invalidTransition }
        await #expect(throws:V2ForwardPlanValidationError.invalidProgress) { try await store.recordForwardPlanProgress(f.progress(resolvedCount:0),claim:next,until:f.now,scheduling:.backingOff) }
        await #expect(throws:V2ForwardPlanValidationError.invalidReceipt) { try await store.completeForwardPlan(f.resolved(f.progress(resolvedCount:0,cancelRemaining:true)),workID:id,now:f.now) }
        #expect(try await store.forwardPlanSnapshot(workID:id).progress==admitted)
        try await store.close()
    }
    @Test("public completion and full domain result roll back together on storage failure")
    func transactionRollback() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open(),id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        _ = try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now)
        try await store.databasePool.write { db in try db.execute(sql:"CREATE TRIGGER reject_forward_progress BEFORE UPDATE OF progress ON v2_forward_plan_operations BEGIN SELECT RAISE(ABORT,'test'); END") }
        await #expect(throws:DatabaseError.self) { try await store.completeForwardPlan(f.resolved(f.progress(resolvedCount:4)),workID:id,now:f.now) }
        #expect(try await store.operationWork(id:id)?.execution == .submitting)
        #expect(try await store.forwardPlanSnapshot(workID:id).progress==nil)
        try await store.close()
    }
}
