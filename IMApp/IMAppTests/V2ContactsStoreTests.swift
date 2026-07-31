import Foundation
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2ContactsStoreTests {
    @Test func refreshGroupsRelationshipProjectionsAndHydratesMissingContactCards() async throws {
        let currentUserID = try UserID("00000000-0000-0000-0000-000000000801")
        let friend = try makeIdentity(userID: "00000000-0000-0000-0000-000000000802", handle: "alice", displayName: "Alice")
        let incoming = try makeIdentity(userID: "00000000-0000-0000-0000-000000000803", handle: "bob", displayName: "Bob")
        let outgoing = try makeIdentity(userID: "00000000-0000-0000-0000-000000000804", handle: "carol", displayName: "Carol")
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let source = ContactsDataSourceFake(
            projections: [
                .init(userID: friend.userID, state: .accepted, requestedByUserID: currentUserID, updatedAt: date, publicIdentity: friend),
                .init(userID: incoming.userID, state: .pending, requestedByUserID: incoming.userID, updatedAt: date.addingTimeInterval(2), publicIdentity: nil),
                .init(userID: outgoing.userID, state: .pending, requestedByUserID: currentUserID, updatedAt: date.addingTimeInterval(1), publicIdentity: outgoing)
            ],
            hydratedProfiles: [incoming.userID: incoming]
        )
        let store = makeStore(dataSource: source, currentUserID: currentUserID)

        await store.refresh()

        #expect(store.state == .loaded)
        #expect(store.friends.map(\.displayName) == ["Alice"])
        #expect(store.incomingRequests.map(\.displayName) == ["Bob"])
        #expect(store.outgoingRequests.map(\.displayName) == ["Carol"])
        #expect(store.incomingRequestCount == 1)
        #expect(await source.hydratedRequests() == [[incoming.userID]])
    }

    @Test func addFriendSubmitsDurableIntentWithoutOptimisticallyCreatingAFriend() async throws {
        let currentUserID = try UserID("00000000-0000-0000-0000-000000000811")
        let target = try makeIdentity(userID: "00000000-0000-0000-0000-000000000812", handle: "target", displayName: "目标用户")
        let source = ContactsDataSourceFake(projections: [], hydratedProfiles: [:])
        let resolver = PublicIdentityResolverFake(identity: target)
        let changer = RelationshipChangerFake(outcome: .accepted)
        let store = makeStore(
            dataSource: source,
            currentUserID: currentUserID,
            identityResolver: resolver,
            relationshipChanger: changer
        )
        store.addFriendHandle = "@target"

        await store.resolveAddFriend()
        await store.sendFriendRequest()

        #expect(await changer.actions() == [.request])
        #expect(store.friends.isEmpty)
        #expect(store.incomingRequests.isEmpty)
        #expect(store.outgoingRequests.isEmpty)
        #expect(store.feedback == "请求已提交，正在同步。")
    }

    @Test func openingAFriendConversationSelectsTheMessagesTabWithTheReturnedRoom() async throws {
        let currentUserID = try UserID("00000000-0000-0000-0000-000000000821")
        let friend = try makeIdentity(userID: "00000000-0000-0000-0000-000000000822", handle: "friend", displayName: "好友")
        let roomID = "00000000-0000-0000-0000-000000000823"
        let source = ContactsDataSourceFake(
            projections: [.init(userID: friend.userID, state: .accepted, requestedByUserID: currentUserID, updatedAt: .now, publicIdentity: friend)],
            hydratedProfiles: [:]
        )
        let opener = DirectConversationOpenerFake(roomID: roomID)
        let store = makeStore(dataSource: source, currentUserID: currentUserID, directConversationOpener: opener)
        let rootNavigation = V2RootNavigationStore()

        await store.refresh()
        let openedRoomID = await store.openConversation(with: try #require(store.friends.first))
        if let openedRoomID { rootNavigation.showConversation(roomID: openedRoomID) }

        #expect(await opener.openedUserIDs() == [friend.userID])
        #expect(rootNavigation.selectedTab == .conversations)
        #expect(rootNavigation.conversationRequest?.roomID == roomID)
    }

    private func makeStore(
        dataSource: any V2ContactsReading,
        currentUserID: UserID,
        identityResolver: any V2ConversationPublicIdentityResolving = PublicIdentityResolverFake(identity: nil),
        relationshipChanger: any V2RelationshipChanging = RelationshipChangerFake(outcome: .accepted),
        directConversationOpener: any V2DirectConversationOpening = DirectConversationOpenerFake(roomID: "00000000-0000-0000-0000-000000000899")
    ) -> V2ContactsStore {
        V2ContactsStore(
            dataSource: dataSource,
            identityResolver: identityResolver,
            relationshipChanger: relationshipChanger,
            userBlockChanger: UserBlockChangerFake(),
            directConversationOpener: directConversationOpener,
            currentUserID: currentUserID
        )
    }

    private func makeIdentity(userID: String, handle: String, displayName: String) throws -> V2PublicIdentity {
        try .init(userID: .init(userID), handle: .init(handle), displayName: displayName)
    }
}

private actor ContactsDataSourceFake: V2ContactsReading {
    private var projections: [V2ContactProjection]
    private let hydratedProfiles: [UserID: V2PublicIdentity]
    private var requests: [[UserID]] = []

    init(projections: [V2ContactProjection], hydratedProfiles: [UserID: V2PublicIdentity]) {
        self.projections = projections
        self.hydratedProfiles = hydratedProfiles
    }

    func contactProjections() async throws -> [V2ContactProjection] {
        projections
    }

    func hydrateRelationshipProfiles(for userIDs: [UserID]) async throws {
        requests.append(userIDs)
        projections = projections.map { projection in
            guard projection.publicIdentity == nil, let identity = hydratedProfiles[projection.userID] else {
                return projection
            }
            return .init(
                userID: projection.userID,
                state: projection.state,
                requestedByUserID: projection.requestedByUserID,
                updatedAt: projection.updatedAt,
                publicIdentity: identity
            )
        }
    }

    func hydratedRequests() -> [[UserID]] { requests }
}

private actor PublicIdentityResolverFake: V2ConversationPublicIdentityResolving {
    private let identity: V2PublicIdentity?

    init(identity: V2PublicIdentity?) {
        self.identity = identity
    }

    func resolve(handle _: String) async throws -> V2PublicIdentity {
        guard let identity else { throw V2PublicIdentityValidationError.invalidHandle }
        return identity
    }
}

private actor RelationshipChangerFake: V2RelationshipChanging {
    private let outcome: V2RelationshipChangeOutcome
    private var recordedActions: [V2RelationshipAction] = []

    init(outcome: V2RelationshipChangeOutcome) {
        self.outcome = outcome
    }

    func changeRelationship(targetUserID _: String, action: V2RelationshipAction) async throws -> V2RelationshipChangeOutcome {
        recordedActions.append(action)
        return outcome
    }

    func actions() -> [V2RelationshipAction] { recordedActions }
}

private actor UserBlockChangerFake: V2UserBlockChanging {
    func changeBlock(targetUserID _: String, action _: V2UserBlockAction) async throws -> V2UserBlockChangeOutcome {
        .accepted
    }
}

private actor DirectConversationOpenerFake: V2DirectConversationOpening {
    private let roomID: String
    private var users: [UserID] = []

    init(roomID: String) {
        self.roomID = roomID
    }

    func openConversation(with publicIdentity: V2PublicIdentity) async throws -> String {
        users.append(publicIdentity.userID)
        return roomID
    }

    func openedUserIDs() -> [UserID] { users }
}
