import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Group creation original operation recovery",.serialized)
struct V2GroupCreationOperationTests {
    @Test("large audiences advance one bounded page per claim and retain identity after restart")
    func boundedPagesAndRestart() async throws {
        let f=try GroupCreationFixture();defer { f.remove() }
        let members=(0..<4_999).map { _ in UserID(uuid:UUID()) }
        let id=try await f.service.enqueue(title:"Large",members:members)
        for _ in 0..<4 { try await f.step(id) }
        let before=try await f.service.pending(id:id)
        try await f.store.close()
        let store=try GRDBV2LocalSyncStore(databaseURL:f.url,installationBinding:f.binding,userID:f.account)
        let service=V2GroupCreationOperationService(accountID:f.account,store:store,client:f.remote)
        #expect(try await service.enqueue(title:"Large",members:members)==id)
        for _ in 0..<20 {
            let work=try #require(try await store.operationWork(id:id))
            if work.execution.isTerminal { break }
            guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
            try await service.execute(claim)
        }
        let after=try await service.pending(id:id)
        #expect(after.intent==before.intent)
        #expect(after.work.execution == .committed)
        #expect(await f.remote.maximumPage<=512)
        #expect(await f.remote.members.count==4_999)
        try await store.close()
    }
    @Test("cancel is durable and finalizing cannot be falsely reported closed",arguments:[false,true])
    func cancellation(finalizing:Bool) async throws {
        let f=try GroupCreationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(title:"Cancel",members:[])
        try await f.step(id)
        if finalizing { try await f.step(id) }
        try await f.service.requestCancellation(id:id)
        #expect(try await f.service.pending(id:id).cancellationRequested)
        try await f.step(id)
        let result=try await f.service.pending(id:id)
        #expect(result.work.execution == (finalizing ? .committed:.closed))
        try await f.store.close()
    }
    @Test("mismatched prefix proof pauses without advancing the durable cursor")
    func wrongPrefixCannotAdvance() async throws {
        let f=try GroupCreationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(title:"Prefix",members:[.init(uuid:UUID())])
        try await f.step(id)
        await f.remote.breakPrefix()
        try await f.step(id)
        let result=try await f.service.pending(id:id)
        #expect(result.progress?.acceptedMemberCount==0)
        #expect(result.work.scheduling == .needsAttention)
        try await f.store.close()
    }
    @Test("unchanged progress does not replenish the retry budget")
    func unchangedProgressKeepsBudget() async throws {
        let f=try GroupCreationFixture();defer { f.remove() }
        let id=try await f.service.enqueue(title:"Poll",members:[])
        try await f.step(id)
        let work=try #require(try await f.store.operationWork(id:id))
        guard case .claimed(let claim)=try await f.store.claimOperationWork(id:id,ownerID:UUID(),action:.reconcile,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        try await f.service.execute(claim)
        #expect(try await f.store.operationWork(id:id)?.reconciliationRoundAttempts==1)
        try await f.store.close()
    }
}
private struct GroupCreationFixture {
    let url=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString).appending(path:"state.sqlite")
    let binding=V2LocalInstallationBinding(value:UUID()),account=UserID(uuid:UUID())
    let store:GRDBV2LocalSyncStore,remote=GroupCreationRemote(),service:V2GroupCreationOperationService
    init() throws {
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
        service = .init(accountID:account,store:store,client:remote)
    }
    func step(_ id:UUID) async throws {
        let work=try #require(try await store.operationWork(id:id))
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:work.nextAction,now:work.nextActionAt) else { throw V2OperationWorkError.invalidTransition }
        try await service.execute(claim)
    }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
}
private actor GroupCreationRemote:V2GroupCreationOperationClient {
    let room=RoomID(uuid:UUID())
    var members:[UserID]=[],maximumPage=0,phase=V2GroupCreationPhase.staging,wrongPrefix=false
    func breakPrefix() { wrongPrefix=true }
    func begin(_ intent:V2GroupCreationIntent) throws -> V2GroupCreationOperationResult { try progress(intent) }
    func append(_ page:V2GroupCreationAppendRequest) throws -> V2GroupCreationOperationResult {
        guard page.offset==members.count else { throw V2GroupCreationValidationError.invalidPage }
        maximumPage=max(maximumPage,page.memberUserIDs.count);members += page.memberUserIDs
        return try progress(page.intent)
    }
    func finalize(_ intent:V2GroupCreationIntent) throws -> V2GroupCreationOperationResult { phase = .finalizing;return try progress(intent) }
    func recover(_ intent:V2GroupCreationIntent,action:V2OperationRecoveryRequest.Action) throws -> V2GroupCreationOperationResult {
        if phase == .finalizing { return .receipt(try .init(intent:intent,outcome:.created(roomID:room,title:intent.title,capacityClass:intent.capacityClass,memberCount:intent.initialMemberCount+1),resolvedAtMilliseconds:1_000)) }
        if action == .closeIfAbsent { return .receipt(try .init(intent:intent,outcome:.closed,resolvedAtMilliseconds:1_000)) }
        return try progress(intent)
    }
    private func progress(_ intent:V2GroupCreationIntent) throws -> V2GroupCreationOperationResult {
        .progress(try .init(intent:intent,roomID:room,phase:phase,acceptedMemberCount:members.count,acceptedPrefixDigest:V2GroupCreationAudience.digest(wrongPrefix ? []:members)))
    }
}
