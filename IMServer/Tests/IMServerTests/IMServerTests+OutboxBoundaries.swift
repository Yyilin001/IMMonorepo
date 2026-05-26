@testable import IMServer
import Fluent
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Performance tuning environment configures outbox and write queue limits")
    func performanceTuningEnvironmentConfiguresRuntimeLimits() async throws {
        let oldOutboxConcurrency = Environment.get("IM_OUTBOX_MAX_CONCURRENCY")
        let oldWriteQueueDepth = Environment.get("IM_MESSAGE_WRITE_BATCH_MAX_QUEUE_DEPTH")
        defer {
            restoreEnvironment("IM_OUTBOX_MAX_CONCURRENCY", to: oldOutboxConcurrency)
            restoreEnvironment("IM_MESSAGE_WRITE_BATCH_MAX_QUEUE_DEPTH", to: oldWriteQueueDepth)
        }

        setenv("IM_OUTBOX_MAX_CONCURRENCY", "7", 1)
        setenv("IM_MESSAGE_WRITE_BATCH_MAX_QUEUE_DEPTH", "19", 1)

        let outboxConfiguration = ConversationOutboxConfiguration.load(from: .testing)
        let writeBatchConfiguration = IMMessageWriteBatchConfiguration.load(from: .testing)

        #expect(outboxConfiguration.maxConcurrentConversations == 7)
        #expect(writeBatchConfiguration.maxQueueDepthPerConversation == 19)
    }

    @Test("Message write batcher rejects messages above per-conversation queue limit")
    func messageWriteBatcherRejectsAboveConversationQueueLimit() async throws {
        try await withApp(configure: configure) { app in
            app.messageWriteBatchConfiguration = IMMessageWriteBatchConfiguration(
                enabled: true,
                maxSize: 10,
                maxDelayMillis: 250,
                maxQueueDepthPerConversation: 1
            )

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let peer = try await makeUser(email: "write-queue-peer@example.com", on: app)
            let conversation = Conversation(
                title: "Write Queue Limit",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_100_000)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: senderID,
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: try peer.requireID()
            ).create(on: app.db)

            let service = IMRealtimeMessageService(app: app)
            let firstWrite = Task {
                try await service.persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationID,
                        clientMessageID: "write-queue-first",
                        text: "first"
                    ),
                    senderUserID: senderID
                )
            }

            try await Task.sleep(nanoseconds: 20_000_000)
            do {
                _ = try await service.persistIncomingMessage(
                    imTCPTextPayload(
                        conversationID: conversationID,
                        clientMessageID: "write-queue-second",
                        text: "second"
                    ),
                    senderUserID: senderID
                )
                Issue.record("Expected second queued message to be rejected")
            } catch IMRealtimeMessageError.messageWriteQueueFull {
            } catch {
                Issue.record("Unexpected write queue error: \(error)")
            }

            let firstResult = try await firstWrite.value
            #expect(firstResult.acknowledgement.status == "accepted")
            try await Task.sleep(nanoseconds: 10_000_000)
            let metrics = await app.messageWriteMetrics.currentSnapshot()
            #expect(metrics.writeQueueRejected == 1)
        }
    }

    @Test("Message-created projection uses event message and updates large group summaries")
    func messageCreatedProjectionUsesEventMessageForLargeGroups() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]

            for index in 0..<24 {
                let user = User(
                    email: "projection-large-\(index)@example.com",
                    passwordHash: "test-password-hash",
                    status: .active
                )
                try await user.create(on: app.db)
                memberUserIDs.append(try user.requireID())
            }

            let conversation = Conversation(
                title: "Large Projection",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_000_000),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member,
                    lastReadSequence: userID == senderID ? 1 : 0
                ).create(on: app.db)
            }

            let eventMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                clientMessageID: "projection-event-message",
                content: .richText(.plain("event message"))
            )
            try await eventMessage.create(on: app.db)
            let eventMessageID = try eventMessage.requireID()

            let laterMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 2,
                clientMessageID: "projection-later-message",
                content: .richText(.plain("later message"))
            )
            try await laterMessage.create(on: app.db)

            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .init(recipientUserIDs: memberUserIDs, messageID: eventMessageID),
                createdAt: Date(timeIntervalSince1970: 1_710_000_001)
            )
            let envelope = ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationProjectionConsumer(app: app, sourceDB: app.db).consume(envelope)
            try await ChangesLogConsumer(app: app, sourceDB: app.db).consume(envelope)

            for userID in memberUserIDs {
                let recordID = ConversationUserSummary.recordID(
                    ownerUserID: userID,
                    conversationID: conversationID
                )
                let maybeSummary = try await ConversationUserSummary.find(recordID, on: app.imSummaryDB)
                let summary = try #require(maybeSummary)
                #expect(summary.lastMessage?.id == eventMessageID)
                #expect(summary.lastMessage?.body["text"] == "event message")
                #expect(summary.lastMessage?.serverSequence == 1)
                #expect(summary.memberCount == memberUserIDs.count)
                #expect(summary.memberUserIDs.sorted { $0.uuidString < $1.uuidString } == memberUserIDs.sorted { $0.uuidString < $1.uuidString })
                #expect(summary.lastReadSequence == (userID == senderID ? 1 : 0))
                #expect(summary.unreadCount == (userID == senderID ? 0 : 1))

                let maybeChange = try await ConversationChangesLogEntry.find(recordID, on: app.imSummaryDB)
                let change = try #require(maybeChange)
                #expect(change.summaryRecordID == recordID)
                #expect(change.isRemoved == false)

                let maybeToken = try await ConversationReadModelToken.find(
                    ConversationReadModelToken.recordID(ownerUserID: userID),
                    on: app.imSummaryDB
                )
                let token = try #require(maybeToken)
                #expect(token.targetToken.isEmpty == false)
            }
        }
    }

    @Test("Message-created projection preserves stable fields on existing summaries")
    func messageCreatedProjectionPreservesStableFieldsOnExistingSummaries() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let peer = try await makeUser(email: "summary-stable-peer@example.com", on: app)
            let peerID = try peer.requireID()
            let conversation = Conversation(
                title: "Updated DB Title",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_210_000)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(conversationID: conversationID, userID: senderID, role: .owner).create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID).create(on: app.db)

            let stableSummary = try ConversationUserSummary(
                ownerUserID: peerID,
                conversationID: conversationID,
                title: "Existing Stable Title",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeerUserID: nil,
                directPeerEmail: nil,
                notice: "Existing notice",
                avatarPreset: .ocean,
                memberUserIDs: [senderID, peerID],
                lastMessage: nil,
                lastReadSequence: 0,
                unreadCount: 0,
                lastActivityAt: .distantPast,
                updatedAt: .distantPast,
                isRemoved: false
            )
            try await stableSummary.create(on: app.imSummaryDB)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 3,
                clientMessageID: "summary-stable-message",
                content: .richText(.plain("new dynamic message"))
            )
            try await message.create(on: app.db)

            try await IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: app.imSummaryDB
            ).applyMessageCreated(
                conversationID: conversationID,
                messageID: try message.requireID(),
                recipientUserIDs: [peerID],
                on: app.db,
                writeChangeLog: true
            )

            let recordID = ConversationUserSummary.recordID(ownerUserID: peerID, conversationID: conversationID)
            let summary = try #require(try await ConversationUserSummary.find(recordID, on: app.imSummaryDB))
            #expect(summary.title == "Existing Stable Title")
            #expect(summary.notice == "Existing notice")
            #expect(summary.avatarPresetEnum == .ocean)
            #expect(summary.memberUserIDs == [senderID, peerID])
            #expect(summary.lastMessage?.serverSequence == 3)
            #expect(summary.unreadCount == 3)
            #expect(try await ConversationChangesLogEntry.find(recordID, on: app.imSummaryDB) != nil)
        }
    }

    @Test("Read-advanced projection updates only the target owner summary")
    func readAdvancedProjectionUpdatesOnlyTargetOwnerSummary() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let reader = try await makeUser(email: "read-advanced-reader@example.com", on: app)
            let readerID = try reader.requireID()
            let observer = try await makeUser(email: "read-advanced-observer@example.com", on: app)
            let observerID = try observer.requireID()
            let memberUserIDs = [senderID, readerID, observerID]

            let conversation = Conversation(
                title: "Read Advanced Incremental",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_300_000),
                lastMessageSequence: 10
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member,
                    lastReadSequence: 0
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 10,
                clientMessageID: "read-advanced-source",
                content: .richText(.plain("latest"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            let projectionService = IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: app.imSummaryDB
            )
            try await projectionService.applyMessageCreated(
                conversationID: conversationID,
                messageID: messageID,
                recipientUserIDs: memberUserIDs,
                on: app.db,
                writeChangeLog: false
            )

            let observerRecordID = ConversationUserSummary.recordID(
                ownerUserID: observerID,
                conversationID: conversationID
            )
            let observerBefore = try #require(
                try await ConversationUserSummary.find(observerRecordID, on: app.imSummaryDB)
            )
            #expect(observerBefore.unreadCount == 10)

            let readerMember = try #require(
                try await ConversationMember.query(on: app.db)
                    .filter(\.$conversation.$id == conversationID)
                    .filter(\.$user.$id == readerID)
                    .first()
            )
            readerMember.lastReadSequence = 7
            try await readerMember.update(on: app.db)

            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .readAdvanced,
                payload: .init(recipientUserIDs: [readerID]),
                createdAt: Date(timeIntervalSince1970: 1_710_300_010)
            )
            let envelope = ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationProjectionConsumer(app: app, sourceDB: app.db).consume(envelope)
            try await ChangesLogConsumer(app: app, sourceDB: app.db).consume(envelope)

            let readerRecordID = ConversationUserSummary.recordID(
                ownerUserID: readerID,
                conversationID: conversationID
            )
            let readerSummary = try #require(
                try await ConversationUserSummary.find(readerRecordID, on: app.imSummaryDB)
            )
            #expect(readerSummary.lastReadSequence == 7)
            #expect(readerSummary.unreadCount == 3)
            #expect(readerSummary.lastMessage?.serverSequence == 10)

            let observerAfter = try #require(
                try await ConversationUserSummary.find(observerRecordID, on: app.imSummaryDB)
            )
            #expect(observerAfter.lastReadSequence == 0)
            #expect(observerAfter.unreadCount == 10)
            #expect(observerAfter.lastMessage?.serverSequence == 10)

            let readerChange = try await ConversationChangesLogEntry.find(readerRecordID, on: app.imSummaryDB)
            #expect(readerChange?.summaryRecordID == readerRecordID)
            let observerChange = try await ConversationChangesLogEntry.find(observerRecordID, on: app.imSummaryDB)
            #expect(observerChange == nil)

            let token = try await ConversationReadModelToken.find(
                ConversationReadModelToken.recordID(ownerUserID: readerID),
                on: app.imSummaryDB
            )
            #expect(token?.targetToken.isEmpty == false)
        }
    }

    @Test("Read-advanced projection refreshes missing summaries")
    func readAdvancedProjectionRefreshesMissingSummaries() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let reader = try await makeUser(email: "read-advanced-missing@example.com", on: app)
            let readerID = try reader.requireID()

            let conversation = Conversation(
                title: "Read Advanced Missing Summary",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_310_000),
                lastMessageSequence: 8
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: senderID,
                role: .owner
            ).create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: readerID,
                lastReadSequence: 4
            ).create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 8,
                clientMessageID: "read-advanced-missing-source",
                content: .richText(.plain("restored latest"))
            )
            try await message.create(on: app.db)

            let didApplyIncrementally = try await IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: app.imSummaryDB
            ).applyReadAdvanced(
                conversationID: conversationID,
                recipientUserID: readerID,
                on: app.db,
                writeChangeLog: true
            )
            #expect(didApplyIncrementally == false)

            let recordID = ConversationUserSummary.recordID(ownerUserID: readerID, conversationID: conversationID)
            let summary = try #require(try await ConversationUserSummary.find(recordID, on: app.imSummaryDB))
            #expect(summary.lastReadSequence == 4)
            #expect(summary.unreadCount == 4)
            #expect(summary.lastMessage?.serverSequence == 8)

            let change = try await ConversationChangesLogEntry.find(recordID, on: app.imSummaryDB)
            #expect(change?.summaryRecordID == recordID)
            let token = try await ConversationReadModelToken.find(
                ConversationReadModelToken.recordID(ownerUserID: readerID),
                on: app.imSummaryDB
            )
            #expect(token?.targetToken.isEmpty == false)
        }
    }

    @Test("Media asset reference consumer indexes and removes media messages")
    func mediaAssetReferenceConsumerIndexesAndRemovesMediaMessages() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let peer = try await makeUser(email: "media-reference-peer@example.com", on: app)
            let peerID = try peer.requireID()
            let conversation = Conversation(
                title: "Media References",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_200_000)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(conversationID: conversationID, userID: senderID, role: .owner).create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID).create(on: app.db)

            let asset = IMMediaAsset(
                assetID: "shared-reference-asset",
                kind: .file,
                mimeType: "application/pdf",
                byteSize: 128,
                filename: "plan.pdf",
                width: nil,
                height: nil,
                durationMillis: nil,
                previewAssetID: nil
            )
            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 4,
                clientMessageID: "media-reference-message",
                content: .file(asset)
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let createdEvent = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .init(recipientUserIDs: [senderID, peerID], messageID: messageID)
            )
            let createdEnvelope = ConversationEventEnvelope(
                event: createdEvent,
                payload: try createdEvent.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationMediaAssetReferenceConsumer(db: app.db, app: app).consume(createdEnvelope)

            let recordID = ConversationMediaAssetReference.recordID(messageID: messageID)
            let reference = try #require(
                try await ConversationMediaAssetReference.find(recordID, on: app.db)
            )
            #expect(reference.assetID == asset.assetID)
            #expect(reference.ownerUserID == senderID)
            #expect(reference.conversationID == conversationID)
            #expect(reference.serverSequence == 4)
            #expect(reference.kind == IMMediaAssetKind.file.rawValue)
            let directory = try #require(
                try await ConversationMediaAssetReferenceDirectory.find(
                    ConversationMediaAssetReferenceDirectory.recordID(messageID: messageID),
                    on: app.imSummaryDB
                )
            )
            #expect(directory.assetID == asset.assetID)
            #expect(directory.shardID == SingleShardConversationShardRouter.defaultShardID)
            #expect(directory.conversationID == conversationID)
            #expect(directory.ownerUserID == senderID)

            try message.replaceContent(.recalled)
            try await message.update(on: app.db)
            let recalledEvent = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageRecalled,
                payload: .init(recipientUserIDs: [senderID, peerID], messageID: messageID)
            )
            let recalledEnvelope = ConversationEventEnvelope(
                event: recalledEvent,
                payload: try recalledEvent.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationMediaAssetReferenceConsumer(db: app.db, app: app).consume(recalledEnvelope)
            let removedReference = try await ConversationMediaAssetReference.find(recordID, on: app.db)
            #expect(removedReference == nil)
            let removedDirectory = try await ConversationMediaAssetReferenceDirectory.find(
                ConversationMediaAssetReferenceDirectory.recordID(messageID: messageID),
                on: app.imSummaryDB
            )
            #expect(removedDirectory == nil)
        }
    }

    @Test("Directory backed shard router caches conversation shard lookups")
    func directoryBackedShardRouterCachesConversationLookups() async throws {
        try await withApp(configure: configure) { app in
            let directory = CountingConversationDirectory(shardID: "shard-a")
            let router = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: ["shard-a", "shard-b"],
                shardDatabaseIDs: [:],
                shardReplicaDatabaseIDs: [:],
                directory: directory
            )
            let conversationID = UUID()

            let first = try await router.shardID(forConversationID: conversationID)
            let second = try await router.shardID(forConversationID: conversationID)

            #expect(first == "shard-a")
            #expect(second == "shard-a")
            #expect(await directory.lookupCount == 1)
        }
    }

    @Test("Outbox failure increments retry count")
    func conversationOutboxFailureIncrementsRetryCount() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init()
            )
            try await event.create(on: app.db)
            guard let eventID = event.id else {
                Issue.record("Missing outbox event ID")
                return
            }

            try await sql.raw("""
                UPDATE conversation_domain_events
                SET payload_json = '{"malformed":'
                WHERE id = \(bind: eventID)
                """).run()

            _ = try await ConversationOutboxProcessor(db: app.db).processPendingBatch(
                app: app,
                configuration: .init(
                    batchSize: 10,
                    pollIntervalNanoseconds: 100_000_000,
                    maxRetries: 2,
                    logsProcessingFailures: false
                )
            )

            guard let reloaded = try await ConversationDomainEvent.find(eventID, on: app.db) else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.statusEnum == .failed)
            #expect(reloaded.retryCount == 1)
            #expect(reloaded.errorMessage?.isEmpty == false)
        }
    }

    @Test("Outbox side-effect failures do not block critical projections")
    func outboxSideEffectFailuresDoNotBlockCriticalProjections() async throws {
        try await withApp(configure: configure) { app in
            app.conversationSearchIndexWriter = FailingConversationSearchIndexWriter()

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let peer = try await makeUser(email: "side-effect-peer@example.com", on: app)
            let peerID = try peer.requireID()
            let conversation = Conversation(
                title: "Side Effect Failure",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_320_000),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(conversationID: conversationID, userID: senderID, role: .owner).create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID).create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                clientMessageID: "side-effect-message",
                content: .richText(.plain("critical path should finish"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .init(recipientUserIDs: [senderID, peerID], messageID: messageID)
            )
            try await event.create(on: app.db)
            let eventID = try #require(event.id)

            let processedCount = try await ConversationOutboxProcessor(db: app.db).processPendingBatch(
                app: app,
                configuration: .init(
                    batchSize: 10,
                    pollIntervalNanoseconds: 100_000_000,
                    maxRetries: 2,
                    logsProcessingFailures: false
                )
            )
            #expect(processedCount == 1)

            let reloadedEvent = try #require(try await ConversationDomainEvent.find(eventID, on: app.db))
            #expect(reloadedEvent.statusEnum == .processed)
            #expect(reloadedEvent.retryCount == 0)

            for userID in [senderID, peerID] {
                let recordID = ConversationUserSummary.recordID(
                    ownerUserID: userID,
                    conversationID: conversationID
                )
                let summary = try #require(try await ConversationUserSummary.find(recordID, on: app.imSummaryDB))
                #expect(summary.lastMessage?.id == messageID)
                let change = try await ConversationChangesLogEntry.find(recordID, on: app.imSummaryDB)
                #expect(change?.summaryRecordID == recordID)
            }
        }
    }

    @Test("Failed outbox events can be requeued")
    func failedConversationOutboxEventsCanBeRequeued() async throws {
        try await withApp(configure: configure) { app in
            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init(),
                status: .failed
            )
            event.retryCount = 3
            event.processingStartedAt = Date()
            event.errorMessage = "boom"
            try await event.create(on: app.imWriteDB)

            let requeuedCount = try await ConversationOutboxRetryService(db: app.imWriteDB).requeueFailedEvents(maxRetryCount: 5)
            #expect(requeuedCount == 1)

            guard let eventID = event.id,
                  let reloaded = try await ConversationDomainEvent.find(eventID, on: app.imWriteDB)
            else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.statusEnum == .pending)
            #expect(reloaded.retryCount == 0)
            #expect(reloaded.processingStartedAt == nil)
            #expect(reloaded.processedAt == nil)
            #expect(reloaded.errorMessage == nil)
        }
    }

    @Test("Outbox relay marks stream publication once per event")
    func conversationOutboxRelayMarksPublishedEvents() async throws {
        try await withApp(configure: configure) { app in
            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init(recipientUserIDs: [UUID()])
            )
            try await event.create(on: app.imWriteDB)

            let relayedCount = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
            #expect(relayedCount == 1)

            guard let eventID = event.id,
                  let reloaded = try await ConversationDomainEvent.find(eventID, on: app.imWriteDB)
            else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.streamPublishedAt != nil)
            #expect(reloaded.streamPublishError == nil)
            #expect(reloaded.streamPublishStartedAt == nil)
            #expect(reloaded.streamPublishClaimedBy == nil)

            let secondRelayCount = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
            #expect(secondRelayCount == 0)
        }
    }

    @Test("Outbox relay skips active claims and recovers timed out claims")
    func conversationOutboxRelayRecoversTimedOutClaims() async throws {
        try await withApp(configure: configure) { app in
            app.conversationOutboxConfiguration = .init(
                batchSize: 10,
                pollIntervalNanoseconds: 100_000_000,
                maxRetries: 5,
                claimTimeoutNanoseconds: 1_000_000_000
            )
            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init(recipientUserIDs: [UUID()])
            )
            event.streamPublishStartedAt = Date()
            event.streamPublishClaimedBy = "other-relay"
            try await event.create(on: app.imWriteDB)

            let activeClaimRelayCount = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
            #expect(activeClaimRelayCount == 0)

            event.streamPublishStartedAt = Date(timeIntervalSinceNow: -5)
            try await event.update(on: app.imWriteDB)

            let recoveredRelayCount = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
            #expect(recoveredRelayCount == 1)

            guard let eventID = event.id,
                  let reloaded = try await ConversationDomainEvent.find(eventID, on: app.imWriteDB)
            else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.streamPublishedAt != nil)
            #expect(reloaded.streamPublishStartedAt == nil)
            #expect(reloaded.streamPublishClaimedBy == nil)
        }
    }

    @Test("Outbox relay keeps events retryable when stream publish fails")
    func conversationOutboxRelayKeepsEventsRetryableWhenPublishFails() async throws {
        try await withApp(configure: configure) { app in
            app.conversationEventStreamProducer = FailingConversationEventStreamProducer()
            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .init(recipientUserIDs: [UUID()])
            )
            try await event.create(on: app.imWriteDB)

            do {
                _ = try await ConversationOutboxRelay(app: app).relayPendingEvents(limit: 10)
                Issue.record("Expected stream publish failure")
            } catch let abort as any AbortError {
                #expect(abort.status == .serviceUnavailable)
            } catch {
                Issue.record("Unexpected publish error: \(error)")
            }

            guard let eventID = event.id,
                  let reloaded = try await ConversationDomainEvent.find(eventID, on: app.imWriteDB)
            else {
                Issue.record("Missing reloaded outbox event")
                return
            }

            #expect(reloaded.streamPublishedAt == nil)
            #expect(reloaded.streamPublishError?.contains("stream unavailable") == true)
            #expect(reloaded.streamPublishStartedAt == nil)
            #expect(reloaded.streamPublishClaimedBy == nil)
        }
    }

    @Test("Notification consumer writes owner-scoped notification entries")
    func notificationConsumerWritesOwnerScopedEntries() async throws {
        try await withApp(configure: configure) { app in
            let recipientUserID = UUID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: UUID(),
                eventType: .messageUpdated,
                payload: .init(recipientUserIDs: [recipientUserID]),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let envelope = ConversationEventEnvelope(event: event, payload: try event.decodedPayload(), deliveryContext: nil)

            try await ConversationNotificationConsumer(app: app).consume(envelope)

            let recordID = ConversationNotificationEntry.recordID(ownerUserID: recipientUserID, eventID: try #require(event.id))
            let stored = try await ConversationNotificationEntry.find(recordID, on: app.imSummaryDB)
            #expect(stored?.ownerUserID == recipientUserID)
            #expect(stored?.conversationID == event.conversationID)
            #expect(stored?.eventType == ConversationDomainEventType.messageUpdated.rawValue)
        }
    }

    @Test("Repair replay consumer stores dead-letter envelopes for later replay")
    func repairReplayConsumerStoresDeadLetterEnvelopes() async throws {
        try await withApp(configure: configure) { app in
            let eventID = UUID()
            let conversationID = UUID()
            let envelope = ConversationEventEnvelope(
                event: try ConversationDomainEvent(
                    id: eventID,
                    conversationID: conversationID,
                    eventType: .metadataUpdated,
                    payload: .init(recipientUserIDs: [UUID()]),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                payload: .init(recipientUserIDs: [UUID()]),
                deliveryContext: .init(
                    sourceTopic: "conversation-domain-events-dead-letter",
                    consumerGroupID: "repair-replay-consumer",
                    producerShard: "shard-0",
                    deadLetterError: "projection failed"
                )
            )

            try await RepairReplayConsumer(
                db: app.imWriteDB,
                consumerGroupID: "repair-replay-consumer"
            ).consume(envelope)

            let recordID = ConversationReplayRecord.recordID(
                consumerGroupID: "repair-replay-consumer",
                eventID: eventID
            )
            let stored = try await ConversationReplayRecord.find(recordID, on: app.imWriteDB)
            #expect(stored?.conversationID == conversationID)
            #expect(stored?.sourceTopic == "conversation-domain-events-dead-letter")
            #expect(stored?.producerShard == "shard-0")
            #expect(stored?.lastError == "projection failed")
            #expect(stored?.statusEnum == .pending)
        }
    }
}

private actor CountingConversationDirectory: ConversationDirectory {
    private let storedShardID: String
    private(set) var lookupCount = 0

    init(shardID: String) {
        storedShardID = shardID
    }

    func shardID(for conversationID: UUID) async throws -> String {
        lookupCount += 1
        return storedShardID
    }

    func registerConversation(conversationID: UUID, shardID: String) async throws { }
}

private struct FailingConversationSearchIndexWriter: ConversationSearchIndexWriter {
    func reindexMessage(messageID: UUID, on database: any Database) async throws {
        throw Abort(.internalServerError, reason: "search index unavailable")
    }
}

private actor FailingConversationEventStreamProducer: ConversationEventStreamProducer {
    let driverName = "failing-test"

    func publish(_ envelope: ConversationEventStreamEnvelope) async throws {
        throw Abort(.serviceUnavailable, reason: "stream unavailable")
    }
}
