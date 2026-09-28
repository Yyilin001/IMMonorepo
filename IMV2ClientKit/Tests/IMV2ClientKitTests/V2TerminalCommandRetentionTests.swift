import Foundation
import GRDB
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 terminal command retention")
struct V2TerminalCommandRetentionTests {
    @Test("completed-work retention never reject an attempted public message")
    func publicUnknownIsNotExpired() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let intent=try f.intent("unknown must survive")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let work=try await f.head()
        try await V2MessageSendOperationService(accountID:f.account,store:f.store,client:f.remote).execute(f.claim(work))
        let before=try await f.store.operationWork(id:work.id)
        let afterWindow=Date().addingTimeInterval(31 * 86_400)
        _ = try await f.store.pruneCompletedOperationHistory(now:afterWindow)
        #expect(try await f.store.operationWork(id:work.id)==before)
        #expect(try await f.store.messageSendCommand(workID:work.id).command.clientMessageID==intent.clientMessageID)
        try await f.store.close()
    }
    @Test("invalid cleanup clocks do not mutate public message identity",arguments:[Double.nan,.infinity,-.infinity])
    func invalidCleanupClock(value:Double) async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let intent=try f.intent("retain")
        try await f.store.freezeSendIntent(intent)
        try await f.store.handOffSendIntent(intent.id)
        let work=try await f.head()
        await #expect(throws:V2ClientCommandError.commandConflict) { try await f.store.pruneCompletedOperationHistory(now:Date(timeIntervalSince1970:value)) }
        #expect(try await f.store.operationWork(id:work.id)==work)
        try await f.store.close()
    }

    @Test("completed-work retention never expires cancelling or finalizing public group creation",arguments:[false,true])
    func pruningPreservesGroupCreationStateMachine(finalizing:Bool) async throws {
        let account=UserID(uuid:UUID()),url=temporaryTerminalRetentionDatabaseURL()
        let store=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:terminalRetentionInstallationBinding,userID:account)
        let intent=try V2GroupCreationIntent(identity:.init(accountID:account,scope:.account(account),operation:.groupRoom(.init(uuid:UUID()))),title:"Retain",capacityClass:.standard,initialMemberCount:0,audienceDigest:V2GroupCreationAudience.digest([]),firstSubmissionDeadlineMilliseconds:700_000)
        let id=try await store.enqueueGroupCreationOperation(intent,members:[],now:Date(timeIntervalSince1970:100))
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:Date(timeIntervalSince1970:100)) else { throw V2OperationWorkError.invalidTransition }
        let progress=try V2GroupCreationProgress(intent:intent,roomID:.init(uuid:UUID()),phase:finalizing ? .finalizing:.staging,acceptedMemberCount:0,acceptedPrefixDigest:V2GroupCreationAudience.digest([]))
        try await store.saveGroupCreationProgress(progress,claim:claim,nextAction:.reconcile,now:Date(timeIntervalSince1970:101))
        if !finalizing { try await store.requestGroupCreationCancellation(id:id,accountID:account) }
        let before=try await store.groupCreationPending(id:id)
        let future=Date(timeIntervalSince1970:100+31 * 86_400)
        _ = try await store.pruneCompletedOperationHistory(now:future)
        #expect(try await store.groupCreationPending(id:id)==before)
        try await store.close()
    }

    @Test("completed forward history is pruned after seven days")
    func pruningRemovesTerminalForwardPlanGraph() async throws {
        let f=try DurableForwardFixture(sourceCount:1,targetCount:1);defer { f.remove() }
        let store=try f.open()
        let id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        _ = try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now)
        let result=try f.resolved(f.progress(resolvedCount:1))
        try await store.completeForwardPlan(result,workID:id,now:f.now)
        #expect(try await store.pruneCompletedOperationHistory(now:f.now.addingTimeInterval(86_400*8)) == 1)
        #expect(try await store.operationWork(id:id) == nil)
        try await store.close()
    }



}

private func temporaryTerminalRetentionDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "im-v2-terminal-retention-\(UUID().uuidString).sqlite")
}

private let terminalRetentionInstallationBinding = V2LocalInstallationBinding(
    value: UUID(uuidString: "00000000-0000-0000-0000-000000000997")!
)
