import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

extension AuthManagerTests {
    @Test func addIMConversationMembersRefreshesSummaryAndMembers() async throws {
        let mutationState = IMConversationMutationState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let summary = IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "服务端群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: await mutationState.isMutated() ? 3 : 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: [summary],
                        nextCursor: nil,
                        hasMore: false,
                        snapshotToken: "snapshot-\(conversationID.uuidString.lowercased())"
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                let members = await mutationState.isMutated()
                    ? [
                        IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                            email: "peer@example.com"
                        ),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                            email: "new@example.com"
                        )
                    ]
                    : [
                        IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                            email: "peer@example.com"
                        )
                    ]
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersPageBody(members)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/members"):
                let payload = try JSONDecoder().decode(
                    IMConversationMemberUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                #expect(payload.memberEmails == ["new@example.com"])
                await mutationState.markMutated()
                let updatedSummary = IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "服务端群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.user.id],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_100)
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(updatedSummary)
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.id == conversationID.uuidString
                    && manager.imConversationStore.selectedConversation?.memberCount == 2
                    && manager.imConversationStore.selectedConversation?.members.count == 2
            }
        }

        let didAdd = await manager.addIMConversationMembers(
            to: conversationID.uuidString,
            memberEmails: ["  NEW@example.com  ", "new@example.com"]
        )

        #expect(didAdd)
        #expect(manager.imConversationStore.selectedConversation?.kind == .group)
        #expect(manager.imConversationStore.selectedConversation?.memberCount == 3)
        #expect(manager.imConversationStore.selectedConversation?.members.map(\.email).sorted() == [
            "manager@example.com",
            "new@example.com",
            "peer@example.com"
        ])
    }



    @Test func leaveIMConversationRemovesCurrentConversationAndFallsBackToListSelection() async throws {
        let mutationState = IMConversationMutationState()
        let currentConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let summaries = await mutationState.isMutated()
                    ? [
                        IMConversationSummaryResponseBody(
                            id: fallbackConversationID,
                            title: "剩余会话",
                            kind: IMConversationKind.direct.rawValue,
                            memberCount: 2,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
                        )
                    ]
                    : [
                        IMConversationSummaryResponseBody(
                            id: currentConversationID,
                            title: "当前群聊",
                            kind: IMConversationKind.group.rawValue,
                            memberCount: 3,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
                        ),
                        IMConversationSummaryResponseBody(
                            id: fallbackConversationID,
                            title: "剩余会话",
                            kind: IMConversationKind.direct.rawValue,
                            memberCount: 2,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
                        )
                    ]
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: summaries,
                        nextCursor: nil,
                        hasMore: false,
                        snapshotToken: "snapshot-\(currentConversationID.uuidString.lowercased())"
                    )
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", "/api/im/conversations/\(currentConversationID.uuidString)/leave"):
                await mutationState.markMutated()
                return HTTPFixtures.response(statusCode: 200, body: Data())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == currentConversationID.uuidString
                    && manager.imConversationStore.conversations.count == 2
            }
        }

        let didLeave = await manager.leaveIMConversation(currentConversationID.uuidString)

        #expect(didLeave)
        #expect(manager.imConversationStore.conversations.count == 1)
        #expect(manager.imConversationStore.conversations.first?.id == fallbackConversationID.uuidString)
        #expect(manager.imConversationStore.selectedConversationID == fallbackConversationID.uuidString)
    }



    @Test func conversationRemovedForSelfEventRemovesCurrentSelectionWithoutSummaryRefresh() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let currentConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                await requestCounter.increment("conversations")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: [
                            IMConversationSummaryResponseBody(
                                id: currentConversationID,
                                title: "Current",
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                                updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                            ),
                            IMConversationSummaryResponseBody(
                                id: fallbackConversationID,
                                title: "Fallback",
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                            )
                        ],
                        nextCursor: nil,
                        hasMore: false,
                        snapshotToken: "snapshot-conversation-removal"
                    )
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: currentConversationID)
                )
            case ("POST", "/api/im/conversations/\(currentConversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages/since", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == currentConversationID.uuidString
                    && manager.imConnectionStatus == .connected
            }
        }

        let initialConversationRequests = await requestCounter.count(for: "conversations")
        await harness.yield(
            .conversationEvent(
                requestID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                payload: IMTCPConversationEventPayload(
                    eventType: .conversationRemovedForSelf,
                    conversation: IMConversationSummaryResponseBody(
                        id: currentConversationID,
                        title: "Current",
                        memberUserIDs: [Self.user.id],
                        lastMessage: nil,
                        createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                        updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                    ),
                    actorUserID: Self.user.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_400_000)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == fallbackConversationID.uuidString
                    && manager.imConversationStore.conversations.count == 1
            }
        }

        #expect(await requestCounter.count(for: "conversations") == initialConversationRequests)
        #expect(manager.imConversationStore.conversations.first?.id == fallbackConversationID.uuidString)
    }



    @Test func reconnectIMConnectionSyncsConversationGap() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let summarySequenceState = IMSummarySequenceState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: await summarySequenceState.currentLatestServerSequence()
                    )
                )
            case ("GET", "/api/im/conversations/changes", _):
                let latestSequence = await summarySequenceState.currentLatestServerSequence()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationChangesBody(
                        upserts: [
                            Self.imConversationSummary(
                                id: conversationID,
                                latestServerSequence: latestSequence,
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(latestSequence - 1)),
                                title: latestSequence == 1 ? "来自历史接口" : "服务端摘要更新"
                            )
                        ],
                        targetToken: "snapshot-\(conversationID.uuidString.lowercased())-\(latestSequence)"
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSinceBody(conversationID: conversationID)
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        await summarySequenceState.setLatestServerSequence(1)
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await manager.reloadIMConversations(force: true)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == conversationID.uuidString
            }
        }

        await summarySequenceState.setLatestServerSequence(2)
        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 2
                    && manager.imConversationStore.selectedConversation?.messages.last?.text == "来自补洞接口"
                    && manager.imConnectionStatus == .connected
            }
        }

        #expect(await gapCounter.currentValue() >= 1)
    }



    @Test func openIMConversationSyncsGapForLoadedConversation() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSinceBody(conversationID: conversationID)
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        await manager.openIMConversation(conversationID.uuidString)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 2
                    && manager.imConversationStore.selectedConversation?.messages.last?.text == "来自补洞接口"
            }
        }

        #expect(await gapCounter.currentValue() >= 1)
    }



    @Test func gapSyncFailureDoesNotClearLoadedMessages() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                throw URLError(.timedOut)
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        await manager.openIMConversation(conversationID.uuidString)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.sessionStore.authRouteState == .signedIn(Self.user, availability: .offline(message: "请求超时，请稍后重试。")))
        #expect(manager.currentUser?.id == Self.user.id)
        #expect(manager.imConversationStore.selectedConversation?.messages.count == 1)
        #expect(manager.imConversationStore.selectedConversation?.messages.first?.text == "来自历史接口")
        #expect(manager.imConversationStore.statusMessage == "请求超时，请稍后重试。")
        #expect(manager.serverStatus == .offline(message: "请求超时，请稍后重试。"))
    }



    @Test func reconnectIMConnectionLoopsGapSyncUntilFullyCaughtUp() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let summarySequenceState = IMSummarySequenceState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: await summarySequenceState.currentLatestServerSequence()
                    )
                )
            case ("GET", "/api/im/conversations/changes", _):
                let latestSequence = await summarySequenceState.currentLatestServerSequence()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationChangesBody(
                        upserts: [
                            Self.imConversationSummary(
                                id: conversationID,
                                latestServerSequence: latestSequence,
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(latestSequence - 1)),
                                title: latestSequence == 1 ? "来自历史接口" : "服务端摘要更新"
                            )
                        ],
                        targetToken: "snapshot-\(conversationID.uuidString.lowercased())-\(latestSequence)"
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSincePageBody(
                        conversationID: conversationID,
                        messages: [
                            IMConversationMessageResponseBody(
                                id: UUID(uuidString: "ffffffff-1111-2222-3333-eeeeeeeeeeee")!,
                                conversationID: conversationID,
                                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                clientMessageID: "client-gap-2",
                                serverSequence: 2,
                                kind: "rich_text",
                                body: ["text": "gap-2"],
                                createdAt: Date(timeIntervalSince1970: 1_700_001_100)
                            )
                        ],
                        hasMore: true,
                        nextAfterSequence: 2
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=2&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSincePageBody(
                        conversationID: conversationID,
                        messages: [
                            IMConversationMessageResponseBody(
                                id: UUID(uuidString: "aaaaaaaa-9999-2222-3333-eeeeeeeeeeee")!,
                                conversationID: conversationID,
                                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                clientMessageID: "client-gap-3",
                                serverSequence: 3,
                                kind: "rich_text",
                                body: ["text": "gap-3"],
                                createdAt: Date(timeIntervalSince1970: 1_700_001_200)
                            )
                        ],
                        hasMore: false,
                        nextAfterSequence: 3
                    )
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        await summarySequenceState.setLatestServerSequence(1)
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await manager.reloadIMConversations(force: true)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == conversationID.uuidString
            }
        }
        await summarySequenceState.setLatestServerSequence(3)
        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["来自历史接口", "gap-2", "gap-3"]
            }
        }

        #expect(await gapCounter.currentValue() >= 2)
        #expect(manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == [1, 2, 3])
    }



    @Test func reconnectIMConnectionSkipsGapSyncWhenSummarySequenceIsNotAhead() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                await requestCounter.increment("conversations")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/changes", _):
                await requestCounter.increment("conversations")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyConversationChangesBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                await requestCounter.increment("members")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                await requestCounter.increment("messages")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await requestCounter.increment("messagesSince")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMessagesSinceBody()
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await manager.reloadIMConversations(force: true)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == conversationID.uuidString
            }
        }
        try await Self.waitUntil {
            await requestCounter.count(for: "markRead") >= 1
        }

        let initialConversationRequests = await requestCounter.count(for: "conversations")
        let initialMemberRequests = await requestCounter.count(for: "members")
        let initialMessageRequests = await requestCounter.count(for: "messages")
        let initialMarkReadRequests = await requestCounter.count(for: "markRead")

        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            let isConnected = await MainActor.run { manager.imConnectionStatus == .connected }
            let didRefreshSummaries = await requestCounter.count(for: "conversations") > initialConversationRequests
            return isConnected && didRefreshSummaries
        }

        #expect(await requestCounter.count(for: "messagesSince") == 0)
        #expect(await requestCounter.count(for: "markRead") == initialMarkReadRequests)
        #expect(await requestCounter.count(for: "members") == initialMemberRequests)
        #expect(await requestCounter.count(for: "messages") == initialMessageRequests)
    }



    @Test func loginGapSyncContinuesBackgroundBackfillBeyondSingleBatchBudget() async throws {
        let harness = IMConnectionTestHarness()
        let gate = RestoreGate()
        let requestCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: 12
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                guard let afterSequence = Self.afterSequence(from: request) else {
                    Issue.record("缺少 afterSequence 查询参数")
                    return HTTPFixtures.response(statusCode: 500)
                }

                switch afterSequence {
                case 1...10:
                    let nextSequence = afterSequence + 1
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: nextSequence)],
                            hasMore: true,
                            nextAfterSequence: nextSequence
                        )
                    )
                case 11:
                    await gate.markStarted()
                    await gate.waitForResume()
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: 12)],
                            hasMore: false,
                            nextAfterSequence: 12
                        )
                    )
                default:
                    Issue.record("收到未预期 afterSequence: \(afterSequence)")
                    return HTTPFixtures.response(statusCode: 500)
                }
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
        await manager.reloadIMConversations(force: true)
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }
        let openTask = Task {
            await manager.openIMConversation(conversationID.uuidString)
        }
        try await Self.waitUntil {
            await gate.started()
        }
        try await Self.waitUntil {
            let contactsLoaded = await requestCounter.count(for: "contacts") > 0
            return await MainActor.run {
                contactsLoaded
                    && manager.imConnectionStatus == .connected
                    && manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == Array(1...11).map(UInt64.init)
            }
        }

        await gate.resume()
        await openTask.value
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == Array(1...12).map(UInt64.init)
            }
        }
    }



    @Test func loginGapSyncAdvancesSelectedConversationReadSequenceBatchByBatch() async throws {
        let harness = IMConnectionTestHarness()
        let gate = RestoreGate()
        let readRecorder = IMReadSequenceRecorder()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: 12
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                let payload = try JSONDecoder().decode(
                    IMConversationReadRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                await readRecorder.record(payload.readSequence)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(
                        conversationID: conversationID,
                        lastReadSequence: Int(payload.readSequence)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                guard let afterSequence = Self.afterSequence(from: request) else {
                    Issue.record("缺少 afterSequence 查询参数")
                    return HTTPFixtures.response(statusCode: 500)
                }

                switch afterSequence {
                case 1...10:
                    let nextSequence = afterSequence + 1
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: nextSequence)],
                            hasMore: true,
                            nextAfterSequence: nextSequence
                        )
                    )
                case 11:
                    await gate.markStarted()
                    await gate.waitForResume()
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: 12)],
                            hasMore: false,
                            nextAfterSequence: 12
                        )
                    )
                default:
                    Issue.record("收到未预期 afterSequence: \(afterSequence)")
                    return HTTPFixtures.response(statusCode: 500)
                }
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
        await manager.reloadIMConversations(force: true)
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }
        let openTask = Task {
            await manager.openIMConversation(conversationID.uuidString)
        }
        try await Self.waitUntil {
            await gate.started()
        }
        try await Self.waitUntil {
            let sequences = await readRecorder.allSequences()
            return await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 11
                    && sequences.contains(11)
                    && sequences.last == 11
            }
        }

        await gate.resume()
        await openTask.value
        try await Self.waitUntil {
            let sequences = await readRecorder.allSequences()
            return await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 12
                    && sequences.contains(11)
                    && sequences.last == 12
            }
        }
    }



    @Test func backgroundGapSyncFailureKeepsMergedMessagesAndMarksServerOffline() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: 12
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                guard let afterSequence = Self.afterSequence(from: request) else {
                    Issue.record("缺少 afterSequence 查询参数")
                    return HTTPFixtures.response(statusCode: 500)
                }

                switch afterSequence {
                case 1...10:
                    let nextSequence = afterSequence + 1
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: nextSequence)],
                            hasMore: true,
                            nextAfterSequence: nextSequence
                        )
                    )
                case 11:
                    throw URLError(.timedOut)
                default:
                    Issue.record("收到未预期 afterSequence: \(afterSequence)")
                    return HTTPFixtures.response(statusCode: 500)
                }
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
        await manager.reloadIMConversations(force: true)
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }
        await manager.openIMConversation(conversationID.uuidString)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == Array(1...11).map(UInt64.init)
                    && manager.imConversationStore.statusMessage == "请求超时，请稍后重试。"
                    && manager.serverStatus == .offline(message: "请求超时，请稍后重试。")
            }
        }
    }



    @Test func logoutCancelsBackgroundGapSyncAndPreventsLateMutation() async throws {
        let harness = IMConnectionTestHarness()
        let gate = RestoreGate()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("DELETE", "/api/auth/sessions/current"):
                return HTTPFixtures.response(statusCode: 200)
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: 12
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                guard let afterSequence = Self.afterSequence(from: request) else {
                    Issue.record("缺少 afterSequence 查询参数")
                    return HTTPFixtures.response(statusCode: 500)
                }

                switch afterSequence {
                case 1...10:
                    let nextSequence = afterSequence + 1
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: nextSequence)],
                            hasMore: true,
                            nextAfterSequence: nextSequence
                        )
                    )
                case 11:
                    await gate.markStarted()
                    await gate.waitForResume()
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: 12)],
                            hasMore: false,
                            nextAfterSequence: 12
                        )
                    )
                default:
                    Issue.record("收到未预期 afterSequence: \(afterSequence)")
                    return HTTPFixtures.response(statusCode: 500)
                }
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
        await manager.reloadIMConversations(force: true)
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }
        let openTask = Task {
            await manager.openIMConversation(conversationID.uuidString)
        }
        try await Self.waitUntil {
            await gate.started()
        }
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 11
            }
        }

        await manager.logout()
        #expect(manager.sessionStore.authRouteState == .signedOut(nil))
        #expect(manager.imConversationStore.conversations.isEmpty)

        await gate.resume()
        await openTask.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.sessionStore.authRouteState == .signedOut(nil))
        #expect(manager.imConversationStore.conversations.isEmpty)
    }



    @Test func loginBootstrapAppliesServerUnreadCountToBackgroundConversationSummary() async throws {
        let harness = IMConnectionTestHarness()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: [
                            IMConversationSummaryResponseBody(
                                id: selectedConversationID,
                                title: "selected",
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                                    senderUserID: Self.user.id,
                                    serverSequence: 1,
                                    kind: "rich_text",
                                    body: ["text": "selected preview"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_001_000)
                                ),
                                lastReadSequence: 1,
                                unreadCount: 0,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_600)
                            ),
                            IMConversationSummaryResponseBody(
                                id: backgroundConversationID,
                                title: "background",
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                    serverSequence: 8,
                                    kind: "rich_text",
                                    body: ["text": "background preview"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_001_500)
                                ),
                                lastReadSequence: 5,
                                unreadCount: 3,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_500),
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_500)
                            )
                        ],
                        nextCursor: nil,
                        hasMore: false,
                        snapshotToken: "snapshot-bootstrap"
                    )
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMembersBody()
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMessagesBody()
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.count == 2
                    && manager.imConversationStore.conversations.first(where: { $0.id == backgroundConversationID.uuidString })?.serverUnreadCount == 3
            }
        }

        let backgroundConversation = manager.imConversationStore.conversations.first {
            $0.id == backgroundConversationID.uuidString
        }
        #expect(backgroundConversation?.serverLastReadSequence == 5)
        #expect(backgroundConversation?.serverUnreadCount == 3)
        #expect(backgroundConversation?.unreadCount == 3)
    }



    @Test func loginRestoresCachedConversationBeforeNetworkRefreshAndThenAppliesServerSummary() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()

        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "cached-message-1",
                                conversationID: conversationIDString,
                                clientMessageID: "cached-client-1",
                                serverMessageID: "cached-server-1",
                                senderUserID: Self.user.id,
                                serverSequence: 7,
                                kind: "rich_text",
                                text: "来自缓存",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "来自缓存",
                        hasMoreHistory: true,
                        latestSyncedServerSequence: 7,
                        oldestLoadedServerSequence: 7,
                        serverLastReadSequence: 7,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_700_100_100)
            ),
            for: Self.user.id
        )

        let summaryRefreshGate = RestoreGate()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                await summaryRefreshGate.markStarted()
                await summaryRefreshGate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 3,
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                    serverSequence: 8,
                                    kind: "rich_text",
                                    body: ["text": "服务端预览"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_100_200)
                                ),
                                lastReadSequence: 7,
                                unreadCount: 1,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_200)
                            )
                        ],
                        nextCursor: nil,
                        hasMore: false,
                        snapshotToken: "snapshot-\(conversationID.uuidString.lowercased())"
                    )
                )
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
            openIMConnection: nil,
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await summaryRefreshGate.waitUntilStarted()
        #expect(manager.imConversationStore.selectedConversation?.title == "缓存会话")
        #expect(manager.imConversationStore.selectedConversation?.messages.map { $0.text } == ["来自缓存"])
        #expect(manager.imConversationStore.latestLoadedServerSequence(for: conversationIDString) == 7)

        await summaryRefreshGate.resume()
        manager.imConversationStore.applyConversationSummaryContent(
            IMConversationSummaryResponseBody(
                id: conversationID,
                title: "服务端会话",
                kind: IMConversationKind.direct.rawValue,
                memberCount: 3,
                memberUserIDs: [Self.user.id],
                lastMessage: IMMessagePreviewResponseBody(
                    id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 8,
                    kind: "rich_text",
                    body: ["text": "服务端预览"],
                    createdAt: Date(timeIntervalSince1970: 1_700_100_200)
                ),
                lastReadSequence: 7,
                unreadCount: 1,
                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_100_200)
            )
        )
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.title == "服务端会话"
                    && manager.imConversationStore.selectedConversation?.kind == .direct
                    && manager.imConversationStore.selectedConversation?.memberCount == 3
                    && manager.imConversationStore.selectedConversation?.serverUnreadCount == 1
            }
        }

        #expect(manager.imConversationStore.selectedConversationID == conversationIDString)
        #expect(manager.imConversationStore.selectedConversation?.messages.map { $0.text } == ["来自缓存"])
        #expect(manager.imConversationStore.hasLoadedMessages(for: conversationIDString))
        #expect(manager.imConversationStore.latestLoadedServerSequence(for: conversationIDString) == 7)
        #expect(manager.imConversationStore.oldestLoadedServerSequence(for: conversationIDString) == 7)
    }



    @Test func loginContinuesWithNetworkBootstrapWhenConversationCacheLoadFails() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "网络会话",
                                kind: IMConversationKind.group.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ],
                        nextCursor: nil,
                        hasMore: false,
                        snapshotToken: "snapshot-\(conversationID.uuidString.lowercased())"
                    )
                )
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
            imConversationCache: IMConversationCacheHandler(FailingLoadIMConversationCache()),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.title == "网络会话"
                    && manager.imConversationStore.selectedConversationID == conversationID.uuidString
            }
        }

        #expect(manager.imConversationStore.conversations.count == 1)
    }

}
