import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

private extension IMTCPConnectionEvent {
    static func contactEvent(
        requestID: UUID?,
        payload: IMTCPContactEventPayload
    ) -> IMTCPConnectionEvent {
        .domainEvent(
            requestID: requestID,
            payload: IMTCPChatDomainEventPayload(
                eventID: UUID(),
                eventType: payload.domainEventType,
                aggregateType: "contact",
                aggregateID: payload.contactUserID
                    ?? payload.contact?.id
                    ?? payload.request?.id
                    ?? payload.actorUserID
                    ?? UUID(),
                aggregateSequence: 0,
                occurredAt: payload.serverTimestamp,
                actorUserID: payload.actorUserID,
                conversation: nil,
                body: .contactChanged(
                    request: payload.request,
                    contact: payload.contact,
                    contactUserID: payload.contactUserID
                )
            )
        )
    }
}

private extension IMTCPContactEventPayload {
    var domainEventType: IMTCPChatDomainEventType {
        switch eventType {
        case .friendRequestCreated:
            return .contactRequestCreated
        case .friendRequestAccepted:
            return .contactRequestAccepted
        case .friendRequestDeclined, .friendRequestCancelled, .contactRemoved:
            return .contactRequestUpdated
        }
    }
}

extension AuthManagerTests {
    @Test func contactEventsUpdateRequestsAndContactsInRealtime() async throws {
        let harness = IMConnectionTestHarness()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "aaaaaaaa-aaaa-bbbb-cccc-dddddddddddd")!
        let pendingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "hi",
            requesterRemark: "me",
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_200_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_200_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestCreated,
                    request: pendingRequest,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_200_001)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [requestID]
            }
        }

        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "Peer",
            createdAt: Date(timeIntervalSince1970: 1_700_200_002)
        )
        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestAccepted,
                    request: ContactRequestResponseBody(
                        id: requestID,
                        requester: peer,
                        addressee: Self.user,
                        status: .accepted,
                        message: "hi",
                        requesterRemark: "me",
                        addresseeRemark: "Peer",
                        createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                        updatedAt: Date(timeIntervalSince1970: 1_700_200_002),
                        respondedAt: Date(timeIntervalSince1970: 1_700_200_002)
                    ),
                    contact: contact,
                    contactUserID: nil,
                    actorUserID: Self.user.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_200_002)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.isEmpty && manager.contacts.map(\.id) == [peer.id]
            }
        }

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .contactRemoved,
                    request: nil,
                    contact: nil,
                    contactUserID: peer.id,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_200_003)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run { manager.contacts.isEmpty }
        }
    }


    @Test func imConnectionSyncsContactStateAfterConnection() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "Peer",
            createdAt: Date(timeIntervalSince1970: 1_700_210_000)
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "aaaaaaaa-2222-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "hi",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_210_001),
            updatedAt: Date(timeIntervalSince1970: 1_700_210_001),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [peer.id]
                    && manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
                    && manager.pendingIncomingContactRequestCount == 1
            }
        }
        try await Self.waitUntil {
            let contactCount = await requestCounter.count(for: "contacts")
            let contactRequestCount = await requestCounter.count(for: "contactRequests")
                return contactCount >= 1 && contactRequestCount >= 1
        }
    }


    @Test func completeContactEventDoesNotTriggerHTTPCorrection() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "aaaaaaaa-3333-bbbb-cccc-dddddddddddd")!
        let pendingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_220_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_220_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            let contactCount = await requestCounter.count(for: "contacts")
            let contactRequestCount = await requestCounter.count(for: "contactRequests")
            return contactCount >= 1 && contactRequestCount >= 1
        }
        let contactCount = await requestCounter.count(for: "contacts")
        let contactRequestCount = await requestCounter.count(for: "contactRequests")

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestCreated,
                    request: pendingRequest,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_220_001)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [requestID]
                    && manager.pendingIncomingContactRequestCount == 1
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await requestCounter.count(for: "contacts") == contactCount)
        #expect(await requestCounter.count(for: "contactRequests") == contactRequestCount)
    }


    @Test func acceptContactRequestMovesPendingIntoResolvedHistoryAndPersistsSnapshot() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "abababab-1111-2222-3333-444444444444")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "cdcdcdcd-1111-2222-3333-444444444444")!
        let pendingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "hi",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_225_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_225_000),
            respondedAt: nil
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "好友",
            createdAt: Date(timeIntervalSince1970: 1_700_225_010)
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/accept"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody(contact))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [requestID]
            }
        }

        let acceptResult = await manager.acceptContactRequestResult(id: requestID, remark: "peer")

        #expect(acceptResult.succeeded)
        #expect(manager.acceptingRequestIDs.isEmpty)
        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.isEmpty
                    && manager.recentResolvedContactRequests.map(\.id) == [requestID]
                    && manager.recentResolvedContactRequests.first?.status == .accepted
                    && manager.contacts.map(\.id) == [peer.id]
            }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.resolvedRequests.map(\.id) == [requestID]
                && snapshot?.resolvedRequests.first?.status == .accepted
        }
    }

    @Test func contactRequestResultUpdatesRequestsWithoutWritingNotices() async throws {
        let requestID = UUID(uuidString: "cdcdcdcd-9999-2222-3333-444444444444")!
        let peer = AuthUser(
            id: UUID(uuidString: "abababab-9999-2222-3333-444444444444")!,
            email: "peer@example.com"
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("POST", "/api/contact-requests"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        ContactRequestResponseBody(
                            id: requestID,
                            requester: Self.user,
                            addressee: peer,
                            status: .pending,
                            message: "hi",
                            requesterRemark: "remark",
                            addresseeRemark: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_226_000),
                            updatedAt: Date(timeIntervalSince1970: 1_700_226_000),
                            respondedAt: nil
                        )
                    )
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(transport: transport)

        await manager.login(email: Self.user.email, password: "password123")
        manager.contactStore.setNotice("request notice", scope: .requests, tone: .info)
        manager.contactStore.setNotice("form notice", scope: .form, tone: .warning)

        let result = await manager.sendContactRequestResult(email: peer.email, message: "hi", remark: "remark")

        #expect(result == .success("好友申请已发送。"))
        #expect(manager.contactRequests.map(\.id) == [requestID])
        #expect(manager.contactStore.notice(for: .requests)?.message == "request notice")
        #expect(manager.contactStore.notice(for: .form)?.message == "form notice")
        #expect(manager.contactStore.notice(for: .form)?.message == "form notice")
    }

    @Test func contactRequestResultFailureDoesNotWriteRequestNotice() async throws {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("POST", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 500)
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(transport: transport)

        await manager.login(email: Self.user.email, password: "password123")
        manager.contactStore.setNotice("request notice", scope: .requests, tone: .info)

        let result = await manager.sendContactRequestResult(email: "peer@example.com")

        #expect(result.succeeded == false)
        #expect(result.tone == .error)
        #expect(result.message.isEmpty == false)
        #expect(manager.contactStore.notice(for: .requests)?.message == "request notice")
    }

    @Test func cancelContactRequestMovesOutgoingPendingIntoResolvedHistory() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "abababab-5555-2222-3333-444444444444")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "cdcdcdcd-5555-2222-3333-444444444444")!
        let outgoingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: Self.user,
            addressee: peer,
            status: .pending,
            message: "hello",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_225_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_225_100),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([outgoingRequest]))
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/cancel"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        ContactRequestResponseBody(
                            id: requestID,
                            requester: Self.user,
                            addressee: peer,
                            status: .cancelled,
                            message: "hello",
                            requesterRemark: nil,
                            addresseeRemark: nil,
                            createdAt: outgoingRequest.createdAt,
                            updatedAt: Date(timeIntervalSince1970: 1_700_225_110),
                            respondedAt: Date(timeIntervalSince1970: 1_700_225_110)
                        )
                    )
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.outgoingContactRequests.map(\.id) == [requestID]
            }
        }

        let cancelResult = await manager.cancelContactRequestResult(id: requestID)

        #expect(cancelResult.succeeded)
        #expect(manager.cancellingRequestIDs.isEmpty)
        try await Self.waitUntil {
            await MainActor.run {
                manager.outgoingContactRequests.isEmpty
                    && manager.recentResolvedContactRequests.map(\.id) == [requestID]
                    && manager.recentResolvedContactRequests.first?.status == .cancelled
            }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.resolvedRequests.map(\.id) == [requestID]
                && snapshot?.resolvedRequests.first?.status == .cancelled
        }
    }


    @Test func incompleteContactEventTriggersHTTPCorrectionWithoutClearingCurrentState() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_230_000)
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "aaaaaaaa-4444-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_230_001),
            updatedAt: Date(timeIntervalSince1970: 1_700_230_001),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [peer.id]
                    && manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
            }
        }
        try await Self.waitUntil {
            let contactCount = await requestCounter.count(for: "contacts")
            let contactRequestCount = await requestCounter.count(for: "contactRequests")
            return contactCount >= 1 && contactRequestCount >= 1
        }
        let contactCount = await requestCounter.count(for: "contacts")
        let contactRequestCount = await requestCounter.count(for: "contactRequests")
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.contacts.map(\.id) == [peer.id]
                && snapshot?.incomingRequests.map(\.id) == [pendingRequest.id]
        }
        let saveCount = await contactCache.saveCount(for: Self.user.id)

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .contactRemoved,
                    request: nil,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_230_002)
                )
            )
        )

        #expect(manager.contacts.map(\.id) == [peer.id])
        try await Self.waitUntil {
            let latestContactCount = await requestCounter.count(for: "contacts")
            let latestContactRequestCount = await requestCounter.count(for: "contactRequests")
            return latestContactCount > contactCount && latestContactRequestCount > contactRequestCount
        }
        #expect(manager.contacts.map(\.id) == [peer.id])
        #expect(manager.incomingContactRequests.map(\.id) == [pendingRequest.id])
        #expect(await contactCache.saveCount(for: Self.user.id) == saveCount)
    }


    @Test func loginRestoresContactCacheBeforeNetworkOverrides() async throws {
        let harness = IMConnectionTestHarness()
        let restoreGate = RestoreGate()
        let contactCache = InMemoryContactStateCache()
        let cachedPeer = AuthUser(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            email: "cached@example.com"
        )
        let networkPeer = AuthUser(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            email: "network@example.com"
        )
        let cachedRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            requester: cachedPeer,
            addressee: Self.user,
            status: .pending,
            message: "cached",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_240_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_240_000),
            respondedAt: nil
        )
        let networkRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            requester: networkPeer,
            addressee: Self.user,
            status: .pending,
            message: "network",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_240_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_240_100),
            respondedAt: nil
        )
        await contactCache.seed(
            ContactStateCacheSnapshot(
                contacts: [
                    CachedContactState(
                        id: cachedPeer.id,
                        email: cachedPeer.email,
                        remark: "缓存联系人",
                        createdAt: Date(timeIntervalSince1970: 1_700_239_999)
                    )
                ],
                incomingRequests: [CachedContactRequestState(cachedRequest)],
                outgoingRequests: [],
                resolvedRequests: [],
                lastRefreshAt: Date(timeIntervalSince1970: 1_700_240_000),
                lastSeenIncomingContactRequestAt: cachedRequest.createdAt
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await restoreGate.markStarted()
                await restoreGate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([
                        ContactResponseBody(
                            id: networkPeer.id,
                            email: networkPeer.email,
                            remark: "网络联系人",
                            createdAt: Date(timeIntervalSince1970: 1_700_240_100)
                        )
                    ])
                )
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([networkRequest])
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await restoreGate.waitUntilStarted()

        #expect(manager.contacts.map(\.id) == [cachedPeer.id])
        #expect(manager.incomingContactRequests.map(\.id) == [cachedRequest.id])
        #expect(manager.pendingIncomingContactRequestCount == 1)
        #expect(manager.unseenIncomingContactRequestCount == 0)
        #expect(manager.hasUnreadIncomingContactRequests == false)

        await restoreGate.resume()

        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [networkPeer.id]
                    && manager.incomingContactRequests.map(\.id) == [networkRequest.id]
                    && manager.pendingIncomingContactRequestCount == 1
                    && manager.unseenIncomingContactRequestCount == 1
            }
        }
    }


    @Test func contactEventPersistsPendingRequestForColdStartReplay() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-5555-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-5555-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "hi",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_250_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_250_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.isEmpty && manager.incomingContactRequests.isEmpty
                    && manager.imConnectionStatus == .connected
            }
        }

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestCreated,
                    request: pendingRequest,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_250_001)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
                    && manager.unseenIncomingContactRequestCount == 1
            }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.incomingRequests.map(\.id) == [pendingRequest.id]
        }
    }


    @Test func markIncomingContactRequestsSeenClearsUnreadAndPersistsSeenTimestamp() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-9999-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-9999-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_290_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_290_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
                    && manager.unseenIncomingContactRequestCount == 1
                    && manager.hasUnreadIncomingContactRequests
            }
        }

        await MainActor.run {
            manager.markIncomingContactRequestsSeen()
        }

        #expect(manager.unseenIncomingContactRequestCount == 0)
        #expect(manager.hasUnreadIncomingContactRequests == false)
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.lastSeenIncomingContactRequestAt == pendingRequest.createdAt
        }
    }


    @Test func frozenDirectConversationShowsUnavailableUntilPeerLoads() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let peerID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                        memberUserIDs: [Self.user.id, peerID]
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        manager.imConversationStore.replaceConversationSummaries([
            IMConversationSummaryResponseBody(
                id: conversationID,
                title: "服务端会话",
                kind: IMConversationKind.direct.rawValue,
                directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                memberUserIDs: [Self.user.id, peerID],
                lastMessage: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
            )
        ])
        manager.imConversationStore.openConversation(id: conversationID.uuidString)
        manager.imConversationStore.setLoadingMembers(true)

        let unavailable = manager.directPeerRelationshipPresentation(for: conversationID.uuidString)
        #expect(unavailable?.state == .unavailable)
        #expect(unavailable?.message == "正在加载对方信息…")

        manager.imConversationStore.replaceMembers(
            in: conversationID.uuidString,
            members: [
                IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email),
                IMConversationMemberResponseBody(id: peerID, email: "peer@example.com")
            ]
        )
        manager.imConversationStore.setLoadingMembers(false)

        #expect(
            manager.directPeerRelationshipPresentation(for: conversationID.uuidString)?.state
                == DirectPeerRelationshipState.none
        )
    }


    @Test func sendDirectConversationFriendRequestMovesFrozenConversationToOutgoingPending() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let peer = AuthUser(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                        memberUserIDs: [Self.user.id, peer.id],
                        directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/contact-requests"):
                let body = try JSONDecoder().decode(
                    ContactRequestCreateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                #expect(body.email == peer.email)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        ContactRequestResponseBody(
                            id: requestID,
                            requester: Self.user,
                            addressee: peer,
                            status: .pending,
                            message: body.message,
                            requesterRemark: body.remark,
                            addresseeRemark: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_260_000),
                            updatedAt: Date(timeIntervalSince1970: 1_700_260_000),
                            respondedAt: nil
                        )
                    )
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        manager.imConversationStore.replaceConversationSummaries([
            IMConversationSummaryResponseBody(
                id: conversationID,
                title: "服务端会话",
                kind: IMConversationKind.direct.rawValue,
                directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email),
                memberUserIDs: [Self.user.id, peer.id],
                lastMessage: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
            )
        ])
        manager.imConversationStore.openConversation(id: conversationID.uuidString)
        manager.contactStore.setNotice("request notice", scope: .requests, tone: .info)
        manager.contactStore.setNotice("form notice", scope: .form, tone: .warning)

        let sendResult = await manager.sendDirectConversationFriendRequestResult(conversationID: conversationID.uuidString)

        #expect(sendResult.succeeded)
        #expect(manager.contactStore.notice(for: .requests)?.message == "request notice")
        #expect(manager.contactStore.notice(for: .form)?.message == "form notice")
        #expect(manager.contactStore.notice(for: .form)?.message == "form notice")
        #expect(manager.directRelationshipNotice(for: conversationID.uuidString)?.message == "好友申请已发送。")
        #expect(manager.contactStore.directRelationshipNotices[conversationID.uuidString]?.tone == .success)
        #expect(manager.directPeerRelationshipPresentation(for: conversationID.uuidString)?.state == .outgoingPending)
    }


    @Test func acceptDirectConversationFriendRequestMovesFrozenConversationToFriendState() async throws {
        let harness = IMConnectionTestHarness()
        let mutationState = IMConversationMutationState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let peer = AuthUser(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "好友",
            createdAt: Date(timeIntervalSince1970: 1_700_260_100)
        )
        let incomingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "add me",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_260_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_260_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                let contacts = await mutationState.isMutated() ? [contact] : [ContactResponseBody]()
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody(contacts))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([incomingRequest]))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                        memberUserIDs: [Self.user.id, peer.id],
                        directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/accept"):
                await mutationState.markMutated()
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody(contact))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        manager.imConversationStore.replaceConversationSummaries([
            IMConversationSummaryResponseBody(
                id: conversationID,
                title: "服务端会话",
                kind: IMConversationKind.direct.rawValue,
                directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email),
                memberUserIDs: [Self.user.id, peer.id],
                lastMessage: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
            )
        ])
        manager.imConversationStore.openConversation(id: conversationID.uuidString)
        manager.contactRequests = []
        manager.contactStore.setNotice("request notice", scope: .requests, tone: .info)
        manager.contactStore.setNotice("form notice", scope: .form, tone: .warning)

        let acceptResult = await manager.acceptDirectConversationFriendRequestResult(conversationID: conversationID.uuidString)

        #expect(acceptResult.succeeded)
        #expect(manager.contactStore.notice(for: .requests)?.message == "request notice")
        #expect(manager.contactStore.notice(for: .form)?.message == "form notice")
        #expect(manager.contactStore.notice(for: .form)?.message == "form notice")
        #expect(manager.directRelationshipNotice(for: conversationID.uuidString)?.message == "已添加好友。")
        #expect(manager.contactStore.directRelationshipNotices[conversationID.uuidString]?.tone == .success)
        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [peer.id]
                    && manager.directPeerRelationshipPresentation(for: conversationID.uuidString)?.state == .friend
            }
        }
    }

    @Test func declineAndCancelDirectConversationFriendRequestsDoNotPolluteRequestNotices() async throws {
        let incomingConversationID = UUID(uuidString: "aaaaaaaa-2222-2222-3333-bbbbbbbbbbbb")!
        let outgoingConversationID = UUID(uuidString: "aaaaaaaa-3333-2222-3333-bbbbbbbbbbbb")!
        let incomingPeer = AuthUser(
            id: UUID(uuidString: "44444444-5555-4444-4444-444444444444")!,
            email: "incoming@example.com"
        )
        let outgoingPeer = AuthUser(
            id: UUID(uuidString: "55555555-5555-4444-4444-444444444444")!,
            email: "outgoing@example.com"
        )
        let incomingRequestID = UUID(uuidString: "cccccccc-2222-2222-3333-dddddddddddd")!
        let outgoingRequestID = UUID(uuidString: "cccccccc-3333-2222-3333-dddddddddddd")!
        let incomingRequest = ContactRequestResponseBody(
            id: incomingRequestID,
            requester: incomingPeer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_260_200),
            updatedAt: Date(timeIntervalSince1970: 1_700_260_200),
            respondedAt: nil
        )
        let outgoingRequest = ContactRequestResponseBody(
            id: outgoingRequestID,
            requester: Self.user,
            addressee: outgoingPeer,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_260_300),
            updatedAt: Date(timeIntervalSince1970: 1_700_260_300),
            respondedAt: nil
        )
        let conversationSummaries = [
            IMConversationSummaryResponseBody(
                id: incomingConversationID,
                title: "收到申请会话",
                kind: IMConversationKind.direct.rawValue,
                directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                directPeer: IMDirectPeerResponseBody(id: incomingPeer.id, email: incomingPeer.email),
                memberUserIDs: [Self.user.id, incomingPeer.id],
                lastMessage: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
            ),
            IMConversationSummaryResponseBody(
                id: outgoingConversationID,
                title: "发出申请会话",
                kind: IMConversationKind.direct.rawValue,
                directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                directPeer: IMDirectPeerResponseBody(id: outgoingPeer.id, email: outgoingPeer.email),
                memberUserIDs: [Self.user.id, outgoingPeer.id],
                lastMessage: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
            )
        ]
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([incomingRequest, outgoingRequest])
                )
            case ("GET", "/api/blocks"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([UserBlockResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: conversationSummaries,
                        nextCursor: nil,
                        hasMore: false,
                        snapshotToken: "snapshot-direct-contact-actions"
                    )
                )
            case ("POST", "/api/contact-requests/\(incomingRequestID.uuidString)/decline"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(ContactRequestResponseBody(
                        id: incomingRequest.id,
                        requester: incomingRequest.requester,
                        addressee: incomingRequest.addressee,
                        status: .declined,
                        message: incomingRequest.message,
                        requesterRemark: incomingRequest.requesterRemark,
                        addresseeRemark: incomingRequest.addresseeRemark,
                        createdAt: incomingRequest.createdAt,
                        updatedAt: Date(timeIntervalSince1970: 1_700_260_400),
                        respondedAt: Date(timeIntervalSince1970: 1_700_260_400)
                    ))
                )
            case ("POST", "/api/contact-requests/\(outgoingRequestID.uuidString)/cancel"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(ContactRequestResponseBody(
                        id: outgoingRequest.id,
                        requester: outgoingRequest.requester,
                        addressee: outgoingRequest.addressee,
                        status: .cancelled,
                        message: outgoingRequest.message,
                        requesterRemark: outgoingRequest.requesterRemark,
                        addresseeRemark: outgoingRequest.addresseeRemark,
                        createdAt: outgoingRequest.createdAt,
                        updatedAt: Date(timeIntervalSince1970: 1_700_260_500),
                        respondedAt: Date(timeIntervalSince1970: 1_700_260_500)
                    ))
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(transport: transport, wrapDefaultIMResponses: false)

        await manager.login(email: Self.user.email, password: "password123")
        manager.imConversationStore.replaceConversationSummaries(conversationSummaries)
        manager.contactRequests = [incomingRequest, outgoingRequest]
        try await Self.waitUntil {
            await MainActor.run {
                Set(manager.contactRequests.map(\.id)) == Set([incomingRequestID, outgoingRequestID])
            }
        }
        manager.contactStore.setNotice("request notice", scope: .requests, tone: .info)
        manager.contactStore.setNotice("form notice", scope: .form, tone: .warning)

        let declineResult = await manager.declineDirectConversationFriendRequestResult(conversationID: incomingConversationID.uuidString)
        let cancelResult = await manager.cancelDirectConversationFriendRequestResult(conversationID: outgoingConversationID.uuidString)

        #expect(declineResult.succeeded)
        #expect(cancelResult.succeeded)
        #expect(manager.contactStore.notice(for: .requests)?.message == "request notice")
        #expect(manager.contactStore.notice(for: .form)?.message == "form notice")
        #expect(manager.directRelationshipNotice(for: incomingConversationID.uuidString)?.message == "已拒绝好友申请。")
        #expect(manager.directRelationshipNotice(for: outgoingConversationID.uuidString)?.message == "好友申请已取消。")
        #expect(manager.contactStore.directRelationshipNotices[incomingConversationID.uuidString]?.tone == .success)
        #expect(manager.contactStore.directRelationshipNotices[outgoingConversationID.uuidString]?.tone == .success)
    }


    @Test func directConversationIdentityPresentationPrefersContactRemarkOverPeerEmail() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "99999999-1111-2222-3333-bbbbbbbbbbbb")!
        let peer = AuthUser(
            id: UUID(uuidString: "88888888-4444-4444-4444-444444444444")!,
            email: "peer@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "备注好友",
            createdAt: Date(timeIntervalSince1970: 1_700_261_000)
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        memberUserIDs: [Self.user.id, peer.id],
                        directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.map { $0.id } == [conversationID.uuidString]
            }
        }

        let identity = manager.conversationIdentityPresentation(for: conversationID.uuidString)
        #expect(identity?.title == "备注好友")
        #expect(identity?.detailSummary == peer.email)
        #expect(identity?.rowSecondaryLabel == peer.email)
    }


    @Test func directConversationIdentityPresentationFallsBackToPeerEmailWithoutContactRemark() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "77777777-1111-2222-3333-bbbbbbbbbbbb")!
        let peer = AuthUser(
            id: UUID(uuidString: "66666666-4444-4444-4444-444444444444")!,
            email: "peer@example.com"
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        memberUserIDs: [Self.user.id, peer.id],
                        directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.map { $0.id } == [conversationID.uuidString]
            }
        }

        let identity = manager.conversationIdentityPresentation(for: conversationID.uuidString)
        #expect(identity?.title == peer.email)
        #expect(identity?.detailSummary == peer.email)
        #expect(identity?.rowSecondaryLabel == nil)
    }


    @Test func seenIncomingRequestsStayReadAfterCorrectionUntilNewerRequestArrives() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-abcd-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let oldRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-abcd-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_300_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_300_000),
            respondedAt: nil
        )
        let newRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "cccccccc-abcd-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "new",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_300_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_300_100),
            respondedAt: nil
        )
        await contactCache.seed(
            ContactStateCacheSnapshot(
                contacts: [],
                incomingRequests: [CachedContactRequestState(oldRequest)],
                outgoingRequests: [],
                resolvedRequests: [],
                lastRefreshAt: Date(timeIntervalSince1970: 1_700_300_010),
                lastSeenIncomingContactRequestAt: oldRequest.createdAt
            ),
            for: Self.user.id
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([oldRequest]))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [oldRequest.id]
                    && manager.unseenIncomingContactRequestCount == 0
            }
        }
        let baselineCorrectionCount = await requestCounter.count(for: "contactRequests")

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .contactRemoved,
                    request: nil,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_300_050)
                )
            )
        )

        try await Self.waitUntil {
            let latestCorrectionCount = await requestCounter.count(for: "contactRequests")
            return latestCorrectionCount > baselineCorrectionCount
        }
        #expect(manager.unseenIncomingContactRequestCount == 0)

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestCreated,
                    request: newRequest,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_300_101)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [newRequest.id, oldRequest.id]
                    && manager.unseenIncomingContactRequestCount == 1
            }
        }
    }


    @Test func contactRemovedEventUpdatesPersistedContactSnapshot() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-6666-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "旧联系人",
            createdAt: Date(timeIntervalSince1970: 1_700_260_000)
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.contacts.map(\.id) == [peer.id] }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.contacts.map(\.id) == [peer.id]
        }

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .contactRemoved,
                    request: nil,
                    contact: nil,
                    contactUserID: peer.id,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_260_100)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run { manager.contacts.isEmpty }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.contacts.isEmpty == true
        }
    }


    @Test func contactCacheRestoreFailureFallsBackToNetworkStartup() async throws {
        let harness = IMConnectionTestHarness()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-7777-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-7777-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_270_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_270_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([
                        ContactResponseBody(
                            id: peer.id,
                            email: peer.email,
                            remark: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_270_000)
                        )
                    ])
                )
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(FailingLoadContactStateCache()),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [peer.id]
                    && manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
                    && manager.pendingIncomingContactRequestCount == 1
            }
        }
    }


    @Test func logoutClearsCurrentUsersContactCache() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-8888-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-8888-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_280_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_280_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("POST", "/api/auth/logout"):
                return HTTPFixtures.response(statusCode: 204)
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([
                        ContactResponseBody(
                            id: peer.id,
                            email: peer.email,
                            remark: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_280_000)
                        )
                    ])
                )
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.contacts.map(\.id) == [peer.id]
                && snapshot?.incomingRequests.map(\.id) == [pendingRequest.id]
        }

        await manager.logout()

        #expect(await contactCache.latestSnapshot(for: Self.user.id) == nil)
    }

    @Test func blockUserRemovesContactFromLocalStore() async throws {
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-9999-bbbb-cccc-dddddddddddd")!,
            email: "blocked@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            displayName: "Blocked User",
            avatarPreset: nil,
            remark: "将被拉黑",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/blocks"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([UserBlockResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("POST", "/api/users/\(peer.id.uuidString)/block"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        UserBlockResponseBody(
                            blockedUserID: peer.id,
                            reason: nil,
                            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
                        )
                    )
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(transport: transport, wrapDefaultIMResponses: false)

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.contacts.map(\.id) == [peer.id] }
        }
        manager.contactStore.setNotice("home", scope: .contactsHome, tone: .info)

        let blockResult = await manager.blockUserResult(peer.id)

        #expect(blockResult.succeeded)
        #expect(blockResult.message == "已拉入黑名单。")
        #expect(manager.contactStore.notice(for: .contactsHome)?.message == "home")
        #expect(manager.contacts.isEmpty)
        #expect(manager.blockedUsers.map(\.blockedUserID) == [peer.id])
        #expect(manager.contactStore.knownUserDisplay(for: peer.id)?.displayName == "将被拉黑")
    }

}
