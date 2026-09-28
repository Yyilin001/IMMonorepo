import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 durable message moderation")
struct V2MessageModerationWorkTests {
    @Test("lost submit response recovers original proof after restart without another submission")
    func lostResponseRecoversOriginal() async throws {
        let fixture=try ModerationFixture();defer { fixture.remove() }
        let store=try fixture.open(),remote=ModerationRemote()
        let service=V2MessageModerationOperationService(accountID:fixture.account,activationID:UUID(),store:store,client:remote)
        let id=try await service.enqueue(baseline:fixture.baseline,reason:.init("policy_violation"))
        try await service.execute(fixture.claim(store,id:id)) // Admission only.
        let original=try await store.messageModerationPending(id:id)
        #expect(original.admission != nil)
        try await service.execute(fixture.claim(store,id:id)) // Server commits; response is lost.
        #expect(try await store.messageModerationPending(id:id).work.execution == .awaitingConfirmation)
        try await store.close()
        let restarted=try fixture.open()
        let recovery=V2MessageModerationOperationService(accountID:fixture.account,activationID:UUID(),store:restarted,client:remote)
        try await recovery.execute(fixture.claim(restarted,id:id))
        let result=try await restarted.messageModerationPending(id:id)
        #expect(result.work.execution == .committed)
        #expect(result.intent==original.intent)
        #expect(result.admission==original.admission)
        #expect(await remote.submissions()==1)
        try await restarted.close()
    }

    @Test("restart before admission closes the original confirmation without acquiring new authority")
    func unfrozenRestartDoesNotReadmit() async throws {
        let fixture=try ModerationFixture();defer { fixture.remove() }
        let store=try fixture.open(),remote=ModerationRemote()
        let original=V2MessageModerationOperationService(accountID:fixture.account,activationID:UUID(),store:store,client:remote)
        let id=try await original.enqueue(baseline:fixture.baseline,reason:.init("policy_violation"))
        try await store.close()
        let restarted=try fixture.open()
        let service=V2MessageModerationOperationService(accountID:fixture.account,activationID:UUID(),store:restarted,client:remote)
        try await service.execute(fixture.claim(restarted,id:id))
        #expect(try await restarted.messageModerationPending(id:id).work.execution == .closed)
        #expect(await remote.admissions()==0)
        #expect(await remote.submissions()==0)
        try await restarted.close()
    }

    @Test("a second confirmation cannot replace an unknown operation for the same message")
    func unknownCannotBeReplaced() async throws {
        let fixture=try ModerationFixture();defer { fixture.remove() }
        let store=try fixture.open(),remote=ModerationRemote()
        let service=V2MessageModerationOperationService(accountID:fixture.account,activationID:UUID(),store:store,client:remote)
        let id=try await service.enqueue(baseline:fixture.baseline,reason:.init("policy_violation"))
        let before=try await store.messageModerationPending(id:id)
        await #expect(throws:V2OperationWorkError.invalidTransition) {
            try await service.enqueue(baseline:fixture.baseline,reason:.init("another_reason"))
        }
        #expect(try await store.messageModerationPending(id:id)==before)
        try await store.close()
    }
}

private struct ModerationFixture {
    let account=UserID(uuid:UUID())
    let url=FileManager.default.temporaryDirectory.appending(path:"moderation-\(UUID().uuidString).sqlite")
    let binding=V2LocalInstallationBinding(value:UUID())
    let baseline:V2MessageModerationBaseline
    init() throws { baseline=try .init(roomID:.init(uuid:UUID()),messageID:.init(uuid:UUID()),messageRevision:1,membershipRevision:5,isRedacted:false) }
    func open() throws -> GRDBV2LocalSyncStore { try .init(databaseURL:url,installationBinding:binding,userID:account) }
    func remove() { for suffix in ["","-wal","-shm"] { try? FileManager.default.removeItem(atPath:url.path+suffix) } }
    func claim(_ store:GRDBV2LocalSyncStore,id:UUID) async throws -> V2OperationWorkClaim {
        let work=try #require(await store.operationWork(id:id))
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:binding.value,action:work.nextAction,now:max(Date(),work.nextActionAt)) else { throw V2OperationWorkError.invalidTransition }
        return claim
    }
}
private actor ModerationRemote:V2MessageModerationOperationClient {
    private var admissionCount=0,submitCount=0
    private var committed:V2MessageModerationReceipt?
    func baseline(roomID:RoomID,messageID:MessageID) throws -> V2MessageModerationBaseline { throw V2OperationWorkError.invalidTransition }
    func admit(_ intent:V2MessageModerationIntent) throws -> V2MessageModerationAdmissionResult {
        admissionCount+=1
        return .admitted(try .init(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,actorJoinedRevision:1,issuedAtMilliseconds:intent.confirmedUntilMilliseconds-120_000,expiresAtMilliseconds:intent.confirmedUntilMilliseconds))
    }
    func submit(_ command:V2MessageModerationCommand) throws -> V2MessageModerationRecoveryResult {
        submitCount+=1
        committed=try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:.redacted(messageID:command.intent.messageID,messageRevision:command.intent.expectedMessageRevision+1,roomSequence:9,eventID:.init(uuid:UUID())),resolvedAtMilliseconds:command.admission.issuedAtMilliseconds)
        throw URLError(.networkConnectionLost)
    }
    func recover(_ intent:V2MessageModerationIntent,action:V2OperationRecoveryRequest.Action) throws -> V2MessageModerationRecoveryResult {
        if let committed { return .receipt(committed) }
        guard action == .closeIfAbsent else { return .unresolved }
        return .receipt(try .init(identity:intent.identity,fingerprint:intent.fingerprint,outcome:.closed,resolvedAtMilliseconds:intent.confirmedUntilMilliseconds))
    }
    func admissions()->Int { admissionCount }
    func submissions()->Int { submitCount }
}
