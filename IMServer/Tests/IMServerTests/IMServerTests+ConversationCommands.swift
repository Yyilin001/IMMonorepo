@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("IM create conversation endpoint respects explicit direct kind and clears title")
    func createConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "create-peer@example.com", on: app)
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "Fresh Chat",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                createdConversationID = conversation.id
                #expect(conversation.title == nil)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.directMessagingState == IMDirectMessagingState.active.rawValue)
                #expect(conversation.directPeer == IMDirectPeerResponse(id: try peerUser.requireID(), email: peerUser.email))
                #expect(conversation.memberCount == 2)
                #expect(conversation.lastMessage == nil)
                #expect(conversation.lastReadSequence == 0)
                #expect(conversation.unreadCount == 0)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })

            let conversationID = try #require(createdConversationID)
            let directoryEntry = try await ConversationDirectoryEntry.find(conversationID, on: app.db)
            #expect(directoryEntry?.shardID == SingleShardConversationShardRouter.defaultShardID)

            let pairHash = [try demoUser.requireID(), try peerUser.requireID()]
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            let directIndexEntry = try await DirectConversationIndexEntry.find(pairHash, on: app.db)
            #expect(directIndexEntry?.conversationID == conversationID)
        }
    }

    @Test("AI message stream endpoint creates canonical message and exposes completed snapshot")
    func aiMessageStreamCreatesCanonicalMessageAndSnapshot() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "ai-stream-peer@example.com", on: app)

            var createdConversationID: UUID?
            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "AI Stream",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                createdConversationID = try res.content.decode(IMConversationResponse.self).id
            })
            let conversationID = try #require(createdConversationID)

            var response: IMMessageStreamResponse?
            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/ai/messages",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMAIMessageStreamStartRequest(prompt: "hello"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(IMMessageStreamResponse.self)
                    response = body
                    #expect(body.message.conversationID == conversationID)
                    #expect(body.message.derivedState.streamState?.state == .streaming)
                    #expect(body.stream.messageID == body.message.id.uuidString)
                    #expect(body.stream.state == .streaming)
                }
            )

            let started = try #require(response)
            try await Task.sleep(nanoseconds: 250_000_000)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(started.message.id.uuidString)/stream",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(IMMessageStreamResponse.self)
                    #expect(body.message.id == started.message.id)
                    #expect(body.stream.streamID == started.stream.streamID)
                    #expect(body.stream.state == .completed)
                    #expect(body.message.content.previewText == "AI: hello")
                    #expect(body.message.derivedState.streamState?.partialText == "AI: hello")
                }
            )

            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(started.message.id.uuidString)/stream/cancel",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(IMMessageStreamResponse.self)
                    #expect(body.stream.streamID == started.stream.streamID)
                    #expect(body.stream.state == .completed)
                    #expect(body.message.content.previewText == "AI: hello")
                }
            )
        }
    }

    @Test("AI stream startup repair marks stale streaming messages failed")
    func aiMessageStreamStartupRepairMarksStaleStreamsFailed() async throws {
        try await withApp(configure: configure) { app in
            app.aiStreamingProvider = NeverAIStreamingProvider()
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "ai-stream-repair-peer@example.com", on: app)

            var createdConversationID: UUID?
            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "AI Stream Repair",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                createdConversationID = try res.content.decode(IMConversationResponse.self).id
            })
            let conversationID = try #require(createdConversationID)

            var response: IMMessageStreamResponse?
            try await app.testing().test(
                .POST,
                "api/im/conversations/\(conversationID.uuidString)/ai/messages",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(IMAIMessageStreamStartRequest(prompt: "blocked"))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    response = try res.content.decode(IMMessageStreamResponse.self)
                }
            )
            let started = try #require(response)
            let repaired = try await IMAIStreamRepairService(app: app).repairStaleStreamingMessages()
            #expect(repaired >= 1)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/\(started.message.id.uuidString)/stream",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(IMMessageStreamResponse.self)
                    #expect(body.stream.streamID == started.stream.streamID)
                    #expect(body.stream.state == .failed)
                    #expect(body.message.derivedState.streamState?.errorCode == "server_restarted")
                }
            )
        }
    }


    @Test("IM create conversation endpoint creates group for three or more members")
    func createGroupConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let firstPeer = try await makeUser(email: "group-create-first@example.com", on: app)
            let secondPeer = try await makeUser(email: "group-create-second@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Fresh Group",
                        memberEmails: [firstPeer.email, secondPeer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == "Fresh Group")
                #expect(conversation.kind == IMConversationKind.group.rawValue)
                #expect(conversation.memberCount == 3)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try firstPeer.requireID(),
                    try secondPeer.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }


    @Test("IM group creation writes a system message into summary and history")
    func createGroupConversationPersistsSystemMessage() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let firstPeer = try await makeUser(email: "group-system-first@example.com", on: app)
            let secondPeer = try await makeUser(email: "group-system-second@example.com", on: app)
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "System Group",
                        memberEmails: [firstPeer.email, secondPeer.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                createdConversationID = conversation.id
                #expect(conversation.lastMessage?.content.previewText == "\(demoUser.email) 创建了群聊")
                #expect(conversation.lastReadSequence == 1)
                #expect(conversation.unreadCount == 0)
            })

            let conversationID = try #require(createdConversationID)
            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.count == 1)
                #expect(messages[0].content.previewText == "\(demoUser.email) 创建了群聊")
                #expect(messages[0].serverSequence == 1)
            })
        }
    }


    @Test("IM create conversation endpoint preserves explicit group kind for two members")
    func createTwoMemberGroupConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "two-member-group@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.group.rawValue,
                        title: "Two Member Group",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == "Two Member Group")
                #expect(conversation.kind == IMConversationKind.group.rawValue)
                #expect(conversation.memberCount == 2)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }


    @Test("IM create conversation endpoint allows duplicate explicit two-member groups")
    func createTwoMemberGroupConversationDoesNotReuseExistingGroup() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "two-member-group-duplicate@example.com", on: app)
            var createdConversationIDs: [UUID] = []

            for title in ["Two Member Group A", "Two Member Group B"] {
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.group.rawValue,
                            title: title,
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)

                    let conversation = try res.content.decode(IMConversationResponse.self)
                    #expect(conversation.title == title)
                    #expect(conversation.kind == IMConversationKind.group.rawValue)
                    #expect(conversation.memberCount == 2)
                    createdConversationIDs.append(conversation.id)
                })
            }

            #expect(Set(createdConversationIDs).count == 2)

            let conversations = try await Conversation.query(on: app.db).all()
            #expect(conversations.count == 2)
            #expect(conversations.allSatisfy { $0.conversationKind == .group })
        }
    }


    @Test("IM create conversation endpoint marks untitled two-member conversations as direct")
    func createDirectConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "direct-peer@example.com", on: app)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: nil,
                        title: nil,
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.title == nil)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.memberCount == 2)
                #expect(conversation.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == [
                    try demoUser.requireID(),
                    try peerUser.requireID()
                ].sorted { $0.uuidString < $1.uuidString })
            })
        }
    }


    @Test("IM create conversation endpoint reuses existing two-member conversation")
    func createDirectConversationReusesExistingConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let peerUser = try await makeUser(email: "direct-reuse-peer@example.com", on: app)
            var firstConversationID: UUID?
            let requestedTitles: [String?] = [nil, "Duplicate Title"]

            for title in requestedTitles {
                try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(
                        IMConversationCreateRequest(
                            kind: IMConversationKind.direct.rawValue,
                            title: title,
                            memberEmails: [peerUser.email]
                        )
                    )
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)

                    let conversation = try res.content.decode(IMConversationResponse.self)
                    #expect(conversation.title == nil)
                    #expect(conversation.kind == IMConversationKind.direct.rawValue)
                    if let firstConversationID {
                        #expect(conversation.id == firstConversationID)
                    } else {
                        firstConversationID = conversation.id
                    }
                })
            }

            let conversations = try await Conversation.query(on: app.db).all()
            let matchingMemberships = try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == firstConversationID!)
                .all()
            #expect(conversations.count == 1)
            #expect(matchingMemberships.count == 2)
        }
    }


    @Test("IM create conversation endpoint reuses frozen direct conversation")
    func createDirectConversationReusesFrozenConversation() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "direct-frozen-reuse@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()

            let existingConversation = Conversation(
                title: nil,
                kind: .direct,
                directMessagingState: .frozenAfterUnfriend,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_900)
            )
            try await existingConversation.create(on: app.db)
            let existingConversationID = try existingConversation.requireID()

            try await ConversationMember(conversationID: existingConversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: existingConversationID, userID: peerUserID)
                .create(on: app.db)

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "Should Reuse Frozen",
                        memberEmails: [peerUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversation = try res.content.decode(IMConversationResponse.self)
                #expect(conversation.id == existingConversationID)
                #expect(conversation.kind == IMConversationKind.direct.rawValue)
                #expect(conversation.title == nil)
                #expect(conversation.directMessagingState == IMDirectMessagingState.frozenAfterUnfriend.rawValue)
                #expect(conversation.directPeer == IMDirectPeerResponse(id: peerUserID, email: peerUser.email))
            })

            let conversations = try await Conversation.query(on: app.db).all()
            #expect(conversations.count == 1)
            #expect(conversations.first?.directMessagingStateEnum == .frozenAfterUnfriend)

            let pairHash = [demoUserID, peerUserID]
                .map(\.uuidString)
                .sorted()
                .joined(separator: ":")
            let directIndexEntry = try await DirectConversationIndexEntry.find(pairHash, on: app.db)
            #expect(directIndexEntry?.conversationID == existingConversationID)
        }
    }


}

private struct NeverAIStreamingProvider: AIStreamingProvider {
    func streamText(for request: AIStreamingRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { _ in }
    }
}
