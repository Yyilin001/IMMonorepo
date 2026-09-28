import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Forward child UUID restart preserves authority")
struct V2ForwardChunkIdentityRestartTests {
    @Test("completed child proof and pending identities survive reopen")
    func restartPreservesIdentity() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open()
        let id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now) else { throw V2OperationWorkError.invalidTransition }
        let progress=try f.progress(resolvedCount:1)
        try await store.recordForwardPlanProgress(progress,claim:claim,until:f.now.addingTimeInterval(30),scheduling:.backingOff)
        try await store.close()
        let reopened=try f.open()
        let snapshot=try await reopened.forwardPlanSnapshot(workID:id)
        #expect(snapshot.succeeded==20 && snapshot.unresolved==30)
        #expect(snapshot.progress==progress)
        #expect(snapshot.work.execution == .processing && snapshot.work.nextAction == .reconcile)
        #expect(snapshot.progress?.children.map(\.operationID)==progress.children.map(\.operationID))
        #expect(progress.children.allSatisfy{$0.operationID.uuidValue != nil})
        try await reopened.close()
    }
}
