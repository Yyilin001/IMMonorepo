import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Forward source intent survives persistence")
struct V2ForwardSourceReferenceTests {
    @Test("mixed rooms and source revisions stay frozen after reopen")
    func durableReferences() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open()
        let id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        try await store.close()
        let reopened=try f.open()
        let saved=try await reopened.forwardPlanSnapshot(workID:id)
        #expect(saved.command.command.sources==f.command.command.sources)
        for index in 0..<f.command.childCount {
            #expect(try saved.command.childCommand(index:index)==f.command.childCommand(index:index))
        }
        let changed=try V2ForwardPlanOperationCommand(actorUserID:f.user,command:.init(operationID:f.command.operationID,sources:f.command.command.sources.dropLast().map{$0},targetRoomIDs:f.command.command.targetRoomIDs),firstSubmissionDeadlineMilliseconds:f.command.firstSubmissionDeadlineMilliseconds)
        await #expect(throws:V2OperationWorkError.identityConflict) { try await reopened.enqueueForwardPlanOperation(changed,now:f.now) }
        try await reopened.close()
    }
}
