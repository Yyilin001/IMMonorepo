import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2UserProfileActionStoreTests {
    @Test func relationshipDirectionAndBlockDetermineAvailableActions() async throws {
        let actor = UserID(uuid: UUID()), peer = UserID(uuid: UUID())
        for (state, requestedBy, blocked, expected) in [
            (V2RelationshipState.none, nil, false, V2UserProfileActionStore.Relationship.stranger),
            (.accepted, nil, false, .friend),
            (.pending, actor, false, .outgoing),
            (.pending, peer, false, .incoming),
            (.accepted, nil, true, .blocked)
        ] {
            let baseline = try V2SocialOperationSnapshot(actorUserID: actor, targetUserID: peer, relationshipState: state, requestedByUserID: requestedBy, relationshipRevision: 12, isBlocked: blocked, blockRevision: 9)
            let manager = ProfileSocialManager(baseline)
            let store = V2UserProfileActionStore(target: peer, manager: manager, notifier: nil)
            await store.refresh()
            #expect(store.relationship == expected)
            if blocked {
                await store.submit(.relationship(.request))
                #expect(await manager.submitted().isEmpty)
            }
        }
    }

    @Test func confirmedClickPreservesPeerAndObservedRevisionAndDoesNotSubmitTwice() async throws {
        let peer = UserID(uuid: UUID())
        let baseline = try V2SocialOperationSnapshot(actorUserID: .init(uuid: UUID()), targetUserID: peer, relationshipState: .none, requestedByUserID: nil, relationshipRevision: 17, isBlocked: false, blockRevision: 3)
        let manager = ProfileSocialManager(baseline)
        let store = V2UserProfileActionStore(target: peer, manager: manager, notifier: nil)
        await store.refresh()
        await store.submit(.relationship(.request))
        await store.submit(.relationship(.request))
        let submitted = await manager.submitted()
        #expect(submitted.count == 1)
        #expect(submitted.first?.0 == .relationship(.request))
        #expect(submitted.first?.1 == baseline)
        #expect(store.pending)
    }

    @Test func wrongPeerBaselineCannotAuthorizeAnAction() async throws {
        let baseline = try V2SocialOperationSnapshot(actorUserID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID()), relationshipState: .none, requestedByUserID: nil, relationshipRevision: 0, isBlocked: false, blockRevision: 0)
        let manager = ProfileSocialManager(baseline)
        let store = V2UserProfileActionStore(target: .init(uuid: UUID()), manager: manager, notifier: nil)
        await store.refresh()
        await store.submit(.relationship(.request))
        #expect(store.snapshot == nil)
        #expect(await manager.submitted().isEmpty)
    }
}

private actor ProfileSocialManager: V2SocialOperationManaging {
    let baseline: V2SocialOperationSnapshot
    var submissions: [(V2SocialOperationAction, V2SocialOperationSnapshot)] = []
    init(_ baseline: V2SocialOperationSnapshot) { self.baseline = baseline }
    func submitted() -> [(V2SocialOperationAction, V2SocialOperationSnapshot)] { submissions }
    func socialBaseline(target: UserID) async throws -> V2SocialOperationSnapshot { baseline }
    func enqueueSocial(action: V2SocialOperationAction, snapshot: V2SocialOperationSnapshot) async throws { submissions.append((action, snapshot)) }
    func socialProposals() async -> AsyncThrowingStream<[V2SocialOperationProposal], any Error> { .init { $0.finish() } }
    func socialUpdates() async -> AsyncThrowingStream<[V2SocialOperationPending], any Error> { .init { $0.finish() } }
    func saveSocialProposal(action: V2SocialOperationAction, target: UserID) async throws -> UUID { UUID() }
    func confirmSocialProposal(id: UUID, snapshot: V2SocialOperationSnapshot) async throws { }
    func discardSocialProposal(id: UUID) async throws { }
    func resumeSocialConfirmation(workID: UUID) async throws { }
}
