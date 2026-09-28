import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxGroupCorrelationTests {
    @Test("cancelled group operations do not create durable commands")
    func cancelledGroupOperation() async throws {
        let f=try MembershipAppFixture(rejectOld:false);defer { f.remove() }
        let adapter=V2OperationGroupMembershipChanger(service:f.service)
        let confirmation=try adapter.membershipConfirmation(roomID:f.room.rawValue,action:.add,expectedMembershipRevision:0)
        let task=Task { withUnsafeCurrentTask { $0?.cancel() };_ = try await adapter.changeMembership(targetUserID:f.target.rawValue,confirmation:confirmation) }
        await #expect(throws:CancellationError.self) { try await task.value }
        var iterator=(await f.service.updates(roomID:f.room)).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty==true)
        try await f.store.close()
    }
    @Test("feedback remains correlated with its durable command",arguments:[false,true])
    func groupCorrelation(rejectOld:Bool) async throws {
        let f=try MembershipAppFixture(rejectOld:rejectOld);defer { f.remove() }
        let oldWindow=try f.service.confirmationWindow(roomID:f.room,action:.add,expectedMembershipRevision:0)
        let older=try await f.service.enqueue(targetUserID:f.remote.oldTarget,confirmation:oldWindow)
        #expect(try await f.service.prepareNextIntent())
        let work=try #require(try await f.store.membershipPending(id:older).work)
        guard case .claimed(let claim)=try await f.store.claimOperationWork(id:work.id,ownerID:UUID(),action:.submit,now:work.nextActionAt) else { Issue.record("missing old claim");return }
        try await f.service.execute(claim)
        #expect(try await f.store.operationWork(id:work.id)?.execution == (rejectOld ? .rejected:.committed))
        let adapter=V2OperationGroupMembershipChanger(service:f.service)
        let next=try adapter.membershipConfirmation(roomID:f.room.rawValue,action:.add,expectedMembershipRevision:rejectOld ? 0:1)
        #expect(try await adapter.changeMembership(targetUserID:f.target.rawValue,confirmation:next) == .queuedForRetry)
        var iterator=(await f.service.updates(roomID:f.room)).makeAsyncIterator()
        let current=try #require(try await iterator.next()?.first)
        #expect(current.intent.targetUserID==f.target)
        #expect(current.work==nil)
        #expect(current.intent.operationID != oldWindow.operationID)
        #expect(await f.remote.submissions==1)
        try await f.store.close()
    }
}
private struct MembershipAppFixture {
    let url=FileManager.default.temporaryDirectory.appending(path:"app-membership-"+UUID().uuidString).appending(path:"state.sqlite")
    let account=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),target=UserID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote:MembershipAppRemote,service:V2MembershipOperationService
    init(rejectOld:Bool) throws {
        store=try .init(databaseURL:url,installationBinding:.init(value:UUID()),userID:account)
        remote=MembershipAppRemote(rejectOld:rejectOld)
        service = .init(accountID:account,activationID:UUID(),store:store,client:remote)
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
private actor MembershipAppRemote:V2MembershipOperationClient {
    nonisolated let oldTarget=UserID(uuid:UUID())
    let rejectOld:Bool
    var submissions=0
    init(rejectOld:Bool) { self.rejectOld=rejectOld }
    func admit(_ intent:V2MembershipIntent) async throws -> V2MembershipAdmissionResult {
        .admitted(try .init(id:.init(uuid:UUID()),identity:intent.identity,intentFingerprint:intent.fingerprint,action:intent.action,membershipRevision:intent.expectedMembershipRevision,targetJoinedRevision:intent.action == .add ? nil:0,issuedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000),expiresAtMilliseconds:intent.confirmedUntilMilliseconds))
    }
    func submit(_ command:V2MembershipOperationCommand) async throws -> V2MembershipRecoveryResult {
        submissions += 1
        return .receipt(try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:rejectOld ? .rejected(.permissionDenied):.changed(try .init(membershipRevision:1,roomSequence:1,eventID:.init(uuid:UUID()))),resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000)))
    }
    func recover(_ command:V2MembershipOperationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2MembershipRecoveryResult { .unresolved }
}

@MainActor
struct V2MemberAdministrationAppTests {
    @Test("UI adapter saves the observed revision before any network call",arguments:[false,true])
    func durableConfirmation(remove:Bool) async throws {
        let f=try AdministrationAppFixture();defer { f.remove() }
        let adapter=V2OperationGroupMemberAdministrator(service:f.service)
        if remove {
            #expect(try await adapter.removeMemberByModerator(roomID:f.room.rawValue,targetUserID:f.target.rawValue,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:7) == .queuedForRetry)
        } else {
            #expect(try await adapter.muteMember(roomID:f.room.rawValue,targetUserID:f.target.rawValue,muteUntil:Date().addingTimeInterval(600),reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:7) == .queuedForRetry)
        }
        var iterator=(await f.service.updates(roomID:f.room)).makeAsyncIterator()
        let saved=try #require(try await iterator.next()?.first)
        #expect(saved.intent.expectedMembershipRevision==7)
        #expect(saved.work==nil)
        #expect(await f.remote.calls==0)
        // Cancelling a page observer does not retract its saved confirmation.
        let observer=Task { for try await _ in await adapter.administrationUpdates(roomID:f.room) { try Task.checkCancellation() } }
        observer.cancel();_ = try? await observer.value
        var retained=(await f.service.updates(roomID:f.room)).makeAsyncIterator()
        #expect(try await retained.next()?.first?.id==saved.id)
        try await f.store.close()
    }
    @Test("cancelled click creates no durable administration intent")
    func cancelledClick() async throws {
        let f=try AdministrationAppFixture();defer { f.remove() }
        let adapter=V2OperationGroupMemberAdministrator(service:f.service)
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await adapter.removeMemberByModerator(roomID:f.room.rawValue,targetUserID:f.target.rawValue,reasonCode:.init("ADMIN_ACTION"),expectedMembershipRevision:7)
        }
        await #expect(throws:CancellationError.self) { try await task.value }
        var iterator=(await f.service.updates(roomID:f.room)).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty==true)
        try await f.store.close()
    }
}
private struct AdministrationAppFixture {
    let url=FileManager.default.temporaryDirectory.appending(path:"app-member-admin-"+UUID().uuidString).appending(path:"state.sqlite")
    let account=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),target=UserID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote:AdministrationAppRemote,service:V2MemberAdministrationOperationService
    init() throws {
        store=try .init(databaseURL:url,installationBinding:.init(value:UUID()),userID:account)
        remote=AdministrationAppRemote()
        service = .init(accountID:account,activationID:UUID(),store:store,client:remote)
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
private actor AdministrationAppRemote:V2MemberAdministrationOperationClient {
    var calls=0
    func admit(_ intent:V2MemberAdministrationIntent) async throws -> V2MemberAdministrationAdmissionResult { calls += 1;throw URLError(.notConnectedToInternet) }
    func submit(_ command:V2MemberAdministrationCommand) async throws -> V2MemberAdministrationRecoveryResult { calls += 1;throw URLError(.notConnectedToInternet) }
    func recover(_ command:V2MemberAdministrationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2MemberAdministrationRecoveryResult { calls += 1;throw URLError(.notConnectedToInternet) }
}
