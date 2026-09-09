import Foundation
import SwiftUI
import UIKit
@testable import IMV2ClientKit
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

    @Test func contactListLoadsStableAdditionalPages() async throws {
        let currentUserID = try UserID("00000000-0000-0000-0000-000000000831")
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let projections = try (1 ... 51).map { index in
            let identity = try makeIdentity(
                userID: String(format: "00000000-0000-0000-0000-%012d", 900 + index),
                handle: "friend\(index)",
                displayName: "Friend \(index)"
            )
            return V2ContactProjection(
                userID: identity.userID,
                state: .accepted,
                requestedByUserID: currentUserID,
                updatedAt: date.addingTimeInterval(TimeInterval(index)),
                publicIdentity: identity
            )
        }
        let source = ContactsDataSourceFake(projections: projections, hydratedProfiles: [:])
        let store = makeStore(dataSource: source, currentUserID: currentUserID)

        await store.refresh()
        #expect(store.friends.count == 50)
        #expect(store.friendsNextCursor != nil)
        await store.loadMoreFriends()
        #expect(store.friends.count == 51)
        #expect(Set(store.friends.map(\.id)).count == 51)
        #expect(store.friendsNextCursor == nil)
        await store.refresh()
        #expect(store.friends.count == 51)
        #expect(store.friendsNextCursor == nil)
    }

    @Test func refreshRetainsIndependentContactAndSearchWindows() async throws {
        let currentUserID = UserID(uuid: UUID())
        var projections: [V2ContactProjection] = []
        for (group, count) in [120, 80, 75].enumerated() {
            for index in 0..<count {
                let identity = try makeIdentity(userID: UUID().uuidString, handle: "member\(group)x\(index)", displayName: "Member \(group) \(index)")
                projections.append(.init(userID: identity.userID, state: group == 0 ? .accepted : .pending,
                    requestedByUserID: group == 1 ? identity.userID : currentUserID,
                    updatedAt: Date(timeIntervalSince1970: Double(index)), publicIdentity: identity))
            }
        }
        let source = ContactsDataSourceFake(projections: projections, hydratedProfiles: [:])
        let store = makeStore(dataSource: source, currentUserID: currentUserID)
        await store.refresh()
        await store.loadMoreFriends()
        await store.loadMoreFriends()
        await store.loadMoreIncomingRequests()
        await store.loadMoreOutgoingRequests()
        #expect(store.friends.count == 120 && store.incomingRequests.count == 80 && store.outgoingRequests.count == 75)
        store.searchQuery = "Member"
        await store.refreshFriendSearch()
        await store.loadMoreFriends()
        #expect(store.filteredFriends.count == 100)
        await store.refresh()
        #expect(store.friends.count == 120 && store.incomingRequests.count == 80 && store.outgoingRequests.count == 75)
        #expect(store.filteredFriends.count == 100 && store.friendSearchNextCursor != nil)
        #expect(store.incomingRequestCount == 80)
        #expect(store.friendsNextCursor == nil && store.incomingRequestsNextCursor == nil && store.outgoingRequestsNextCursor == nil)
        let removed = try #require(store.filteredFriends.first?.userID)
        await source.remove(userID: removed)
        await store.refresh()
        #expect(store.friends.count == 119)
        #expect(!store.filteredFriends.contains { $0.userID == removed })
        #expect(store.item(userID: removed.rawValue) == nil)
        store.searchQuery = "Member 0 1"
        await store.refreshFriendSearch()
        #expect(store.filteredFriends.count <= 50)
    }

    @Test("contact refresh follows scrolling across windows and request sections", arguments: [false, true])
    func scrollingDuringContactRead(searching: Bool) async throws {
        let current = UserID(uuid: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-contact-scroll-read-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        var sequence: UInt64 = 0
        for group in 0...2 { sequence = try await seedContactGroup(local, current: current, group: group, range: 1...500, after: sequence) }
        let gate = V2ListWindowReadGate()
        let source = V2GatedContactWindows(source: .init(localStore: local, profiles: .init(store: local, reader: ContactWindowProfileReader()), currentUserID: current), gate: gate)
        let store = makeStore(dataSource: source, currentUserID: current)
        await store.refresh()
        if searching { store.searchQuery = "Member 0"; await store.refreshFriendSearch() }
        for _ in 0..<7 { await store.loadMoreFriends() }
        for _ in 0..<4 { await store.loadMoreIncomingRequests(); await store.loadMoreOutgoingRequests() }
        let friendIDs = store.filteredFriends.map(\.id)
        let requestIDs = (store.incomingRequests + store.outgoingRequests).map(\.id)
        let latestFriend = friendIDs[0]
        let latestRequest = store.outgoingRequests[20].id
        showContact(friendIDs[200], viewport: store.friendsViewport, ids: friendIDs)
        showContact(store.incomingRequests[100].id, viewport: store.requestsViewport, ids: requestIDs)
        await gate.arm()
        let refresh = Task {
            if searching { await store.refreshFriendSearch() }
            else { await store.refresh() }
        }
        await gate.waitForRead()
        showContact(latestFriend, viewport: store.friendsViewport, ids: friendIDs)
        showContact(latestRequest, viewport: store.requestsViewport, ids: requestIDs)
        await gate.release()
        await refresh.value
        #expect(store.friendsViewport.restoration?.itemID == latestFriend)
        #expect(store.filteredFriends.contains { $0.id == latestFriend })
        if !searching {
            #expect(store.requestsViewport.restoration?.itemID == latestRequest)
            #expect(store.incomingRequestCount == 500)
        }
        #expect(store.filteredFriends.count == 300)
        #expect(store.incomingRequests.count == 150 && store.outgoingRequests.count == 150)
        #expect(await gate.reads >= 2)
        try await local.close()
    }

    @Test("all contact lanes preserve the viewport and cursor during paging", arguments: [0, 1, 2, 3])
    func scrollingDuringContactPagination(lane: Int) async throws {
        let current = UserID(uuid: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-contact-page-scroll-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        var sequence: UInt64 = 0
        for group in 0...2 { sequence = try await seedContactGroup(local, current: current, group: group, range: 1...500, after: sequence) }
        let gate = V2ListWindowReadGate()
        let source = V2GatedContactWindows(source: .init(localStore: local, profiles: .init(store: local, reader: ContactWindowProfileReader()), currentUserID: current), gate: gate)
        let store = makeStore(dataSource: source, currentUserID: current)
        await store.refresh()
        if lane == 1 { store.searchQuery = "Member 0"; await store.refreshFriendSearch() }
        let viewport = lane < 2 ? store.friendsViewport : store.requestsViewport
        func values() -> [V2ContactListItem] {
            switch lane { case 0, 1: store.filteredFriends; case 2: store.incomingRequests; default: store.outgoingRequests }
        }
        func cursor() -> V2ClientRelationshipCursor? {
            switch lane { case 0: store.friendsNextCursor; case 1: store.friendSearchNextCursor; case 2: store.incomingRequestsNextCursor; default: store.outgoingRequestsNextCursor }
        }
        func show(_ id: String) {
            let ids = lane < 2 ? values().map(\.id) : (store.incomingRequests + store.outgoingRequests).map(\.id)
            showContact(id, viewport: viewport, ids: ids)
        }
        func loadMore() async {
            switch lane { case 0, 1: await store.loadMoreFriends(); case 2: await store.loadMoreIncomingRequests(); default: await store.loadMoreOutgoingRequests() }
        }
        func loadEarlier() async {
            switch lane { case 0, 1: await store.loadEarlierFriends(); case 2: await store.loadEarlierIncomingRequests(); default: await store.loadEarlierOutgoingRequests() }
        }
        for _ in 0..<(lane < 2 ? 7 : 4) { show(try #require(values().last?.id)); await loadMore() }
        let before = values().map(\.id), beforeCursor = cursor()
        show(try #require(before.last))
        await gate.arm()
        let next = Task { await loadMore() }
        await gate.waitForRead()
        show(before[0])
        await gate.release()
        await next.value
        #expect(values().map(\.id) == before && cursor() == beforeCursor)
        #expect(viewport.anchorID == before[0] && viewport.restoration == nil)
        show(try #require(before.last))
        await loadMore()
        #expect(values().map(\.id) != before)
        let advanced = values().map(\.id), advancedCursor = cursor()
        show(advanced[0])
        await gate.arm()
        let earlier = Task { await loadEarlier() }
        await gate.waitForRead()
        let latest = try #require(advanced.last)
        show(latest)
        await gate.release()
        await earlier.value
        #expect(values().map(\.id) == advanced && cursor() == advancedCursor)
        #expect(viewport.anchorID == latest && viewport.restoration == nil)
        show(advanced[0])
        await loadEarlier()
        #expect(values().map(\.id) != advanced)
        #expect(values().count == (lane < 2 ? 300 : 150))
        #expect(store.incomingRequestCount == 500)
        try await local.close()
    }

    @Test("earlier contact windows hydrate only missing authorized profile views")
    func earlierWindowHydratesMissingProfile() async throws {
        let current = UserID(uuid: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-earlier-profile-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        _ = try await seedContactGroup(local, current: current, group: 0, range: 1...600, after: 0)
        let target = try UserID("00000000-0000-0000-0000-000000000600")
        let profile = try #require(try await local.profileView(userID: target))
        let reader = EarlierWindowProfileReader(profile: profile)
        let source = V2GRDBContactsDataSource(localStore: local, profiles: .init(store: local, reader: reader), currentUserID: current)
        let store = makeStore(dataSource: source, currentUserID: current)
        await store.refresh()
        for _ in 0..<10 {
            showContact(try #require(store.friends.last?.id), viewport: store.friendsViewport, ids: store.friends.map(\.id))
            await store.loadMoreFriends()
        }
        #expect(!store.friends.contains { $0.userID == target })
        #expect(await reader.requests.isEmpty)
        try await local.markProfileUnavailable(userID: target)
        await store.loadEarlierFriends()
        #expect(store.friends.first?.userID == target)
        #expect(store.friends.first?.publicIdentity != nil)
        #expect(store.friends.count == 300)
        #expect(await reader.requests == [[V2ProfileViewLookupKey(userID: target, context: .relationship)]])
        #expect(try await local.profileView(userID: target) == profile)
        try await local.close()
    }

    @Test("relationship revocation cancels a slow profile read before applying the latest SQLite window")
    func urgentRevocationCancelsProfileHydration() async throws {
        let current = UserID(uuid: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-contact-revoke-refresh-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        _ = try await seedContactGroup(local, current: current, group: 0, range: 1...1, after: 0)
        let reader = CancellableContactProfileReader()
        let source = V2GRDBContactsDataSource(localStore: local, profiles: .init(store: local, reader: reader), currentUserID: current)
        let notifier = V2ProjectionChangeNotifier(localStore: local)
        let store = makeStore(dataSource: source, currentUserID: current, projectionChangeNotifier: notifier)
        await store.refresh()
        let target = try #require(store.friends.first?.userID)
        try await local.markProfileUnavailable(userID: target)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await store.observeProjectionChanges() }
            await reader.waitForRequest()
            #expect(store.friends.count == 1)
            let record = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init(UUID().uuidString), projectionKind: "relationship",
                payload: JSONSerialization.data(withJSONObject: ["target_user_id": target.rawValue, "state": "none", "updated_at_ms": 1_750_100_000_000]))
            _ = try await local.apply(.init(generation: 1, records: [record], nextSyncToken: .init("revoked"), receipt: .init("revoked-receipt"), hasMore: false, capabilityProfile: "base"))
            await reader.waitForCancellation()
            try await waitForContactLayout { store.state == .loaded && store.friends.isEmpty }
            #expect(store.feedback == nil)
            #expect(await reader.requestCount == 1)
            #expect(try await local.profileView(userID: target) == nil)
            group.cancelAll()
        }
        try await local.close()
    }

    @Test func productionContactWindowsKeepIndependentAnchorsAndExactBadge() async throws {
        let current = UserID(uuid: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-contact-window-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        var sequence: UInt64 = 0
        for (group, count) in [600, 400, 400].enumerated() {
            sequence = try await seedContactGroup(local, current: current, group: group, range: 1...count, after: sequence)
        }
        let source = V2GRDBContactsDataSource(localStore: local, profiles: .init(store: local, reader: ContactWindowProfileReader()), currentUserID: current)
        let store = makeStore(dataSource: source, currentUserID: current)
        await store.refresh()
        for _ in 0..<10 {
            showContact(try #require(store.friends.last?.id), viewport: store.friendsViewport, ids: store.friends.map(\.id))
            await store.loadMoreFriends()
        }
        for _ in 0..<6 {
            showContact(try #require(store.incomingRequests.last?.id), viewport: store.requestsViewport, ids: (store.incomingRequests + store.outgoingRequests).map(\.id))
            await store.loadMoreIncomingRequests()
            showContact(try #require(store.outgoingRequests.last?.id), viewport: store.requestsViewport, ids: (store.incomingRequests + store.outgoingRequests).map(\.id))
            await store.loadMoreOutgoingRequests()
        }
        #expect(store.friends.count == 300 && store.incomingRequests.count == 150 && store.outgoingRequests.count == 150)
        #expect(store.hasEarlierFriends && store.hasEarlierIncomingRequests && store.hasEarlierOutgoingRequests)
        let friendAnchor = store.friends[70].id, requestAnchor = store.outgoingRequests[70].id
        let inactiveIncomingAnchor = try #require(store.incomingRequests.first?.id)
        showContact(friendAnchor, viewport: store.friendsViewport, ids: store.friends.map(\.id))
        showContact(requestAnchor, viewport: store.requestsViewport, ids: (store.incomingRequests + store.outgoingRequests).map(\.id))
        sequence = try await seedContactGroup(local, current: current, group: 0, range: 701...900, after: sequence)
        await store.refresh()
        #expect(store.friendsViewport.restoration?.itemID == friendAnchor)
        #expect(store.requestsViewport.restoration?.itemID == requestAnchor)
        #expect(store.incomingRequests.contains { $0.id == inactiveIncomingAnchor })
        #expect(store.incomingRequestCount == 400)
        let beforeEarlier = try #require(store.incomingRequests.first?.updatedAt)
        await store.loadEarlierIncomingRequests()
        #expect(try #require(store.incomingRequests.first?.updatedAt) > beforeEarlier)
        #expect(store.incomingRequests.count == 150 && store.outgoingRequests.count == 150)

        store.searchQuery = "Member 0"
        await store.refreshFriendSearch()
        for _ in 0..<7 {
            showContact(try #require(store.filteredFriends.last?.id), viewport: store.friendsViewport, ids: store.filteredFriends.map(\.id))
            await store.loadMoreFriends()
        }
        #expect(store.filteredFriends.count == 300 && store.hasEarlierFriends)
        let searchAnchor = store.filteredFriends[70].id
        showContact(searchAnchor, viewport: store.friendsViewport, ids: store.filteredFriends.map(\.id))
        await store.refreshFriendSearch()
        #expect(store.friendsViewport.restoration?.itemID == searchAnchor)
        store.searchQuery = "Member 0 9"
        await store.refreshFriendSearch()
        #expect(store.filteredFriends.count <= 50 && !store.hasEarlierFriends)
        store.searchQuery = ""
        await store.refreshFriendSearch()
        await store.returnToFirstFriends()
        #expect(store.friends.count == 50 && !store.hasEarlierFriends)

        let removed = try #require(store.outgoingRequests.first)
        showContact(removed.id, viewport: store.requestsViewport, ids: (store.incomingRequests + store.outgoingRequests).map(\.id))
        let record = try V2ClientSyncRecord(sequence: sequence + 1, sourceEventID: .init(UUID().uuidString), projectionKind: "relationship", payload: JSONSerialization.data(withJSONObject: [
            "target_user_id": removed.id, "state": "none", "updated_at_ms": 1_750_020_000_000
        ]))
        _ = try await local.apply(.init(generation: 1, records: [record], nextSyncToken: .init("removed"), receipt: .init("removed-receipt"), hasMore: false, capabilityProfile: "base"))
        await store.refresh()
        #expect(!store.outgoingRequests.contains { $0.id == removed.id })
        #expect(store.requestsViewport.restoration?.itemID != removed.id)
        #expect(store.incomingRequestCount == 400)
        try await local.close()
    }

    @Test func actualFriendAndRequestListsRestoreVisibleRows() async throws {
        await V2UITestWindowOwnership.acquire()
        defer { V2UITestWindowOwnership.release() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let current = UserID(uuid: UUID())
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-contact-layout-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        var sequence: UInt64 = 0
        for (group, count) in [450, 250, 250].enumerated() {
            sequence = try await seedContactGroup(local, current: current, group: group, range: 1...count, after: sequence)
        }
        let source = V2GRDBContactsDataSource(localStore: local, profiles: .init(store: local, reader: ContactWindowProfileReader()), currentUserID: current)
        let store = makeStore(dataSource: source, currentUserID: current)
        await store.refresh()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: AnyView(V2ContactsRootView(store: store, rootNavigation: .init())))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await waitForContactLayout { store.friendsViewport.anchorID.map(store.friendsViewport.containsVisibleRow) == true }
        for _ in 0..<7 {
            let last = try #require(store.friends.last?.id)
            store.friendsViewport.restore(to: last)
            try await waitForContactLayout { store.friendsViewport.restoration == nil && store.friendsViewport.containsVisibleRow(last) }
            await store.loadMoreFriends()
            try await waitForContactLayout { store.friendsViewport.restoration == nil }
        }
        _ = try await seedContactGroup(local, current: current, group: 0, range: 501...650, after: sequence)
        let friendAnchor = try #require(store.friendsViewport.anchorID)
        #expect(store.friendsViewport.containsVisibleRow(friendAnchor))
        await store.refresh()
        let requestedAnchor = store.friendsViewport.restoration?.itemID
        do { try await waitForContactLayout { store.friendsViewport.restoration == nil && store.friendsViewport.containsVisibleRow(friendAnchor) } }
        catch {
            Issue.record("contact refresh state=\(store.state), feedback=\(String(describing: store.feedback)), count=\(store.filteredFriends.count), target=\(friendAnchor), requested=\(String(describing: requestedAnchor)), current=\(String(describing: store.friendsViewport.anchorID)), layout=\(store.friendsViewport.layoutDescription(for: friendAnchor))")
            throw error
        }
        #expect(store.friends.count == 300 && store.hasEarlierFriends)

        host.rootView = AnyView(NavigationStack { V2FriendRequestsView(store: store) })
        try await waitForContactLayout { store.requestsViewport.anchorID.map(store.requestsViewport.containsVisibleRow) == true }
        for incoming in [true, false] {
            for _ in 0..<4 {
                let last = try #require((incoming ? store.incomingRequests : store.outgoingRequests).last?.id)
                store.requestsViewport.restore(to: last)
                try await waitForContactLayout { store.requestsViewport.restoration == nil && store.requestsViewport.containsVisibleRow(last) }
                if incoming { await store.loadMoreIncomingRequests() } else { await store.loadMoreOutgoingRequests() }
                try await waitForContactLayout { store.requestsViewport.restoration == nil }
            }
        }
        let requestAnchor = try #require(store.requestsViewport.anchorID)
        await store.refresh()
        try await waitForContactLayout { store.requestsViewport.restoration == nil && store.requestsViewport.containsVisibleRow(requestAnchor) }
        #expect(store.incomingRequests.count == 150 && store.outgoingRequests.count == 150)
        #expect(store.incomingRequestCount == 250)
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
        try await local.close()
    }

    private enum ContactLayoutError: Error { case timedOut(line: Int) }
    private func waitForContactLayout(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ContactLayoutError.timedOut(line: line)
    }

    private func showContact(_ id: String, viewport: V2ListViewport, ids: [String]) {
        viewport.reset(); viewport.reconcile(ids: ids); viewport.resize(height: 600)
        viewport.record(id: id, position: .init(minY: 0, maxY: 60))
    }

    private func seedContactGroup(_ local: GRDBV2LocalSyncStore, current: UserID, group: Int, range: ClosedRange<Int>, after sequence: UInt64) async throws -> UInt64 {
        var next = sequence
        let revision = try #require(V2ProfileRevision(rawValue: 1))
        for start in stride(from: range.lowerBound, through: range.upperBound, by: 100) {
            var records: [V2ClientSyncRecord] = []
            var profiles: [V2ProfileViewLookupResult] = []
            for index in start...min(start + 99, range.upperBound) {
                let identity = try makeIdentity(userID: String(format: "00000000-0000-0000-0000-%012d", group * 10_000 + index), handle: "member\(group)x\(index)", displayName: "Member \(group) \(index)")
                var payload: [String: Any] = ["target_user_id": identity.userID.rawValue, "state": group == 0 ? "accepted" : "pending", "updated_at_ms": 1_750_000_000_000 + index * 1_000]
                if group != 0 { payload["requested_by_user_id"] = group == 1 ? identity.userID.rawValue : current.rawValue }
                next += 1
                records.append(try .init(sequence: next, sourceEventID: .init(UUID().uuidString), projectionKind: "relationship", payload: JSONSerialization.data(withJSONObject: payload)))
                profiles.append(.profile(key: .init(userID: identity.userID, context: .relationship), view: try .init(userID: identity.userID, publicIdentity: identity, avatar: nil, state: .active, revision: revision, visibilityRevision: revision)))
            }
            _ = try await local.apply(.init(generation: 1, records: records, nextSyncToken: .init("seed-\(next)"), receipt: .init("receipt-\(next)"), hasMore: false, capabilityProfile: "base"))
            try await local.applyProfileViewResults(profiles)
        }
        return next
    }

    private func makeStore(
        dataSource: any V2ContactsReading,
        currentUserID: UserID,
        identityResolver: any V2ConversationPublicIdentityResolving = PublicIdentityResolverFake(identity: nil),
        relationshipChanger: any V2RelationshipChanging = RelationshipChangerFake(outcome: .accepted),
        directConversationOpener: any V2DirectConversationOpening = DirectConversationOpenerFake(roomID: "00000000-0000-0000-0000-000000000899"),
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil
    ) -> V2ContactsStore {
        V2ContactsStore(
            dataSource: dataSource,
            identityResolver: identityResolver,
            relationshipChanger: relationshipChanger,
            userBlockChanger: UserBlockChangerFake(),
            directConversationOpener: directConversationOpener,
            currentUserID: currentUserID,
            projectionChangeNotifier: projectionChangeNotifier
        )
    }

    private func makeIdentity(userID: String, handle: String, displayName: String) throws -> V2PublicIdentity {
        try .init(userID: .init(userID), handle: .init(handle), displayName: displayName, accountKind: .regular)
    }
}

private struct ContactWindowProfileReader: V2ProfileViewReading {
    func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult] {
        Issue.record("window fixture already has all authorized profiles")
        return keys.map { .unavailable(key: $0) }
    }
}

private actor ContactsDataSourceFake: V2ContactsReading {
    private var projections: [V2ContactProjection]
    private let hydratedProfiles: [UserID: V2PublicIdentity]
    private var requests: [[UserID]] = []

    func remove(userID: UserID) { projections.removeAll { $0.userID == userID } }

    init(projections: [V2ContactProjection], hydratedProfiles: [UserID: V2PublicIdentity]) {
        self.projections = projections
        self.hydratedProfiles = hydratedProfiles
    }

    func contactProjectionPage(
        scope: V2ContactProjectionPageScope,
        matching query: String?,
        before cursor: V2ClientRelationshipCursor?,
        limit: Int,
        includeTotalCount: Bool
    ) async throws -> V2ContactProjectionPage {
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = projections
            .filter { projection in
                switch scope {
                case .friends:
                    projection.state == .accepted
                case .incomingRequests:
                    projection.state == .pending && projection.requestedByUserID == projection.userID
                case .outgoingRequests:
                    projection.state == .pending && projection.requestedByUserID != projection.userID
                }
            }
            .filter { projection in
                guard !normalizedQuery.isEmpty else { return true }
                return projection.publicIdentity?.displayName.localizedCaseInsensitiveContains(normalizedQuery) == true
                    || projection.publicIdentity?.handle.description.localizedCaseInsensitiveContains(normalizedQuery) == true
            }
            .filter { projection in
                guard let cursor else { return true }
                return projection.updatedAt < cursor.updatedAt
                    || (projection.updatedAt == cursor.updatedAt && projection.userID > cursor.targetUserID)
            }
            .sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.userID < rhs.userID : lhs.updatedAt > rhs.updatedAt
            }
        let page = Array(candidates.prefix(limit))
        let nextCursor = candidates.count > limit ? page.last.map {
            V2ClientRelationshipCursor(updatedAt: $0.updatedAt, targetUserID: $0.userID)
        } : nil
        let totalCount: Int? = if includeTotalCount {
            projections.filter { projection in
                projection.state == .pending && projection.requestedByUserID == projection.userID
            }.count
        } else {
            nil
        }
        return .init(projections: page, nextCursor: nextCursor, totalCount: totalCount)
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

private actor EarlierWindowProfileReader: V2ProfileViewReading {
    let profile: V2ProfileView
    private(set) var requests: [[V2ProfileViewLookupKey]] = []
    init(profile: V2ProfileView) { self.profile = profile }
    func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult] {
        requests.append(keys)
        return keys.map { key in
            if key.userID == profile.userID { return .profile(key: key, view: profile) }
            Issue.record("unexpected profile hydration outside the earlier window fixture")
            return .unavailable(key: key)
        }
    }
}

private actor CancellableContactProfileReader: V2ProfileViewReading {
    private(set) var requestCount = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<[V2ProfileViewLookupResult], any Error>?
    private var wasCancelled = false

    func readProfileViews(_ keys: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult] {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                requestCount += 1
                pending = continuation
                for waiter in requestWaiters { waiter.resume() }
                requestWaiters.removeAll()
                if Task.isCancelled { cancel() }
            }
        }, onCancel: { Task { await self.cancel() } })
    }
    private func cancel() {
        guard let pending else { return }
        self.pending = nil
        wasCancelled = true
        // URLSession may return URLError.cancelled, not CancellationError.
        pending.resume(throwing: URLError(.cancelled))
        for waiter in cancellationWaiters { waiter.resume() }
        cancellationWaiters.removeAll()
    }
    func waitForRequest() async {
        guard pending == nil else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }
    func waitForCancellation() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
}
