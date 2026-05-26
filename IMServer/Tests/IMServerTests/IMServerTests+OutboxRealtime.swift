@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Realtime persistence pipeline returns empty result for empty batch")
    func realtimePersistencePipelineReturnsEmptyResultForEmptyBatch() async throws {
        try await withApp(configure: configure) { app in
            let pipeline = IMMessagePersistencePipeline(
                service: IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db),
                conversationID: UUID(),
                preparedMessages: []
            )

            let results = try await pipeline.run()
            #expect(results.isEmpty)
        }
    }

    @Test("Conversation outbox worker refreshes summary and search index for created messages")
    func conversationOutboxProcessesMessageCreatedIntoSummaryAndSearchIndex() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "outbox-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Outbox Chat",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_042),
                lastMessageSequence: 1
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

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try peerUser.requireID(),
                serverSequence: 1,
                content: .file(
                    IMMediaAsset(
                        assetID: "asset-outbox",
                        kind: .file,
                        mimeType: "application/pdf",
                        byteSize: 1_024,
                        filename: "capacity-plan.pdf",
                        width: nil,
                        height: nil,
                        durationMillis: nil,
                        previewAssetID: nil
                    )
                )
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await ConversationOutboxService(db: app.db).enqueue(
                type: .messageCreated,
                conversationID: conversationID,
                payload: ConversationDomainEventPayload(
                    recipientUserIDs: [try demoUser.requireID(), try peerUser.requireID()],
                    messageID: messageID
                )
            )

            let processedCount = try await ConversationOutboxService(db: app.db)
                .processPendingBatch(
                    app: app,
                    configuration: .init(batchSize: 50, pollIntervalNanoseconds: 100_000_000, maxRetries: 5)
                )
            #expect(processedCount == 1)

            let summaryRecordID = ConversationUserSummary.recordID(
                ownerUserID: try demoUser.requireID(),
                conversationID: conversationID
            )
            let ownerSummary = try await ConversationUserSummary.find(summaryRecordID, on: app.db)
            #expect(ownerSummary?.lastMessage?.serverSequence == 1)
            #expect(ownerSummary?.lastMessage?.content.previewText == "[文件] capacity-plan.pdf")

            let searchIndex = try await ConversationMessageSearchIndex.find(
                ConversationMessageSearchIndex.recordID(messageID: messageID),
                on: app.db
            )
            #expect(searchIndex?.conversationID == conversationID)
            #expect(searchIndex?.serverSequence == 1)
            #expect(searchIndex?.searchableText.contains("capacity-plan.pdf") == true)
        }
    }


    @Test("Conversation outbox worker removes search index rows when source message disappears")
    func conversationOutboxRemovesSearchIndexForDeletedMessage() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "outbox-delete-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Outbox Delete",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_043),
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
                content: .richText(.plain("delete this index row"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await ConversationSearchIndexWorker(db: app.db).reindexMessage(messageID: messageID, on: app.db)
            #expect(
                try await ConversationMessageSearchIndex.find(
                    ConversationMessageSearchIndex.recordID(messageID: messageID),
                    on: app.db
                ) != nil
            )

            try await message.delete(on: app.db)

            try await ConversationOutboxService(db: app.db).enqueue(
                type: .messageUpdated,
                conversationID: conversationID,
                payload: ConversationDomainEventPayload(
                    recipientUserIDs: [try demoUser.requireID(), try peerUser.requireID()],
                    messageID: messageID
                )
            )

            let processedCount = try await ConversationOutboxService(db: app.db)
                .processPendingBatch(
                    app: app,
                    configuration: .init(batchSize: 50, pollIntervalNanoseconds: 100_000_000, maxRetries: 5)
                )
            #expect(processedCount == 1)
            #expect(
                try await ConversationMessageSearchIndex.find(
                    ConversationMessageSearchIndex.recordID(messageID: messageID),
                    on: app.db
                ) == nil
            )
        }
    }


    @Test("TCP message persistence is reflected by IM conversations and history endpoints")
    func tcpMessagePersistenceFeedsHTTPConversationData() async throws {
        try await withApp(configure: configure) { app in
            let accessToken = try await loginAccessToken(using: app)
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-peer@example.com", on: app)
            var createdConversationID: UUID?

            try await app.testing().test(.POST, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(
                    IMConversationCreateRequest(
                        kind: IMConversationKind.direct.rawValue,
                        title: "TCP Chat",
                        memberEmails: [otherUser.email]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let conversation = try res.content.decode(IMConversationResponse.self)
                createdConversationID = conversation.id
                #expect(conversation.memberCount == 2)
            })

            let conversationID = try #require(createdConversationID)
            let result = try await IMRealtimeMessageService(app: app).persistIncomingMessage(
                IMTCPMessagePayload(
                    clientMessageID: "client-msg-1",
                    messageID: nil,
                    conversationID: conversationID.uuidString,
                    senderUserID: nil,
                    serverSequence: nil,
                    serverTimestamp: nil,
                    kind: "rich_text",
                    body: ["text": " hello from tcp "]
                ),
                senderUserID: try demoUser.requireID()
            )
            try await app.processInlineOutboxProjectionIfAllowed()

            #expect(result.acknowledgement.status == "accepted")
            #expect(result.acknowledgement.conversationID == conversationID.uuidString)
            #expect(result.message.serverSequence == 1)
            #expect(result.message.body["text"] == "hello from tcp")
            #expect(result.recipientUserIDs.count == 2)

            try await app.testing().test(.GET, "api/im/conversations", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let conversations = try res.content.decode(IMConversationPageResponse.self).items
                #expect(conversations.count == 1)
                #expect(conversations[0].id == conversationID)
                #expect(conversations[0].lastMessage?.serverSequence == 1)
                #expect(conversations[0].lastMessage?.body["text"] == "hello from tcp")
                #expect(conversations[0].unreadCount == 0)
            })

            try await app.testing().test(.GET, "api/im/conversations/\(conversationID.uuidString)/messages", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let messages = try res.content.decode([IMMessageResponse].self)
                #expect(messages.count == 1)
                #expect(messages[0].serverSequence == 1)
                #expect(messages[0].clientMessageID == "client-msg-1")
                #expect(messages[0].body["text"] == "hello from tcp")
            })
        }
    }


    @Test("TCP reply persistence canonicalizes the referenced preview and sender")
    func tcpReplyPersistenceCanonicalizesReference() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-reply-peer@example.com", on: app)
            let conversation = Conversation(title: "TCP Reply Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_101))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            let referencedMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: try otherUser.requireID(),
                serverSequence: 1,
                content: .richText(.plain("canonical source"))
            )
            try await referencedMessage.create(on: app.db)
            let referencedMessageID = try referencedMessage.requireID()

            let result = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                IMTCPMessagePayload(
                    clientMessageID: "client-reply-1",
                    messageID: nil,
                    conversationID: conversationID.uuidString,
                    senderUserID: nil,
                    serverSequence: nil,
                    serverTimestamp: nil,
                    content: .reply(
                        reference: IMReplyReference(
                            messageID: referencedMessageID.uuidString,
                            senderUserID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
                            previewText: "stale preview"
                        ),
                        body: .plain("reply body")
                    )
                ),
                senderUserID: try demoUser.requireID()
            )

            #expect(result.acknowledgement.status == "accepted")
            #expect(result.message.content == .reply(
                reference: IMReplyReference(
                    messageID: referencedMessageID.uuidString,
                    senderUserID: try otherUser.requireID(),
                    previewText: "canonical source"
                ),
                body: .plain("reply body")
            ))
        }
    }


    @Test("TCP message persistence is idempotent by sender conversation and client message id")
    func tcpMessagePersistenceIsIdempotentByClientMessageID() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-idempotent-peer@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let conversation = Conversation(title: "Idempotent Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_105))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            let first = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "client-idempotent-1",
                    text: "first body wins"
                ),
                senderUserID: demoUserID
            )
            let duplicate = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "client-idempotent-1",
                    text: "changed body should be ignored"
                ),
                senderUserID: demoUserID
            )

            #expect(first.acknowledgement.status == "accepted")
            #expect(duplicate.acknowledgement.status == "accepted")
            #expect(duplicate.didCreateMessage == false)
            #expect(duplicate.acknowledgement.messageID == first.acknowledgement.messageID)
            #expect(duplicate.message.messageID == first.message.messageID)
            #expect(duplicate.message.serverSequence == first.message.serverSequence)
            #expect(duplicate.message.body["text"] == "first body wins")

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.count == 1)
        }
    }

    @Test("Duplicate reply message returns existing message before canonicalizing reply reference")
    func duplicateReplyMessageReturnsExistingBeforeCanonicalizingReplyReference() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-duplicate-reply-peer@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let conversation = Conversation(title: "Idempotent Reply", updatedAt: Date(timeIntervalSince1970: 1_700_100_106))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            let existing = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: demoUserID,
                serverSequence: 1,
                clientMessageID: "duplicate-reply-client",
                content: .richText(.plain("stored original"))
            )
            try await existing.create(on: app.db)
            let existingID = try existing.requireID()

            let duplicate = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                IMTCPMessagePayload(
                    clientMessageID: "duplicate-reply-client",
                    messageID: nil,
                    conversationID: conversationID.uuidString,
                    senderUserID: nil,
                    serverSequence: nil,
                    serverTimestamp: nil,
                    content: .reply(
                        reference: IMReplyReference(
                            messageID: UUID().uuidString,
                            senderUserID: nil,
                            previewText: "stale missing reference"
                        ),
                        body: .plain("retry body")
                    )
                ),
                senderUserID: demoUserID
            )

            #expect(duplicate.acknowledgement.status == "accepted")
            #expect(duplicate.didCreateMessage == false)
            #expect(duplicate.acknowledgement.messageID == existingID.uuidString)
            #expect(duplicate.message.messageID == existingID.uuidString)
            #expect(duplicate.message.body["text"] == "stored original")

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.count == 1)
        }
    }


    @Test("Retrying first stranger direct message with same client id stays accepted")
    func retryingFirstStrangerDirectMessageIsIdempotentBeforePeerReply() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-idempotent@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let conversation = Conversation(title: nil, kind: .direct, updatedAt: Date(timeIntervalSince1970: 1_700_100_107))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try peerUser.requireID())
                .create(on: app.db)
            try await DirectConversationPairDirectoryService(db: app.db)
                .sync(conversationID: conversationID)

            let first = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-idempotent-first",
                    text: "first hello"
                ),
                senderUserID: demoUserID
            )
            let retry = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-idempotent-first",
                    text: "first hello retry"
                ),
                senderUserID: demoUserID
            )

            #expect(first.acknowledgement.status == "accepted")
            #expect(retry.acknowledgement.status == "accepted")
            #expect(retry.didCreateMessage == false)
            #expect(retry.acknowledgement.messageID == first.acknowledgement.messageID)

            do {
                _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationID,
                        clientMessageID: "stranger-idempotent-second",
                        text: "second hello"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected a new second stranger direct message to remain rejected")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .strangerDirectMessageLimitReached)
            }

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.count == 1)
        }
    }


    @Test("Null client message ids are not constrained by idempotency index")
    func nullClientMessageIDsCanStillPersistMultipleMessages() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-null-client-id-peer@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let conversation = Conversation(title: "Null Client ID Chat", updatedAt: Date(timeIntervalSince1970: 1_700_100_108))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            for sequence in 1...2 {
                try await ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: demoUserID,
                    serverSequence: sequence,
                    clientMessageID: nil,
                    kind: "rich_text",
                    body: ["text": "indexed-\(sequence)"]
                ).create(on: app.db)
            }

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.count == 2)
        }
    }


    @Test("TCP message persistence rejects users outside the conversation")
    func tcpMessagePersistenceRequiresMembership() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let otherUser = try await makeUser(email: "tcp-member@example.com", on: app)
            let outsider = try await makeUser(email: "tcp-outsider@example.com", on: app)
            let conversation = Conversation(title: nil, updatedAt: Date(timeIntervalSince1970: 1_700_100_110))
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: try demoUser.requireID())
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: try otherUser.requireID())
                .create(on: app.db)

            do {
                _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                    IMTCPMessagePayload(
                        clientMessageID: "client-msg-outsider",
                        messageID: nil,
                        conversationID: conversationID.uuidString,
                        senderUserID: nil,
                        serverSequence: nil,
                        serverTimestamp: nil,
                        kind: "rich_text",
                        body: ["text": "should fail"]
                    ),
                    senderUserID: try outsider.requireID()
                )
                Issue.record("Expected TCP message persistence to reject outsider membership")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .conversationUnavailable)
            }

            let messages = try await ConversationMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .all()
            #expect(messages.isEmpty)
        }
    }


    @Test("Non-friends can only send one direct message before the peer replies")
    func nonFriendsCanOnlySendOneDirectMessageBeforeReply() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-direct@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_120)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                .create(on: app.db)
            try await DirectConversationPairDirectoryService(db: app.db)
                .sync(conversationID: conversationID)

            let firstMessage = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-first",
                    text: "first hello"
                ),
                senderUserID: demoUserID
            )
            #expect(firstMessage.acknowledgement.status == "accepted")

            do {
                _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationID,
                        clientMessageID: "stranger-second",
                        text: "second hello"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected second stranger direct message to be rejected before peer reply")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .strangerDirectMessageLimitReached)
                #expect(error.ackStatus == "stranger_direct_message_limit_reached")
            }

            let reply = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-reply",
                    text: "reply"
                ),
                senderUserID: peerUserID
            )
            #expect(reply.acknowledgement.status == "accepted")

            let thirdMessage = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "stranger-third",
                    text: "after reply"
                ),
                senderUserID: demoUserID
            )
            #expect(thirdMessage.acknowledgement.status == "accepted")
        }
    }


    @Test("Frozen direct conversations reject new messages")
    func frozenDirectConversationRejectsNewMessages() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "frozen-direct-peer@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            let conversation = Conversation(
                title: nil,
                kind: .direct,
                directMessagingState: .frozenAfterUnfriend,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_121)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                .create(on: app.db)

            do {
                _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationID,
                        clientMessageID: "frozen-direct-message",
                        text: "still there?"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected frozen direct conversation to reject sending")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .directConversationFrozen)
                #expect(error.ackStatus == "direct_conversation_frozen")
                #expect(error.errorDescription == "你们已不是好友，当前会话不能继续发送消息。")
            }
        }
    }


    @Test("Non-friend direct message limit is enforced across duplicate direct conversations")
    func nonFriendDirectMessageLimitSpansDuplicateDirectConversations() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-duplicate@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            var conversationIDs: [UUID] = []

            for index in 0..<2 {
                let conversation = Conversation(
                    title: nil,
                    kind: .direct,
                    updatedAt: Date(timeIntervalSince1970: 1_700_100_130 + Double(index))
                )
                try await conversation.create(on: app.db)
                let conversationID = try conversation.requireID()
                conversationIDs.append(conversationID)

                try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                    .create(on: app.db)
                try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                    .create(on: app.db)
                try await DirectConversationPairDirectoryService(db: app.db)
                    .sync(conversationID: conversationID)
            }

            _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationIDs[0],
                    clientMessageID: "duplicate-first",
                    text: "first hello"
                ),
                senderUserID: demoUserID
            )

            do {
                _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationIDs[1],
                        clientMessageID: "duplicate-second",
                        text: "second hello"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected duplicate direct conversation to keep stranger message limit")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .strangerDirectMessageLimitReached)
            }
        }
    }


    @Test("Non-friend message limit does not apply to two-member group conversations")
    func nonFriendMessageLimitDoesNotApplyToTwoMemberGroups() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-two-member-group@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            let conversation = Conversation(
                title: "Two Person Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_140)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                .create(on: app.db)

            let firstMessage = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "two-member-group-first",
                    text: "first hello"
                ),
                senderUserID: demoUserID
            )

            let secondMessage = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "two-member-group-second",
                    text: "second hello"
                ),
                senderUserID: demoUserID
            )

            #expect(firstMessage.acknowledgement.status == "accepted")
            #expect(secondMessage.acknowledgement.status == "accepted")
            #expect(secondMessage.message.serverSequence == 2)
        }
    }


    @Test("Two-member group messages do not count toward direct stranger message limit")
    func twoMemberGroupMessagesDoNotCountTowardDirectStrangerLimit() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "stranger-group-direct-split@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            let groupConversation = Conversation(
                title: "Two Person Group",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_141)
            )
            try await groupConversation.create(on: app.db)
            let groupConversationID = try groupConversation.requireID()
            let directConversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_142)
            )
            try await directConversation.create(on: app.db)
            let directConversationID = try directConversation.requireID()

            for conversationID in [groupConversationID, directConversationID] {
                try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                    .create(on: app.db)
                try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                    .create(on: app.db)
            }
            try await DirectConversationPairDirectoryService(db: app.db)
                .sync(conversationID: directConversationID)

            _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: groupConversationID,
                    clientMessageID: "group-before-direct",
                    text: "group hello"
                ),
                senderUserID: demoUserID
            )

            let firstDirectMessage = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: directConversationID,
                    clientMessageID: "direct-after-group-first",
                    text: "first direct hello"
                ),
                senderUserID: demoUserID
            )
            #expect(firstDirectMessage.acknowledgement.status == "accepted")

            do {
                _ = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: directConversationID,
                        clientMessageID: "direct-after-group-second",
                        text: "second direct hello"
                    ),
                    senderUserID: demoUserID
                )
                Issue.record("Expected second direct message to be rejected after one direct send")
            } catch let error as IMRealtimeMessageError {
                #expect(error == .strangerDirectMessageLimitReached)
            }
        }
    }


    @Test("Friends are not limited by the pre-reply direct message rule")
    func friendsAreNotLimitedByPreReplyDirectMessageRule() async throws {
        try await withApp(configure: configure) { app in
            let demoUser = try await user(email: "demo@example.com", on: app)
            let peerUser = try await makeUser(email: "friend-direct@example.com", on: app)
            let demoUserID = try demoUser.requireID()
            let peerUserID = try peerUser.requireID()
            try await UserContact(ownerUserID: demoUserID, contactUserID: peerUserID)
                .create(on: app.db)
            try await UserContact(ownerUserID: peerUserID, contactUserID: demoUserID)
                .create(on: app.db)

            let conversation = Conversation(
                title: nil,
                kind: .direct,
                updatedAt: Date(timeIntervalSince1970: 1_700_100_140)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            try await ConversationMember(conversationID: conversationID, userID: demoUserID)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerUserID)
                .create(on: app.db)

            let firstMessage = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "friend-first",
                    text: "first"
                ),
                senderUserID: demoUserID
            )
            let secondMessage = try await IMRealtimeMessageService(fixedDatabaseForLowLevelTest: app.db).persistIncomingMessage(
                imTCPTextPayload(
                    conversationID: conversationID,
                    clientMessageID: "friend-second",
                    text: "second"
                ),
                senderUserID: demoUserID
            )

            #expect(firstMessage.acknowledgement.status == "accepted")
            #expect(secondMessage.acknowledgement.status == "accepted")
            #expect(secondMessage.message.serverSequence == 2)
        }
    }

}
