import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

extension AuthManagerTests {
    @Test func appSessionStoreResetPreservesSignedOutBoundary() {
        let store = AppSessionStore()
        store.setSignedIn(Self.user)
        store.isBusy = true
        store.isLoadingSessions = true
        store.sessionsMessage = "loaded"
        store.isUpdatingProfile = true
        store.profileMessage = "updated"
        store.serverStatus = .offline(message: "offline")

        store.resetForSignedOut(message: "signed out")

        #expect(store.authRouteState == .signedOut(AuthNotice(
            code: .unknown,
            message: "signed out",
            severity: .error,
            isRecoverable: false
        )))
        #expect(store.currentUser == nil)
        #expect(store.sessions.isEmpty)
        #expect(store.sessionsMessage == nil)
        #expect(store.isUpdatingProfile == false)
        #expect(store.profileMessage == nil)
        #expect(store.serverStatus == .unknown)
    }

    @Test func contactStoreAppliesContactEventsAndClearsOnSignOut() {
        let store = ContactStore()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "aaaaaaaa-aaaa-bbbb-cccc-dddddddddddd")!
        let createdAt = Date(timeIntervalSince1970: 1_700_200_000)
        let pendingRequest = contactRequest(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            createdAt: createdAt
        )

        let createdResult = store.apply(
            event: IMTCPContactEventPayload(
                eventType: .friendRequestCreated,
                request: pendingRequest,
                contact: nil,
                contactUserID: nil,
                actorUserID: peer.id,
                serverTimestamp: createdAt
            ),
            currentUserID: Self.user.id,
            isRelevant: contactRequestIsRelevant,
            normalize: normalizeContactRequests,
            sortPendingNewestFirst: sortPendingNewestFirst
        )

        #expect(createdResult == .applied)
        #expect(store.incomingPendingContactRequests(
            currentUserID: Self.user.id,
            sort: sortPendingNewestFirst
        ).map(\.id) == [requestID])
        #expect(store.unseenIncomingContactRequestCount == 1)

        let acceptedRequest = contactRequest(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .accepted,
            createdAt: createdAt,
            respondedAt: Date(timeIntervalSince1970: 1_700_200_010)
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "Peer",
            createdAt: Date(timeIntervalSince1970: 1_700_200_010)
        )

        let acceptedResult = store.apply(
            event: IMTCPContactEventPayload(
                eventType: .friendRequestAccepted,
                request: acceptedRequest,
                contact: contact,
                contactUserID: nil,
                actorUserID: Self.user.id,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_200_010)
            ),
            currentUserID: Self.user.id,
            isRelevant: contactRequestIsRelevant,
            normalize: normalizeContactRequests,
            sortPendingNewestFirst: sortPendingNewestFirst
        )

        #expect(acceptedResult == .applied)
        #expect(store.contacts.map(\.id) == [peer.id])
        #expect(store.incomingPendingContactRequests(
            currentUserID: Self.user.id,
            sort: sortPendingNewestFirst
        ).isEmpty)
        #expect(store.recentResolvedContactRequests(sort: sortPendingNewestFirst).map(\.id) == [requestID])

        let removedResult = store.apply(
            event: IMTCPContactEventPayload(
                eventType: .contactRemoved,
                request: nil,
                contact: nil,
                contactUserID: peer.id,
                actorUserID: peer.id,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_200_020)
            ),
            currentUserID: Self.user.id,
            isRelevant: contactRequestIsRelevant,
            normalize: normalizeContactRequests,
            sortPendingNewestFirst: sortPendingNewestFirst
        )

        #expect(removedResult == .applied)
        #expect(store.contacts.isEmpty)

        store.setNotice("cached", scope: .contactsHome, tone: .info)
        store.acceptingRequestIDs = [requestID]
        store.resetForSignedOut()

        #expect(store.contactRequests.isEmpty)
        #expect(store.contacts.isEmpty)
        #expect(store.notice(for: .contactsHome) == nil)
        #expect(store.acceptingRequestIDs.isEmpty)
        #expect(store.unseenIncomingContactRequestCount == 0)
    }

    @Test func authManagerFacadeForwardsSessionAndContactState() {
        let manager = makeManager(transport: MockHTTPTransport { _ in
            HTTPFixtures.response(statusCode: 500)
        })
        let contact = ContactResponseBody(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com",
            remark: nil,
            createdAt: nil
        )

        manager.sessionStore.setSignedIn(Self.user)
        manager.serverStatus = .online
        manager.contacts = [contact]
        manager.unseenIncomingContactRequestCount = 2

        #expect(manager.sessionStore.authRouteState == .signedIn(Self.user, availability: .online))
        #expect(manager.sessionStore.serverStatus == .online)
        #expect(manager.contactStore.contacts == [contact])
        #expect(manager.contactStore.unseenIncomingContactRequestCount == 2)

        manager.sessionStore.profileMessage = "updated"
        manager.contactStore.setNotice("loaded", scope: .contactsHome, tone: .info)

        #expect(manager.profileMessage == "updated")
        #expect(manager.contactStore.notice(for: .contactsHome)?.message == "loaded")
        #expect(manager.currentUser == Self.user)
    }

    @Test func contactStoreNoticeScopesClearIndependently() {
        let store = ContactStore()
        store.setNotice("home", scope: .contactsHome, tone: .success)
        store.setNotice("requests", scope: .requests, tone: .error)

        #expect(store.notice(for: .contactsHome)?.message == "home")
        #expect(store.notice(for: .requests)?.tone == .error)

        store.clearNotice(scope: .contactsHome)

        #expect(store.notice(for: .contactsHome) == nil)
        #expect(store.notice(for: .requests)?.message == "requests")
    }

    @Test func contactStoreRefreshTTLUsesLastRefreshAt() {
        let store = ContactStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(store.shouldRefreshContactState(now: now))

        store.lastContactStateRefreshAt = now.addingTimeInterval(-59)
        #expect(store.shouldRefreshContactState(now: now) == false)

        store.lastContactStateRefreshAt = now.addingTimeInterval(-60)
        #expect(store.shouldRefreshContactState(now: now))
    }

    @Test func directRelationshipNoticesDoNotPolluteRequestNotices() {
        let store = ContactStore()
        store.setNotice("request", scope: .requests, tone: .info)
        store.setDirectRelationshipNotice(
            "conversation one",
            conversationID: "conversation-1",
            tone: .success,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        store.setDirectRelationshipNotice(
            "conversation two",
            conversationID: "conversation-2",
            tone: .error,
            createdAt: Date(timeIntervalSince1970: 1_800_000_001)
        )

        #expect(store.notice(for: .requests)?.message == "request")
        #expect(store.directRelationshipNotices["conversation-1"]?.message == "conversation one")
        #expect(store.directRelationshipNotices["conversation-2"]?.tone == .error)

        store.clearDirectRelationshipNotice(conversationID: "conversation-1")

        #expect(store.notice(for: .requests)?.message == "request")
        #expect(store.directRelationshipNotices["conversation-1"] == nil)
        #expect(store.directRelationshipNotices["conversation-2"]?.message == "conversation two")
    }

    private func contactRequest(
        id: UUID,
        requester: AuthUser,
        addressee: AuthUser,
        status: ContactRequestStatus,
        createdAt: Date,
        respondedAt: Date? = nil
    ) -> ContactRequestResponseBody {
        ContactRequestResponseBody(
            id: id,
            requester: requester,
            addressee: addressee,
            status: status,
            message: "hi",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: createdAt,
            updatedAt: respondedAt ?? createdAt,
            respondedAt: respondedAt
        )
    }

    private func contactRequestIsRelevant(_ request: ContactRequestResponseBody, currentUserID: UUID) -> Bool {
        request.requester.id == currentUserID || request.addressee.id == currentUserID
    }

    private func normalizeContactRequests(
        _ requests: [ContactRequestResponseBody],
        currentUserID: UUID
    ) -> [ContactRequestResponseBody] {
        requests.filter { contactRequestIsRelevant($0, currentUserID: currentUserID) }
    }

    private func sortPendingNewestFirst(
        _ lhs: ContactRequestResponseBody,
        _ rhs: ContactRequestResponseBody
    ) -> Bool {
        let leftDate = lhs.createdAt ?? .distantPast
        let rightDate = rhs.createdAt ?? .distantPast
        if leftDate == rightDate {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return leftDate > rightDate
    }
}
