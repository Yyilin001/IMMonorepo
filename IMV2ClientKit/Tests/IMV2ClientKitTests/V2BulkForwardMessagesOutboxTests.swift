import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Public work forward plan execution")
struct V2BulkForwardMessagesOutboxTests {
    @Test("100 by 10 manifests retain 50 stable children and exact terminal totals")
    func boundedManifest() async throws {
        let f=try DurableForwardFixture(sourceCount:100,targetCount:10);defer { f.remove() }
        let store=try f.open()
        let id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        #expect(f.command.childCount==50)
        _ = try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now)
        let result=try f.resolved(f.progress(resolvedCount:50))
        try await store.completeForwardPlan(result,workID:id,now:f.now)
        let snapshot=try await store.forwardPlanSnapshot(workID:id)
        #expect(snapshot.succeeded==1000 && snapshot.unresolved==0 && snapshot.work.execution == .committed)
        #expect(try JSONEncoder().encode(result.receipt).count<65_536)
        try await store.close()
    }
    @Test("local cancellation stops work before any submission claim")
    func localCancellation() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open()
        let id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        try await store.requestForwardPlanCancellation(workID:id,accountID:f.user,now:f.now)
        let snapshot=try await store.forwardPlanSnapshot(workID:id)
        #expect(snapshot.work.execution == .cancelledLocally && !snapshot.work.submissionStarted)
        #expect(snapshot.progress==nil)
        try await store.close()
    }
}
