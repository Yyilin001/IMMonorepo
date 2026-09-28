import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("App durable message sender")
struct V2OperationMessageSenderTests {
    @Test("the page persists a new send independently of older results",arguments:[false,true])
    func olderCommandDoesNotDetermineSendOutcome(rejectOld:Bool) async throws {
        let f=try V2AppMessageWorkFixture(rejectOld:rejectOld);defer { f.remove() }
        let first=try await f.send.enqueueMessage(roomID:f.room,text:"old")
        try await f.store.handOffSendIntent(first)
        let older=try #require(try await f.store.dueOperationWork(now:.now,kinds:[.sendMessage]).first)
        try await f.send.execute(f.claim(older))
        let sender=V2OperationConversationSender(service:f.send)
        #expect(try await sender.send(text:"new",media:[],in:f.room.rawValue) == .queuedForRetry)
        #expect(try await f.store.preparingSendIntents().first?.text=="new")
        #expect(try await f.store.operationWork(id:older.id)?.execution == (rejectOld ? .rejected : .committed))
        #expect(await f.remote.calls==1)
        try await f.store.close()
    }
    @Test("page cancellation before sending cannot write an intent")
    func cancelledSendDoesNotEnqueue() async throws {
        let f=try V2AppMessageWorkFixture();defer { f.remove() }
        let sender=V2OperationConversationSender(service:f.send)
        let task=Task { withUnsafeCurrentTask { $0?.cancel() };return try await sender.send(text:"cancelled",media:[],in:f.room.rawValue) }
        await #expect(throws:CancellationError.self) { try await task.value }
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(await f.remote.calls==0)
        try await f.store.close()
    }
}
struct V2AppMessageWorkFixture {
    let root:URL,binding=V2LocalInstallationBinding(value:UUID()),account=UserID(uuid:UUID()),room=RoomID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote:V2AppMessageWorkClient,send:V2MessageSendOperationService,mutation:V2MessageMutationOperationService
    init(rejectOld:Bool=false) throws {
        root=FileManager.default.temporaryDirectory.appending(path:"app-message-work-"+UUID().uuidString)
        store=try .init(databaseURL:root.appending(path:"state.sqlite"),installationBinding:binding,userID:account)
        remote=V2AppMessageWorkClient(rejectOld:rejectOld)
        send = .init(accountID:account,store:store,client:remote)
        mutation = .init(accountID:account,store:store,client:remote)
    }
    func claim(_ work:V2OperationWork) async throws -> V2OperationWorkClaim {
        guard case .claimed(let claim)=try await store.claimOperationWork(id:work.id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        return claim
    }
    func remove() { try? FileManager.default.removeItem(at:root) }
}
actor V2AppMessageWorkClient:V2MessageSendOperationClient,V2MessageMutationOperationClient {
    let rejectOld:Bool
    var calls=0
    init(rejectOld:Bool) { self.rejectOld=rejectOld }
    func submit(_ command:V2MessageSendOperationCommand) async throws -> V2MessageSendOperationRecoveryResult {
        calls += 1
        let outcome:V2MessageSendOperationTerminalOutcome = rejectOld ? .rejected(.permissionDenied)
            : .accepted(try .init(messageID:.init(uuid:UUID()),roomSequence:1))
        return .receipt(try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:outcome,resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000)))
    }
    func submit(_ payload:V2MessageMutationPayload) async throws -> V2MessageMutationRecoveryResult {
        calls += 1
        guard case .message(_,let message)=try payload.identity.scope else { throw V2OperationWorkError.invalidRecord }
        let outcome:V2MessageMutationTerminalOutcome = rejectOld ? .rejected(.permissionDenied)
            : .committed(try .init(messageID:message,messageRevision:2,roomSequence:1,eventID:.init(uuid:UUID())))
        return .receipt(try .init(identity:payload.identity,fingerprint:payload.fingerprint,outcome:outcome,resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000)))
    }
    func recover(_ request:V2MessageSendOperationRecoveryRequest) async throws -> V2MessageSendOperationRecoveryResult { .unresolved }
    func recover(_ request:V2MessageMutationRecoveryRequest) async throws -> V2MessageMutationRecoveryResult { .unresolved }
}
