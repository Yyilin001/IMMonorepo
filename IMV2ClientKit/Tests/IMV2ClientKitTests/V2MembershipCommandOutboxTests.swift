import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Membership original operation recovery",.serialized)
struct V2MembershipOperationTests {
    @Test("network retry survives restart and reuses the original membership operation ID")
    func retrySurvivesRestart() async throws {
        let f=try MembershipWorkFixture();defer { f.remove() }
        let confirmation=try f.service.confirmationWindow(roomID:f.room,action:.add,expectedMembershipRevision:7)
        let id=try await f.service.enqueue(targetUserID:f.target,confirmation:confirmation)
        #expect(try await f.service.prepareNextIntent())
        let original=try #require(try await f.store.membershipPending(id:id).command)
        let work=try #require(try await f.store.membershipPending(id:id).work)
        try await f.service.execute(f.claim(work.id))
        #expect(try await f.store.operationWork(id:work.id)?.execution == .awaitingConfirmation)
        try await f.store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let service=V2MembershipOperationService(accountID:f.account,activationID:UUID(),store:reopened,client:f.remote)
        let pending=try #require(try await reopened.operationWork(id:work.id))
        guard case .claimed(let claim)=try await reopened.claimOperationWork(id:work.id,ownerID:UUID(),action:.reconcile,now:pending.nextActionAt) else { Issue.record("missing original reconciliation");return }
        try await service.execute(claim)
        #expect(try await reopened.operationWork(id:work.id)?.execution == .committed)
        #expect(try await reopened.membershipCommand(workID:work.id)==original)
        #expect(await f.remote.received==[confirmation.operationID,confirmation.operationID])
        #expect(await f.remote.admissions==1)
        try await reopened.close()
    }
    @Test("original revision conflict receipt is terminal and is not retried")
    func revisionConflictIsNotRetried() async throws {
        let f=try MembershipWorkFixture(conflict:true);defer { f.remove() }
        let confirmation=try f.service.confirmationWindow(roomID:f.room,action:.remove,expectedMembershipRevision:7)
        let id=try await f.service.enqueue(targetUserID:f.target,confirmation:confirmation)
        #expect(try await f.service.prepareNextIntent())
        let work=try #require(try await f.store.membershipPending(id:id).work)
        try await f.service.execute(f.claim(work.id))
        #expect(try await f.store.operationWork(id:work.id)?.execution == .conflicted)
        #expect(try await f.store.dueOperationWork(now:.distantFuture,kinds:[.membership]).isEmpty)
        #expect(await f.remote.received==[confirmation.operationID])
        try await f.store.close()
    }
    @Test("restart keeps an existing frozen membership identity and cannot authorize a replacement")
    func duplicatePendingMembershipChangeReusesTheOriginalOperationAfterRestart() async throws {
        let f=try MembershipWorkFixture();defer { f.remove() }
        let confirmation=try f.service.confirmationWindow(roomID:f.room,action:.add,expectedMembershipRevision:7)
        let id=try await f.service.enqueue(targetUserID:f.target,confirmation:confirmation)
        #expect(try await f.service.prepareNextIntent())
        let original=try await f.store.membershipPending(id:id)
        try await f.store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let service=V2MembershipOperationService(accountID:f.account,activationID:UUID(),store:reopened,client:f.remote)
        let next=try service.confirmationWindow(roomID:f.room,action:.add,expectedMembershipRevision:7)
        await #expect(throws:V2MembershipAdmissionError.confirmationRequired) { _ = try await service.enqueue(targetUserID:f.target,confirmation:next) }
        #expect(try await reopened.membershipPending(id:id).intent.operationID==confirmation.operationID)
        #expect(try await reopened.membershipPending(id:id).command==original.command)
        #expect(await f.remote.admissions==1)
        try await reopened.close()
    }
}
struct MembershipWorkFixture {
    let url=FileManager.default.temporaryDirectory.appending(path:"membership-work-"+UUID().uuidString).appending(path:"state.sqlite")
    let binding=V2LocalInstallationBinding(value:UUID()),account=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),target=UserID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote:MembershipWorkRemote,service:V2MembershipOperationService
    init(conflict:Bool=false) throws {
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
        remote=MembershipWorkRemote(conflict:conflict)
        service = .init(accountID:account,activationID:UUID(),store:store,client:remote)
    }
    func claim(_ id:UUID) async throws -> V2OperationWorkClaim {
        let work=try #require(try await store.operationWork(id:id))
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition };return claim
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
actor MembershipWorkRemote:V2MembershipOperationClient {
    let conflict:Bool
    var admissions=0,received:[MembershipOperationID]=[]
    var saved:V2MembershipReceipt?
    init(conflict:Bool) { self.conflict=conflict }
    func admit(_ intent:V2MembershipIntent) async throws -> V2MembershipAdmissionResult {
        admissions += 1
        return .admitted(try .init(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,action:intent.action,membershipRevision:intent.expectedMembershipRevision,targetJoinedRevision:intent.action == .add ? nil:0,issuedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000),expiresAtMilliseconds:intent.confirmedUntilMilliseconds))
    }
    func submit(_ command:V2MembershipOperationCommand) async throws -> V2MembershipRecoveryResult {
        received.append(command.intent.operationID)
        let outcome:V2MembershipTerminalOutcome = conflict ? .rejected(.membershipChanged(currentRevision:8)) : .changed(try .init(membershipRevision:8,roomSequence:1,eventID:.init(uuid:UUID())))
        saved=try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:outcome,resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000))
        if conflict { return .receipt(saved!) }
        throw URLError(.networkConnectionLost)
    }
    func recover(_ command:V2MembershipOperationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2MembershipRecoveryResult {
        received.append(command.intent.operationID)
        guard let saved else { return .unresolved };return .receipt(saved)
    }
}
