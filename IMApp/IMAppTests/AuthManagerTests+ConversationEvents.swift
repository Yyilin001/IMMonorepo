import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

extension AuthManagerTests {
    @Test func recalledMessageOnAnotherDeviceConvergesViaSummaryChangesEvenWhenHistoryIsLoaded() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let recalledMessageID = UUID(uuidString: "99999999-1111-2222-3333-aaaaaaaaaaaa")!
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: IMConversationSummaryResponseBody(
                id: conversationID,
                title: "待撤回消息",
                kind: IMConversationKind.group.rawValue,
                memberCount: 1,
                memberUserIDs: [Self.user.id],
                lastMessage: IMMessagePreviewResponseBody(
                    id: recalledMessageID,
                    senderUserID: Self.user.id,
                    serverSequence: 1,
                    kind: "rich_text",
                    body: ["text": "待撤回消息"],
                    createdAt: Date(timeIntervalSince1970: 1_700_600_350)
                ),
                lastReadSequence: 0,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_600_300),
                updatedAt: Date(timeIntervalSince1970: 1_700_600_350)
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
                        accessToken: "access-recall-\(loginIndex)",
                        refreshToken: "refresh-recall-\(loginIndex)"
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
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/messages/\(recalledMessageID.uuidString)/recall"):
                let response = await summaryState.recallLatestMessage(senderUserID: Self.user.id)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(try #require(response))
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationMessageResponseBody(
                                id: recalledMessageID,
                                conversationID: conversationID,
                                senderUserID: Self.user.id,
                                clientMessageID: nil,
                                serverSequence: 1,
                                kind: "rich_text",
                                body: ["text": "待撤回消息"],
                                createdAt: Date(timeIntervalSince1970: 1_700_600_350)
                            )
                        ]
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyTimelineBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/members") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/timeline/since") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyTimelineBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/timeline") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyTimelineBody())
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
        await secondManager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.messages.last?.text == "待撤回消息"
            }
        }

        let changesBeforeRecall = await requestCounter.count(for: "changes")
        let didRecall = await firstManager.recallIMMessage(
            messageID: recalledMessageID.uuidString,
            in: conversationID.uuidString
        )
        #expect(didRecall)

        try await Self.waitUntil {
            await MainActor.run {
                firstManager.imConversationStore.selectedConversation?.lastMessagePreview == "撤回了一条消息"
            }
        }

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") > changesBeforeRecall)
        #expect(secondManager.imConversationStore.selectedConversation?.lastMessagePreview == "撤回了一条消息")
    }



    @Test func editedMessageOnAnotherDeviceConvergesViaRealtimeEventChangesAndReconnect() async throws {
        let harness = IMConnectionTestHarness()
        let firstHarness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-7777-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "99999999-7777-2222-3333-aaaaaaaaaaaa")!
        let originalTimestamp = Date(timeIntervalSince1970: 1_700_860_100)
        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "跨端编辑",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: messageID,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("编辑前正文")),
                        createdAt: originalTimestamp
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_860_000),
                    updatedAt: originalTimestamp
                )
            ],
            messagesByConversationID: [
                conversationID: [
                    IMConversationMessageResponseBody(
                        id: messageID,
                        conversationID: conversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: "client-edit-cross-device",
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("编辑前正文")),
                        createdAt: originalTimestamp
                    )
                ]
            ]
        )

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
                        accessToken: "access-edit-\(loginIndex)",
                        refreshToken: "refresh-edit-\(loginIndex)"
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
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.timelineResponse(for: conversationID))
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline/since"):
                await requestCounter.increment("gapSync")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: conversationID, afterSequence: afterSequence))
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/edit"):
                let payload = try JSONDecoder().decode(
                    IMConversationMessageEditRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                let response = await state.editMessage(
                    id: messageID,
                    in: conversationID,
                    text: payload.body.text
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(try #require(response))
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: {
                await firstHarness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")
        await firstManager.openIMConversation(conversationID.uuidString)
        await secondManager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                firstManager.imConversationStore.selectedConversation?.messages.last?.id == messageID.uuidString
                    && secondManager.imConversationStore.selectedConversation?.messages.last?.text == "编辑前正文"
                    && secondManager.imConnectionStatus == .connected
            }
        }

        let updatedMessage = try #require(
            await state.editMessage(
                id: messageID,
                in: conversationID,
                text: "编辑后正文"
            )
        )
        let changesBeforeEdit = await requestCounter.count(for: "changes")
        let updatedSummary = try #require(await state.currentSummary(for: conversationID))
        await harness.yield(
            .conversationEvent(
                requestID: nil,
                payload: TestConversationEventPayload(
                    eventType: .messageUpdated,
                    conversation: updatedSummary,
                    message: updatedMessage,
                    actorUserID: Self.user.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_860_200)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = secondManager.imConversationStore.selectedConversation
                return selectedConversation?.lastMessagePreview == "编辑后正文"
                    && selectedConversation?.messages.last?.text == "编辑后正文"
                    && selectedConversation?.messages.last?.derivedState.edits.last?.body.text == "编辑后正文"
            }
        }

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()
        #expect(await requestCounter.count(for: "changes") > changesBeforeEdit)
        #expect(secondManager.imConversationStore.selectedConversation?.lastMessagePreview == "编辑后正文")

        let gapSyncBeforeReconnect = await requestCounter.count(for: "gapSync")
        await secondManager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = secondManager.imConversationStore.selectedConversation
                return selectedConversation?.messages.last?.text == "编辑后正文"
                    && selectedConversation?.messages.last?.derivedState.edits.last?.body.text == "编辑后正文"
                    && secondManager.imConnectionStatus == .connected
            }
        }

        #expect(await requestCounter.count(for: "gapSync") >= gapSyncBeforeReconnect)
    }



    @Test func messageReactionOnAnotherDeviceConvergesViaRealtimeEventChangesAndReconnect() async throws {
        let harness = IMConnectionTestHarness()
        let firstHarness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-8888-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "99999999-8888-2222-3333-aaaaaaaaaaaa")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let originalTimestamp = Date(timeIntervalSince1970: 1_700_861_100)
        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "跨端 reaction",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: messageID,
                        senderUserID: peerUserID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("reaction 目标")),
                        createdAt: originalTimestamp
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_861_000),
                    updatedAt: originalTimestamp
                )
            ],
            messagesByConversationID: [
                conversationID: [
                    IMConversationMessageResponseBody(
                        id: messageID,
                        conversationID: conversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("reaction 目标")),
                        createdAt: originalTimestamp
                    )
                ]
            ]
        )

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
                        accessToken: "access-reaction-\(loginIndex)",
                        refreshToken: "refresh-reaction-\(loginIndex)"
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
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.timelineResponse(for: conversationID))
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline/since"):
                await requestCounter.increment("gapSync")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: conversationID, afterSequence: afterSequence))
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/reactions"):
                let payload = try JSONDecoder().decode(
                    IMConversationMessageReactionRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                let response = await state.toggleReaction(
                    on: messageID,
                    in: conversationID,
                    actorUserID: Self.user.id,
                    emoji: payload.emoji
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(try #require(response))
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: {
                await firstHarness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")
        await firstManager.openIMConversation(conversationID.uuidString)
        await secondManager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                firstManager.imConversationStore.selectedConversation?.messages.last?.id == messageID.uuidString
                    && secondManager.imConversationStore.selectedConversation?.messages.last?.text == "reaction 目标"
                    && secondManager.imConnectionStatus == .connected
            }
        }

        let updatedMessage = try #require(
            await state.toggleReaction(
                on: messageID,
                in: conversationID,
                actorUserID: Self.user.id,
                emoji: "👍"
            )
        )
        let updatedSummary = try #require(await state.currentSummary(for: conversationID))
        await harness.yield(
            .conversationEvent(
                requestID: nil,
                payload: TestConversationEventPayload(
                    eventType: .messageUpdated,
                    conversation: updatedSummary,
                    message: updatedMessage,
                    actorUserID: Self.user.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_861_200)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.messages.last?.derivedState.reactions == [
                    .init(emoji: "👍", actorUserIDs: [Self.user.id])
                ]
            }
        }

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()
        #expect(secondManager.imConversationStore.selectedConversation?.messages.last?.derivedState.reactions == [
            .init(emoji: "👍", actorUserIDs: [Self.user.id])
        ])

        let gapSyncBeforeReconnect = await requestCounter.count(for: "gapSync")
        await secondManager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.messages.last?.derivedState.reactions == [
                    .init(emoji: "👍", actorUserIDs: [Self.user.id])
                ]
            }
        }

        #expect(await requestCounter.count(for: "gapSync") >= gapSyncBeforeReconnect)
        #expect(secondManager.imConversationStore.selectedConversation?.lastMessagePreview == "reaction 目标")
    }



    @Test func recalledReadChangesAndGapSyncConvergeAcrossDevices() async throws {
        let secondHarness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let previousMessageID = UUID(uuidString: "11111111-1111-2222-3333-aaaaaaaaaaaa")!
        let recalledGapMessageID = UUID(uuidString: "22222222-1111-2222-3333-aaaaaaaaaaaa")!
        let initialMessages = [
            IMConversationMessageResponseBody(
                id: previousMessageID,
                conversationID: conversationID,
                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                clientMessageID: nil,
                serverSequence: 1,
                kind: "rich_text",
                body: ["text": "历史中的旧消息"],
                createdAt: Date(timeIntervalSince1970: 1_700_610_000)
            )
        ]
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: IMConversationSummaryResponseBody(
                id: conversationID,
                title: "撤回+已读+补洞",
                kind: IMConversationKind.group.rawValue,
                memberCount: 1,
                memberUserIDs: [Self.user.id],
                lastMessage: IMMessagePreviewResponseBody(
                    id: previousMessageID,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 1,
                    kind: "rich_text",
                    body: ["text": "历史中的旧消息"],
                    createdAt: Date(timeIntervalSince1970: 1_700_610_000)
                ),
                lastReadSequence: 1,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_609_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_610_000)
            ),
            messages: initialMessages
        )
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let query = request.url?.query
            switch (request.httpMethod, path, query) {
            case ("POST", "/api/auth/login", _):
                await requestCounter.increment("login")
                let loginIndex = await requestCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-combo-\(loginIndex)",
                        refreshToken: "refresh-combo-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes", _):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.timelineResponse())
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline/since", _):
                await requestCounter.increment("gapSync")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.messagesSinceResponse(afterSequence: afterSequence))
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
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
            openIMConnection: {
                await secondHarness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.messages.map(\.text) == ["历史中的旧消息"]
                    && secondManager.imConnectionStatus == .connected
            }
        }

        await summaryState.appendMessage(
            IMConversationMessageResponseBody(
                id: recalledGapMessageID,
                conversationID: conversationID,
                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                clientMessageID: nil,
                serverSequence: 2,
                kind: "rich_text",
                body: ["text": "稍后会被撤回"],
                createdAt: Date(timeIntervalSince1970: 1_700_610_100)
            ),
            unreadCount: 1,
            lastReadSequence: 1
        )
        _ = await summaryState.recallLatestMessage(
            senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        _ = await summaryState.updateReadState(lastReadSequence: 2, unreadCount: 0)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(secondManager.imConversationStore.selectedConversation?.lastMessagePreview == "撤回了一条消息")
        #expect(secondManager.imConversationStore.selectedConversation?.serverLastReadSequence == 2)
        #expect(secondManager.imConversationStore.selectedConversation?.unreadCount == 0)

        let gapRequestsBeforeReconnect = await requestCounter.count(for: "gapSync")
        await secondManager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = secondManager.imConversationStore.selectedConversation
                return selectedConversation?.lastMessagePreview == "撤回了一条消息"
                    && selectedConversation?.serverLastReadSequence == 2
                    && selectedConversation?.unreadCount == 0
                    && selectedConversation?.messages.count == 2
                    && selectedConversation?.messages.last?.derivedState.isRecalled == true
            }
        }

        #expect(await requestCounter.count(for: "gapSync") > gapRequestsBeforeReconnect)
        #expect(secondManager.imConversationStore.selectedConversation?.localUnreadDelta == 0)
        #expect(secondManager.imConversationStore.selectedConversation?.messages.map(\.text) == [
            "历史中的旧消息",
            "撤回了一条消息"
        ])
    }



    @Test func backgroundRealtimeUnreadDeltaConvergesAfterCrossDeviceReadRecallAndGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let backgroundHistoryMessageID = UUID(uuidString: "33333333-1111-2222-3333-aaaaaaaaaaaa")!
        let backgroundRealtimeMessageID = UUID(uuidString: "44444444-1111-2222-3333-aaaaaaaaaaaa")!
        let backgroundRecalledMessageID = UUID(uuidString: "55555555-1111-2222-3333-aaaaaaaaaaaa")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "当前会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "66666666-1111-2222-3333-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        kind: "rich_text",
                        body: ["text": "当前会话消息"],
                        createdAt: Date(timeIntervalSince1970: 1_700_820_000)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_819_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_820_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "后台会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: backgroundHistoryMessageID,
                        senderUserID: peerUserID,
                        serverSequence: 1,
                        kind: "rich_text",
                        body: ["text": "后台历史消息"],
                        createdAt: Date(timeIntervalSince1970: 1_700_820_100)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_819_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_820_100)
                )
            ],
            messagesByConversationID: [
                selectedConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "66666666-1111-2222-3333-aaaaaaaaaaaa")!,
                        conversationID: selectedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        kind: "rich_text",
                        body: ["text": "当前会话消息"],
                        createdAt: Date(timeIntervalSince1970: 1_700_820_000)
                    )
                ],
                backgroundConversationID: [
                    IMConversationMessageResponseBody(
                        id: backgroundHistoryMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 1,
                        kind: "rich_text",
                        body: ["text": "后台历史消息"],
                        createdAt: Date(timeIntervalSince1970: 1_700_820_100)
                    )
                ]
            ]
        )

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let query = request.url?.query
            switch (request.httpMethod, path, query) {
            case ("POST", "/api/auth/login", _):
                await requestCounter.increment("login")
                let loginIndex = await requestCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-background-\(loginIndex)",
                        refreshToken: "refresh-background-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations", _):
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
            case ("GET", let path?, _) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/timeline", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.timelineResponse(for: selectedConversationID))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/timeline", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.timelineResponse(for: backgroundConversationID))
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/timeline/since", _):
                await requestCounter.increment("gapSyncSelected")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: selectedConversationID, afterSequence: afterSequence))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/timeline/since", _):
                await requestCounter.increment("gapSyncBackground")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: backgroundConversationID, afterSequence: afterSequence))
                )
            case ("POST", let path?, _) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests", _):
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
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString
                    && manager.imConnectionStatus == .connected
                    && manager.imConversationStore.conversations.count == 2
            }
        }

        await harness.yield(
            .message(
                requestID: UUID(uuidString: "77777777-1111-2222-3333-aaaaaaaaaaaa"),
                payload: IMTCPMessagePayload(
                    clientMessageID: nil,
                    messageID: backgroundRealtimeMessageID.uuidString,
                    conversationID: backgroundConversationID.uuidString,
                    senderUserID: peerUserID,
                    serverSequence: 2,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_820_200),
                    kind: "rich_text",
                    body: ["text": "后台实时未读"]
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                guard let backgroundConversation = manager.imConversationStore.conversations.first(where: {
                    $0.id == backgroundConversationID.uuidString
                }) else {
                    return false
                }

                return backgroundConversation.localUnreadDelta == 1
                    && backgroundConversation.unreadCount == 1
                    && manager.imConversationStore.totalUnreadCount == 1
            }
        }

        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: backgroundRecalledMessageID,
                conversationID: backgroundConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 3,
                kind: "rich_text",
                body: ["text": "稍后被另一端撤回"],
                createdAt: Date(timeIntervalSince1970: 1_700_820_300)
            ),
            unreadCount: 2,
            lastReadSequence: 1
        )
        _ = await state.recallLatestMessage(
            in: backgroundConversationID,
            senderUserID: peerUserID
        )
        await state.updateReadState(
            for: backgroundConversationID,
            lastReadSequence: 3,
            unreadCount: 0
        )

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString)

        let backgroundAfterChanges = manager.imConversationStore.conversations.first {
            $0.id == backgroundConversationID.uuidString
        }
        #expect(backgroundAfterChanges?.lastMessagePreview == "撤回了一条消息")
        #expect(backgroundAfterChanges?.serverLastReadSequence == 3)
        #expect(backgroundAfterChanges?.serverUnreadCount == 0)
        #expect(backgroundAfterChanges?.localUnreadDelta == 0)
        #expect(backgroundAfterChanges?.unreadCount == 0)
        #expect(manager.imConversationStore.totalUnreadCount == 0)

        let gapRequestsBeforeReconnect = await requestCounter.count(for: "gapSyncBackground")
        await manager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                guard let backgroundConversation = manager.imConversationStore.conversations.first(where: {
                    $0.id == backgroundConversationID.uuidString
                }) else {
                    return false
                }

                return backgroundConversation.lastMessagePreview == "撤回了一条消息"
                    && backgroundConversation.serverLastReadSequence == 3
                    && backgroundConversation.localUnreadDelta == 0
                    && backgroundConversation.unreadCount == 0
                    && backgroundConversation.messages.last?.derivedState.isRecalled == true
                    && backgroundConversation.messages.map(\.text) == [
                        "后台实时未读",
                        "撤回了一条消息"
                    ]
            }
        }

        #expect(await requestCounter.count(for: "gapSyncBackground") > gapRequestsBeforeReconnect)
        #expect(manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString)
        #expect(manager.imConversationStore.totalUnreadCount == 0)
    }



    @Test func backgroundReplyReferenceConvergesAfterCrossDeviceRecallReadAndGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-2222-3333-4444-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-2222-3333-4444-cccccccccccc")!
        let selectedMessageID = UUID(uuidString: "11111111-2222-3333-4444-aaaaaaaaaaaa")!
        let backgroundBaselineMessageID = UUID(uuidString: "22222222-2222-3333-4444-aaaaaaaaaaaa")!
        let backgroundTargetMessageID = UUID(uuidString: "33333333-2222-3333-4444-aaaaaaaaaaaa")!
        let backgroundReplyMessageID = UUID(uuidString: "44444444-2222-3333-4444-aaaaaaaaaaaa")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "当前会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: selectedMessageID,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("当前会话消息")),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_000)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_829_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_830_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "后台引用会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: backgroundBaselineMessageID,
                        senderUserID: peerUserID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("后台已加载基线")),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_100)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_829_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_830_100)
                )
            ],
            messagesByConversationID: [
                selectedConversationID: [
                    IMConversationMessageResponseBody(
                        id: selectedMessageID,
                        conversationID: selectedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("当前会话消息")),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_000)
                    )
                ],
                backgroundConversationID: [
                    IMConversationMessageResponseBody(
                        id: backgroundBaselineMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("后台已加载基线")),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_100)
                    )
                ]
            ]
        )

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let query = request.url?.query
            switch (request.httpMethod, path, query) {
            case ("POST", "/api/auth/login", _):
                await requestCounter.increment("login")
                let loginIndex = await requestCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-background-reply-\(loginIndex)",
                        refreshToken: "refresh-background-reply-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations", _):
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
            case ("GET", let path?, _) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/timeline", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.timelineResponse(for: selectedConversationID))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/timeline", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.timelineResponse(for: backgroundConversationID))
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/timeline/since", _):
                await requestCounter.increment("gapSyncSelected")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: selectedConversationID, afterSequence: afterSequence))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/timeline/since", _):
                await requestCounter.increment("gapSyncBackground")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: backgroundConversationID, afterSequence: afterSequence))
                )
            case ("POST", let path?, _) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests", _):
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
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString
                    && manager.imConnectionStatus == .connected
                    && manager.imConversationStore.conversations.count == 2
            }
        }

        await MainActor.run {
            manager.imConversationStore.replaceTimelineItems(
                in: backgroundConversationID.uuidString,
                messages: [
                    IMConversationMessageResponseBody(
                        id: backgroundBaselineMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("后台已加载基线")),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_100)
                    )
                ],
                currentUserID: Self.user.id
            )
        }

        #expect(manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString)
        #expect(manager.imConversationStore.conversations.first(where: {
            $0.id == backgroundConversationID.uuidString
        })?.messages.map(\.text) == ["后台已加载基线"])

        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: backgroundTargetMessageID,
                conversationID: backgroundConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 2,
                timelineSequence: 2,
                content: .richText(.plain("稍后会被撤回的引用目标")),
                createdAt: Date(timeIntervalSince1970: 1_700_830_200)
            ),
            unreadCount: 1,
            lastReadSequence: 1
        )
        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: backgroundReplyMessageID,
                conversationID: backgroundConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 3,
                timelineSequence: 3,
                content: .reply(
                    reference: IMReplyReference(
                        messageID: backgroundTargetMessageID.uuidString,
                        senderUserID: peerUserID,
                        previewText: "稍后会被撤回的引用目标"
                    ),
                    body: .plain("后台 reply 正文")
                ),
                createdAt: Date(timeIntervalSince1970: 1_700_830_300)
            ),
            unreadCount: 2,
            lastReadSequence: 1
        )
        _ = await state.recallMessage(
            id: backgroundTargetMessageID,
            in: backgroundConversationID,
            senderUserID: peerUserID
        )
        await state.updateReadState(
            for: backgroundConversationID,
            lastReadSequence: 3,
            unreadCount: 0
        )

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        let backgroundAfterChanges = try #require(
            manager.imConversationStore.conversations.first(where: {
                $0.id == backgroundConversationID.uuidString
            })
        )
        #expect(backgroundAfterChanges.lastMessagePreview == "后台 reply 正文")
        #expect(backgroundAfterChanges.serverLastReadSequence == 3)
        #expect(backgroundAfterChanges.unreadCount == 0)
        #expect(backgroundAfterChanges.localUnreadDelta == 0)
        #expect(backgroundAfterChanges.messages.map(\.text) == ["后台已加载基线"])

        let gapRequestsBeforeReconnect = await requestCounter.count(for: "gapSyncBackground")
        await manager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                guard let backgroundConversation = manager.imConversationStore.conversations.first(where: {
                    $0.id == backgroundConversationID.uuidString
                }) else {
                    return false
                }

                guard let replyMessage = backgroundConversation.messages.last else {
                    return false
                }

                return manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString
                    && backgroundConversation.serverLastReadSequence == 3
                    && backgroundConversation.unreadCount == 0
                    && backgroundConversation.localUnreadDelta == 0
                    && backgroundConversation.messages.count == 3
                    && replyMessage.resolvedReplyReference(in: backgroundConversation.messages) == IMReplyReferenceResolution(
                        state: .recalled,
                        text: "原消息已撤回"
                    )
            }
        }

        let backgroundAfterGapSync = try #require(
            manager.imConversationStore.conversations.first(where: {
                $0.id == backgroundConversationID.uuidString
            })
        )
        let replyAfterGapSync = try #require(backgroundAfterGapSync.messages.last)
        #expect(await requestCounter.count(for: "gapSyncBackground") > gapRequestsBeforeReconnect)
        #expect(backgroundAfterGapSync.messages.map(\.text) == [
            "后台已加载基线",
            "撤回了一条消息",
            "后台 reply 正文"
        ])
        #expect(backgroundAfterGapSync.lastMessagePreview == "后台 reply 正文")
        #expect(replyAfterGapSync.resolvedReplyReference(in: backgroundAfterGapSync.messages) == IMReplyReferenceResolution(
            state: .recalled,
            text: "原消息已撤回"
        ))
        #expect(manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString)
        #expect(manager.imConversationStore.totalUnreadCount == 0)
    }



    @Test func backgroundReplyReferenceLoadsOlderPagesAfterOpenThenStaysConsistentThroughChangesAndGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-3333-4444-5555-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-3333-4444-5555-cccccccccccc")!
        let selectedMessageID = UUID(uuidString: "11111111-3333-4444-5555-aaaaaaaaaaaa")!
        let backgroundReplyMessageID = UUID(uuidString: "22222222-3333-4444-5555-aaaaaaaaaaaa")!
        let backgroundIntermediateMessageID = UUID(uuidString: "33333333-3333-4444-5555-aaaaaaaaaaaa")!
        let backgroundTargetMessageID = UUID(uuidString: "44444444-3333-4444-5555-aaaaaaaaaaaa")!
        let backgroundGapMessageID = UUID(uuidString: "55555555-3333-4444-5555-aaaaaaaaaaaa")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let cache = InMemoryIMConversationCache()

        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: selectedConversationID.uuidString,
                        title: "当前会话",
                        kind: .group,
                        memberCount: 1,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            try! IMCachedMessageState(
                                id: selectedMessageID.uuidString,
                                conversationID: selectedConversationID.uuidString,
                                clientMessageID: nil,
                                serverMessageID: selectedMessageID.uuidString,
                                senderUserID: Self.user.id,
                                serverSequence: 1,
                                timelineSequence: 1,
                                content: .richText(.plain("当前会话消息")),
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_840_000),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "当前会话消息",
                        hasMoreHistory: false,
                        latestLoadedTimelineSequence: 1,
                        oldestLoadedTimelineSequence: 1,
                        serverLastReadSequence: 1,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_840_000)
                    ),
                    IMCachedConversationState(
                        id: backgroundConversationID.uuidString,
                        title: "后台补页引用会话",
                        kind: .group,
                        memberCount: 1,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            try! IMCachedMessageState(
                                id: backgroundReplyMessageID.uuidString,
                                conversationID: backgroundConversationID.uuidString,
                                clientMessageID: nil,
                                serverMessageID: backgroundReplyMessageID.uuidString,
                                senderUserID: peerUserID,
                                serverSequence: 4,
                                timelineSequence: 4,
                                content: .reply(
                                    reference: IMReplyReference(
                                        messageID: backgroundTargetMessageID.uuidString,
                                        senderUserID: peerUserID,
                                        previewText: "稍后会被撤回的引用目标"
                                    ),
                                    body: .plain("缓存里的 reply")
                                ),
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_840_400),
                                deliveryState: .received
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "缓存里的 reply",
                        hasMoreHistory: true,
                        latestLoadedTimelineSequence: 4,
                        oldestLoadedTimelineSequence: 4,
                        serverLastReadSequence: 3,
                        serverUnreadCount: 1,
                        updatedAt: Date(timeIntervalSince1970: 1_700_840_400)
                    )
                ],
                selectedConversationID: selectedConversationID.uuidString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "当前会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: selectedMessageID,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("当前会话消息")),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_000)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_839_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_840_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "后台补页引用会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: backgroundReplyMessageID,
                        senderUserID: peerUserID,
                        serverSequence: 4,
                        timelineSequence: 4,
                        content: .reply(
                            reference: IMReplyReference(
                                messageID: backgroundTargetMessageID.uuidString,
                                senderUserID: peerUserID,
                                previewText: "稍后会被撤回的引用目标"
                            ),
                            body: .plain("缓存里的 reply")
                        ),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_400)
                    ),
                    lastReadSequence: 3,
                    unreadCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_839_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_840_400)
                )
            ],
            messagesByConversationID: [
                selectedConversationID: [
                    IMConversationMessageResponseBody(
                        id: selectedMessageID,
                        conversationID: selectedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("当前会话消息")),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_000)
                    )
                ],
                backgroundConversationID: [
                    IMConversationMessageResponseBody(
                        id: backgroundTargetMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 2,
                        timelineSequence: 2,
                        content: .richText(.plain("稍后会被撤回的引用目标")),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_200)
                    ),
                    IMConversationMessageResponseBody(
                        id: backgroundIntermediateMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 3,
                        timelineSequence: 3,
                        content: .richText(.plain("中间历史消息")),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_300)
                    ),
                    IMConversationMessageResponseBody(
                        id: backgroundReplyMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 4,
                        timelineSequence: 4,
                        content: .reply(
                            reference: IMReplyReference(
                                messageID: backgroundTargetMessageID.uuidString,
                                senderUserID: peerUserID,
                                previewText: "稍后会被撤回的引用目标"
                            ),
                            body: .plain("缓存里的 reply")
                        ),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_400)
                    )
                ]
            ]
        )

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let components = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let beforeSequence = queryItems.first(where: { $0.name == "beforeSequence" })?.value.flatMap(UInt64.init)
            let afterToken = queryItems.first(where: { $0.name == "afterToken" })?.value
            let afterSequence = queryItems.first(where: { $0.name == "afterSequence" })?.value.flatMap(UInt64.init)

            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await requestCounter.increment("login")
                let loginIndex = await requestCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-background-open-\(loginIndex)",
                        refreshToken: "refresh-background-open-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/timeline"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.timelineResponse(for: selectedConversationID))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/timeline"):
                switch beforeSequence {
                case nil:
                    await requestCounter.increment("messagesBackgroundLatestPage")
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody(await state.timelineResponse(for: backgroundConversationID))
                    )
                case 4:
                    await requestCounter.increment("loadOlderBackground")
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody([
                            IMConversationMessageResponseBody(
                                id: backgroundIntermediateMessageID,
                                conversationID: backgroundConversationID,
                                senderUserID: peerUserID,
                                clientMessageID: nil,
                                serverSequence: 3,
                                timelineSequence: 3,
                                content: .richText(.plain("中间历史消息")),
                                createdAt: Date(timeIntervalSince1970: 1_700_840_300)
                            )
                        ])
                    )
                case 3:
                    await requestCounter.increment("loadOlderBackground")
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody([
                            IMConversationMessageResponseBody(
                                id: backgroundTargetMessageID,
                                conversationID: backgroundConversationID,
                                senderUserID: peerUserID,
                                clientMessageID: nil,
                                serverSequence: 2,
                                timelineSequence: 2,
                                content: .richText(.plain("后台实时未读")),
                                derivedState: IMMessageDerivedState(recallState: .recalled),
                                createdAt: Date(timeIntervalSince1970: 1_700_840_200)
                            )
                        ])
                    )
                case 2:
                    return HTTPFixtures.response(statusCode: 200, body: try Self.emptyTimelineBody())
                default:
                    Issue.record("收到未预期的历史补页 beforeSequence：\(beforeSequence.map(String.init) ?? "nil")")
                    return HTTPFixtures.response(statusCode: 500)
                }
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/timeline/since"):
                await requestCounter.increment("gapSyncSelected")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: selectedConversationID, afterSequence: afterSequence))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/timeline/since"):
                await requestCounter.increment("gapSyncBackground")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: backgroundConversationID, afterSequence: afterSequence))
                )
            case ("POST", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                await requestCounter.increment("markRead")
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
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString
                    && manager.imConnectionStatus == .connected
                    && manager.imConversationStore.conversations.count == 2
                    && manager.imConversationStore.conversations.first(where: {
                        $0.id == backgroundConversationID.uuidString
                    })?.messages.count == 1
            }
        }

        let backgroundBeforeRefresh = try #require(
            manager.imConversationStore.conversations.first(where: {
                $0.id == backgroundConversationID.uuidString
            })
        )
        let cachedReply = try #require(backgroundBeforeRefresh.messages.last)
        #expect(cachedReply.resolvedReplyReference(in: backgroundBeforeRefresh.messages) == IMReplyReferenceResolution(
            state: .unavailable,
            text: "稍后会被撤回的引用目标"
        ))

        _ = await state.recallMessage(
            id: backgroundTargetMessageID,
            in: backgroundConversationID,
            senderUserID: peerUserID
        )
        await state.updateReadState(
            for: backgroundConversationID,
            lastReadSequence: 4,
            unreadCount: 0
        )

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        let backgroundAfterChanges = try #require(
            manager.imConversationStore.conversations.first(where: {
                $0.id == backgroundConversationID.uuidString
            })
        )
        let replyAfterChanges = try #require(backgroundAfterChanges.messages.last)
        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(backgroundAfterChanges.serverLastReadSequence == 4)
        #expect(backgroundAfterChanges.unreadCount == 0)
        #expect(backgroundAfterChanges.localUnreadDelta == 0)
        #expect(replyAfterChanges.resolvedReplyReference(in: backgroundAfterChanges.messages) == IMReplyReferenceResolution(
            state: .unavailable,
            text: "稍后会被撤回的引用目标"
        ))

        await manager.openIMConversation(backgroundConversationID.uuidString)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == backgroundConversationID.uuidString
            }
        }

        await manager.loadOlderIMMessages()
        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = manager.imConversationStore.selectedConversation
                return (selectedConversation?.messages.count ?? 0) >= 2
                    && selectedConversation?.messages.last?.text == "缓存里的 reply"
            }
        }

        let afterFirstPage = try #require(manager.imConversationStore.selectedConversation)
        let replyAfterFirstPage = try #require(afterFirstPage.messages.last)
        if afterFirstPage.messages.count == 2 {
            #expect(afterFirstPage.messages.map(\.text) == [
                "中间历史消息",
                "缓存里的 reply"
            ])
            #expect(replyAfterFirstPage.resolvedReplyReference(in: afterFirstPage.messages) == IMReplyReferenceResolution(
                state: .unavailable,
                text: "稍后会被撤回的引用目标"
            ))
        }

        if afterFirstPage.messages.count < 3 {
            await manager.loadOlderIMMessages()
        }
        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = manager.imConversationStore.selectedConversation
                guard let replyMessage = selectedConversation?.messages.last else {
                    return false
                }

                return selectedConversation?.messages.map(\.text) == [
                    "撤回了一条消息",
                    "中间历史消息",
                    "缓存里的 reply"
                ] && replyMessage.resolvedReplyReference(in: selectedConversation?.messages ?? []) == IMReplyReferenceResolution(
                    state: .recalled,
                    text: "原消息已撤回"
                )
            }
        }

        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: backgroundGapMessageID,
                conversationID: backgroundConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 5,
                timelineSequence: 5,
                content: .richText(.plain("重连后补进的新消息")),
                createdAt: Date(timeIntervalSince1970: 1_700_840_500)
            ),
            unreadCount: 0,
            lastReadSequence: 5
        )

        try await Task.sleep(for: .seconds(5.2))
        let gapRequestsBeforeReconnect = await requestCounter.count(for: "gapSyncBackground")
        await manager.reconnectIMConnection()

        var didConverge = false
        var lastConvergenceState = ""
        for _ in 0..<1_000 {
            didConverge = await MainActor.run {
                guard let selectedConversation = manager.imConversationStore.selectedConversation,
                      let replyMessage = selectedConversation.messages.dropLast().last
                else {
                    lastConvergenceState = "selected=nil selectedID=\(manager.imConversationStore.selectedConversationID ?? "nil")"
                    return false
                }

                let resolution = replyMessage.resolvedReplyReference(in: selectedConversation.messages)
                lastConvergenceState = "selectedID=\(manager.imConversationStore.selectedConversationID ?? "nil") read=\(selectedConversation.serverLastReadSequence) unread=\(selectedConversation.unreadCount) localDelta=\(selectedConversation.localUnreadDelta) messages=\(selectedConversation.messages.map(\.text)) resolution=\(String(describing: resolution))"
                return manager.imConversationStore.selectedConversationID == backgroundConversationID.uuidString
                    && selectedConversation.serverLastReadSequence == 5
                    && selectedConversation.unreadCount == 0
                    && selectedConversation.localUnreadDelta == 0
                    && selectedConversation.messages.map(\.text) == [
                        "撤回了一条消息",
                        "中间历史消息",
                        "缓存里的 reply",
                        "重连后补进的新消息"
                    ]
                    && replyMessage.resolvedReplyReference(in: selectedConversation.messages) == IMReplyReferenceResolution(
                        state: .recalled,
                        text: "原消息已撤回"
                    )
            }

            if didConverge {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(didConverge, "Convergence state: \(lastConvergenceState)")

        #expect(await requestCounter.count(for: "gapSyncBackground") > gapRequestsBeforeReconnect)
        #expect(await requestCounter.count(for: "messagesBackgroundLatestPage") <= 1)
    }



    @Test func jumpToReferencedIMMessageLoadsOlderPagesUntilTargetIsFound() async throws {
        let requestCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-4444-5555-6666-bbbbbbbbbbbb")!
        let targetMessageID = UUID(uuidString: "11111111-4444-5555-6666-aaaaaaaaaaaa")!
        let intermediateMessageID = UUID(uuidString: "22222222-4444-5555-6666-aaaaaaaaaaaa")!
        let replyMessageID = UUID(uuidString: "33333333-4444-5555-6666-aaaaaaaaaaaa")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let components = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let beforeSequence = queryItems.first(where: { $0.name == "beforeSequence" })?.value.flatMap(UInt64.init)

            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-jump-1",
                        refreshToken: "refresh-jump-1"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        IMConversationSummaryPageResponseBody(
                            items: [
                                IMConversationSummaryResponseBody(
                                    id: conversationID,
                                    title: "Reply Jump",
                                    kind: IMConversationKind.group.rawValue,
                                    memberCount: 2,
                                    memberUserIDs: [Self.user.id, peerUserID],
                                    lastMessage: IMMessagePreviewResponseBody(
                                        id: replyMessageID,
                                        senderUserID: peerUserID,
                                        serverSequence: 4,
                                        timelineSequence: 4,
                                        content: .reply(
                                            reference: IMReplyReference(
                                                messageID: targetMessageID.uuidString,
                                                senderUserID: peerUserID,
                                                previewText: "更早的引用目标"
                                            ),
                                            body: .plain("reply body")
                                        ),
                                        createdAt: Date(timeIntervalSince1970: 1_700_960_400)
                                    ),
                                    lastReadSequence: 4,
                                    unreadCount: 0,
                                    createdAt: Date(timeIntervalSince1970: 1_700_960_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_700_960_400)
                                )
                            ],
                            nextCursor: nil,
                            hasMore: false,
                            snapshotToken: "snapshot-jump"
                        )
                    )
                )
            case ("GET", "/api/im/conversations/changes"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationChangesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline"):
                switch beforeSequence {
                case nil:
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody([
                            IMConversationMessageResponseBody(
                                id: replyMessageID,
                                conversationID: conversationID,
                                senderUserID: peerUserID,
                                clientMessageID: nil,
                                serverSequence: 4,
                                timelineSequence: 4,
                                content: .reply(
                                    reference: IMReplyReference(
                                        messageID: targetMessageID.uuidString,
                                        senderUserID: peerUserID,
                                        previewText: "更早的引用目标"
                                    ),
                                    body: .plain("reply body")
                                ),
                                createdAt: Date(timeIntervalSince1970: 1_700_960_400)
                            )
                        ])
                    )
                case 4:
                    await requestCounter.increment("loadOlder")
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody([
                            IMConversationMessageResponseBody(
                                id: intermediateMessageID,
                                conversationID: conversationID,
                                senderUserID: peerUserID,
                                clientMessageID: nil,
                                serverSequence: 3,
                                timelineSequence: 3,
                                content: .richText(.plain("中间历史消息")),
                                createdAt: Date(timeIntervalSince1970: 1_700_960_300)
                            )
                        ])
                    )
                case 3:
                    await requestCounter.increment("loadOlder")
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody([
                            IMConversationMessageResponseBody(
                                id: targetMessageID,
                                conversationID: conversationID,
                                senderUserID: peerUserID,
                                clientMessageID: nil,
                                serverSequence: 2,
                                timelineSequence: 2,
                                content: .richText(.plain("回复跳转目标")),
                                derivedState: IMMessageDerivedState(recallState: .recalled),
                                createdAt: Date(timeIntervalSince1970: 1_700_960_200)
                            )
                        ])
                    )
                default:
                    Issue.record("收到未预期的 reply jump 历史补页 beforeSequence：\(beforeSequence.map(String.init) ?? "nil")")
                    return HTTPFixtures.response(statusCode: 500)
                }
            case ("GET", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/timeline/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyTimelineBody())
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
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await manager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["reply body"]
            }
        }

        await manager.jumpToReferencedIMMessage(targetMessageID.uuidString, in: conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = manager.imConversationStore.selectedConversation
                return manager.imConversationStore.replyJumpState == .found
                    && manager.imConversationStore.replyJumpMatchedMessageID == targetMessageID.uuidString
                    && selectedConversation?.messages.map(\.text) == [
                        "撤回了一条消息",
                        "中间历史消息",
                        "reply body"
                    ]
                    && selectedConversation?.messages.last?.resolvedReplyReference(
                        in: selectedConversation?.messages ?? []
                    ) == IMReplyReferenceResolution(
                        state: .recalled,
                        text: "原消息已撤回"
                    )
            }
        }

        #expect(await requestCounter.count(for: "loadOlder") == 2)
    }


}
