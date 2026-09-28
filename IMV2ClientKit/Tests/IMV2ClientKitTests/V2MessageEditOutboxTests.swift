import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Message mutation authoritative outcomes", .serialized)
struct V2MessageMutationTerminalTests {
    @Test("only a bound terminal receipt completes a mutation",arguments:["committed","conflicted","rejected","closed"])
    func terminal(kind:String) async throws {
        let f=try V2MutationTestFixture(kind:kind);defer { f.remove() }
        let payload=try f.payload(),id=try await f.service.enqueue(payload)
        try await f.service.execute(f.claim(id))
        let work=try #require(try await f.store.operationWork(id:id))
        let expected:V2OperationExecutionState = kind=="committed" ? .committed : kind=="conflicted" ? .conflicted : kind=="closed" ? .closed : .rejected
        #expect(work.execution==expected && work.scheduling == .finished)
        #expect(try await f.store.messageMutationPayload(workID:id)==payload)
        #expect(try await f.store.messages(in:f.room).isEmpty)
        try await f.store.close()
    }
    @Test("an unrelated receipt cannot turn an unknown mutation into success")
    func unrelatedReceipt() async throws {
        let f=try V2MutationTestFixture(kind:"mismatch");defer { f.remove() }
        let id=try await f.service.enqueue(f.payload())
        try await f.service.execute(f.claim(id))
        let work=try #require(try await f.store.operationWork(id:id))
        #expect(work.execution == .awaitingConfirmation && work.scheduling == .needsAttention)
        try await f.store.close()
    }
}
struct V2MutationTestFixture {
    let url:URL,binding=V2LocalInstallationBinding(value:UUID()),account=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),message=MessageID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote:V2MutationFixtureClient,service:V2MessageMutationOperationService
    init(kind:String) throws {
        url=FileManager.default.temporaryDirectory.appending(path:"mutation-terminal-"+UUID().uuidString).appending(path:"state.sqlite")
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
        remote=V2MutationFixtureClient(kind:kind)
        service=V2MessageMutationOperationService(accountID:account,store:store,client:remote)
    }
    func payload(withdraw:Bool=false) throws -> V2MessageMutationPayload {
        let deadline=UInt64(Date().addingTimeInterval(600).timeIntervalSince1970*1_000)
        if withdraw { return .withdraw(try .init(command:.init(roomID:room,actorUserID:account,operationID:.init(uuid:UUID()),messageID:message,expectedMessageRevision:1),firstSubmissionDeadlineMilliseconds:deadline)) }
        return .edit(try .init(command:.init(roomID:room,actorUserID:account,operationID:.init(uuid:UUID()),messageID:message,expectedMessageRevision:1,text:"saved draft",maximumUTF8Bytes:65_536),firstSubmissionDeadlineMilliseconds:deadline))
    }
    func claim(_ id:UUID) async throws -> V2OperationWorkClaim {
        let work=try #require(try await store.operationWork(id:id))
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        return claim
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
actor V2MutationFixtureClient:V2MessageMutationOperationClient {
    let kind:String
    let serverFloor=Date().addingTimeInterval(3_600)
    var submissions=0
    init(kind:String) { self.kind=kind }
    func submit(_ payload:V2MessageMutationPayload) async throws -> V2MessageMutationRecoveryResult {
        submissions += 1
        if kind=="cancel" { throw CancellationError() }
        if kind=="cooldown" { throw V2HTTPFailure(kind:.httpStatus,service:"accountAPI",statusCode:429,retryAfter:serverFloor) }
        let identity=try payload.identity,fingerprint=try payload.fingerprint
        guard case .message(_,let message)=identity.scope else { throw V2OperationWorkError.invalidRecord }
        let outcome:V2MessageMutationTerminalOutcome
        switch kind {
        case "closed":outcome = .closed
        case "conflicted":outcome = .rejected(.revisionConflict(current:2))
        case "rejected":outcome = .rejected(.permissionDenied)
        default:outcome = .committed(try .init(messageID:message,messageRevision:2,roomSequence:2,eventID:.init(uuid:UUID())))
        }
        let bound = kind=="mismatch" ? try V2OperationFingerprint(kind:identity.kind,fields:[.init("wrong",.text("wrong"))]) : fingerprint
        return .receipt(try .init(identity:identity,fingerprint:bound,outcome:outcome,resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000)))
    }
    func recover(_ request:V2MessageMutationRecoveryRequest) async throws -> V2MessageMutationRecoveryResult { .unresolved }
}
