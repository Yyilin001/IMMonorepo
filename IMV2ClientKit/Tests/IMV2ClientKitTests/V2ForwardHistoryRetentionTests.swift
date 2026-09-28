import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Forward history retention")
struct V2ForwardHistoryRetentionTests {
    @Test func completedProofAndDomainPayloadArePrunedAtomicallyAfterSevenDays() async throws {
        let f = try DurableForwardFixture()
        defer { f.remove() }
        let store = try f.open()
        let id = try await store.enqueueForwardPlanOperation(f.command, now: f.now)
        guard case .claimed = try await store.claimOperationWork(id: id, ownerID: UUID(), action: .submit, now: f.now) else {
            Issue.record("missing forward submission claim"); return
        }
        try await store.completeForwardPlan(f.resolved(f.progress(resolvedCount: Int(f.command.childCount))), workID: id, now: f.now)
        #expect(try await store.pruneCompletedOperationHistory(now: f.now.addingTimeInterval(6 * 86_400)) == 0)
        try await store.close()
        let reopened = try f.open()
        #expect(try await reopened.pruneCompletedOperationHistory(now: f.now.addingTimeInterval(8 * 86_400)) == 1)
        #expect(try await reopened.operationWork(id: id) == nil)
        let db = try DatabasePool(path: f.url.path)
        let remaining = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_forward_plan_operations") }
        #expect(remaining == 0)
        #expect(try await reopened.pruneCompletedOperationHistory(now: f.now.addingTimeInterval(9 * 86_400)) == 0)
        try await reopened.close()
    }

    @Test func unknownAndPartiallyCompletedPlansAreNeverAgedOut() async throws {
        let f = try DurableForwardFixture()
        defer { f.remove() }
        let store = try f.open()
        let id = try await store.enqueueForwardPlanOperation(f.command, now: f.now)
        guard case .claimed(let first) = try await store.claimOperationWork(id: id, ownerID: UUID(), action: .submit, now: f.now) else {
            Issue.record("missing forward claim"); return
        }
        let future = f.now.addingTimeInterval(30 * 86_400)
        #expect(try await store.pruneCompletedOperationHistory(now: future) == 0)
        let partial = try f.progress(resolvedCount: 1)
        try await store.recordForwardPlanProgress(partial, claim: first, until: f.now, scheduling: .needsAttention)
        #expect(try await store.pruneCompletedOperationHistory(now: future) == 0)
        #expect(try await store.forwardPlanSnapshot(workID: id).progress == partial)
        #expect(try await store.operationWork(id: id)?.scheduling == .needsAttention)
        try await store.close()
    }

    @Test func incomingDependencyPinsCompletedForwardHistory() async throws {
        let f = try DurableForwardFixture()
        defer { f.remove() }
        let store = try f.open()
        let id = try await store.enqueueForwardPlanOperation(f.command, now: f.now)
        guard case .claimed = try await store.claimOperationWork(id: id, ownerID: UUID(), action: .submit, now: f.now) else {
            Issue.record("missing forward submission claim"); return
        }
        try await store.completeForwardPlan(f.resolved(f.progress(resolvedCount: Int(f.command.childCount))), workID: id, now: f.now)
        let other = try V2ForwardPlanOperationCommand(actorUserID: f.user,
            command: .init(operationID: .init(uuid: UUID()), sources: f.command.command.sources,
                targetRoomIDs: [.init(uuid: UUID())]), firstSubmissionDeadlineMilliseconds: f.command.firstSubmissionDeadlineMilliseconds)
        let child = try await store.enqueueForwardPlanOperation(other, now: f.now)
        let db = try DatabasePool(path: f.url.path)
        try await db.write { try $0.execute(sql: "INSERT INTO v2_operation_dependencies(child_work_id,parent_work_id) VALUES(?,?)",
            arguments: [child.uuidString, id.uuidString]) }
        #expect(try await store.pruneCompletedOperationHistory(now: f.now.addingTimeInterval(8 * 86_400)) == 0)
        #expect(try await store.operationWork(id: id)?.execution == .committed)
        try await db.write { try $0.execute(sql: "DELETE FROM v2_operation_dependencies WHERE child_work_id=?", arguments: [child.uuidString]) }
        #expect(try await store.pruneCompletedOperationHistory(now: f.now.addingTimeInterval(8 * 86_400)) == 1)
        #expect(try await store.operationWork(id: child) != nil)
        try await store.close()
    }
}
