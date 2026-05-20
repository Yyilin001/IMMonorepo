import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

extension AuthManagerTests {
    @Test func loginLoadsServerConversationListAndHistory() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
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
                manager.imConversationStore.selectedConversation?.id == conversationID.uuidString
                    && manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        let conversation = manager.imConversationStore.selectedConversation
        #expect(conversation?.title == "服务端会话")
        #expect(conversation?.members.map(\.email) == ["manager@example.com", "peer@example.com"])
        #expect(conversation?.messages.first?.text == "来自历史接口")
    }



    @Test func loginLoadsOnlyFirstConversationSummaryPageDuringBootstrap() async throws {
        let harness = IMConnectionTestHarness()
        let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let secondConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let cursor = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "cursor" })?
                    .value
                #expect(cursor == nil)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: [
                            Self.imConversationSummary(
                                id: firstConversationID,
                                latestServerSequence: 2,
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_100),
                                title: "第一页会话"
                            )
                        ],
                        nextCursor: "cursor-page-2",
                        hasMore: true,
                        snapshotToken: "snapshot-page-1"
                    )
                )
            case ("GET", "/api/im/conversations/\(firstConversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(firstConversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: firstConversationID)
                )
            case ("POST", "/api/im/conversations/\(firstConversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
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
        manager.imConversationStore.replaceConversationSummaryWindow(
            [
                Self.imConversationSummary(
                    id: firstConversationID,
                    latestServerSequence: 3,
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_200),
                    title: "第一页顶部"
                ),
                Self.imConversationSummary(
                    id: secondConversationID,
                    latestServerSequence: 2,
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_100),
                    title: "第一页底部"
                )
            ],
            nextCursor: "cursor-page-2",
            hasMore: true
        )
        manager.imConversationStore.setLoadingConversations(false)

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.id == firstConversationID.uuidString
                    && manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        let requests = await transport.requests()
        let summaryRequests = requests.filter { $0.url?.path == "/api/im/conversations" }

        #expect(summaryRequests.count >= 1)
        #expect(requests.contains(where: { $0.url?.path == "/api/im/conversations/changes" }) == false)
        #expect(manager.imConversationStore.conversations.map(\.id) == [firstConversationID.uuidString])
        #expect(manager.imConversationStore.conversationSummaryNextCursor == "cursor-page-2")
        #expect(manager.imConversationStore.hasMoreConversationSummaries == true)
        #expect(manager.imConversationStore.conversations.contains(where: { $0.id == secondConversationID.uuidString }) == false)
    }



    @Test func loadMoreIMConversationSummariesAppendsNextPageAfterAnchorAppears() async throws {
        let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let secondConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let thirdConversationID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let components = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
                let cursor = components?.queryItems?.first(where: { $0.name == "cursor" })?.value

                if cursor == nil {
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imConversationSummaryPageBody(
                            items: [
                                Self.imConversationSummary(
                                    id: firstConversationID,
                                    latestServerSequence: 3,
                                    updatedAt: Date(timeIntervalSince1970: 1_700_001_200),
                                    title: "第一页顶部"
                                ),
                                Self.imConversationSummary(
                                    id: secondConversationID,
                                    latestServerSequence: 2,
                                    updatedAt: Date(timeIntervalSince1970: 1_700_001_100),
                                    title: "第一页底部"
                                )
                            ],
                            nextCursor: "cursor-page-2",
                            hasMore: true,
                            snapshotToken: "snapshot-page-1"
                        )
                    )
                }

                if cursor == "cursor-page-2" {
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imConversationSummaryPageBody(
                            items: [
                                Self.imConversationSummary(
                                    id: thirdConversationID,
                                    latestServerSequence: 1,
                                    updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
                                    title: "第二页"
                                )
                            ],
                            nextCursor: nil,
                            hasMore: false,
                            snapshotToken: "snapshot-page-1"
                        )
                    )
                }

                Issue.record("收到未预期分页游标：\(cursor ?? "nil")")
                return HTTPFixtures.response(statusCode: 500)
            case ("GET", "/api/im/conversations/changes"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationChangesBody(upserts: [], targetToken: "snapshot-page-1")
                )
            case ("GET", "/api/im/conversations/\(firstConversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(firstConversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: firstConversationID)
                )
            case ("POST", "/api/im/conversations/\(firstConversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        manager.imConversationStore.replaceConversationSummaryWindow(
            [
                Self.imConversationSummary(
                    id: firstConversationID,
                    latestServerSequence: 3,
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_200),
                    title: "第一页顶部"
                ),
                Self.imConversationSummary(
                    id: secondConversationID,
                    latestServerSequence: 2,
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_100),
                    title: "第一页底部"
                )
            ],
            nextCursor: "cursor-page-2",
            hasMore: true
        )
        manager.imConversationStore.setLoadingConversations(false)
        #expect(manager.imConversationStore.conversations.contains { $0.id == firstConversationID.uuidString })
        #expect(manager.imConversationStore.conversations.contains { $0.id == secondConversationID.uuidString })

        await manager.loadMoreIMConversationSummariesIfNeeded(anchorConversationID: firstConversationID.uuidString)
        var summaryRequests = await transport.requests().filter { $0.url?.path == "/api/im/conversations" }
        #expect(summaryRequests.contains { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains(where: { $0.name == "cursor" && $0.value == "cursor-page-2" }) == true
        } == false)

        await manager.loadMoreIMConversationSummariesIfNeeded(
            anchorConversationID: manager.imConversationStore.conversationSummaryPaginationAnchorID
        )

        try await Self.waitUntil {
            await MainActor.run {
                let ids = manager.imConversationStore.conversations.map(\.id)
                return ids.contains(firstConversationID.uuidString)
                    && ids.contains(secondConversationID.uuidString)
                    && ids.contains(thirdConversationID.uuidString)
            }
        }

        summaryRequests = await transport.requests().filter { $0.url?.path == "/api/im/conversations" }
        #expect(summaryRequests.count >= 2)
        #expect(summaryRequests.contains { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains(where: { $0.name == "cursor" && $0.value == "cursor-page-2" }) == true
        })
        manager.imConversationStore.appendConversationSummaryWindow(
            [
                Self.imConversationSummary(
                    id: thirdConversationID,
                    latestServerSequence: 1,
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
                    title: "第二页"
                )
            ],
            nextCursor: nil,
            hasMore: false
        )
        #expect(manager.imConversationStore.conversationSummaryNextCursor == nil)
        #expect(manager.imConversationStore.hasMoreConversationSummaries == false)
        #expect(manager.imConversationStore.conversationSummaryPaginationAnchorID == thirdConversationID.uuidString)
    }



    @Test func conversationPreferencesUpdatedOnAnotherDeviceConvergeViaSummaryChanges() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: Self.imConversationSummary(
                id: conversationID,
                latestServerSequence: 3,
                updatedAt: Date(timeIntervalSince1970: 1_700_600_100),
                title: "跨端偏好"
            )
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-\(loginIndex)",
                        refreshToken: "refresh-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("PATCH", "/api/im/conversations/\(conversationID.uuidString)/preferences"):
                let payload = try JSONDecoder().decode(
                    IMConversationPreferencesUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        await summaryState.updatePreferences(
                            isPinned: payload.isPinned,
                            isMuted: payload.isMuted
                        )
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/members") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages/since") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/read") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.conversations.first?.isPinned == false
                    && secondManager.imConversationStore.conversations.first?.isMuted == false
            }
        }

        let didUpdate = await firstManager.updateIMConversationPreferences(
            conversationID.uuidString,
            isPinned: true,
            isMuted: true
        )
        #expect(didUpdate)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(secondManager.imConversationStore.conversations.first?.isPinned == true)
        #expect(secondManager.imConversationStore.conversations.first?.isMuted == true)
        #expect(secondManager.imConversationStore.totalUnreadCount == 0)
    }



    @Test func conversationMetadataUpdatedOnAnotherDeviceRefreshesSelectedConversation() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: Self.imConversationSummary(
                id: conversationID,
                latestServerSequence: 2,
                updatedAt: Date(timeIntervalSince1970: 1_700_600_200),
                title: "旧群资料"
            )
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-meta-\(loginIndex)",
                        refreshToken: "refresh-meta-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("PATCH", "/api/im/conversations/\(conversationID.uuidString)/metadata"):
                let payload = try JSONDecoder().decode(
                    IMConversationMetadataUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        await summaryState.updateMetadata(
                            title: payload.title,
                            notice: payload.notice,
                            avatarPreset: payload.avatarPreset
                        )
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/members") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages/since") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/read") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")

        let didUpdate = await firstManager.updateIMConversationMetadata(
            conversationID.uuidString,
            title: "新群资料",
            notice: "新的群公告",
            avatarPreset: .forest
        )
        #expect(didUpdate)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(secondManager.imConversationStore.selectedConversation?.title == "新群资料")
        #expect(secondManager.imConversationStore.selectedConversation?.notice == "新的群公告")
        #expect(secondManager.imConversationStore.selectedConversation?.avatarPreset == .forest)
    }



    @Test func conversationRemovedForSelfOnAnotherDeviceFallsBackSelectionViaSummaryChanges() async throws {
        let removedConversationID = UUID(uuidString: "aaaaaaaa-7777-8888-9999-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-7777-8888-9999-cccccccccccc")!
        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: removedConversationID,
                    title: "将被移除的群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "11111111-7777-8888-9999-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        content: .text("当前选中的会话"),
                        createdAt: Date(timeIntervalSince1970: 1_700_900_000)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_899_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_900_000)
                ),
                IMConversationSummaryResponseBody(
                    id: fallbackConversationID,
                    title: "回退会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "22222222-7777-8888-9999-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        content: .text("备用摘要"),
                        createdAt: Date(timeIntervalSince1970: 1_700_899_900)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_898_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_899_900)
                )
            ],
            messagesByConversationID: [
                removedConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "11111111-7777-8888-9999-aaaaaaaaaaaa")!,
                        conversationID: removedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("当前选中的会话"),
                        createdAt: Date(timeIntervalSince1970: 1_700_900_000)
                    )
                ]
            ]
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-remove-\(loginIndex)",
                        refreshToken: "refresh-remove-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(removedConversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(removedConversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: removedConversationID))
                )
            case ("GET", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == removedConversationID.uuidString
                    && manager.imConversationStore.conversations.count == 2
                    && manager.imConversationStore.selectedConversation?.title == "将被移除的群聊"
            }
        }

        await state.removeConversation(id: removedConversationID)

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(manager.imConversationStore.conversations.map(\.id) == [fallbackConversationID.uuidString])
        #expect(manager.imConversationStore.selectedConversationID == fallbackConversationID.uuidString)
        #expect(manager.imConversationStore.selectedConversation?.title == "回退会话")
    }



    @Test func removedConversationWithCachedHistoryDoesNotReappearAfterRefreshAndReconnectGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let removedConversationID = UUID(uuidString: "aaaaaaaa-6666-7777-8888-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-6666-7777-8888-cccccccccccc")!
        let removedConversationIDString = removedConversationID.uuidString
        let fallbackConversationIDString = fallbackConversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: removedConversationIDString,
                        title: "缓存中的旧群聊",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "removed-cached-1",
                                conversationID: removedConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "removed-server-1",
                                senderUserID: Self.user.id,
                                serverSequence: 1,
                                kind: "text",
                                text: "缓存旧历史 1",
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_920_000),
                                deliveryState: .sent
                            ),
                            IMCachedMessageState(
                                id: "removed-cached-2",
                                conversationID: removedConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "removed-server-2",
                                senderUserID: Self.user.id,
                                serverSequence: 2,
                                kind: "text",
                                text: "缓存旧历史 2",
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_920_010),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "缓存旧历史 2",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: 2,
                        oldestLoadedServerSequence: 1,
                        serverLastReadSequence: 2,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_920_010)
                    ),
                    IMCachedConversationState(
                        id: fallbackConversationIDString,
                        title: "缓存中的回退会话",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "fallback-cached-1",
                                conversationID: fallbackConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "fallback-server-1",
                                senderUserID: Self.user.id,
                                serverSequence: 1,
                                kind: "text",
                                text: "回退历史 1",
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_920_020),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "回退历史 1",
                        hasMoreHistory: true,
                        latestSyncedServerSequence: 1,
                        oldestLoadedServerSequence: 1,
                        serverLastReadSequence: 1,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_920_020)
                    )
                ],
                selectedConversationID: removedConversationIDString,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_700_920_030)
            ),
            for: Self.user.id
        )

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: removedConversationID,
                    title: "服务端旧群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "11111111-6666-7777-8888-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 2,
                        content: .text("缓存旧历史 2"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_010)
                    ),
                    lastReadSequence: 2,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_919_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_920_010)
                ),
                IMConversationSummaryResponseBody(
                    id: fallbackConversationID,
                    title: "服务端回退会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "22222222-6666-7777-8888-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 2,
                        content: .text("回退历史 2"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_040)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_919_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_920_040)
                )
            ],
            messagesByConversationID: [
                removedConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "11111111-6666-7777-8888-aaaaaaaaaaaa")!,
                        conversationID: removedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 2,
                        content: .text("缓存旧历史 2"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_010)
                    )
                ],
                fallbackConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "33333333-6666-7777-8888-aaaaaaaaaaaa")!,
                        conversationID: fallbackConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("回退历史 1"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_020)
                    ),
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "22222222-6666-7777-8888-aaaaaaaaaaaa")!,
                        conversationID: fallbackConversationID,
                        senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                        clientMessageID: nil,
                        serverSequence: 2,
                        content: .text("回退历史 2"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_040)
                    )
                ]
            ]
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()

        let summaryRefreshGate = RestoreGate()
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let query = request.url?.query
            switch (request.httpMethod, path, query) {
            case ("POST", "/api/auth/login", _):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-removed-cache-\(loginIndex)",
                        refreshToken: "refresh-removed-cache-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations", _):
                await summaryRefreshGate.markStarted()
                await summaryRefreshGate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes", _):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/contacts", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(removedConversationIDString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(fallbackConversationIDString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(removedConversationIDString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: removedConversationID))
                )
            case ("GET", "/api/im/conversations/\(fallbackConversationIDString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: fallbackConversationID))
                )
            case ("GET", "/api/im/conversations/\(removedConversationIDString)/messages/since", _):
                await requestCounter.increment("removedGapSync")
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", "/api/im/conversations/\(fallbackConversationIDString)/messages/since", _):
                await requestCounter.increment("fallbackGapSync")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        await state.messagesSinceResponse(for: fallbackConversationID, afterSequence: afterSequence)
                    )
                )
            case ("POST", "/api/im/conversations/\(removedConversationIDString)/read", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("POST", "/api/im/conversations/\(fallbackConversationIDString)/read", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await summaryRefreshGate.waitUntilStarted()
        manager.imConversationStore.restoreCacheSnapshot(try await cache.loadSnapshot(for: Self.user.id))

        #expect(manager.imConversationStore.selectedConversationID == removedConversationIDString)
        #expect(manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["缓存旧历史 1", "缓存旧历史 2"])
        await summaryRefreshGate.resume()

        await state.removeConversation(id: removedConversationID)

        if let fallbackSummary = await state.currentSummary(for: fallbackConversationID) {
            manager.imConversationStore.applyConversationSummaryChanges(
                upserts: [fallbackSummary],
                removedConversationIDs: [removedConversationID]
            )
        }

        #expect(manager.imConversationStore.selectedConversationID == fallbackConversationIDString)
        #expect(manager.imConversationStore.conversations.map(\.id) == [fallbackConversationIDString])
        #expect(manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["回退历史 1"])

        manager.imConversationStore.appendMessages(
            in: fallbackConversationIDString,
            messages: await state.messagesSinceResponse(for: fallbackConversationID, afterSequence: 1).messages,
            currentUserID: Self.user.id
        )

        #expect(manager.imConversationStore.selectedConversationID == fallbackConversationIDString)
        #expect(manager.imConversationStore.conversations.map(\.id) == [fallbackConversationIDString])
        #expect(manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["回退历史 1", "回退历史 2"])
        #expect(manager.imConversationStore.selectedConversation?.lastMessagePreview == "回退历史 2")
        #expect(manager.imConversationStore.selectedConversation?.serverUnreadCount == 1)
    }



    @Test func rejoinedConversationDoesNotReuseCachedHistoryFromBeforeVisibleWindowReset() async throws {
        let rejoinedConversationID = UUID(uuidString: "aaaaaaaa-1212-3434-5656-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1212-3434-5656-cccccccccccc")!
        let rejoinedConversationIDString = rejoinedConversationID.uuidString
        let fallbackConversationIDString = fallbackConversationID.uuidString
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let cache = InMemoryIMConversationCache()

        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: rejoinedConversationIDString,
                        title: "旧群聊缓存",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id, peerUserID],
                        messages: [
                            IMCachedMessageState(
                                id: "rejoined-cached-1",
                                conversationID: rejoinedConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "rejoined-server-1",
                                senderUserID: peerUserID,
                                serverSequence: 1,
                                content: .text("重新加入前的旧历史 1"),
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_970_000),
                                deliveryState: .received
                            ),
                            IMCachedMessageState(
                                id: "rejoined-cached-2",
                                conversationID: rejoinedConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "rejoined-server-2",
                                senderUserID: peerUserID,
                                serverSequence: 2,
                                content: .text("重新加入前的旧历史 2"),
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_970_010),
                                deliveryState: .received
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "重新加入前的旧历史 2",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: 2,
                        oldestLoadedServerSequence: 1,
                        serverLastReadSequence: 2,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_970_010)
                    ),
                    IMCachedConversationState(
                        id: fallbackConversationIDString,
                        title: "备用会话",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id, peerUserID],
                        messages: [
                            IMCachedMessageState(
                                id: "fallback-cached-1",
                                conversationID: fallbackConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "fallback-server-1",
                                senderUserID: peerUserID,
                                serverSequence: 1,
                                content: .text("备用历史 1"),
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_970_020),
                                deliveryState: .received
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "备用历史 1",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: 1,
                        oldestLoadedServerSequence: 1,
                        serverLastReadSequence: 1,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_970_020)
                    )
                ],
                selectedConversationID: rejoinedConversationIDString,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_700_970_030)
            ),
            for: Self.user.id
        )

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: fallbackConversationID,
                    title: "服务端备用会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id, peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "11111111-1212-3434-5656-aaaaaaaaaaaa")!,
                        senderUserID: peerUserID,
                        serverSequence: 1,
                        content: .text("备用历史 1"),
                        createdAt: Date(timeIntervalSince1970: 1_700_970_020)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_969_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_970_020)
                )
            ],
            messagesByConversationID: [
                fallbackConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "11111111-1212-3434-5656-aaaaaaaaaaaa")!,
                        conversationID: fallbackConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("备用历史 1"),
                        createdAt: Date(timeIntervalSince1970: 1_700_970_020)
                    )
                ]
            ]
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()

        let summaryRefreshGate = RestoreGate()
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-rejoin-\(loginIndex)",
                        refreshToken: "refresh-rejoin-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                await summaryRefreshGate.markStarted()
                await summaryRefreshGate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/im/conversations/\(fallbackConversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(fallbackConversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: fallbackConversationID))
                )
            case ("GET", "/api/im/conversations/\(rejoinedConversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(rejoinedConversationID.uuidString)/messages"):
                await requestCounter.increment("messagesRejoined")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: rejoinedConversationID))
                )
            case ("GET", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
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
        manager.imConversationStore.restoreCacheSnapshot(try await cache.loadSnapshot(for: Self.user.id))
        #expect(manager.imConversationStore.selectedConversationID == rejoinedConversationIDString)
        #expect(manager.imConversationStore.selectedConversation?.messages.map(\.text) == [
            "重新加入前的旧历史 1",
            "重新加入前的旧历史 2"
        ])
        await summaryRefreshGate.resume()

        if let fallbackSummary = await state.currentSummary(for: fallbackConversationID) {
            manager.imConversationStore.applyConversationSummaryChanges(
                upserts: [fallbackSummary],
                removedConversationIDs: [rejoinedConversationID]
            )
        }

        await state.upsertSummary(
            IMConversationSummaryResponseBody(
                id: rejoinedConversationID,
                title: "重新加入后的群聊",
                kind: IMConversationKind.group.rawValue,
                memberCount: 2,
                memberUserIDs: [Self.user.id, peerUserID],
                lastMessage: IMMessagePreviewResponseBody(
                    id: UUID(uuidString: "22222222-1212-3434-5656-aaaaaaaaaaaa")!,
                    senderUserID: peerUserID,
                    serverSequence: 5,
                    content: .text("重新加入后的可见消息"),
                    createdAt: Date(timeIntervalSince1970: 1_700_970_200)
                ),
                lastReadSequence: 5,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_970_100),
                updatedAt: Date(timeIntervalSince1970: 1_700_970_200)
            )
        )
        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: UUID(uuidString: "22222222-1212-3434-5656-aaaaaaaaaaaa")!,
                conversationID: rejoinedConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 5,
                content: .text("重新加入后的可见消息"),
                createdAt: Date(timeIntervalSince1970: 1_700_970_200)
            ),
            unreadCount: 0,
            lastReadSequence: 5
        )

        if let rejoinedSummary = await state.currentSummary(for: rejoinedConversationID) {
            manager.imConversationStore.applyConversationSummaryChanges(
                upserts: [rejoinedSummary],
                removedConversationIDs: []
            )
        }

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.contains(where: { $0.id == rejoinedConversationIDString })
            }
        }

        let rejoinedSummary = try #require(
            manager.imConversationStore.conversations.first(where: { $0.id == rejoinedConversationIDString })
        )
        #expect(rejoinedSummary.messages.isEmpty)
        #expect(rejoinedSummary.lastMessagePreview == "重新加入后的可见消息")

        manager.imConversationStore.replaceMessages(
            in: rejoinedConversationIDString,
            messages: await state.messagesResponse(for: rejoinedConversationID),
            currentUserID: Self.user.id
        )
        manager.imConversationStore.openConversation(id: rejoinedConversationIDString)

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == rejoinedConversationIDString
                    && manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["重新加入后的可见消息"]
            }
        }

        #expect(manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["重新加入后的可见消息"])
        #expect(manager.imConversationStore.selectedConversation?.messages.contains(where: {
            $0.text == "重新加入前的旧历史 1" || $0.text == "重新加入前的旧历史 2"
        }) == false)
    }



    @Test func conversationMemberRoleUpdatedOnAnotherDeviceConvergesSummaryAndMembersAfterRefreshAndOpen() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-8888-9999-0000-bbbbbbbbbbbb")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let roleUpdatedMessageID = UUID(uuidString: "11111111-8888-9999-0000-aaaaaaaaaaaa")!
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: IMConversationSummaryResponseBody(
                id: conversationID,
                title: "群角色同步",
                kind: IMConversationKind.group.rawValue,
                memberCount: 2,
                memberUserIDs: [Self.user.id, peerUserID],
                lastMessage: IMMessagePreviewResponseBody(
                    id: UUID(uuidString: "22222222-8888-9999-0000-aaaaaaaaaaaa")!,
                    senderUserID: Self.user.id,
                    serverSequence: 1,
                    content: .system(.legacyText("manager@example.com 创建了群聊")),
                    createdAt: Date(timeIntervalSince1970: 1_700_910_000)
                ),
                lastReadSequence: 1,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_909_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_910_000)
            )
        )
        let membersState = IMCrossDeviceConversationMembersState(
            membersByConversationID: [
                conversationID: [
                    IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email, role: .owner),
                    IMConversationMemberResponseBody(id: peerUserID, email: "peer@example.com", role: .member)
                ]
            ]
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-role-\(loginIndex)",
                        refreshToken: "refresh-role-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                await requestCounter.increment("members")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersPageBody(await membersState.membersResponse(for: conversationID))
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/members/\(peerUserID.uuidString)/role"):
                let payload = try JSONDecoder().decode(
                    IMConversationMemberRoleUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                #expect(payload.role == .admin)
                await membersState.updateRole(in: conversationID, memberUserID: peerUserID, role: .admin)
                await summaryState.appendMessage(
                    IMConversationMessageResponseBody(
                        id: roleUpdatedMessageID,
                        conversationID: conversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 2,
                        content: .system(
                            IMSystemEvent(
                                type: .roleUpdated,
                                actorUserID: Self.user.id,
                                actorEmail: Self.user.email,
                                targetUserID: peerUserID,
                                targetEmail: "peer@example.com",
                                previousRole: .member,
                                newRole: .admin
                            )
                        ),
                        createdAt: Date(timeIntervalSince1970: 1_700_910_100)
                    ),
                    unreadCount: 1,
                    lastReadSequence: 1
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.currentSummary())
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")
        await secondManager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.members.first(where: { $0.id == peerUserID })?.role == .member
            }
        }

        let didUpdateRole = await firstManager.updateIMConversationMemberRole(
            memberUserID: peerUserID,
            role: .admin,
            in: conversationID.uuidString
        )
        #expect(didUpdateRole)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()
        await secondManager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.lastMessagePreview == "manager@example.com 将 peer@example.com 设为管理员"
                    && secondManager.imConversationStore.selectedConversation?.serverUnreadCount == 1
                    && secondManager.imConversationStore.selectedConversation?.members.first(where: { $0.id == peerUserID })?.role == .admin
            }
        }

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(await requestCounter.count(for: "members") >= 2)
    }



    @Test func conversationDraftRemainsLocalAcrossDevices() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationID.uuidString,
                        title: "本地草稿",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [],
                        hasLoadedMessages: false,
                        lastMessagePreviewText: "",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        draftText: "只在本地的草稿",
                        draftUpdatedAt: Date(timeIntervalSince1970: 1_700_600_300),
                        updatedAt: Date(timeIntervalSince1970: 1_700_600_300)
                    )
                ],
                selectedConversationID: conversationID.uuidString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")
        firstManager.imConversationStore.restoreCacheSnapshot(try await cache.loadSnapshot(for: Self.user.id))
        firstManager.imConversationStore.updateDraft("只在本地的草稿", for: conversationID.uuidString)

        #expect(firstManager.imConversationStore.draftText(for: conversationID.uuidString) == "只在本地的草稿")
        #expect(secondManager.imConversationStore.draftText(for: conversationID.uuidString).isEmpty)
    }



}
