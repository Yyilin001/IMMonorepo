import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Message outcome recovery without replacing the original intent", .serialized)
struct V2MessageOperationRecoveryTests {
    @Test("only a bound permanent closure permits an explicitly new send")
    func unresolvedThenClosed() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let intent=try f.intent("never duplicate"),created=Date().addingTimeInterval(-90_000)
        try await f.store.freezeSendIntent(intent,now:created)
        try await f.store.handOffSendIntent(intent.id,now:created)
        let remote=ClosureMessageClient(),service=V2MessageSendOperationService(accountID:f.account,store:f.store,client:remote)
        let work=try await f.head()
        guard case .claimed(let submitted)=try await f.store.claimOperationWork(id:work.id,ownerID:UUID(),action:.submit,now:created.addingTimeInterval(1)) else { throw V2OperationWorkError.invalidTransition }
        try await service.execute(submitted)
        await #expect(throws:V2ResourceJournalError.conflict) { try await f.store.replaceProvenUnsentSendIntent(intent.id) }
        try await service.resumeConfirmation(intentID:intent.id)
        let original=try await f.store.messageSendCommand(workID:work.id)
        try await service.execute(f.claim(try #require(await f.store.operationWork(id:work.id))))
        #expect(try await f.store.operationWork(id:work.id)?.execution == .awaitingConfirmation)
        try await service.execute(f.claim(try #require(await f.store.operationWork(id:work.id))))
        #expect(try await f.store.operationWork(id:work.id)?.execution == .closed)
        #expect(await remote.actions == [.closeIfAbsent,.closeIfAbsent])
        let replacement=try await f.store.replaceProvenUnsentSendIntent(intent.id)
        #expect(try await f.store.replaceProvenUnsentSendIntent(intent.id)==replacement)
        let draft=try #require(try await f.store.preparingSendIntents().first)
        #expect(draft.id==replacement && draft.clientMessageID != original.command.clientMessageID)
        #expect(draft.text==original.command.text)
        try await f.store.close()
    }
    @Test("unknown send blocks its room key without blocking a different room")
    func unknownRoomHead() async throws {
        let f=try SendWorkFixture();defer { f.remove() }
        let first=try f.intent("unknown"),second=try f.intent("successor")
        for intent in [first,second] { try await f.store.freezeSendIntent(intent);try await f.store.handOffSendIntent(intent.id) }
        let work=try await f.head()
        try await V2MessageSendOperationService(accountID:f.account,store:f.store,client:f.remote).execute(f.claim(work))
        let independent=try V2SendIntent(id:UUID(),roomID:.init(uuid:UUID()),clientMessageID:.init(uuid:UUID()),text:"other room",attachmentJobIDs:[])
        try await f.store.freezeSendIntent(independent);try await f.store.handOffSendIntent(independent.id)
        let due=try await f.store.dueOperationWork(now:.distantFuture,kinds:[.sendMessage])
        #expect(due.contains { $0.intentID==first.id })
        #expect(!due.contains { $0.intentID==second.id })
        #expect(due.contains { $0.intentID==independent.id })
        try await f.store.close()
    }
}
private actor ClosureMessageClient:V2MessageSendOperationClient {
    var command:V2MessageSendOperationCommand?
    var actions:[V2OperationRecoveryRequest.Action]=[]
    func submit(_ command:V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        self.command=command;throw URLError(.networkConnectionLost)
    }
    func recover(_ request:V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult {
        actions.append(request.action)
        if actions.count==1 { return .unresolved }
        guard let command else { return .unresolved }
        return .receipt(try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:.closed,resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000)))
    }
}
