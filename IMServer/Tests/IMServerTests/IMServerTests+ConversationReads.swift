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

    @Test("Summary list omits large-group member IDs by response limit")
    func summaryListOmitsLargeGroupMemberIDsByResponseLimit() async throws {
        try await withApp(configure: configure) { app in
            let ownerID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010001")!
            let memberIDs = [
                ownerID,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010002")!,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010003")!
            ]
            let conversationID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010004")!
            try await ConversationUserSummary(
                ownerUserID: ownerID,
                conversationID: conversationID,
                title: "Large Summary",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeerUserID: nil,
                directPeerEmail: nil,
                memberUserIDs: memberIDs,
                lastMessage: nil,
                lastReadSequence: 0,
                unreadCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_415_001),
                updatedAt: Date(timeIntervalSince1970: 1_710_415_001),
                isRemoved: false
            ).create(on: app.imSummaryDB)

            let page = try await IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: app.imSummaryDB,
                responseMemberUserIDsLimit: 2
            ).listConversations(
                for: ownerID,
                cursor: nil,
                limit: 10
            )

            let item = try #require(page.items.first)
            #expect(item.memberCount == 3)
            #expect(item.memberUserIDs.isEmpty)
        }
    }

    @Test("Summary changes omit large-group member IDs by response limit")
    func summaryChangesOmitsLargeGroupMemberIDsByResponseLimit() async throws {
        try await withApp(configure: configure) { app in
            let ownerID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010011")!
            let memberIDs = [
                ownerID,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010012")!,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010013")!
            ]
            let conversationID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010014")!
            let summary = try ConversationUserSummary(
                ownerUserID: ownerID,
                conversationID: conversationID,
                title: "Large Changes",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeerUserID: nil,
                directPeerEmail: nil,
                memberUserIDs: memberIDs,
                lastMessage: nil,
                lastReadSequence: 0,
                unreadCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_415_011),
                updatedAt: Date(timeIntervalSince1970: 1_710_415_011),
                isRemoved: false
            )
            try await summary.create(on: app.imSummaryDB)
            let recordID = try #require(summary.id)
            try await ConversationChangesLogEntry(
                ownerUserID: ownerID,
                conversationID: conversationID,
                summaryRecordID: recordID,
                updatedAt: Date(timeIntervalSince1970: 1_710_415_012),
                isRemoved: false
            ).create(on: app.imSummaryDB)

            let response = try await IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: app.imSummaryDB,
                responseMemberUserIDsLimit: 2
            ).listConversationChanges(
                for: ownerID,
                afterToken: IMConversationSummaryProjectionService.encodeChangeToken(
                    IMConversationSummaryProjectionService.ChangeToken(updatedAt: .distantPast, recordID: "")
                ),
                cursor: nil,
                limit: 10
            )

            let item = try #require(response.upserts.first)
            #expect(item.memberCount == 3)
            #expect(item.memberUserIDs.isEmpty)
        }
    }

    @Test("Single summary read omits large-group member IDs by response limit")
    func singleSummaryReadOmitsLargeGroupMemberIDsByResponseLimit() async throws {
        try await withApp(configure: configure) { app in
            let ownerID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010021")!
            let memberIDs = [
                ownerID,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010022")!,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010023")!
            ]
            let conversationID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000010024")!
            try await ConversationUserSummary(
                ownerUserID: ownerID,
                conversationID: conversationID,
                title: "Large Single",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeerUserID: nil,
                directPeerEmail: nil,
                memberUserIDs: memberIDs,
                lastMessage: nil,
                lastReadSequence: 0,
                unreadCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_415_021),
                updatedAt: Date(timeIntervalSince1970: 1_710_415_021),
                isRemoved: false
            ).create(on: app.imSummaryDB)

            let response = try await DatabaseSummaryReadModelStore(
                summaryDB: app.imSummaryDB,
                responseMemberUserIDsLimit: 2
            ).conversationSummary(
                conversationID: conversationID,
                for: ownerID
            )

            #expect(response.memberCount == 3)
            #expect(response.memberUserIDs.isEmpty)
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
                timelineSequence: 1,
                kind: "rich_text",
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
                timelineSequence: 1,
                kind: "rich_text",
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

    @Test("Conversation list and changes overlay large-group activity summaries")
    func conversationListAndChangesOverlayLargeGroupActivitySummaries() async throws {
        let key = "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "activity-list-owner@example.com", on: app)
            let peer = try await makeUser(email: "activity-list-peer@example.com", on: app)
            let third = try await makeUser(email: "activity-list-third@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let thirdID = try third.requireID()
            let readModelDB = app.summaryShardRouter.database(forOwnerUserID: ownerID)

            let activeConversationID = UUID(uuidString: "dddddddd-1111-2222-3333-aaaaaaaaaaaa")!
            let otherConversationID = UUID(uuidString: "eeeeeeee-1111-2222-3333-bbbbbbbbbbbb")!
            let oldActivityAt = Date(timeIntervalSince1970: 1_700_230_100)
            let otherActivityAt = Date(timeIntervalSince1970: 1_700_230_200)
            let largeGroupActivityAt = Date(timeIntervalSince1970: 1_700_230_300)

            let activeConversation = Conversation(
                id: activeConversationID,
                title: "Large Activity",
                kind: .group,
                updatedAt: oldActivityAt,
                lastMessageSequence: 5
            )
            try await activeConversation.create(on: app.db)
            for userID in [ownerID, peerID, thirdID] {
                try await ConversationMember(
                    conversationID: activeConversationID,
                    userID: userID,
                    role: userID == ownerID ? .owner : .member,
                    lastReadSequence: 0
                ).create(on: app.db)
            }

            let activeSummary = try makeConversationSummaryProjection(
                ownerUserID: ownerID,
                conversationID: activeConversationID,
                peerUserID: peerID,
                title: "Large Activity",
                serverSequence: 1,
                lastActivityAt: oldActivityAt,
                updatedAt: oldActivityAt
            )
            let otherSummary = try makeConversationSummaryProjection(
                ownerUserID: ownerID,
                conversationID: otherConversationID,
                peerUserID: peerID,
                title: "Currently Newest",
                serverSequence: 2,
                lastActivityAt: otherActivityAt,
                updatedAt: otherActivityAt
            )
            for summary in [activeSummary, otherSummary] {
                try await summary.create(on: readModelDB)
                try await ConversationChangesLogEntry(
                    ownerUserID: ownerID,
                    conversationID: summary.conversationID,
                    summaryRecordID: try #require(summary.id),
                    updatedAt: summary.updatedAt,
                    isRemoved: false
                ).create(on: readModelDB)
            }

            let projection = IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: readModelDB
            )
            let baselinePage = try await projection.listConversations(
                for: ownerID,
                cursor: nil,
                limit: 10
            )
            #expect(baselinePage.items.map(\.id) == [otherConversationID, activeConversationID])
            let baselineToken = baselinePage.snapshotToken

            let message = try ConversationMessage(
                conversationID: activeConversationID,
                senderUserID: peerID,
                serverSequence: 5,
                timelineSequence: 5,
                clientMessageID: "activity-list-message",
                content: .richText(.plain("large group activity update"))
            )
            message.createdAt = largeGroupActivityAt
            try await message.create(on: app.db)

            try await projection.applyMessageCreated(
                conversationID: activeConversationID,
                messageID: try message.requireID(),
                recipientUserIDs: [ownerID, peerID, thirdID],
                on: app.db,
                writeChangeLog: true
            )

            let activeSummaryAfterProjection = try #require(
                try await ConversationUserSummary.find(
                    ConversationUserSummary.recordID(ownerUserID: ownerID, conversationID: activeConversationID),
                    on: readModelDB
                )
            )
            #expect(activeSummaryAfterProjection.lastMessage?.serverSequence == 1)
            #expect(
                try await ConversationChangesLogEntry.find(
                    ConversationChangesLogEntry.recordID(ownerUserID: ownerID, conversationID: activeConversationID),
                    on: readModelDB
                )?.updatedAt == oldActivityAt
            )

            let updatedPage = try await projection.listConversations(
                for: ownerID,
                cursor: nil,
                limit: 10
            )
            #expect(updatedPage.items.map(\.id) == [activeConversationID, otherConversationID])
            #expect(updatedPage.items.first?.lastMessage?.body["text"] == "large group activity update")
            #expect(updatedPage.items.first?.lastMessage?.serverSequence == 5)
            #expect(updatedPage.items.first?.unreadCount == 5)
            #expect(updatedPage.snapshotToken != baselineToken)

            let ancientToken = IMConversationSummaryProjectionService.encodeChangeToken(
                IMConversationSummaryProjectionService.ChangeToken(updatedAt: .distantPast, recordID: "")
            )
            let fullChanges = try await projection.listConversationChanges(
                for: ownerID,
                afterToken: ancientToken,
                cursor: nil,
                limit: 10
            )
            #expect(fullChanges.upserts.map(\.id) == [otherConversationID, activeConversationID])
            #expect(fullChanges.upserts.filter { $0.id == activeConversationID }.count == 1)

            let changes = try await projection.listConversationChanges(
                for: ownerID,
                afterToken: baselineToken,
                cursor: nil,
                limit: 10
            )
            #expect(changes.upserts.map(\.id) == [activeConversationID])
            #expect(changes.upserts.first?.lastMessage?.body["text"] == "large group activity update")
            #expect(changes.upserts.first?.unreadCount == 5)
            #expect(changes.removedConversationIDs.isEmpty)
            #expect(changes.hasMore == false)
            #expect(changes.targetToken != baselineToken)
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
                timelineSequence: 1,
                clientMessageID: "client-history-1",
                kind: "rich_text",
                body: ["text": "first"]
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try otherUser.requireID(),
                serverSequence: 2,
                timelineSequence: 2,
                clientMessageID: "client-history-2",
                kind: "rich_text",
                body: ["text": "second"]
            ).create(on: app.db)
            try await IMConversationSummaryProjectionService(db: app.db)
                .rebuildSummaries(for: try demoUser.requireID())

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/timeline", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let timeline = try res.content.decode(IMTimelinePageResponse.self)
                let messages = timeline.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [1, 2])
                #expect(messages.map(\.timelineSequence) == [1, 2])
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

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/timeline", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }


    @Test("IM conversation search matches indexed text, reply, and file content with stable pagination")
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
                timelineSequence: 1,
                content: .richText(.plain("alpha release notes"))
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try demoUser.requireID(),
                serverSequence: 2,
                timelineSequence: 2,
                content: .reply(
                    reference: IMReplyReference(
                        messageID: UUID().uuidString,
                        senderUserID: try peerUser.requireID(),
                        previewText: "alpha sprint preview"
                    ),
                    body: .plain("beta reply")
                )
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 4,
                timelineSequence: 4,
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
            let messageIDs = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
                .map { try $0.requireID() }
            try await ConversationSearchIndexWorker(db: app.db).reindexMessages(messageIDs: messageIDs)

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
                    #expect(page.items.isEmpty)
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
                timelineSequence: 1,
                content: .richText(.plain("visible archive before rejoin"))
            ).create(on: app.db)
            try await ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 2,
                timelineSequence: 2,
                content: .richText(.plain("visible archive still old"))
            ).create(on: app.db)
            let visibleMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 3,
                timelineSequence: 3,
                content: .richText(.plain("visible timeline after rejoin"))
            )
            try await visibleMessage.create(on: app.db)
            try await ConversationSearchIndexWorker(db: app.db).reindexMessage(
                messageID: try visibleMessage.requireID()
            )

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

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/timeline", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: newUserToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let timeline = try res.content.decode(IMTimelinePageResponse.self)
                let messages = timeline.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [3])
                #expect(messages.map(\.timelineSequence) == [3])
                #expect(messages.map(\.content.previewText) == ["after join"])
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: newUserToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(IMTimelinePageResponse.self)
                let messages = payload.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [3])
                #expect(messages.map(\.timelineSequence) == [3])
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
                    timelineSequence: sequence,
                    clientMessageID: "client-since-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "since-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [1, 2, 3, 4])
                #expect(messages.map(\.timelineSequence) == [1, 2, 3, 4])
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
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=2&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
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
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: strangerAccessToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }


    @Test("IM messages since hot cache hits safe pages and bypasses user-hidden messages")
    func imMessagesSinceHotCacheHitsAndBypassesHiddenMessages() async throws {
        try await withApp(configure: configure) { app in
            app.timelineReadConfiguration = IMTimelineReadConfiguration(
                visibilityScanMaxRows: 5_000,
                visibilityScanMaxPages: 50,
                sinceHotCacheTTLMilliseconds: 5_000,
                sinceHotCacheMaxEntries: 128
            )

            let owner = try await makeUser(email: "since-hot-cache-owner@example.com", on: app)
            let peer = try await makeUser(email: "since-hot-cache-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let ownerAccessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-hot-cache-owner-device",
                on: app
            )
            let peerAccessToken = try await loginAccessToken(
                email: peer.email,
                password: "password1234",
                deviceID: "since-hot-cache-peer-device",
                on: app
            )
            let conversation = Conversation(
                title: "Since Hot Cache Chat",
                updatedAt: Date(timeIntervalSince1970: 1_700_100_020)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)

            var messageIDs: [UUID] = []
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: peerID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "client-hot-cache-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "hot-cache-\(sequence)"]
                )
                try await message.create(on: app.db)
                messageIDs.append(try message.requireID())
            }

            for _ in 0..<2 {
                try await app.testing().test(
                    .GET,
                    "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&limit=2"
                , beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: ownerAccessToken)
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)

                    let response = try res.content.decode(IMTimelinePageResponse.self)
                    let messages = response.items.compactMap(\.message)
                    #expect(messages.map(\.serverSequence) == [1, 2])
                    #expect(response.hasMore == false)
                    #expect(response.nextAfterSequence == 2)
                })
            }

            var metrics = await app.timelineReadMetrics.currentSnapshot()
            #expect(metrics.sinceHotCacheMissCount == 1)
            #expect(metrics.sinceHotCacheHitCount == 1)

            try await MessageVisibilityOverride(
                ownerUserID: ownerID,
                conversationID: conversationID,
                messageID: messageIDs[0],
                serverSequence: 1,
                isHidden: true
            ).create(on: app.db)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [2])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 2)
            })

            metrics = await app.timelineReadMetrics.currentSnapshot()
            #expect(metrics.sinceHotCacheUnsafeBypassCount == 1)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: peerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [1, 2])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 2)
            })

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=2&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: peerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                #expect(response.items.isEmpty)
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 2)
            })

            let thirdMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: peerID,
                serverSequence: 3,
                timelineSequence: 3,
                clientMessageID: "client-hot-cache-3",
                kind: "rich_text",
                body: ["text": "hot-cache-3"]
            )
            try await thirdMessage.create(on: app.db)
            app.invalidateTimelineSinceHotCache(conversationID: conversationID)
            try await Task.sleep(nanoseconds: 10_000_000)

            metrics = await app.timelineReadMetrics.currentSnapshot()
            #expect(metrics.sinceHotCacheInvalidationCount >= 1)
            #expect(metrics.sinceHotCacheInvalidatedEntryCount >= 1)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=2&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: peerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [3])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 3)
            })
        }
    }

    @Test("IM messages since recent cache serves adjacent safe cursors")
    func imMessagesSinceRecentCacheServesAdjacentSafeCursors() async throws {
        try await withApp(configure: configure) { app in
            app.timelineReadConfiguration = IMTimelineReadConfiguration(
                visibilityScanMaxRows: 5_000,
                visibilityScanMaxPages: 50,
                sinceHotCacheTTLMilliseconds: 5_000,
                sinceHotCacheMaxEntries: 128,
                sinceRecentCacheTTLMilliseconds: 5_000,
                sinceRecentCacheMaxConversations: 128,
                sinceRecentCacheMaxItemsPerConversation: 16
            )

            let owner = try await makeUser(email: "since-recent-cache-owner@example.com", on: app)
            let peer = try await makeUser(email: "since-recent-cache-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let ownerAccessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-recent-cache-owner-device",
                on: app
            )
            let conversation = Conversation(
                title: "Since Recent Cache Chat",
                updatedAt: Date(timeIntervalSince1970: 1_700_100_025)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)

            for sequence in 1...3 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: peerID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "client-recent-cache-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "recent-cache-\(sequence)"]
                )
                try await message.create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&limit=3"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [1, 2, 3])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 3)
            })

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=1&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [2, 3])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 3)
            })

            let metrics = await app.timelineReadMetrics.currentSnapshot()
            #expect(metrics.sinceRecentCacheMissCount == 1)
            #expect(metrics.sinceRecentCacheHitCount == 1)
            #expect(metrics.sinceRecentCacheStoreCount == 1)
        }
    }

    @Test("IM timeline since recent cache clipped suffix does not serve earlier cursors")
    func imTimelineSinceRecentCacheClippedSuffixDoesNotServeEarlierCursors() {
        let cache = IMTimelineSinceRecentCache()
        let conversationID = UUID()
        let items = (1...5).map { sequence in
            IMTimelineItemResponse(
                type: .message,
                timelineSequence: UInt64(sequence),
                message: nil,
                notice: nil
            )
        }

        let didStore = cache.store(
            IMTimelinePageResponse(
                items: items,
                hasMore: false,
                nextAfterSequence: 5
            ),
            conversationID: conversationID,
            minimumVisibleServerSequence: 0,
            lowerTimelineBound: 0,
            ttlMilliseconds: 5_000,
            maxConversations: 128,
            maxItemsPerConversation: 3
        )

        #expect(didStore)
        #expect(cache.response(
            conversationID: conversationID,
            minimumVisibleServerSequence: 0,
            lowerTimelineBound: 0,
            limit: 1
        ) == nil)

        let response = cache.response(
            conversationID: conversationID,
            minimumVisibleServerSequence: 0,
            lowerTimelineBound: 2,
            limit: 3
        )
        #expect(response?.items.map(\.timelineSequence) == [3, 4, 5])
        #expect(response?.hasMore == false)
        #expect(response?.nextAfterSequence == 5)
    }

    @Test("IM timeline since target sequence bypasses stale hot cache before strong read")
    func imTimelineSinceTargetSequenceBypassesStaleHotCacheBeforeStrongRead() async throws {
        try await withApp(configure: configure) { app in
            app.timelineReadConfiguration = IMTimelineReadConfiguration(
                visibilityScanMaxRows: 5_000,
                visibilityScanMaxPages: 50,
                sinceHotCacheTTLMilliseconds: 5_000,
                sinceHotCacheMaxEntries: 128
            )

            let owner = try await makeUser(email: "since-target-owner@example.com", on: app)
            let peer = try await makeUser(email: "since-target-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let ownerAccessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-target-owner-device",
                on: app
            )
            let conversation = Conversation(
                title: "Since Target Cache Chat",
                updatedAt: Date(timeIntervalSince1970: 1_700_100_030)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: peerID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "client-target-cache-1",
                kind: "rich_text",
                body: ["text": "target-cache-1"]
            )
            try await message.create(on: app.db)

            app.timelineSinceHotCache.store(
                IMTimelinePageResponse(items: [], hasMore: false, nextAfterSequence: 0),
                for: IMTimelineSinceHotCache.Key(
                    conversationID: conversationID,
                    lowerTimelineBound: 0,
                    minimumVisibleServerSequence: 0,
                    limit: 2
                ),
                ttlMilliseconds: 5_000,
                maxEntries: 128
            )

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&targetSequence=1&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [1])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 1)
            })

            let metrics = await app.timelineReadMetrics.currentSnapshot()
            #expect(metrics.sinceHotCacheHitCount == 0)
            #expect(metrics.sinceHotCacheTargetSequenceBypassCount == 1)
            #expect(metrics.sinceTargetSequenceRequestCount == 1)
            #expect(metrics.sinceTargetSequenceEventualSatisfiedCount == 1)
            #expect(metrics.sinceTargetSequenceStrongFallbackCount == 0)
            #expect(metrics.sinceTargetSequenceStrongSatisfiedCount == 0)
            #expect(metrics.sinceTargetSequenceStrongMissCount == 0)
            #expect(metrics.sinceTargetSequenceErrorCount == 0)
        }
    }

    @Test("IM timeline since target sequence records eventual satisfied")
    func imTimelineSinceTargetSequenceRecordsEventualSatisfied() async throws {
        try await withApp(configure: configure) { app in
            app.timelineReadConfiguration = IMTimelineReadConfiguration(
                visibilityScanMaxRows: 5_000,
                visibilityScanMaxPages: 50,
                sinceHotCacheTTLMilliseconds: 0,
                sinceHotCacheMaxEntries: 0,
                sinceRecentCacheTTLMilliseconds: 0,
                sinceRecentCacheMaxConversations: 0,
                sinceRecentCacheMaxItemsPerConversation: 0
            )

            let owner = try await makeUser(email: "since-target-eventual-owner@example.com", on: app)
            let peer = try await makeUser(email: "since-target-eventual-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let ownerAccessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-target-eventual-owner-device",
                on: app
            )
            let conversation = Conversation(
                title: "Since Target Eventual Chat",
                updatedAt: Date(timeIntervalSince1970: 1_700_100_031)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: peerID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "client-target-eventual-1",
                kind: "rich_text",
                body: ["text": "target-eventual-1"]
            )
            try await message.create(on: app.db)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&targetSequence=1&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [1])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 1)
            })

            let metrics = await app.timelineReadMetrics.currentSnapshot()
            #expect(metrics.sinceTargetSequenceRequestCount == 1)
            #expect(metrics.sinceTargetSequenceEventualSatisfiedCount == 1)
            #expect(metrics.sinceTargetSequenceStrongFallbackCount == 0)
            #expect(metrics.sinceTargetSequenceStrongSatisfiedCount == 0)
            #expect(metrics.sinceTargetSequenceStrongMissCount == 0)
            #expect(metrics.sinceTargetSequenceErrorCount == 0)
        }
    }

    @Test("IM timeline since target sequence records errors")
    func imTimelineSinceTargetSequenceRecordsErrors() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "since-target-error-owner@example.com", on: app)
            let ownerAccessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-target-error-owner-device",
                on: app
            )
            let missingConversationID = UUID()

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(missingConversationID.uuidString)/timeline/since?afterSequence=0&targetSequence=1&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerAccessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })

            let metrics = await app.timelineReadMetrics.currentSnapshot()
            #expect(metrics.sinceTargetSequenceRequestCount == 1)
            #expect(metrics.sinceTargetSequenceErrorCount == 1)
            #expect(metrics.sinceTargetSequenceEventualSatisfiedCount == 0)
            #expect(metrics.sinceTargetSequenceStrongFallbackCount == 0)
            #expect(metrics.sinceTargetSequenceStrongSatisfiedCount == 0)
            #expect(metrics.sinceTargetSequenceStrongMissCount == 0)
        }
    }

    @Test("Timeline since response coalescer joins concurrent loads")
    func timelineSinceResponseCoalescerJoinsConcurrentLoads() async throws {
        let coalescer = IMTimelineSinceResponseCoalescer()
        let counter = TimelineSinceCoalescerLoadCounter()
        let key = IMTimelineSinceHotCache.Key(
            conversationID: UUID(),
            lowerTimelineBound: 10,
            minimumVisibleServerSequence: 0,
            limit: 100
        )

        let joinedCount = try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let result = try await coalescer.response(for: key) {
                        await counter.increment()
                        try await Task.sleep(nanoseconds: 50_000_000)
                        return IMTimelineSinceResponseCoalescer.PageResult(
                            response: IMTimelinePageResponse(
                                items: [],
                                hasMore: false,
                                nextAfterSequence: UInt64(key.lowerTimelineBound)
                            ),
                            scannedRows: 1,
                            scannedPages: 1
                        )
                    }
                    return result.joinedInFlight
                }
            }

            var count = 0
            for try await joined in group where joined {
                count += 1
            }
            return count
        }

        #expect(await counter.value == 1)
        #expect(joinedCount >= 1)
    }

    @Test("Timeline since response coalescer keys target sequence")
    func timelineSinceResponseCoalescerKeysTargetSequence() async throws {
        let coalescer = IMTimelineSinceResponseCoalescer()
        let sameTargetCounter = TimelineSinceCoalescerLoadCounter()
        let key = IMTimelineSinceHotCache.Key(
            conversationID: UUID(),
            lowerTimelineBound: 10,
            minimumVisibleServerSequence: 0,
            limit: 100
        )

        let sameTargetJoinedCount = try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let result = try await coalescer.response(for: key, targetSequence: 42) {
                        await sameTargetCounter.increment()
                        try await Task.sleep(nanoseconds: 50_000_000)
                        return IMTimelineSinceResponseCoalescer.PageResult(
                            response: IMTimelinePageResponse(
                                items: [],
                                hasMore: false,
                                nextAfterSequence: UInt64(key.lowerTimelineBound)
                            ),
                            scannedRows: 1,
                            scannedPages: 1
                        )
                    }
                    return result.joinedInFlight
                }
            }

            var count = 0
            for try await joined in group where joined {
                count += 1
            }
            return count
        }

        #expect(await sameTargetCounter.value == 1)
        #expect(sameTargetJoinedCount >= 1)

        let differentTargetCounter = TimelineSinceCoalescerLoadCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for targetSequence in [42, 43] {
                group.addTask {
                    _ = try await coalescer.response(for: key, targetSequence: targetSequence) {
                        await differentTargetCounter.increment()
                        try await Task.sleep(nanoseconds: 50_000_000)
                        return IMTimelineSinceResponseCoalescer.PageResult(
                            response: IMTimelinePageResponse(
                                items: [],
                                hasMore: false,
                                nextAfterSequence: UInt64(key.lowerTimelineBound)
                            ),
                            scannedRows: 1,
                            scannedPages: 1
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await differentTargetCounter.value == 2)
    }

    @Test("Timeline since target sequence coalescer batches lower bound variants")
    func timelineSinceTargetSequenceCoalescerBatchesLowerBoundVariants() async throws {
        let coalescer = IMTimelineSinceResponseCoalescer()
        let counter = TimelineSinceCoalescerLoadCounter()
        let conversationID = UUID()
        let firstKey = IMTimelineSinceHotCache.Key(
            conversationID: conversationID,
            lowerTimelineBound: 10,
            minimumVisibleServerSequence: 0,
            limit: 5
        )
        let secondKey = IMTimelineSinceHotCache.Key(
            conversationID: conversationID,
            lowerTimelineBound: 12,
            minimumVisibleServerSequence: 0,
            limit: 2
        )
        let loader: IMTimelineSinceResponseCoalescer.TargetSequenceLoader = { lowerTimelineBound, limit in
            await counter.increment()
            #expect(lowerTimelineBound == 10)
            #expect(limit == 5)
            return IMTimelineSinceResponseCoalescer.PageResult(
                response: IMTimelinePageResponse(
                    items: (11...15).map { sequence in
                        IMTimelineItemResponse(
                            type: .message,
                            timelineSequence: UInt64(sequence),
                            message: nil,
                            notice: nil
                        )
                    },
                    hasMore: false,
                    nextAfterSequence: 15
                ),
                scannedRows: 5,
                scannedPages: 1
            )
        }

        let results = try await withThrowingTaskGroup(
            of: (Int, IMTimelineSinceResponseCoalescer.TargetSequenceRequestResult).self,
            returning: [(Int, IMTimelineSinceResponseCoalescer.TargetSequenceRequestResult)].self
        ) { group in
            group.addTask {
                (
                    0,
                    try await coalescer.targetSequenceResponse(
                        for: firstKey,
                        targetSequence: 15,
                        coalescingWindowMilliseconds: 20,
                        loader: loader
                    )
                )
            }
            group.addTask {
                (
                    1,
                    try await coalescer.targetSequenceResponse(
                        for: secondKey,
                        targetSequence: 15,
                        coalescingWindowMilliseconds: 20,
                        loader: loader
                    )
                )
            }

            var values: [(Int, IMTimelineSinceResponseCoalescer.TargetSequenceRequestResult)] = []
            for try await value in group {
                values.append(value)
            }
            return values.sorted { $0.0 < $1.0 }
        }

        #expect(await counter.value == 1)
        #expect(results.map { $0.1.coalescedRequestCount } == [2, 2])
        #expect(results.map { $0.1.result.response.items.map(\.timelineSequence) } == [
            [UInt64(11), 12, 13, 14, 15],
            [UInt64(13), 14]
        ])
        #expect(results.map { $0.1.result.scannedRows }.sorted() == [0, 5])
        #expect(results.contains { $0.1.joinedWindow })
    }

    @Test("Timeline since target sequence coalescing bypasses user-specific notices")
    func timelineSinceTargetSequenceCoalescingBypassesUserSpecificNotices() async throws {
        try await withApp(configure: configure) { app in
            app.timelineReadConfiguration = IMTimelineReadConfiguration(
                visibilityScanMaxRows: 5_000,
                visibilityScanMaxPages: 50,
                sinceHotCacheTTLMilliseconds: 5_000,
                sinceHotCacheMaxEntries: 128,
                sinceRecentCacheTTLMilliseconds: 0,
                sinceRecentCacheMaxConversations: 0,
                sinceRecentCacheMaxItemsPerConversation: 0,
                sinceTargetSequenceCoalesceWindowMilliseconds: 50
            )

            let firstUser = try await makeUser(email: "target-notice-first@example.com", on: app)
            let secondUser = try await makeUser(email: "target-notice-second@example.com", on: app)
            let firstUserID = try firstUser.requireID()
            let secondUserID = try secondUser.requireID()
            let conversation = Conversation(
                title: "Target Notice Coalescing",
                updatedAt: Date(timeIntervalSince1970: 1_700_100_030)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: firstUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: secondUserID)
                .create(on: app.db)
            try await ConversationTimelineNotice(
                eventID: UUID(),
                conversationID: conversationID,
                timelineSequence: 1,
                eventType: ConversationDomainEventType.membershipAdded.rawValue,
                actorUserID: firstUserID,
                targetUserIDs: [firstUserID],
                noticeKind: "member_added",
                params: [:],
                fallbackText: "first user only",
                createdAt: Date(timeIntervalSince1970: 1_700_100_031)
            ).create(on: app.db)

            let support = ConversationTimelineReadSupport(
                db: app.db,
                metrics: app.timelineReadMetrics,
                configuration: app.timelineReadConfiguration,
                sinceHotCache: app.timelineSinceHotCache,
                sinceRecentCache: app.timelineSinceRecentCache,
                sinceVisibilitySafetyCache: app.timelineSinceVisibilitySafetyCache,
                sinceResponseCoalescer: app.timelineSinceResponseCoalescer
            )

            async let firstResponse = support.listTimelineSince(
                in: conversationID,
                for: firstUserID,
                afterSequence: 0,
                targetSequence: 1,
                limit: 10
            )
            try await Task.sleep(nanoseconds: 1_000_000)
            let secondResponse = try await support.listTimelineSince(
                in: conversationID,
                for: secondUserID,
                afterSequence: 0,
                targetSequence: 1,
                limit: 10
            )
            let resolvedFirstResponse = try await firstResponse

            #expect(resolvedFirstResponse.items.compactMap(\.notice).count == 1)
            #expect(secondResponse.items.isEmpty)

            let metrics = await app.timelineReadMetrics.currentSnapshot()
            #expect(metrics.sinceTargetSequenceWindowJoinedCount == 0)
            #expect(metrics.sinceResponseSingleflightNoticeBypassCount == 0)
            #expect(metrics.sinceVisibilitySafetyNoticeBypassCount >= 1)
        }
    }

    @Test("Timeline read metrics records target sequence singleflight joins")
    func timelineReadMetricsRecordsTargetSequenceSingleflightJoins() async {
        let metrics = IMTimelineReadMetrics()

        await metrics.recordSinceResponseSingleflightJoined()
        await metrics.recordSinceResponseSingleflightNoticeBypass()
        await metrics.recordSinceVisibilitySafetyNoticeBypass()
        await metrics.recordSinceTargetSequenceSingleflightJoined()
        await metrics.recordSinceTargetSequenceWindowJoined()

        let snapshot = await metrics.currentSnapshot()
        #expect(snapshot.sinceResponseSingleflightJoinedCount == 1)
        #expect(snapshot.sinceResponseSingleflightNoticeBypassCount == 1)
        #expect(snapshot.sinceVisibilitySafetyNoticeBypassCount == 1)
        #expect(snapshot.sinceTargetSequenceSingleflightJoinedCount == 1)
        #expect(snapshot.sinceTargetSequenceWindowJoinedCount == 1)
    }


    @Test("IM messages since endpoint applies batched visibility filtering")
    func imMessagesSinceAppliesBatchedVisibilityFiltering() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "since-visible-owner@example.com", on: app)
            let peer = try await makeUser(email: "since-visible-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let accessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-visible-owner-device",
                on: app
            )
            let conversation = Conversation(title: "Since Visible Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_021))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)

            var messageIDs: [UUID] = []
            for sequence in 1...4 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: peerID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "client-visible-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "visible-\(sequence)"]
                )
                try await message.create(on: app.db)
                messageIDs.append(try message.requireID())
            }

            try await ConversationVisibilityOverride(
                ownerUserID: ownerID,
                conversationID: conversationID,
                hiddenBeforeSequence: 1,
                isDeleted: false
            ).create(on: app.db)
            try await MessageVisibilityOverride(
                ownerUserID: ownerID,
                conversationID: conversationID,
                messageID: messageIDs[1],
                serverSequence: 2,
                isHidden: true
            ).create(on: app.db)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [3, 4])
                #expect(messages.map(\.timelineSequence) == [3, 4])
                #expect(messages.map { $0.body["text"] } == ["visible-3", "visible-4"])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 4)
            })
        }
    }


    @Test("IM messages since scans past hidden candidate page")
    func imMessagesSinceScansPastHiddenCandidatePage() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "since-hidden-page-owner@example.com", on: app)
            let peer = try await makeUser(email: "since-hidden-page-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let accessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-hidden-page-owner-device",
                on: app
            )
            let conversation = Conversation(
                title: "Since Hidden Page Chat",
                updatedAt: Date(timeIntervalSince1970: 1_700_100_021)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)

            var messageIDs: [UUID] = []
            for sequence in 1...5 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: peerID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "client-hidden-page-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "hidden-page-\(sequence)"]
                )
                try await message.create(on: app.db)
                messageIDs.append(try message.requireID())
            }

            for index in 0..<3 {
                try await MessageVisibilityOverride(
                    ownerUserID: ownerID,
                    conversationID: conversationID,
                    messageID: messageIDs[index],
                    serverSequence: index + 1,
                    isHidden: true
                ).create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [4, 5])
                #expect(messages.map(\.timelineSequence) == [4, 5])
                #expect(messages.map { $0.body["text"] } == ["hidden-page-4", "hidden-page-5"])
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 5)
            })
        }
    }


    @Test("IM messages since reports visibility scan limit")
    func imMessagesSinceReportsVisibilityScanLimit() async throws {
        try await withApp(configure: configure) { app in
            app.timelineReadConfiguration = IMTimelineReadConfiguration(
                visibilityScanMaxRows: 3,
                visibilityScanMaxPages: 10
            )

            let owner = try await makeUser(email: "since-scan-limit-owner@example.com", on: app)
            let peer = try await makeUser(email: "since-scan-limit-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let accessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-scan-limit-owner-device",
                on: app
            )
            let conversation = Conversation(
                title: "Since Scan Limit Chat",
                updatedAt: Date(timeIntervalSince1970: 1_700_100_023)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)

            var messageIDs: [UUID] = []
            for sequence in 1...5 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: peerID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "client-scan-limit-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "scan-limit-\(sequence)"]
                )
                try await message.create(on: app.db)
                messageIDs.append(try message.requireID())
            }

            for index in 0..<3 {
                try await MessageVisibilityOverride(
                    ownerUserID: ownerID,
                    conversationID: conversationID,
                    messageID: messageIDs[index],
                    serverSequence: index + 1,
                    isHidden: true
                ).create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&limit=2"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .serviceUnavailable)
            })

            let snapshot = await app.timelineReadMetrics.currentSnapshot()
            #expect(snapshot.errorCount == 1)
            #expect(snapshot.scanLimitExceededCount == 1)
            #expect(snapshot.maxScanRows == 3)
            #expect(snapshot.maxScanPages == 1)
        }
    }


    @Test("IM messages since advances cursor across cleared conversation window")
    func imMessagesSinceAdvancesCursorAcrossClearedConversationWindow() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "since-clear-owner@example.com", on: app)
            let peer = try await makeUser(email: "since-clear-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let accessToken = try await loginAccessToken(
                email: owner.email,
                password: "password1234",
                deviceID: "since-clear-owner-device",
                on: app
            )
            let conversation = Conversation(title: "Since Clear Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_022))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: ownerID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID)
                .create(on: app.db)

            for sequence in 1...4 {
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: peerID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "client-clear-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "clear-\(sequence)"]
                ).create(on: app.db)
            }

            try await ConversationVisibilityOverride(
                ownerUserID: ownerID,
                conversationID: conversationID,
                hiddenBeforeSequence: 4,
                isDeleted: false
            ).create(on: app.db)

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                #expect(response.items.isEmpty)
                #expect(response.hasMore == false)
                #expect(response.nextAfterSequence == 4)
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
                    timelineSequence: sequence,
                    clientMessageID: "client-limit-\(sequence)",
                    kind: "rich_text",
                    body: ["text": "limit-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.count == 100)
                #expect(messages.first?.serverSequence == 1)
                #expect(messages.last?.serverSequence == 100)
                #expect(response.hasMore == true)
                #expect(response.nextAfterSequence == 100)
            })

            try await app.testing().test(
                .GET,
                "api/im/conversations/\(conversationID.uuidString)/timeline/since?afterSequence=0&limit=999"
            , beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
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
                    timelineSequence: sequence,
                    kind: "rich_text",
                    body: ["text": "message-\(sequence)"]
                ).create(on: app.db)
            }

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/timeline?limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [3, 4])
                #expect(messages.map(\.timelineSequence) == [3, 4])
                #expect(messages.map { $0.body["text"] } == ["message-3", "message-4"])
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/timeline?beforeSequence=3&limit=2", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(IMTimelinePageResponse.self)
                let messages = response.items.compactMap(\.message)
                #expect(messages.map(\.serverSequence) == [1, 2])
                #expect(messages.map(\.timelineSequence) == [1, 2])
                #expect(messages.map { $0.body["text"] } == ["message-1", "message-2"])
            })
        }
    }

}

private actor TimelineSinceCoalescerLoadCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
