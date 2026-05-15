@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Summary change log writer skips missing summaries")
    func summaryChangeLogWriterSkipsMissingSummaries() async throws {
        try await withApp(configure: configure) { app in
            try await IMConversationSummaryProjectionService(db: app.db).recordConversationSummaryChanges(
                conversationID: UUID(),
                recipientUserIDs: [UUID()]
            )

            let count = try await ConversationChangesLogEntry.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test("IM conversations endpoint returns member conversations with latest message")
    func imConversations() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "chat-peer@example.com", on: app)
            let conversation = Conversation(title: "Demo Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_002))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try otherUser.requireID(),
                serverSequence: 1,
                kind: "text",
                body: ["text": "hello from history"]
            ).create(on: app.db)
            try await IMConversationSummaryProjectionService(db: app.db)
                .rebuildSummaries(for: try demoUser.requireID())

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].title == "Demo Chat")
                #expect(conversations[0].kind == IMConversationKind.group.rawValue)
                #expect(conversations[0].directMessagingState == nil)
                #expect(conversations[0].memberCount == 2)
                #expect(conversations[0].memberUserIDs.count == 2)
                #expect(conversations[0].lastMessage?.serverSequence == 1)
                #expect(conversations[0].lastMessage?.body["text"] == "hello from history")
                #expect(conversations[0].lastReadSequence == 0)
                #expect(conversations[0].unreadCount == 1)
            })
        }
    }


    @Test("IM conversations read path does not auto rebuild missing summaries")
    func imConversationsReadPathDoesNotAutoRebuildMissingSummaries() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "projection-owner@example.com", on: app)
            let peer = try await makeUser(email: "projection-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let accessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "projection-owner-device",
                on: app
            )

            let conversation = Conversation(
                title: "Needs Backfill",
                updatedAt: Date(timeIntervalSince1970: 1_700_120_000)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: peerID,
                serverSequence: 1,
                kind: "text",
                body: ["text": "needs rebuild"]
            ).create(on: app.db)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.isEmpty)
            })

            try await IMConversationSummaryProjectionService(db: app.db)
                .rebuildSummaries(for: ownerID)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.count == 1)
                #expect(page.items.first?.id == conversationID)
                #expect(page.items.first?.lastMessage?.content.previewText == "needs rebuild")
            })
        }
    }


    @Test("IM conversation summary endpoints page from projection records")
    func imConversationSummaryEndpointsPageFromProjectionRecords() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "summary-owner@example.com", on: app)
            let peer = try await makeUser(email: "summary-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let accessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "summary-owner-device",
                on: app
            )

            var baselineToken = ""
            try await app.testing().test(.GET, "api/im/conversations?limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.isEmpty)
                baselineToken = page.snapshotToken
            })

            let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
            let secondConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
            let thirdConversationID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!

            let readModelDB = app.summaryShardRouter.database(forOwnerUserID: ownerID)
            let summaries = try [
                makeConversationSummaryProjection(
                    ownerUserID: ownerID,
                    conversationID: firstConversationID,
                    peerUserID: peerID,
                    title: "Newest",
                    serverSequence: 3,
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_220_300),
                    updatedAt: Date(timeIntervalSince1970: 1_700_220_300)
                ),
                makeConversationSummaryProjection(
                    ownerUserID: ownerID,
                    conversationID: secondConversationID,
                    peerUserID: peerID,
                    title: "Middle",
                    serverSequence: 2,
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_220_200),
                    updatedAt: Date(timeIntervalSince1970: 1_700_220_200)
                ),
                makeConversationSummaryProjection(
                    ownerUserID: ownerID,
                    conversationID: thirdConversationID,
                    peerUserID: peerID,
                    title: "Oldest",
                    serverSequence: 1,
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_220_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_220_100)
                )
            ]
            for summary in summaries {
                try await summary.create(on: readModelDB)
                try await ConversationChangesLogEntry(
                    ownerUserID: ownerID,
                    conversationID: summary.conversationID,
                    summaryRecordID: try #require(summary.id),
                    updatedAt: summary.updatedAt,
                    isRemoved: summary.isRemoved
                ).create(on: readModelDB)
            }

            var pageCursor = ""
            try await app.testing().test(.GET, queryPath("api/im/conversations", items: [
                URLQueryItem(name: "limit", value: "2")
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.map(\.id) == [firstConversationID, secondConversationID])
                #expect(page.hasMore == true)
                pageCursor = try #require(page.nextCursor)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations", items: [
                URLQueryItem(name: "limit", value: "2"),
                URLQueryItem(name: "cursor", value: pageCursor)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let page = try res.content.decode(IMConversationPageResponse.self)
                #expect(page.items.map(\.id) == [thirdConversationID])
                #expect(page.hasMore == false)
                #expect(page.nextCursor == nil)
            })

            var changesCursor = ""
            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken),
                URLQueryItem(name: "limit", value: "2")
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.map(\.id) == [thirdConversationID, secondConversationID])
                #expect(changes.removedConversationIDs.isEmpty)
                #expect(changes.hasMore == true)
                changesCursor = try #require(changes.nextCursor)
                #expect(changes.targetToken != baselineToken)
            })

            try await app.testing().test(.GET, queryPath("api/im/conversations/changes", items: [
                URLQueryItem(name: "afterToken", value: baselineToken),
                URLQueryItem(name: "limit", value: "2"),
                URLQueryItem(name: "cursor", value: changesCursor)
            ]), beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                let changes = try res.content.decode(IMConversationChangesResponse.self)
                #expect(changes.upserts.map(\.id) == [firstConversationID])
                #expect(changes.removedConversationIDs.isEmpty)
                #expect(changes.hasMore == false)
                #expect(changes.nextCursor == nil)
            })
        }
    }


    @Test("IM members endpoint returns role-aware sorted members for members only")
    func imConversationMembers() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "members-peer@example.com", on: app)
            let adminUser = try await makeUser(email: "members-admin@example.com", on: app)
            let conversation = Conversation(title: "Members Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_030))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            )
                .create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try adminUser.requireID(),
                role: .admin
            )
                .create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try otherUser.requireID(),
                role: .member
            )
                .create(on: app.db)

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let memberPage = try res.content.decode(IMConversationMemberPageResponse.self)
                let members = memberPage.items
                #expect(members.map(\.email) == [
                    "demo@example.com",
                    "members-admin@example.com",
                    "members-peer@example.com"
                ])
                #expect(members.map(\.role) == [
                    IMConversationMemberRole.owner.rawValue,
                    IMConversationMemberRole.admin.rawValue,
                    IMConversationMemberRole.member.rawValue
                ])
            })
        }
    }


    @Test("IM messages endpoint returns ordered conversation history for members only")
    func imMessages() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "history-peer@example.com", on: app)
            let conversation = Conversation(title: nil, updatedAt: Date(timeIntervalSince1970: 1_700_100_010))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 1,
                clientMessageID: "client-history-1",
                kind: "text",
                body: ["text": "first"]
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try otherUser.requireID(),
                serverSequence: 2,
                clientMessageID: "client-history-2",
                kind: "text",
                body: ["text": "second"]
            ).create(on: app.db)
            try await IMConversationSummaryProjectionService(db: app.db)
                .rebuildSummaries(for: try demoUser.requireID())

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.map(\.serverSequence) == [1, 2])
                #expect(messages.map(\.clientMessageID) == ["client-history-1", "client-history-2"])
                #expect(messages.map { $0.body["text"] } == ["first", "second"])
            })

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.first?.id == conversationID)
                #expect(conversations.first?.unreadCount == 2)
            })

            let stranger = try await makeUser(email: "outsider@example.com", on: app)
            let strangerAccessToken = try await loginAccessToken(
                email: "outsider@example.com",
                password: "password1234",
                deviceID: "outsider-device",
                on: app
            )
            _ = stranger

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }


    @Test("IM conversation search matches text, reply, system, and file content with stable pagination")
    func imConversationSearchMatchesStructuredContentAndPaginates() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "search-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Search Chat",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_040)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try peerUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 1,
                content: .text("alpha release notes")
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 2,
                content: .reply(
                    reference: IMReplyReference(
                        messageID: UUID().uuidString,
                        senderUserID: try peerUser.requireID(),
                        previewText: "alpha sprint preview"
                    ),
                    text: "beta reply"
                )
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 3,
                content: .system(
                    IMSystemEvent(
                        type: .metadataUpdated,
                        actorUserID: try demoUser.requireID(),
                        actorEmail: demoUser.email,
                        updatedFields: [.title]
                    )
                )
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 4,
                content: .file(
                    IMMediaAsset(
                        assetID: "asset-plan",
                        kind: .file,
                        mimeType: "application/pdf",
                        byteSize: 2_048,
                        filename: "alpha-plan.pdf",
                        width: nil,
                        height: nil,
                        durationMillis: nil,
                        previewAssetID: nil
                    )
                )
            ).create(on: app.db)

            try await app.testing().test(
                .GET,
                queryPath("api/im/conversations/\(conversationID.uuidString)/search", items: [
                    URLQueryItem(name: "q", value: "alpha"),
                    URLQueryItem(name: "limit", value: "2")
                ]),
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let page = try res.content.decode(IMConversationMessageSearchPageResponse.self)
                    #expect(page.items.map(\.serverSequence) == [4, 2])
                    #expect(page.items.map(\.snippet) == ["alpha-plan.pdf", "alpha sprint preview"])
                    #expect(page.hasMore == true)
                    #expect(page.nextCursor == "2")
                }
            )

            try await app.testing().test(
                .GET,
                queryPath("api/im/conversations/\(conversationID.uuidString)/search", items: [
                    URLQueryItem(name: "q", value: "alpha"),
                    URLQueryItem(name: "cursor", value: "2")
                ]),
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let page = try res.content.decode(IMConversationMessageSearchPageResponse.self)
                    #expect(page.items.map(\.serverSequence) == [1])
                    #expect(page.items.map(\.snippet) == ["alpha release notes"])
                    #expect(page.hasMore == false)
                    #expect(page.nextCursor == nil)
                }
            )

            try await app.testing().test(
                .GET,
                queryPath("api/im/conversations/\(conversationID.uuidString)/search", items: [
                    URLQueryItem(name: "q", value: "群名称")
                ]),
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let page = try res.content.decode(IMConversationMessageSearchPageResponse.self)
                    #expect(page.items.map(\.serverSequence) == [3])
                    #expect(page.items.first?.content.previewText == "\(demoUser.email) 更新了群名称")
                }
            )
        }
    }


    @Test("IM conversation search respects visibleFromSequence for rejoined members")
    func imConversationSearchRespectsVisibleFromSequence() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "search-visible-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Visible Search",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_041)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            let membership = ConversationMember(
                conversationID: conversationID,
                userID: try demoUser.requireID(),
                role: .owner
            )
            try await membership.create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try peerUser.requireID(),
                role: .member
            ).create(on: app.db)

            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 1,
                content: .text("visible archive before rejoin")
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 2,
                content: .text("visible archive still old")
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 3,
                content: .text("visible timeline after rejoin")
            ).create(on: app.db)

            membership.visibleFromSequence = 3
            membership.lastReadSequence = 2
            try await membership.update(on: app.db)

            try await app.testing().test(
                .GET,
                queryPath("api/im/conversations/\(conversationID.uuidString)/search", items: [
                    URLQueryItem(name: "q", value: "visible")
                ]),
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let page = try res.content.decode(IMConversationMessageSearchPageResponse.self)
                    #expect(page.items.map(\.serverSequence) == [3])
                    #expect(page.items.first?.snippet == "visible timeline after rejoin")
                }
            )
        }
    }


    @Test("IM new members only see messages from their visible history window")
    func imConversationHistoryRespectsVisibleFromSequenceForNewMembers() async throws {
        try await withApp(configure: configure) { app in
            let ownerToken = try await loginAccessToken(using: app)
            let ownerUser = try await user(email: "demo@example.com", on: app)
            let existingUser = try await makeUser(email: "visible-existing@example.com", on: app)
            let newUser = try await makeUser(email: "visible-new@example.com", on: app)
            let newUserToken = try await loginAccessToken(
                email: newUser.email,
                password: "password1234",
                deviceID: "visible-new-device",
                on: app
            )

            let conversation = Conversation(
                title: "Visible Window",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_500_300)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(
                conversationID: conversationID,
                userID: try ownerUser.requireID(),
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try existingUser.requireID(),
                role: .member
            ).create(on: app.db)

            _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "visible-before-join",
                    text: "before join"
                ),
                senderUserID: try ownerUser.requireID()
            )

            try await app.testing().test(.POST, "api/im/conversations/\(conversationID.uuidString)/members", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
                try req.content.encode(
                    IMConversationMemberUpdateRequest(memberEmails: [newUser.email])
                )
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "visible-after-join",
                    text: "after join"
                ),
                senderUserID: try ownerUser.requireID()
            )

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: newUserToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.map(\.serverSequence) == [2, 3])
                #expect(messages.map(\.content.previewText) == [
                    "demo@example.com 添加了 visible-new@example.com",
                    "after join"
                ])
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: newUserToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(IMMessageSinceResponse.self)
                #expect(payload.messages.map(\.serverSequence) == [2, 3])
                #expect(payload.nextAfterSequence == 3)
            })
        }
    }


    @Test("Conversation summary verify reports stale and mismatched projections")
    func conversationSummaryVerifyReportsProjectionDrift() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let ownerUserID = try owner.requireID()
            let peer = try await makeUser(email: "verify-peer@example.com", on: app)
            let peerUserID = try peer.requireID()
            let liveConversation = Conversation(
                title: "Verify Live",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_950_000)
            )
            try await liveConversation.create(on: app.db)
            let liveConversationID = try liveConversation.requireID()

            try await ConversationMember(
                conversationID: liveConversationID,
                userID: ownerUserID,
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: liveConversationID,
                userID: peerUserID,
                role: .member
            ).create(on: app.db)

            _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: liveConversationID,
                    clientMessageID: "verify-live-message",
                    text: "verify message"
                ),
                senderUserID: ownerUserID
            )
            try await app.processInlineOutboxProjectionIfAllowed()

            guard let mismatchedSummary = try await ConversationUserSummary.find(
                ConversationUserSummary.recordID(
                    ownerUserID: ownerUserID,
                    conversationID: liveConversationID
                ),
                on: app.db
            ) else {
                Issue.record("Expected refreshConversationSummaries to create a live summary")
                return
            }
            mismatchedSummary.lastMessage = nil
            mismatchedSummary.lastReadSequence = 0
            mismatchedSummary.unreadCount = 0
            try await mismatchedSummary.update(on: app.db)

            let staleConversationID = UUID()
            let staleSummary = try makeConversationSummaryProjection(
                ownerUserID: ownerUserID,
                conversationID: staleConversationID,
                peerUserID: peerUserID,
                title: "Stale Active",
                serverSequence: 2,
                lastActivityAt: Date(timeIntervalSince1970: 1_700_950_100),
                updatedAt: Date(timeIntervalSince1970: 1_700_950_100),
                isRemoved: false
            )
            try await staleSummary.create(on: app.db)

            let tombstonedConversationID = UUID()
            let tombstonedSummary = try makeConversationSummaryProjection(
                ownerUserID: ownerUserID,
                conversationID: tombstonedConversationID,
                peerUserID: peerUserID,
                title: "Tombstoned",
                serverSequence: 1,
                lastActivityAt: Date(timeIntervalSince1970: 1_700_950_200),
                updatedAt: Date(timeIntervalSince1970: 1_700_950_200),
                isRemoved: true
            )
            try await tombstonedSummary.create(on: app.db)

            let verification = try await IMConversationSummaryProjectionService(db: app.db)
                .verifySummaries(for: ownerUserID)

            #expect(verification.ownerUserCount == 1)
            #expect(verification.tombstoneSummaryCount == 1)
            #expect(verification.missingSummaryCount == 0)
            #expect(verification.staleActiveSummaryCount == 1)
            #expect(verification.latestVisibleMessageMismatchCount == 1)
            #expect(verification.unreadMismatchCount == 1)
        }
    }


    @Test("IM messages since endpoint returns ordered incremental messages for conversation members only")
    func imMessagesSince() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "since-peer@example.com", on: app)
            let conversation = Conversation(title: "Since Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_015))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...4 {
                let senderID = sequence.isMultiple(of: 2) ? try otherUser.requireID() : try demoUser.requireID()
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    clientMessageID: "client-since-\(sequence)",
                    kind: "text",
                    body: ["text": "since-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMMessageSinceResponse.self)
                let messages = response.messages
                #expect(messages.map(\.serverSequence) == [1, 2, 3, 4])
                #expect(messages.map(\.clientMessageID) == [
                    "client-since-1",
                    "client-since-2",
                    "client-since-3",
                    "client-since-4"
                ])
                #expect(messages.map { $0.body["text"] } == ["since-1", "since-2", "since-3", "since-4"])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 4)
            })

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=2&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMMessageSinceResponse.self)
                let messages = response.messages
                #expect(messages.map(\.serverSequence) == [3, 4])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 4)
            })

            let stranger = try await makeUser(email: "since-outsider@example.com", on: app)
            let strangerAccessToken = try await loginAccessToken(
                email: stranger.email,
                password: "password1234",
                deviceID: "since-outsider-device",
                on: app
            )

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }


    @Test("IM messages since endpoint applies default and maximum limits")
    func imMessagesSinceRespectsLimits() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "since-limit-peer@example.com", on: app)
            let conversation = Conversation(title: "Since Limit Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_025))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...520 {
                let senderID = sequence.isMultiple(of: 2) ? try otherUser.requireID() : try demoUser.requireID()
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    clientMessageID: "client-limit-\(sequence)",
                    kind: "text",
                    body: ["text": "limit-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMMessageSinceResponse.self)
                let messages = response.messages
                #expect(messages.count == 100)
                #expect(messages.first?.serverSequence == 1)
                #expect(messages.last?.serverSequence == 100)
                #expect(response.hasMore == true)
                #expect(response.nextAfterSequence == 100)
            })

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/messages/since?afterSequence=0&limit=999"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMMessageSinceResponse.self)
                let messages = response.messages
                #expect(messages.count == 500)
                #expect(messages.first?.serverSequence == 1)
                #expect(messages.last?.serverSequence == 500)
                #expect(response.hasMore == true)
                #expect(response.nextAfterSequence == 500)
            })
        }
    }


    @Test("IM messages endpoint supports beforeSequence pagination")
    func imMessagesPagination() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "history-page-peer@example.com", on: app)
            let conversation = Conversation(title: "Paged Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_020))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...4 {
                let senderID = sequence.isMultiple(of: 2) ? try otherUser.requireID() : try demoUser.requireID()
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    kind: "text",
                    body: ["text": "message-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages?limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.map(\.serverSequence) == [3, 4])
                #expect(messages.map { $0.body["text"] } == ["message-3", "message-4"])
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages?beforeSequence=3&limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.map(\.serverSequence) == [1, 2])
                #expect(messages.map { $0.body["text"] } == ["message-1", "message-2"])
            })
        }
    }

}
