import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit

@Suite("Durable own-reaction intent",.serialized)
struct V2MessageReactionWorkTests {
    @Test("offline target saves first and coalesces without renewing identity or deadline")
    func coalescing() async throws {
        let f=try ReactionWorkFixture();defer { f.remove() }
        let id=try await f.service.enqueue(roomID:f.room,messageID:f.message,reaction:"👍",targetState:.present)
        let original=try #require(try await f.store.nextReactionDraft(now:Date()))
        #expect(try await f.service.enqueue(roomID:f.room,messageID:f.message,reaction:"👍",targetState:.absent)==id)
        let changed=try #require(try await f.store.nextReactionDraft(now:Date()))
        #expect(changed.operationID==original.operationID && changed.deadlineMilliseconds==original.deadlineMilliseconds)
        #expect(changed.targetState == .absent)
        #expect(await f.remote.calls==0)
        #expect(try await f.store.dueOperationWork(now:Date(),kinds:[.reaction]).isEmpty)
        try await f.store.close()
    }
    @Test("unknown frozen head keeps its version and blocks later target until original receipt")
    func frozenHead() async throws {
        let f=try ReactionWorkFixture();defer { f.remove() }
        let id=try await f.service.enqueue(roomID:f.room,messageID:f.message,reaction:"👍",targetState:.present)
        #expect(try await f.service.prepareNextIntent())
        let original=try await f.store.reactionCommand(workID:id)
        #expect(original.expectedReactionRevision==7)
        try await f.service.execute(f.claim(id))
        let next=try await f.service.enqueue(roomID:f.room,messageID:f.message,reaction:"👍",targetState:.absent)
        #expect(next != id)
        #expect(!(try await f.service.prepareNextIntent()))
        #expect(try await f.store.reactionCommand(workID:id)==original)
        try await f.store.close()
        let reopened=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let service=V2MessageReactionOperationService(accountID:f.account,store:reopened,client:f.remote)
        let work=try #require(try await reopened.operationWork(id:id))
        guard case .claimed(let claim)=try await reopened.claimOperationWork(id:id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { Issue.record("missing recovery");return }
        try await service.execute(claim)
        #expect(try await reopened.operationWork(id:id)?.execution == .committed)
        #expect(try await service.prepareNextIntent())
        #expect(try await reopened.reactionCommand(workID:next).expectedReactionRevision==8)
        #expect(await f.remote.submissions==1)
        try await reopened.close()
    }
    @Test("snapshot identity must bind actor and key before freezing")
    func wrongActor() async throws {
        let f=try ReactionWorkFixture(wrongActor:true);defer { f.remove() }
        let id=try await f.service.enqueue(roomID:f.room,messageID:f.message,reaction:"👍",targetState:.present)
        #expect(!(try await f.service.prepareNextIntent()))
        #expect(try await f.store.operationWork(id:id)==nil)
        #expect(try await f.store.nextReactionDraft(now:.distantFuture)==nil)
        try await f.store.close()
    }
}
struct ReactionWorkFixture {
    let url:URL,binding=V2LocalInstallationBinding(value:UUID()),account=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),message=MessageID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote:ReactionWorkRemote,service:V2MessageReactionOperationService
    init(wrongActor:Bool=false) throws {
        url=FileManager.default.temporaryDirectory.appending(path:"reaction-work-"+UUID().uuidString).appending(path:"state.sqlite")
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
        remote=ReactionWorkRemote(account:wrongActor ? .init(uuid:UUID()) : account)
        service = .init(accountID:account,store:store,client:remote)
    }
    func claim(_ id:UUID) async throws -> V2OperationWorkClaim {
        let work=try #require(try await store.operationWork(id:id))
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition };return claim
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
actor ReactionWorkRemote:V2MessageReactionOperationClient {
    let account:UserID
    var calls=0,submissions=0,revision:UInt64=7
    var receipt:V2MessageReactionReceipt?
    init(account:UserID) { self.account=account }
    func snapshot(roomID:RoomID,messageID:MessageID,reaction:String) async throws -> V2MessageReactionSnapshot {
        calls += 1
        return try .init(roomID:roomID,actorUserID:account,messageID:messageID,reaction:reaction,targetState:receipt == nil ? .absent : .present,revision:revision)
    }
    func submit(_ command:V2MessageReactionOperationCommand) async throws -> V2MessageReactionRecoveryResult {
        submissions += 1;revision=command.expectedReactionRevision+1
        receipt=try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:.committed(.init(targetState:command.targetState,revision:revision,event:nil)),resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000))
        throw URLError(.networkConnectionLost)
    }
    func recover(_ request:V2MessageReactionRecoveryRequest) async throws -> V2MessageReactionRecoveryResult { guard let receipt else { return .unresolved };return .receipt(receipt) }
}
