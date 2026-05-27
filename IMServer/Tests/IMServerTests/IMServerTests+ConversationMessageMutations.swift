@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("IM recall endpoint marks derived state and refreshes summaries")
    func imRecallMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "recall-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_060),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                timelineSequence: 1,
                content: .richText(.plain("hello recall"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try demoUser.requireID(), try peerUser.requireID()]
            )

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/recall", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let recalled = try res.content.decode(IMMessageResponse.self)
                #expect(recalled.id == messageID)
                #expect(recalled.content == .richText(.plain("hello recall")))
                #expect(recalled.derivedState.recallState == .recalled)
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/timeline", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let timeline = try res.content.decode(IMTimelinePageResponse.self)
                let messages = timeline.items.compactMap(\.message)
                #expect(messages.count == 1)
                #expect(messages[0].id == messageID)
                #expect(messages[0].content == .richText(.plain("hello recall")))
                #expect(messages[0].derivedState.recallState == .recalled)
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].lastMessage?.content == .richText(.plain("hello recall")))
                #expect(conversations[0].lastMessage?.derivedState.recallState == .recalled)
            })
        }
    }


    @Test("IM recall endpoint rejects messages outside the recall window")
    func imRecallMessageRejectsExpiredWindow() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "recall-expired-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_061),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                timelineSequence: 1,
                content: .richText(.plain("expired recall"))
            )
            try await message.create(on: app.db)
            message.createdAt = Date().addingTimeInterval(-(3 * 60))
            try await message.update(on: app.db)
            let messageID = try message.requireID()

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/recall", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("消息发送超过 2 分钟后不能撤回"))
            })
        }
    }


    @Test("IM edit endpoint appends derived edit state and refreshes summary preview")
    func imEditMessageUpdatesDerivedStateAndSummaryPreview() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "edit-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_062),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                timelineSequence: 1,
                content: .richText(.plain("before edit"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await IMConversationSummaryProjectionService(db: app.db).refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [try demoUser.requireID(), try peerUser.requireID()]
            )

            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/edit",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMConversationMessageEditRequest(body: .plain("after edit")))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let edited = try res.content.decode(IMMessageResponse.self)
                    #expect(edited.content == .richText(.plain("before edit")))
                    #expect(edited.derivedState.edits.last?.body.text == "after edit")
                }
            )

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    let timeline = try res.content.decode(IMTimelinePageResponse.self)
                    let messages = timeline.items.compactMap(\.message)
                    #expect(messages.count == 1)
                    #expect(messages[0].content == .richText(.plain("before edit")))
                    #expect(messages[0].derivedState.edits.last?.body.text == "after edit")
                }
            )

            try await app.testing().test(
                .GET,
                "api/im/conversations",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    let conversations = try res.content.decode(IMConversationPageResponse.self).items
                    #expect(conversations.count == 1)
                    #expect(
                        conversations[0].lastMessage.map {
                            MessagePresentation(
                                aggregate: $0.content.aggregate(derivedState: $0.derivedState)
                            ).previewText
                        } == "after edit"
                    )
                    #expect(conversations[0].lastMessage?.derivedState.edits.last?.body.text == "after edit")
                }
            )
        }
    }


    @Test("IM reaction endpoint toggles derived reaction state")
    func imToggleReactionUpdatesDerivedState() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "reaction-peer@example.com", on: app)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_063),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 1,
                timelineSequence: 1,
                content: .richText(.plain("react here"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/reactions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMConversationMessageReactionRequest(emoji: "👍"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let updated = try res.content.decode(IMMessageResponse.self)
                    #expect(updated.derivedState.reactions == [
                        IMMessageReaction(emoji: "👍", actorUserIDs: [try demoUser.requireID()])
                    ])
                }
            )

            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(messageID.uuidString)/reactions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMConversationMessageReactionRequest(emoji: "👍"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let updated = try res.content.decode(IMMessageResponse.self)
                    #expect(updated.derivedState.reactions.isEmpty)
                }
            )
        }
    }


}
