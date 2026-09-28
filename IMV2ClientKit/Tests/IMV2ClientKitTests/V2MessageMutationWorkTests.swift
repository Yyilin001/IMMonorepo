import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Message mutation public work", .serialized)
struct V2MessageMutationWorkTests {
    @Test("lost response retains frozen identity across database reopening")
    func lostResponse() async throws {
        let f=try MutationWorkFixture(); defer { f.remove() }
        let payload=try f.edit(message:f.message,text:"first"), id=try await f.store.enqueueMessageMutation(payload)
        let service=V2MessageMutationOperationService(accountID:f.account,store:f.store,client:f.remote)
        try await service.execute(f.claim(id))
        let first=try #require(try await f.store.operationWork(id:id))
        #expect(first.execution == .awaitingConfirmation && first.nextAction == .reconcile)
        try await f.store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let restored=try #require(try await reopened.operationWork(id:id))
        guard case .claimed(let claim)=try await reopened.claimOperationWork(id:id,ownerID:UUID(),action:restored.nextAction,now:restored.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        try await V2MessageMutationOperationService(accountID:f.account,store:reopened,client:f.remote).execute(claim)
        #expect(try await reopened.operationWork(id:id)?.execution == .committed)
        #expect(try await reopened.messageMutationPayload(workID:id) == payload)
        #expect(await f.remote.submissions == 1)
        #expect(await f.remote.recoveries == 1)
        try await reopened.close()
    }
    @Test("edit and withdrawal share a message key while unrelated messages remain eligible")
    func ordering() async throws {
        let f=try MutationWorkFixture(); defer { f.remove() }
        let edit=try await f.store.enqueueMessageMutation(f.edit(message:f.message,text:"first"))
        let withdraw=try V2WithdrawMessageCommand(roomID:f.room,actorUserID:f.account,operationID:.init(UUID().uuidString),messageID:f.message,expectedMessageRevision:2)
        let second=try await f.store.enqueueMessageMutation(.withdraw(.init(command:withdraw,firstSubmissionDeadlineMilliseconds:f.deadline)))
        let independent=try await f.store.enqueueMessageMutation(f.edit(message:MessageID(uuid:UUID()),text:"another"))
        let due=try await f.store.dueOperationWork(now:Date(),kinds:[.editMessage,.withdrawMessage])
        #expect(Set(due.map(\.id)) == [edit,independent])
        let firstKey=try await f.store.operationWork(id:edit)?.orderingKey
        let secondKey=try await f.store.operationWork(id:second)?.orderingKey
        #expect(firstKey == secondKey)
        try await f.store.close()
    }
    @Test("identity reuse cannot change text or renew the admission deadline")
    func identityConflict() async throws {
        let f=try MutationWorkFixture(); defer { f.remove() }
        let payload=try f.edit(message:f.message,text:"first"), id=try await f.store.enqueueMessageMutation(payload)
        #expect(try await f.store.enqueueMessageMutation(payload) == id)
        guard case .edit(let original)=payload else { return }
        let changed=try V2EditMessageCommand(roomID:f.room,actorUserID:f.account,operationID:original.operationID,messageID:f.message,expectedMessageRevision:1,text:"different",maximumUTF8Bytes:65_536)
        await #expect(throws:V2OperationWorkError.identityConflict) {
            try await f.store.enqueueMessageMutation(.edit(.init(command:changed,firstSubmissionDeadlineMilliseconds:f.deadline)))
        }
        #expect(try await f.store.messageMutationPayload(workID:id) == payload)
        try await f.store.close()
    }
    @Test("another save at the unknown baseline reuses the frozen command or requires confirmation")
    func unknownBaselineCannotCreateReplacement() async throws {
        let f=try MutationWorkFixture();defer { f.remove() }
        let original=try f.edit(message:f.message,text:"saved draft")
        let id=try await f.store.enqueueMessageMutation(original)
        let service=V2MessageMutationOperationService(accountID:f.account,store:f.store,client:f.remote)
        try await service.execute(f.claim(id))
        #expect(try await f.store.enqueueMessageMutation(f.edit(message:f.message,text:"saved draft")) == id)
        await #expect(throws:V2MessageMutationAdmissionError.confirmationRequired) {
            try await f.store.enqueueMessageMutation(f.edit(message:f.message,text:"changed draft"))
        }
        #expect(try await f.store.messageMutationPayload(workID:id) == original)
        try await f.store.close()
    }

}
struct MutationWorkFixture {
    let url:URL, binding=V2LocalInstallationBinding(value:UUID()), account=UserID(uuid:UUID()), room=RoomID(uuid:UUID()),message=MessageID(uuid:UUID())
    let deadline=UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970*1_000)
    let store:GRDBV2LocalSyncStore, remote=MutationWorkRemote()
    init() throws {
        url=FileManager.default.temporaryDirectory.appending(path:"mutation-work-"+UUID().uuidString).appending(path:"state.sqlite")
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
    }
    func edit(message:MessageID,text:String) throws -> V2MessageMutationPayload {
        .edit(try .init(command:.init(roomID:room,actorUserID:account,operationID:.init(UUID().uuidString),messageID:message,expectedMessageRevision:1,text:text,maximumUTF8Bytes:65_536),firstSubmissionDeadlineMilliseconds:deadline))
    }
    func claim(_ id:UUID) async throws -> V2OperationWorkClaim {
        let work=try #require(try await store.operationWork(id:id))
        guard case .claimed(let value)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        return value
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
actor MutationWorkRemote:V2MessageMutationOperationClient {
    var submissions=0,recoveries=0
    var receipt:V2MessageMutationReceipt?
    func submit(_ payload:V2MessageMutationPayload) async throws -> V2MessageMutationRecoveryResult {
        submissions += 1
        guard case .message(_,let message)=try payload.identity.scope else { throw V2OperationWorkError.invalidRecord }
        receipt=try .init(identity:payload.identity,fingerprint:payload.fingerprint,
            outcome:.committed(.init(messageID:message,messageRevision:2,roomSequence:7,eventID:.init(uuid:UUID()))),
            resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000))
        throw URLError(.networkConnectionLost)
    }
    func recover(_ request:V2MessageMutationRecoveryRequest) async throws -> V2MessageMutationRecoveryResult {
        recoveries += 1
        guard let receipt else { return .unresolved }
        return .receipt(receipt)
    }
}
