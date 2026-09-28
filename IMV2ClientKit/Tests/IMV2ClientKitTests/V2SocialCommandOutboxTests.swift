import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 social and account preference operation persistence")
struct V2SocialOperationPersistenceTests {
    @Test("relationship block and account preferences survive restart with original frozen identities")
    func persistsAndDispatchesAllSocialCommandKinds() async throws {
        let account=UserID(uuid:UUID()),target=UserID(uuid:UUID()),binding=V2LocalInstallationBinding(value:UUID())
        let url=FileManager.default.temporaryDirectory.appending(path:"social-work-"+UUID().uuidString).appending(path:"state.sqlite")
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        var store=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:binding,userID:account)
        let remote=SocialOperationFixtureRemote(account:account)
        let social=V2SocialOperationService(accountID:account,store:store,client:remote)
        let preferences=V2AccountPreferenceService(accountID:account,store:store,client:remote)
        let relationship=try await social.enqueue(action:.relationship(.request),targetUserID:target)
        let stranger=try await preferences.enqueue(value:.strangerMessage(.deny),snapshot:remote.baseline(kind:.strangerMessagePreference))
        let add=try await preferences.enqueue(value:.userAdd(.deny),snapshot:remote.baseline(kind:.userAddPreference))
        let frozen=try #require(try await store.operationWork(id:relationship))
        try await store.close()
        store=try .init(databaseURL:url,installationBinding:binding,userID:account)
        let restarted=V2SocialOperationService(accountID:account,store:store,client:remote)
        let restartedPreferences=V2AccountPreferenceService(accountID:account,store:store,client:remote)
        for id in [relationship,stranger,add] {
            guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:Date()) else { Issue.record("expected persistent claim");return }
            if id==relationship { try await restarted.execute(claim) } else { try await restartedPreferences.execute(claim) }
            #expect(try await store.operationWork(id:id)?.execution == .committed)
        }
        #expect(await remote.identities.contains(frozen.identity))
        let block=try await restarted.enqueue(action:.userBlock(.block),targetUserID:target)
        guard case .claimed(let claim)=try await store.claimOperationWork(id:block,ownerID:UUID(),action:.submit,now:Date()) else { Issue.record("expected block claim");return }
        try await restarted.execute(claim)
        #expect(try await store.operationWork(id:block)?.execution == .committed)
        try await store.close()
    }
    @Test("exact frozen privacy retry reuses identity while a new target cannot replace unknown work")
    func duplicatePendingPrivacyIntentReusesOnlyTheEquivalentOperation() async throws {
        let account=UserID(uuid:UUID()),url=FileManager.default.temporaryDirectory.appending(path:"social-reuse-"+UUID().uuidString).appending(path:"state.sqlite")
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let store=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:.init(value:UUID()),userID:account)
        let identity=try V2OperationIdentity(accountID:account,scope:.account(account),operation:.strangerMessagePreference(.init(uuid:UUID())))
        let command=try V2AccountPreferenceCommand(identity:identity,value:.strangerMessage(.deny),expectedRevision:0,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+120000)
        let original=try await store.enqueueAccountPreference(command)
        #expect(try await store.enqueueAccountPreference(command)==original)
        let changed=try V2AccountPreferenceCommand(identity:.init(accountID:account,scope:.account(account),operation:.strangerMessagePreference(.init(uuid:UUID()))),value:.strangerMessage(.allow),expectedRevision:0,firstSubmissionDeadlineMilliseconds:command.firstSubmissionDeadlineMilliseconds)
        await #expect(throws:V2OperationWorkError.invalidTransition) { try await store.enqueueAccountPreference(changed) }
        #expect(try await store.accountPreferenceCommand(workID:original)==command)
        try await store.close()
    }
    @Test("a later social click cannot flush or replace an earlier unknown identity")
    func flushIfReadyLeavesAnEarlierCommandUntouched() async throws {
        let account=UserID(uuid:UUID()),target=UserID(uuid:UUID()),url=FileManager.default.temporaryDirectory.appending(path:"social-head-"+UUID().uuidString).appending(path:"state.sqlite")
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        let store=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:.init(value:UUID()),userID:account)
        let remote=SocialOperationFixtureRemote(account:account)
        let service=V2SocialOperationService(accountID:account,store:store,client:remote)
        let id=try await service.enqueue(action:.relationship(.request),targetUserID:target)
        await #expect(throws:V2OperationWorkError.invalidTransition) { try await service.enqueue(action:.userBlock(.block),targetUserID:target) }
        #expect(try await store.operationWork(id:id)?.execution == .prepared)
        #expect(await remote.identities.isEmpty)
        try await store.close()
    }
}
private actor SocialOperationFixtureRemote:V2SocialOperationClient,V2AccountPreferenceClient {
    let account:UserID
    var identities:[V2OperationIdentity]=[]
    init(account:UserID) { self.account=account }
    func baseline(targetUserID:UserID) async throws -> V2SocialOperationSnapshot { try .init(actorUserID:account,targetUserID:targetUserID,relationshipState:.none,requestedByUserID:nil,relationshipRevision:0,isBlocked:false,blockRevision:0) }
    func baseline(kind:V2OperationKind) async throws -> V2AccountPreferenceSnapshot {
        let value:V2AccountPreferenceValue
        switch kind { case .strangerMessagePreference:value = .strangerMessage(.allow);case .userAddPreference:value = .userAdd(.allow);case .readReceiptPreference:value = .readReceipt(allowsDirectReadReceipts:true,allowsGroupReadReceipts:true);default:value = .liveActivity(allowsOnlinePresence:true,allowsTypingIndicators:true) }
        return try .init(ownerUserID:account,value:value,revision:0)
    }
    func submit(_ command:V2SocialOperationCommand) async throws -> V2SocialOperationRecoveryResult {
        identities.append(command.identity)
        let applied:V2SocialOperationApplied
        switch command.action { case .relationship:applied = .relationship(state:.pending,revision:command.expectedRevision+1);case .userBlock(let action):applied = .userBlock(isBlocked:action == .block,revision:command.expectedRevision+1) }
        return .receipt(try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:.applied(applied),resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000)))
    }
    func recover(_ command:V2SocialOperationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2SocialOperationRecoveryResult { try await submit(command) }
    func submit(_ command:V2AccountPreferenceCommand) async throws -> V2AccountPreferenceRecoveryResult {
        identities.append(command.identity)
        return .receipt(try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:.applied(value:command.value,revision:command.expectedRevision+1),resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000)))
    }
    func recover(_ command:V2AccountPreferenceCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2AccountPreferenceRecoveryResult { try await submit(command) }
}
