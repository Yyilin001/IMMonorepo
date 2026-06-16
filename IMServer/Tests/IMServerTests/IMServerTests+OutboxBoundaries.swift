@testable import IMServer
import Fluent
import Kafka
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Kafka conversation event messages use conversation ID as partition key")
    func kafkaConversationEventMessagesUseConversationIDAsPartitionKey() throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000001")!
        let envelope = ConversationEventStreamEnvelope(
            eventID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000002")!,
            conversationID: conversationID,
            aggregateSequence: 42,
            eventType: ConversationDomainEventType.messageCreated.rawValue,
            payload: .messageCreated(
                messageID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000003")!,
                recipientUserIDs: [],
                preview: ConversationMessageCreatedPreview(
                    senderUserID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000004")!,
                    serverSequence: 42,
                    timelineSequence: 42,
                    previewText: "partition key",
                    createdAt: Date(timeIntervalSince1970: 1_710_410_000)
                )
            ),
            occurredAt: Date(timeIntervalSince1970: 1_710_410_000),
            producerShard: "conversation-shard-0"
        )

        let message = try KafkaConversationEventStreamMessageFactory.makeMessage(
            envelope: envelope,
            topic: "conversation-domain-events"
        )
        let deadLetterMessage = try KafkaConversationEventStreamMessageFactory.makeMessage(
            envelope: envelope,
            topic: "conversation-domain-events-dead-letter",
            additionalHeaders: [kafkaTestHeader(key: "dead-letter-error", value: "decode failed")]
        )

        #expect(message.topic == "conversation-domain-events")
        #expect(message.key == conversationID.uuidString)
        #expect(kafkaHeaderValue("event-id", in: message.headers) == envelope.eventID.uuidString)
        #expect(kafkaHeaderValue("event-version", in: message.headers) == String(envelope.eventVersion))
        #expect(kafkaHeaderValue("aggregate-type", in: message.headers) == envelope.aggregateType)
        #expect(kafkaHeaderValue("event-type", in: message.headers) == ConversationDomainEventType.messageCreated.rawValue)
        #expect(kafkaHeaderValue("producer-shard", in: message.headers) == "conversation-shard-0")
        #expect(kafkaHeaderValue("occurred-at", in: message.headers) != nil)
        #expect(deadLetterMessage.topic == "conversation-domain-events-dead-letter")
        #expect(deadLetterMessage.key == conversationID.uuidString)
        #expect(kafkaHeaderValue("event-type", in: deadLetterMessage.headers) == ConversationDomainEventType.messageCreated.rawValue)
        #expect(kafkaHeaderValue("dead-letter-error", in: deadLetterMessage.headers) == "decode failed")
    }

    @Test("Stream batch fill policy only waits for valid messageCreated events")
    func streamBatchFillPolicyOnlyWaitsForValidMessageCreatedEvents() {
        let conversationID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000011")!
        let messageCreated = testStreamEnvelope(
            conversationID: conversationID,
            eventType: .messageCreated,
            payload: .messageCreated(
                messageID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000012")!,
                recipientUserIDs: [],
                preview: nil
            )
        )
        let readAdvanced = testStreamEnvelope(
            conversationID: conversationID,
            eventType: .readAdvanced,
            payload: .readAdvanced(ownerUserID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000013")!)
        )
        let malformedMessageCreated = testStreamEnvelope(
            conversationID: conversationID,
            eventType: .messageCreated,
            payload: .readAdvanced(ownerUserID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000014")!)
        )

        #expect(ConversationEventStreamBatchFillPolicy.isEligible(messageCreated))
        #expect(!ConversationEventStreamBatchFillPolicy.isEligible(readAdvanced))
        #expect(!ConversationEventStreamBatchFillPolicy.isEligible(malformedMessageCreated))
        #expect(ConversationEventStreamBatchFillPolicy.shouldDecodeEnvelope(headerEventType: nil))
        #expect(ConversationEventStreamBatchFillPolicy.shouldDecodeEnvelope(headerEventType: ConversationDomainEventType.messageCreated.rawValue))
        #expect(!ConversationEventStreamBatchFillPolicy.shouldDecodeEnvelope(headerEventType: ConversationDomainEventType.readAdvanced.rawValue))
    }

    @Test("Contact outbox processing records delivery before best-effort realtime")
    func contactOutboxProcessingRecordsDeliveryBeforeBestEffortRealtime() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let peer = try await makeUser(email: "contact-outbox-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let eventID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

            let event = try ContactDomainEvent(
                id: eventID,
                ownerUserID: ownerID,
                eventType: .contactRemoved,
                aggregateID: peerID,
                ownerSequence: 1,
                actorUserID: ownerID,
                payload: .contactRemoved(contactUserID: peerID, affectedConversationIDs: [])
            )
            try await event.create(on: app.db)

            let processed = try await ContactOutboxProcessor(db: app.db).processPendingBatch(
                app: app,
                configuration: .init(batchSize: 10, pollIntervalNanoseconds: 100_000_000, maxRetries: 5)
            )

            let reloadedEvent = try #require(try await ContactDomainEvent.find(eventID, on: app.db))
            let delivery = try await OwnerDomainEventDelivery.find(
                OwnerDomainEventDelivery.recordID(ownerUserID: ownerID, eventID: eventID),
                on: app.db
            )
            #expect(processed == 1)
            #expect(reloadedEvent.statusEnum == .processed)
            #expect(delivery?.ownerUserID == ownerID)
            #expect(delivery?.sourceType == DomainEventSourceType.contact.rawValue)
        }
    }

    @Test("Contact realtime relay does not create missing delivery rows")
    func contactRealtimeRelayDoesNotCreateMissingDeliveryRows() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let peer = try await makeUser(email: "contact-relay-missing@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let eventID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!

            let event = try ContactDomainEvent(
                id: eventID,
                ownerUserID: ownerID,
                eventType: .contactRemoved,
                aggregateID: peerID,
                ownerSequence: 1,
                actorUserID: ownerID,
                payload: .contactRemoved(contactUserID: peerID, affectedConversationIDs: [])
            )
            try await event.create(on: app.db)

            await ContactRealtimeRelay(app: app, db: app.db).relay(event: event)

            let delivery = try await OwnerDomainEventDelivery.find(
                OwnerDomainEventDelivery.recordID(ownerUserID: ownerID, eventID: eventID),
                on: app.db
            )
            #expect(delivery == nil)
        }
    }

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

    @Test("Owner delivery recordBatch preserves repeated owner sequence semantics")
    func ownerDeliveryRecordBatchPreservesRepeatedOwnerSequenceSemantics() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let ownerID = try owner.requireID()
            let conversationID = UUID()
            let firstEventID = UUID()
            let secondEventID = UUID()
            let firstPayload = ownerDeliveryTestPayload(
                eventID: firstEventID,
                conversationID: conversationID,
                senderUserID: ownerID,
                sequence: 1,
                text: "owner batch first"
            )
            let secondPayload = ownerDeliveryTestPayload(
                eventID: secondEventID,
                conversationID: conversationID,
                senderUserID: ownerID,
                sequence: 2,
                text: "owner batch second"
            )
            let service = OwnerDomainEventDeliveryService(
                db: app.db,
                domainEventMetrics: app.conversationDomainEventMetrics
            )

            let rows = try await service.recordBatch([
                .init(
                    ownerUserID: ownerID,
                    payload: firstPayload,
                    sourceType: .conversation,
                    sourceEventID: firstEventID
                ),
                .init(
                    ownerUserID: ownerID,
                    payload: secondPayload,
                    sourceType: .conversation,
                    sourceEventID: secondEventID
                ),
                .init(
                    ownerUserID: ownerID,
                    payload: firstPayload,
                    sourceType: .conversation,
                    sourceEventID: firstEventID
                )
            ])

            #expect(rows.map(\.eventID) == [firstEventID, secondEventID, firstEventID])
            #expect(rows.map(\.ownerCursor) == [1, 2, 1])
            #expect(rows.map(\.ownerAggregateSequence) == [1, 2, 1])

            let storedRows = try await OwnerDomainEventDelivery.query(on: app.db)
                .filter(\.$ownerUserID == ownerID)
                .sort(\.$ownerCursor, .ascending)
                .all()
            #expect(storedRows.map(\.eventID) == [firstEventID, secondEventID])
            #expect(storedRows.map(\.ownerCursor) == [1, 2])
            #expect(storedRows.map(\.ownerAggregateSequence) == [1, 2])

            let repeatedRows = try await service.recordBatch([
                .init(
                    ownerUserID: ownerID,
                    payload: firstPayload,
                    sourceType: .conversation,
                    sourceEventID: firstEventID
                ),
                .init(
                    ownerUserID: ownerID,
                    payload: secondPayload,
                    sourceType: .conversation,
                    sourceEventID: secondEventID
                )
            ])
            #expect(repeatedRows.map(\.ownerCursor) == [1, 2])
            #expect(repeatedRows.map(\.ownerAggregateSequence) == [1, 2])

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.ownerDeliveryBatchWriteCount == 2)
            #expect(metrics.ownerDeliveryBatchWriteRequestCount == 5)
            #expect(metrics.ownerDeliveryBatchWriteReturnedRowCount == 5)
            #expect(metrics.ownerDeliveryBatchWriteFallbackCount == 2)
            #expect(metrics.ownerDeliveryBatchWriteMaxRequests == 3)
        }
    }

    @Test("Owner delivery recordBatch canonical deliveries preserve repeated owner sequence semantics")
    func ownerDeliveryRecordBatchCanonicalDeliveriesPreserveRepeatedOwnerSequenceSemantics() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let ownerID = try owner.requireID()
            let conversationID = UUID()
            let firstEventID = UUID()
            let secondEventID = UUID()
            let firstPayload = ownerDeliveryTestPayload(
                eventID: firstEventID,
                conversationID: conversationID,
                senderUserID: ownerID,
                sequence: 1,
                text: "owner canonical first"
            )
            let secondPayload = ownerDeliveryTestPayload(
                eventID: secondEventID,
                conversationID: conversationID,
                senderUserID: ownerID,
                sequence: 2,
                text: "owner canonical second"
            )
            let service = OwnerDomainEventDeliveryService(
                db: app.db,
                domainEventMetrics: app.conversationDomainEventMetrics
            )

            let deliveries = try await service.recordBatchCanonicalDeliveries([
                .init(
                    ownerUserID: ownerID,
                    payload: firstPayload,
                    sourceType: .conversation,
                    sourceEventID: firstEventID
                ),
                .init(
                    ownerUserID: ownerID,
                    payload: secondPayload,
                    sourceType: .conversation,
                    sourceEventID: secondEventID
                ),
                .init(
                    ownerUserID: ownerID,
                    payload: firstPayload,
                    sourceType: .conversation,
                    sourceEventID: firstEventID
                )
            ])

            #expect(deliveries.map(\.eventID) == [firstEventID, secondEventID, firstEventID])
            #expect(deliveries.map(\.ownerUserID) == [ownerID, ownerID, ownerID])
            #expect(deliveries.map(\.payload.ownerCursor) == [1, 2, 1])
            #expect(deliveries.map(\.payload.ownerAggregateSequence) == [1, 2, 1])

            let repeatedDeliveries = try await service.recordBatchCanonicalDeliveries([
                .init(
                    ownerUserID: ownerID,
                    payload: firstPayload,
                    sourceType: .conversation,
                    sourceEventID: firstEventID
                ),
                .init(
                    ownerUserID: ownerID,
                    payload: secondPayload,
                    sourceType: .conversation,
                    sourceEventID: secondEventID
                )
            ])
            #expect(repeatedDeliveries.map(\.payload.ownerCursor) == [1, 2])
            #expect(repeatedDeliveries.map(\.payload.ownerAggregateSequence) == [1, 2])
            #expect(repeatedDeliveries.map(\.payload.eventID) == [firstEventID, secondEventID])
        }
    }

    @Test("Message-created run owner delivery preserves per-owner event order")
    func messageCreatedRunOwnerDeliveryPreservesPerOwnerEventOrder() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let peer = try await makeUser(email: "owner-delivery-run-peer@example.com", on: app)
            let peerID = try peer.requireID()
            let memberUserIDs = [senderID, peerID]

            let conversation = Conversation(
                title: "Owner Delivery Run",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_410_050),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            var envelopes: [ConversationEventEnvelope] = []
            var eventIDs: [UUID] = []
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "owner-delivery-run-\(sequence)",
                    content: .richText(.plain("owner delivery run \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                    createdAt: Date(timeIntervalSince1970: 1_710_410_050 + TimeInterval(sequence))
                )
                eventIDs.append(try event.requireID())
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            try await OwnerDomainEventDeliveryConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun(envelopes)

            let deliveryCount = try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count()
            #expect(deliveryCount == memberUserIDs.count * eventIDs.count)

            for ownerID in memberUserIDs {
                let rows = try await OwnerDomainEventDelivery.query(on: app.imSummaryDB)
                    .filter(\.$ownerUserID == ownerID)
                    .sort(\.$ownerCursor, .ascending)
                    .all()
                #expect(rows.map(\.eventID) == eventIDs)
                #expect(rows.map(\.ownerCursor) == [1, 2])
                #expect(rows.map(\.ownerAggregateSequence) == [1, 2])
            }
        }
    }

    @Test("Conversation event registry dispatches messageCreated runs to batch-aware consumers")
    func conversationEventRegistryDispatchesMessageCreatedRunsToBatchAwareConsumers() async throws {
        let probe = MessageCreatedRunProbe()
        let consumer = ProbeMessageCreatedRunConsumer(probe: probe)
        let registry = ConversationEventConsumerRegistry(consumers: [consumer])
        let conversationID = UUID()
        let firstEventID = UUID()
        let secondEventID = UUID()
        let envelopes = try [firstEventID, secondEventID].enumerated().map { index, eventID in
            let sequence = index + 1
            let event = try ConversationDomainEvent(
                id: eventID,
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: sequence,
                payload: .messageCreated(messageID: UUID(), recipientUserIDs: [UUID()]),
                createdAt: Date(timeIntervalSince1970: 1_710_410_080 + TimeInterval(sequence))
            )
            return try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )
        }

        try await registry.consumeMessageCreatedRun(envelopes)

        let snapshot = await probe.snapshot()
        #expect(snapshot.singleEventIDs.isEmpty)
        #expect(snapshot.runEventIDs == [firstEventID, secondEventID])
    }

    @Test("Stream message run grouper only coalesces contiguous messageCreated events")
    func streamMessageRunGrouperOnlyCoalescesContiguousMessageCreatedEvents() throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let otherConversationID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let recipientID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

        let contiguousRun = [
            streamMetadata(
                topic: "conversation-domain-events",
                partition: 0,
                offset: 10,
                conversationID: conversationID,
                payload: .messageCreated(messageID: UUID(), recipientUserIDs: [recipientID])
            ),
            streamMetadata(
                topic: "conversation-domain-events",
                partition: 0,
                offset: 11,
                conversationID: conversationID,
                payload: .messageCreated(messageID: UUID(), recipientUserIDs: [recipientID])
            )
        ]
        #expect(ConversationEventStreamMessageRunGrouper.isMessageCreatedRun(contiguousRun))

        let mixed = contiguousRun + [
            streamMetadata(
                topic: "conversation-domain-events",
                partition: 0,
                offset: 13,
                conversationID: conversationID,
                payload: .messageCreated(messageID: UUID(), recipientUserIDs: [recipientID])
            ),
            streamMetadata(
                topic: "conversation-domain-events",
                partition: 0,
                offset: 14,
                conversationID: otherConversationID,
                payload: .messageCreated(messageID: UUID(), recipientUserIDs: [recipientID])
            ),
            streamMetadata(
                topic: "conversation-domain-events",
                partition: 0,
                offset: 15,
                conversationID: otherConversationID,
                eventType: .metadataUpdated,
                payload: .metadataUpdated(recipientUserIDs: [recipientID])
            ),
            streamMetadata(
                topic: "conversation-domain-events",
                partition: 1,
                offset: 16,
                conversationID: otherConversationID,
                payload: .messageCreated(messageID: UUID(), recipientUserIDs: [recipientID])
            )
        ]

        let runs = ConversationEventStreamMessageRunGrouper.contiguousRuns(in: mixed)
        #expect(runs.map(\.count) == [2, 1, 1, 1, 1])
        #expect(!ConversationEventStreamMessageRunGrouper.isMessageCreatedRun(mixed))
    }

    @Test("Async bounded queue preserves FIFO order with producer backpressure")
    func asyncBoundedQueuePreservesFIFOOrderWithProducerBackpressure() async throws {
        let queue = AsyncBoundedQueue<Int>(capacity: 2)
        let firstSend = await queue.send(1)
        let secondSend = await queue.send(2)
        #expect(firstSend.didSend)
        #expect(secondSend.didSend)
        #expect(!firstSend.didWaitForCapacity)
        #expect(!secondSend.didWaitForCapacity)
        #expect(firstSend.depth == 1)
        #expect(secondSend.depth == 2)
        #expect(firstSend.revision < secondSend.revision)

        let blockedProducer = Task {
            await queue.send(3)
        }
        for _ in 0..<50 {
            let stats = await queue.stats()
            if stats.waitingProducerCount == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let fullStats = await queue.stats()
        #expect(fullStats.depth == 2)
        #expect(fullStats.waitingProducerCount == 1)
        let first = try await queue.next()
        #expect(first == 1)
        let blockedSend = await blockedProducer.value
        #expect(blockedSend.didSend)
        #expect(blockedSend.didWaitForCapacity)
        #expect(blockedSend.depth == 2)
        #expect(blockedSend.revision > secondSend.revision)

        let drained = await queue.drainAvailable(limit: 10)
        #expect(drained == [2, 3])
        let emptyStats = await queue.stats()
        #expect(emptyStats.depth == 0)
        #expect(emptyStats.revision > blockedSend.revision)
        await queue.finish()
        let next = try await queue.next()
        #expect(next == nil)
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
                timelineSequence: 1,
                clientMessageID: "projection-event-message",
                content: .richText(.plain("event message"))
            )
            try await eventMessage.create(on: app.db)
            let eventMessageID = try eventMessage.requireID()

            let laterMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 2,
                timelineSequence: 2,
                clientMessageID: "projection-later-message",
                content: .richText(.plain("later message"))
            )
            try await laterMessage.create(on: app.db)

            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: eventMessageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_000_001)
            )
            let envelope = try ConversationEventEnvelope(
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

    @Test("Large-group messageCreated owner delivery skips by recipient threshold")
    func largeGroupMessageCreatedOwnerDeliverySkipsByRecipientThreshold() async throws {
        let key = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "owner-delivery-skip-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Owner Delivery Skip",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_410_000),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "owner-delivery-skip-message",
                content: .richText(.plain("skip owner delivery for large group"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_410_001)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await OwnerDomainEventDeliveryConsumer(app: app, sourceDB: app.db).consume(envelope)

            let deliveryCount = try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count()
            #expect(deliveryCount == 0)
            #expect(try await ConversationMessage.find(messageID, on: app.db) != nil)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedOwnerDeliverySkippedCount == 1)
            #expect(metrics.messageCreatedOwnerDeliverySkippedRecipientCount == memberUserIDs.count)
            #expect(metrics.messageCreatedOwnerDeliverySkippedMaxRecipients == memberUserIDs.count)
            #expect(metrics.messageCreatedTimelinePullDeliveryCount == 1)
            #expect(metrics.messageCreatedTimelinePullDeliveryRecipientCount == memberUserIDs.count)
            #expect(metrics.messageCreatedTimelinePullDeliveryMaxRecipients == memberUserIDs.count)
        }
    }

    @Test("Large-group owner delivery skip fails closed without realtime delivery path")
    func largeGroupOwnerDeliverySkipFailsClosedWithoutRealtimeDeliveryPath() async throws {
        let values = [
            "IM_STREAM_CONSUMER_GROUPS": "domain-delivery-consumer",
            "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD": "false",
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE": "timeline-pull",
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD": "3"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "owner-delivery-skip-no-realtime-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Owner Delivery Skip No Realtime",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_410_025),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "owner-delivery-skip-no-realtime-message",
                content: .richText(.plain("skip owner delivery must have realtime path"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_410_026)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            do {
                try await OwnerDomainEventDeliveryConsumer(app: app, sourceDB: app.db).consume(envelope)
                Issue.record("Expected owner delivery skip to fail without realtime delivery path")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("Refusing to skip messageCreated owner delivery"))
                #expect(abort.reason.contains("realtime-delivery-consumer"))
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"))
            } catch {
                Issue.record("Unexpected owner delivery skip error: \(error)")
            }

            let deliveryCount = try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count()
            #expect(deliveryCount == 0)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedOwnerDeliverySkippedCount == 0)
            #expect(metrics.messageCreatedTimelinePullDeliveryCount == 0)
        }
    }

    @Test("Explicit owner-delivery mode keeps durable messageCreated owner delivery despite skip threshold")
    func explicitOwnerDeliveryModeKeepsDurableMessageCreatedOwnerDeliveryDespiteSkipThreshold() async throws {
        let modeKey = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE"
        let thresholdKey = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
        let originalModeValue = Environment.get(modeKey)
        let originalThresholdValue = Environment.get(thresholdKey)
        defer {
            restoreEnvironment(modeKey, to: originalModeValue)
            restoreEnvironment(thresholdKey, to: originalThresholdValue)
        }
        setenv(modeKey, "owner-delivery", 1)
        setenv(thresholdKey, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "owner-delivery-mode-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Owner Delivery Explicit Mode",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_410_050),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "owner-delivery-explicit-mode-message",
                content: .richText(.plain("explicit owner delivery mode keeps owner copies"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_410_051)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await OwnerDomainEventDeliveryConsumer(app: app, sourceDB: app.db).consume(envelope)

            let deliveryCount = try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count()
            #expect(deliveryCount == memberUserIDs.count)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedOwnerDeliverySkippedCount == 0)
            #expect(metrics.messageCreatedTimelinePullDeliveryCount == 0)
        }
    }

    @Test("Small-group messageCreated owner delivery remains durable below skip threshold")
    func smallGroupMessageCreatedOwnerDeliveryRemainsDurableBelowSkipThreshold() async throws {
        let key = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "4", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let peer = try await makeUser(email: "owner-delivery-small-peer@example.com", on: app)
            let peerID = try peer.requireID()
            let memberUserIDs = [senderID, peerID]

            let conversation = Conversation(
                title: "Owner Delivery Small",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_410_100),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "owner-delivery-small-message",
                content: .richText(.plain("small group keeps owner delivery"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_410_101)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await OwnerDomainEventDeliveryConsumer(app: app, sourceDB: app.db).consume(envelope)

            let deliveryCount = try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count()
            #expect(deliveryCount == memberUserIDs.count)
            for userID in memberUserIDs {
                let row = try await OwnerDomainEventDeliveryService(db: app.imSummaryDB).find(
                    ownerUserID: userID,
                    eventID: try #require(event.id)
                )
                #expect(row != nil)
            }
        }
    }

    @Test("Large-group messageCreated summary projection writes conversation activity only")
    func largeGroupMessageCreatedSummaryProjectionWritesConversationActivityOnly() async throws {
        let key = "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "activity-only-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Activity Only",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_000),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "activity-only-message",
                content: .richText(.plain("activity only projection"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_411_001)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationProjectionConsumer(app: app, sourceDB: app.db).consume(envelope)

            let activity = try #require(
                try await ConversationActivitySummary.find(conversationID, on: app.imSummaryDB)
            )
            #expect(activity.lastMessage?.id == messageID)
            #expect(activity.lastMessageServerSequence == 1)
            #expect(activity.lastMessage?.body["text"] == "activity only projection")

            let summaryCount = try await ConversationUserSummary.query(on: app.imSummaryDB).count()
            #expect(summaryCount == 0)
            let changeCount = try await ConversationChangesLogEntry.query(on: app.imSummaryDB).count()
            #expect(changeCount == 0)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedSummaryActivityOnlyCount == 1)
            #expect(metrics.messageCreatedSummaryActivityOnlyRecipientCount == memberUserIDs.count)
            #expect(metrics.messageCreatedSummaryActivityOnlyMaxRecipients == memberUserIDs.count)
        }
    }

    @Test("Large-group summary projection uses recipient count hint without expanding snapshot")
    func largeGroupSummaryProjectionUsesRecipientCountHintWithoutExpandingSnapshot() async throws {
        let values = [
            "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD": "3",
            "IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT": "true"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let conversation = Conversation(
                title: "Activity Count Hint",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_010),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(
                conversationID: conversationID,
                userID: senderID,
                role: .owner
            ).create(on: app.db)

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "activity-count-hint-message",
                content: .richText(.plain("activity count hint projection"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let eventID = UUID()
            try await ConversationDomainEventRecipientSnapshot(
                eventID: eventID,
                conversationID: conversationID,
                recipientUserIDs: recipientUserIDs,
                createdAt: Date(timeIntervalSince1970: 1_710_411_011),
                storesRecipientIDsInline: false
            ).create(on: app.db)
            let event = try ConversationDomainEvent(
                id: eventID,
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: []),
                createdAt: Date(timeIntervalSince1970: 1_710_411_011)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationProjectionConsumer(app: app, sourceDB: app.db).consume(envelope)

            let activity = try #require(
                try await ConversationActivitySummary.find(conversationID, on: app.imSummaryDB)
            )
            #expect(activity.lastMessage?.id == messageID)
            #expect(activity.lastMessageServerSequence == 1)
            #expect(try await ConversationUserSummary.query(on: app.imSummaryDB).count() == 0)
            #expect(try await ConversationChangesLogEntry.query(on: app.imSummaryDB).count() == 0)

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedSummaryActivityOnlyCount == 1)
            #expect(metrics.messageCreatedSummaryActivityOnlyRecipientCount == recipientUserIDs.count)
            #expect(metrics.recipientResolveCount == 0)
            #expect(metrics.recipientSnapshotResolveSharedSetHitCount == 0)
        }
    }

    @Test("Summary projection activity-only uses loaded stream consumer configuration")
    func summaryProjectionActivityOnlyUsesLoadedStreamConsumerConfiguration() async throws {
        let key = "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            unsetenv(key)
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "activity-config-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Activity Config",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_020),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "activity-config-message",
                content: .richText(.plain("activity config projection"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_411_021)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationProjectionConsumer(app: app, sourceDB: app.db).consume(envelope)

            let activity = try #require(
                try await ConversationActivitySummary.find(conversationID, on: app.imSummaryDB)
            )
            #expect(activity.lastMessage?.id == messageID)
            #expect(activity.lastMessage?.body["text"] == "activity config projection")
            #expect(try await ConversationUserSummary.query(on: app.imSummaryDB).count() == 0)
        }
    }

    @Test("Summary projection collapses activity-only message-created runs")
    func summaryProjectionCollapsesActivityOnlyMessageCreatedRuns() async throws {
        let key = "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            unsetenv(key)
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "activity-run-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Activity Run",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_040),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let firstMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "activity-run-first",
                content: .richText(.plain("first activity run message"))
            )
            try await firstMessage.create(on: app.db)
            let firstMessageID = try firstMessage.requireID()
            let secondMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 2,
                timelineSequence: 2,
                clientMessageID: "activity-run-second",
                content: .richText(.plain("second activity run message"))
            )
            try await secondMessage.create(on: app.db)
            let secondMessageID = try secondMessage.requireID()

            let firstEvent = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 1,
                payload: .messageCreated(messageID: firstMessageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_411_041)
            )
            let secondEvent = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 2,
                payload: .messageCreated(messageID: secondMessageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_411_042)
            )
            let envelopes = try [firstEvent, secondEvent].map {
                try ConversationEventEnvelope(
                    event: $0,
                    payload: try $0.decodedPayload(),
                    deliveryContext: nil
                )
            }

            try await ConversationProjectionConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun(envelopes)

            let activity = try #require(
                try await ConversationActivitySummary.find(conversationID, on: app.imSummaryDB)
            )
            #expect(activity.lastMessage?.id == secondMessageID)
            #expect(activity.lastMessageServerSequence == 2)
            #expect(activity.lastMessage?.body["text"] == "second activity run message")
            #expect(try await ConversationUserSummary.query(on: app.imSummaryDB).count() == 0)
            #expect(try await ConversationChangesLogEntry.query(on: app.imSummaryDB).count() == 0)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedSummaryActivityOnlyCount == 1)
            #expect(metrics.messageCreatedSummaryActivityOnlyRecipientCount == memberUserIDs.count)
        }
    }

    @Test("Summary projection coalesces activity-only single message writes")
    func summaryProjectionCoalescesActivityOnlySingleMessageWrites() async throws {
        let values = [
            "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD": "3",
            "IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS": "100"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "activity-coalesce-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Activity Coalesce",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_060),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            var envelopes: [ConversationEventEnvelope] = []
            var messageIDs: [UUID] = []
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "activity-coalesce-\(sequence)",
                    content: .richText(.plain("activity coalesce \(sequence)"))
                )
                try await message.create(on: app.db)
                let messageID = try message.requireID()
                messageIDs.append(messageID)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                    createdAt: Date(timeIntervalSince1970: 1_710_411_060 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            let consumer = ConversationProjectionConsumer(app: app, sourceDB: app.db)
            try await consumer.consume(envelopes[0])
            try await consumer.consume(envelopes[1])
            #expect(try await ConversationActivitySummary.find(conversationID, on: app.imSummaryDB) == nil)

            try await Task.sleep(nanoseconds: 200_000_000)

            let activity = try #require(
                try await ConversationActivitySummary.find(conversationID, on: app.imSummaryDB)
            )
            #expect(activity.lastMessage?.id == messageIDs[1])
            #expect(activity.lastMessageServerSequence == 2)
            #expect(activity.lastMessage?.body["text"] == "activity coalesce 2")
            #expect(try await ConversationUserSummary.query(on: app.imSummaryDB).count() == 0)
            #expect(try await ConversationChangesLogEntry.query(on: app.imSummaryDB).count() == 0)

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedSummaryActivityOnlyCount == 2)
            #expect(metrics.summaryActivityCoalescedReplacementCount == 1)
            #expect(metrics.summaryActivityCoalescedFlushCount == 1)
            #expect(metrics.summaryActivityCoalescedFlushRequestCount == 2)
            #expect(metrics.summaryActivityCoalescedFlushFailureCount == 0)
        }
    }

    @Test("Summary projection does not collapse omitted-recipient runs when snapshots differ")
    func summaryProjectionDoesNotCollapseOmittedRecipientRunsWhenSnapshotsDiffer() async throws {
        let key = "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            unsetenv(key)
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var firstRecipients = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "activity-snapshot-first-\(index)@example.com", on: app)
                firstRecipients.append(try member.requireID())
            }
            let addedMember = try await makeUser(email: "activity-snapshot-added@example.com", on: app)
            let addedMemberID = try addedMember.requireID()
            let secondRecipients = firstRecipients + [addedMemberID]

            let conversation = Conversation(
                title: "Activity Snapshot Diff",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_060),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in secondRecipients {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let firstMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "activity-snapshot-first",
                content: .richText(.plain("first omitted snapshot message"))
            )
            try await firstMessage.create(on: app.db)
            let firstMessageID = try firstMessage.requireID()
            let secondMessage = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 2,
                timelineSequence: 2,
                clientMessageID: "activity-snapshot-second",
                content: .richText(.plain("second omitted snapshot message"))
            )
            try await secondMessage.create(on: app.db)
            let secondMessageID = try secondMessage.requireID()

            let firstEventID = UUID()
            let secondEventID = UUID()
            try await ConversationDomainEventRecipientSnapshot(
                eventID: firstEventID,
                conversationID: conversationID,
                recipientUserIDs: firstRecipients
            ).create(on: app.db)
            try await ConversationDomainEventRecipientSnapshot(
                eventID: secondEventID,
                conversationID: conversationID,
                recipientUserIDs: secondRecipients
            ).create(on: app.db)
            let firstEvent = try ConversationDomainEvent(
                id: firstEventID,
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 1,
                payload: .messageCreated(messageID: firstMessageID, recipientUserIDs: []),
                createdAt: Date(timeIntervalSince1970: 1_710_411_061)
            )
            let secondEvent = try ConversationDomainEvent(
                id: secondEventID,
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 2,
                payload: .messageCreated(messageID: secondMessageID, recipientUserIDs: []),
                createdAt: Date(timeIntervalSince1970: 1_710_411_062)
            )
            let envelopes = try [firstEvent, secondEvent].map {
                try ConversationEventEnvelope(
                    event: $0,
                    payload: try $0.decodedPayload(),
                    deliveryContext: nil
                )
            }

            try await ConversationProjectionConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun(envelopes)

            let activity = try #require(
                try await ConversationActivitySummary.find(conversationID, on: app.imSummaryDB)
            )
            #expect(activity.lastMessage?.id == secondMessageID)
            #expect(activity.lastMessageServerSequence == 2)
            #expect(try await ConversationUserSummary.query(on: app.imSummaryDB).count() == 0)
            #expect(try await ConversationChangesLogEntry.query(on: app.imSummaryDB).count() == 0)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedSummaryActivityOnlyCount == 2)
            #expect(metrics.messageCreatedSummaryActivityOnlyRecipientCount == firstRecipients.count + secondRecipients.count)
        }
    }

    @Test("Message-created outbox can omit large recipient lists at threshold")
    func messageCreatedOutboxOmitsLargeRecipientListsAtThreshold() async throws {
        try await withApp(configure: configure) { app in
            let actor = try await user(email: "demo@example.com", on: app)
            let actorID = try actor.requireID()
            let conversation = Conversation(
                title: "Omitted Recipients",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_000)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            let messageID = UUID()
            let recipientUserIDs = [actorID, UUID(), UUID()]

            try await ConversationOutboxEnqueuer(db: app.db).enqueueMessageEvent(
                type: .messageCreated,
                conversationID: conversationID,
                actorUserID: actorID,
                recipientUserIDs: recipientUserIDs,
                messageID: messageID,
                messageCreatedRecipientInlineThreshold: 3
            )

            let event = try #require(try await ConversationDomainEvent.query(on: app.db).first())
            guard case .messageCreated(let decodedMessageID, let decodedRecipients, _) = try event.decodedPayload() else {
                Issue.record("Expected messageCreated payload.")
                return
            }
            #expect(decodedMessageID == messageID)
            #expect(decodedRecipients.isEmpty)
        }
    }

    @Test("Message-created outbox preserves preview when recipients are omitted")
    func messageCreatedOutboxPreservesPreviewWhenRecipientsAreOmitted() async throws {
        try await withApp(configure: configure) { app in
            let actor = try await user(email: "demo@example.com", on: app)
            let actorID = try actor.requireID()
            let conversation = Conversation(
                title: "Omitted Recipients Preview",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_010)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            let messageID = UUID()
            let recipientUserIDs = [actorID, UUID(), UUID()]
            let preview = ConversationMessageCreatedPreview(
                senderUserID: actorID,
                serverSequence: 12,
                timelineSequence: 12,
                previewText: "embedded preview survives recipient omission",
                createdAt: Date(timeIntervalSince1970: 1_710_411_011)
            )

            try await ConversationOutboxEnqueuer(db: app.db).enqueueMessageEvent(
                type: .messageCreated,
                conversationID: conversationID,
                actorUserID: actorID,
                recipientUserIDs: recipientUserIDs,
                messageID: messageID,
                messageCreatedPreview: preview,
                messageCreatedRecipientInlineThreshold: 3
            )

            let event = try #require(try await ConversationDomainEvent.query(on: app.db).first())
            guard case .messageCreated(let decodedMessageID, let decodedRecipients, let decodedPreview) = try event.decodedPayload() else {
                Issue.record("Expected messageCreated payload.")
                return
            }
            #expect(decodedMessageID == messageID)
            #expect(decodedRecipients.isEmpty)
            #expect(decodedPreview == preview)
        }
    }

    @Test("Message-created omitted recipients resolve from event snapshot before current membership")
    func messageCreatedOmittedRecipientsResolveFromEventSnapshotBeforeCurrentMembership() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let originalMember = try await makeUser(email: "snapshot-original@example.com", on: app)
            let originalMemberID = try originalMember.requireID()
            let removedMember = try await makeUser(email: "snapshot-removed@example.com", on: app)
            let removedMemberID = try removedMember.requireID()
            let laterMember = try await makeUser(email: "snapshot-later@example.com", on: app)
            let laterMemberID = try laterMember.requireID()
            let originalRecipients = [senderID, originalMemberID, removedMemberID]

            let conversation = Conversation(
                title: "Recipient Snapshot",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_050),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in originalRecipients {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "recipient-snapshot-message",
                content: .richText(.plain("snapshot recipients"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()

            try await ConversationOutboxEnqueuer(db: app.db).enqueueMessageEvent(
                type: .messageCreated,
                conversationID: conversationID,
                actorUserID: senderID,
                recipientUserIDs: originalRecipients,
                messageID: messageID,
                messageCreatedRecipientInlineThreshold: 3
            )
            let event = try #require(try await ConversationDomainEvent.query(on: app.db).first())
            let eventID = try #require(event.id)
            let snapshot = try #require(
                try await ConversationDomainEventRecipientSnapshot.find(eventID, on: app.db)
            )
            #expect(try snapshot.recipientUserIDs() == originalRecipients.sorted { $0.uuidString < $1.uuidString })
            #expect(snapshot.recipientHash == ConversationDomainEventRecipientSnapshot.recipientHash(for: originalRecipients))

            try await ConversationMember.query(on: app.db)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$user.$id == removedMemberID)
                .delete()
            try await ConversationMember(
                conversationID: conversationID,
                userID: laterMemberID
            ).create(on: app.db)

            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )
            let batches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope, detail: .lightweightMessageCreatedIfLarge)
            let resolvedRecipients = batches.flatMap(\.recipientUserIDs)

            #expect(resolvedRecipients == originalRecipients.sorted { $0.uuidString < $1.uuidString })
            #expect(resolvedRecipients.contains(removedMemberID))
            #expect(!resolvedRecipients.contains(laterMemberID))

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.recipientResolveEventSnapshotCount == 1)
            #expect(metrics.recipientResolveMembershipExpansionCount == 0)
        }
    }

    @Test("Message-created recipient snapshots reuse deduplicated recipient set")
    func messageCreatedRecipientSnapshotsReuseDeduplicatedRecipientSet() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let firstMember = try await makeUser(email: "snapshot-dedup-1@example.com", on: app)
            let secondMember = try await makeUser(email: "snapshot-dedup-2@example.com", on: app)
            let recipientUserIDs = [senderID, try firstMember.requireID(), try secondMember.requireID()]
            let conversation = Conversation(
                title: "Recipient Snapshot Dedup",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_075),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in recipientUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "recipient-snapshot-dedup-\(sequence)",
                    content: .richText(.plain("snapshot dedup \(sequence)"))
                )
                try await message.create(on: app.db)
                try await ConversationOutboxEnqueuer(
                    db: app.db,
                    domainEventMetrics: app.conversationDomainEventMetrics
                ).enqueueMessageEvent(
                    type: .messageCreated,
                    conversationID: conversationID,
                    actorUserID: senderID,
                    recipientUserIDs: recipientUserIDs,
                    messageID: try message.requireID(),
                    messageCreatedRecipientInlineThreshold: 3,
                    recipientSnapshotDeduplicationThreshold: 3
                )
            }

            let events = try await ConversationDomainEvent.query(on: app.db)
                .sort(\.$aggregateSequence, .ascending)
                .all()
            #expect(events.count == 2)
            let recipientSets = try await ConversationDomainEventRecipientSet.query(on: app.db).all()
            #expect(recipientSets.count == 1)
            #expect(recipientSets.first?.recipientCount == 3)
            #expect(try recipientSets.first?.recipientUserIDs() == recipientUserIDs.sorted { $0.uuidString < $1.uuidString })
            let recipientHash = try #require(recipientSets.first?.id)
            let recipientSetMembers = try await ConversationDomainEventRecipientSetMember.query(on: app.db)
                .filter(\.$recipientHash == recipientHash)
                .all()
            #expect(recipientSetMembers.count == 3)
            #expect(Set(recipientSetMembers.map(\.userID)) == Set(recipientUserIDs))

            for event in events {
                let eventID = try #require(event.id)
                let snapshot = try #require(
                    try await ConversationDomainEventRecipientSnapshot.find(eventID, on: app.db)
                )
                #expect(try snapshot.recipientUserIDs().isEmpty)
                #expect(snapshot.recipientHash == recipientHash)
                #expect(try await snapshot.recipientUserIDs(on: app.db) == recipientUserIDs.sorted { $0.uuidString < $1.uuidString })
            }

            let envelope = try ConversationEventEnvelope(
                event: try #require(events.last),
                payload: try #require(events.last).decodedPayload(),
                deliveryContext: nil
            )
            let resolvedRecipients = try await ConversationDomainEventRecipientResolver(db: app.db, app: app)
                .recipientUserIDs(for: envelope)
            #expect(resolvedRecipients == recipientUserIDs.sorted { $0.uuidString < $1.uuidString })

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.recipientSnapshotDeduplicatedStoreCount == 2)
            #expect(metrics.recipientSnapshotDeduplicatedStoreRecipientCount == 6)
            #expect(metrics.recipientSnapshotResolveSharedSetHitCount == 1)
            #expect(metrics.recipientSnapshotResolveRecipientCount == 3)
            #expect(metrics.recipientResolveEventSnapshotCount == 1)
        }
    }

    @Test("Deduplicated recipient snapshot fails loudly when recipient set is missing")
    func deduplicatedRecipientSnapshotFailsWhenRecipientSetMissing() async throws {
        try await withApp(configure: configure) { app in
            let snapshot = try ConversationDomainEventRecipientSnapshot(
                eventID: UUID(),
                conversationID: UUID(),
                recipientUserIDs: [UUID(), UUID()],
                storesRecipientIDsInline: false
            )
            try await snapshot.create(on: app.db)

            do {
                _ = try await snapshot.recipientUserIDs(on: app.db)
                Issue.record("Expected missing recipient set lookup to fail.")
            } catch ConversationProjectionCodingError.missingRecipientSet {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error).")
            }
        }
    }

    @Test("Outbox enqueue rolls back event when deduplicated recipient snapshot write fails")
    func outboxEnqueueRollsBackEventWhenRecipientSnapshotWriteFails() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database.")
                return
            }
            try await sql.raw("DROP TABLE \(ident: ConversationDomainEventRecipientSet.schema)").run()

            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let conversation = Conversation(
                title: "Outbox Atomic Snapshot",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_080),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 1,
                timelineSequence: 1,
                clientMessageID: "atomic-snapshot-failure",
                content: .richText(.plain("atomic snapshot failure"))
            )
            try await message.create(on: app.db)

            do {
                try await ConversationOutboxService(db: app.db).enqueue(
                    type: .messageCreated,
                    conversationID: conversationID,
                    actorUserID: senderID,
                    payload: .messageCreated(messageID: try message.requireID(), recipientUserIDs: []),
                    recipientSnapshotUserIDs: [senderID, UUID()],
                    recipientSnapshotDeduplicationThreshold: 1
                )
                Issue.record("Expected recipient set write failure.")
            } catch {
                #expect(String(describing: error).isEmpty == false)
            }

            let eventCount = try await ConversationDomainEvent.query(on: app.db).count()
            let snapshotCount = try await ConversationDomainEventRecipientSnapshot.query(on: app.db).count()
            #expect(eventCount == 0)
            #expect(snapshotCount == 0)
        }
    }

    @Test("Cleanup deletes only old unreferenced recipient sets")
    func cleanupDeletesOnlyOldUnreferencedRecipientSets() async throws {
        try await withApp(configure: configure) { app in
            let now = Date(timeIntervalSince1970: 1_710_500_000)
            let oldDate = now.addingTimeInterval(-40 * 24 * 60 * 60)
            let freshDate = now.addingTimeInterval(-10 * 24 * 60 * 60)
            let referencedRecipients = [UUID(), UUID()]
            let unreferencedRecipients = [UUID(), UUID(), UUID()]
            let freshRecipients = [UUID(), UUID(), UUID(), UUID()]
            let referencedHash = ConversationDomainEventRecipientSet.recipientHash(for: referencedRecipients)
            let unreferencedHash = ConversationDomainEventRecipientSet.recipientHash(for: unreferencedRecipients)
            let freshHash = ConversationDomainEventRecipientSet.recipientHash(for: freshRecipients)

            try await ConversationDomainEventRecipientSet(
                recipientHash: referencedHash,
                recipientUserIDs: referencedRecipients,
                createdAt: oldDate
            ).create(on: app.db)
            try await ConversationDomainEventRecipientSet(
                recipientHash: unreferencedHash,
                recipientUserIDs: unreferencedRecipients,
                createdAt: oldDate
            ).create(on: app.db)
            try await ConversationDomainEventRecipientSetMember.writeMemberIndex(
                recipientHash: unreferencedHash,
                recipientUserIDs: unreferencedRecipients,
                createdAt: oldDate,
                on: app.db
            )
            try await ConversationDomainEventRecipientSet(
                recipientHash: freshHash,
                recipientUserIDs: freshRecipients,
                createdAt: freshDate
            ).create(on: app.db)
            try await ConversationDomainEventRecipientSnapshot(
                eventID: UUID(),
                conversationID: UUID(),
                recipientUserIDs: referencedRecipients,
                createdAt: oldDate,
                storesRecipientIDsInline: false
            ).create(on: app.db)

            try await IMCleanupService(app: app).runOnce(
                now: now,
                configuration: IMCleanupConfiguration(
                    enabled: true,
                    intervalSeconds: 86_400,
                    recipientSetRetentionDays: 30,
                    recipientSetBatchSize: 10
                )
            )

            #expect(try await ConversationDomainEventRecipientSet.find(referencedHash, on: app.db) != nil)
            #expect(try await ConversationDomainEventRecipientSet.find(unreferencedHash, on: app.db) == nil)
            #expect(try await ConversationDomainEventRecipientSet.find(freshHash, on: app.db) != nil)
            let unreferencedMemberCount = try await ConversationDomainEventRecipientSetMember.query(on: app.db)
                .filter(\.$recipientHash == unreferencedHash)
                .count()
            #expect(unreferencedMemberCount == 0)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.recipientSetCleanupRunCount == 1)
            #expect(metrics.recipientSetCleanupScannedCount == 2)
            #expect(metrics.recipientSetCleanupDeletedCount == 1)
            #expect(metrics.recipientSetCleanupMaxDeletedCount == 1)
        }
    }

    @Test("Message-created realtime expands omitted recipients from membership")
    func messageCreatedRealtimeExpandsOmittedRecipientsFromMembership() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "omitted-recipients-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Omitted Recipient Expansion",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_100),
                lastMessageSequence: 4
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 4,
                timelineSequence: 4,
                clientMessageID: "omitted-recipient-message",
                content: .richText(.plain("membership-expanded payload"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 4,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: []),
                createdAt: Date(timeIntervalSince1970: 1_710_411_101)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            let batches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope, detail: .lightweightMessageCreatedIfLarge)

            #expect(batches.count == 1)
            #expect(batches.first?.recipientUserIDs == memberUserIDs.sorted { $0.uuidString < $1.uuidString })
            guard case .messageCreated(let payloadMessage, _) = batches.first?.payload.body else {
                Issue.record("Expected messageCreated payload body.")
                return
            }
            #expect(payloadMessage.id == messageID)
            #expect(payloadMessage.content.previewText == "membership-expanded payload")
        }
    }

    @Test("Message-created strict recipient snapshot mode rejects omitted recipients without snapshot")
    func messageCreatedStrictRecipientSnapshotModeRejectsOmittedRecipientsWithoutSnapshot() async throws {
        let key = "IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "true", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "strict-snapshot-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Strict Recipient Snapshot",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_150),
                lastMessageSequence: 4
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 4,
                timelineSequence: 4,
                clientMessageID: "strict-recipient-snapshot-message",
                content: .richText(.plain("missing snapshot should fail"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let eventID = UUID()
            let event = try ConversationDomainEvent(
                id: eventID,
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 4,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: []),
                createdAt: Date(timeIntervalSince1970: 1_710_411_151)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            do {
                _ = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                    .domainEventPayloadBatches(for: envelope, detail: .lightweightMessageCreatedIfLarge)
                Issue.record("Expected strict recipient snapshot mode to reject omitted recipients without snapshot")
            } catch let error as ConversationEventTransientProcessingError {
                guard case .messageCreatedRecipientSnapshotMissing(let missingEventID, let missingConversationID) = error else {
                    Issue.record("Unexpected transient error: \(error)")
                    return
                }
                #expect(missingEventID == eventID)
                #expect(missingConversationID == conversationID)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.recipientResolveErrorCount == 1)
            #expect(metrics.recipientResolveMissingSnapshotCount == 1)
            #expect(metrics.recipientResolveMembershipExpansionCount == 0)
        }
    }

    @Test("Message-created owner delivery relay reuses omitted recipient expansion")
    func messageCreatedOwnerDeliveryRelayReusesOmittedRecipientExpansion() async throws {
        let key = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "resolver-reuse-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Resolver Reuse",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_200),
                lastMessageSequence: 5
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 5,
                timelineSequence: 5,
                clientMessageID: "resolver-reuse-message",
                content: .richText(.plain("reuse omitted recipient expansion"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 5,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: []),
                createdAt: Date(timeIntervalSince1970: 1_710_411_201)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await OwnerDomainEventDeliveryConsumer(
                app: app,
                sourceDB: app.db,
                relayRealtimeAfterRecord: true
            ).consume(envelope)

            let deliveryCount = try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count()
            #expect(deliveryCount == 0)

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.recipientResolveCount == 1)
            #expect(metrics.recipientResolveMembershipExpansionCount == 1)
            #expect(metrics.recipientResolveUserCount == memberUserIDs.count)
            #expect(metrics.recipientResolveMaxUserCount == memberUserIDs.count)
        }
    }

    @Test("Message-created owner delivery run reuses recipient expansion")
    func messageCreatedOwnerDeliveryRunReusesRecipientExpansion() async throws {
        let key = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "owner-run-reuse-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Owner Run Reuse",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_300),
                lastMessageSequence: 6
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            var envelopes: [ConversationEventEnvelope] = []
            for sequence in 5...6 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "owner-run-reuse-\(sequence)",
                    content: .richText(.plain("owner run reuse \(sequence)"))
                )
                try await message.create(on: app.db)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(messageID: try message.requireID(), recipientUserIDs: []),
                    createdAt: Date(timeIntervalSince1970: 1_710_411_300 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            try await OwnerDomainEventDeliveryConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun(envelopes)

            let deliveryCount = try await OwnerDomainEventDelivery.query(on: app.imSummaryDB).count()
            #expect(deliveryCount == 0)

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.recipientResolveCount == 1)
            #expect(metrics.recipientResolveMembershipExpansionCount == 1)
            #expect(metrics.recipientResolveUserCount == memberUserIDs.count)
            #expect(metrics.recipientResolveMaxUserCount == memberUserIDs.count)
        }
    }

    @Test("Realtime message-created run reuses recipient expansion")
    func realtimeMessageCreatedRunReusesRecipientExpansion() async throws {
        let key = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "realtime-run-reuse-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Realtime Run Reuse",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_400),
                lastMessageSequence: 6
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            var envelopes: [ConversationEventEnvelope] = []
            for sequence in 5...6 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "realtime-run-reuse-\(sequence)",
                    content: .richText(.plain("realtime run reuse \(sequence)"))
                )
                try await message.create(on: app.db)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(messageID: try message.requireID(), recipientUserIDs: []),
                    createdAt: Date(timeIntervalSince1970: 1_710_411_400 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            try await ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun(envelopes)

            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.recipientResolveCount == 1)
            #expect(metrics.recipientResolveMembershipExpansionCount == 1)
            #expect(metrics.recipientResolveUserCount == memberUserIDs.count)
            #expect(metrics.recipientResolveMaxUserCount == memberUserIDs.count)
        }
    }

    @Test("Realtime message-created delivery keeps every full message for active fanout")
    func realtimeMessageCreatedDeliveryKeepsEveryFullMessageForActiveFanout() async throws {
        let values = [
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED": "true",
            "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS": "1"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for key in values.keys {
                restoreEnvironment(key, to: originalValues[key] ?? nil)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "realtime-run-active-fanout-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Realtime Run Active Fanout",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_500),
                lastMessageSequence: 6
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            var envelopes: [ConversationEventEnvelope] = []
            for sequence in 5...6 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "realtime-run-active-fanout-\(sequence)",
                    content: .richText(.plain("realtime run active fanout \(sequence)"))
                )
                try await message.create(on: app.db)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(messageID: try message.requireID(), recipientUserIDs: []),
                    createdAt: Date(timeIntervalSince1970: 1_710_411_500 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            try await ConversationRealtimeDeliveryConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun(envelopes)
            try? await Task.sleep(nanoseconds: 100_000_000)

            let recipientMetrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(recipientMetrics.recipientResolveCount == 1)
            #expect(recipientMetrics.recipientResolveMembershipExpansionCount == 1)
            let routingMetrics = await app.routingMetrics.currentSnapshot()
            #expect(routingMetrics.userFanoutCount == memberUserIDs.count * envelopes.count)
        }
    }

    @Test("Realtime side-effect run collapses large lightweight hints")
    func realtimeSideEffectRunCollapsesLargeLightweightHints() async throws {
        let key = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "realtime-side-effect-collapse-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Realtime Side Effect Collapse",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_411_600),
                lastMessageSequence: 6
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            var envelopes: [ConversationEventEnvelope] = []
            for sequence in 5...6 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "realtime-side-effect-collapse-\(sequence)",
                    content: .richText(.plain("realtime side effect collapse \(sequence)"))
                )
                try await message.create(on: app.db)
                let event = try ConversationDomainEvent(
                    id: UUID(),
                    conversationID: conversationID,
                    eventType: .messageCreated,
                    aggregateSequence: sequence,
                    payload: .messageCreated(messageID: try message.requireID(), recipientUserIDs: []),
                    createdAt: Date(timeIntervalSince1970: 1_710_411_600 + TimeInterval(sequence))
                )
                envelopes.append(
                    try ConversationEventEnvelope(
                        event: event,
                        payload: try event.decodedPayload(),
                        deliveryContext: nil
                    )
                )
            }

            try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .consumeMessageCreatedRun(envelopes)

            let recipientMetrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(recipientMetrics.recipientResolveCount == 1)
            #expect(recipientMetrics.recipientResolveMembershipExpansionCount == 1)
            let routingMetrics = await app.routingMetrics.currentSnapshot()
            #expect(routingMetrics.userFanoutCount == memberUserIDs.count)
        }
    }

    @Test("Large-group realtime lightweight payload uses activity-only conversation hint")
    func largeGroupRealtimeLightweightPayloadUsesActivityOnlyConversationHint() async throws {
        let key = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "realtime-lightweight-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Realtime Lightweight",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_412_000),
                lastMessageSequence: 3
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
                let summary = try makeConversationSummaryProjection(
                    ownerUserID: userID,
                    conversationID: conversationID,
                    peerUserID: senderID,
                    title: "Realtime Lightweight",
                    serverSequence: 2,
                    lastActivityAt: Date(timeIntervalSince1970: 1_710_411_999),
                    updatedAt: Date(timeIntervalSince1970: 1_710_411_999)
                )
                try await summary.create(on: app.imSummaryDB)
            }

            let message = try ConversationMessage(
                conversationID: conversationID,
                senderUserID: senderID,
                serverSequence: 3,
                timelineSequence: 3,
                clientMessageID: "realtime-lightweight-message",
                content: .richText(.plain("large realtime payload body"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 3,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_412_001)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            let fullMessageBatches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope, detail: .fullMessageCreatedWithoutSummaryIfLarge)
            let batches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope, detail: .lightweightMessageCreatedIfLarge)
            let repeatedBatches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope, detail: .lightweightMessageCreatedIfLarge)

            #expect(fullMessageBatches.count == 1)
            let fullMessagePayload = try #require(fullMessageBatches.first?.payload)
            #expect(fullMessagePayload.eventID == (try event.requireID()))
            #expect(fullMessagePayload.eventType == .messageCreated)
            #expect(fullMessagePayload.conversation == nil)
            guard case .messageCreated(let activeMessage, _) = fullMessagePayload.body else {
                Issue.record("Expected full active fanout payload to keep messageCreated body.")
                return
            }
            #expect(activeMessage.id == messageID)
            #expect(activeMessage.content.previewText == "large realtime payload body")

            #expect(batches.count == 1)
            #expect(batches.first?.recipientUserIDs == memberUserIDs.sorted { $0.uuidString < $1.uuidString })
            let payload = try #require(batches.first?.payload)
            #expect(payload.eventID != (try event.requireID()))
            #expect(payload.eventID == repeatedBatches.first?.payload.eventID)
            #expect(payload.eventType == .conversationActivityHint)
            #expect(payload.aggregateID == conversationID)
            #expect(payload.requiresTimelineNotice == false)
            #expect(payload.conversation == nil)
            guard case .conversationActivityHint(let hint) = payload.body else {
                Issue.record("Expected conversationActivityHint payload body.")
                return
            }
            #expect(hint.messageID == messageID)
            #expect(hint.senderUserID == senderID)
            #expect(hint.serverSequence == 3)
            #expect(hint.timelineSequence == 3)
            #expect(hint.previewText == "large realtime payload body")
            #expect(hint.updatedAt == Date(timeIntervalSince1970: 1_710_412_001))
        }
    }

    @Test("Realtime conversation summary omits large-group member IDs by response limit")
    func realtimeConversationSummaryOmitsLargeGroupMemberIDsByResponseLimit() async throws {
        let key = "IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "2", 1)

        try await withApp(configure: configure) { app in
            let owner = try await user(email: "demo@example.com", on: app)
            let ownerID = try owner.requireID()
            let secondMember = try await makeUser(email: "realtime-summary-limit-2@example.com", on: app)
            let secondMemberID = try secondMember.requireID()
            let thirdMember = try await makeUser(email: "realtime-summary-limit-3@example.com", on: app)
            let thirdMemberID = try thirdMember.requireID()
            let memberUserIDs = [ownerID, secondMemberID, thirdMemberID]

            let conversation = Conversation(
                title: "Realtime Summary Limit",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_412_100)
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()

            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == ownerID ? .owner : .member
                ).create(on: app.db)
            }

            let summary = try ConversationUserSummary(
                ownerUserID: ownerID,
                conversationID: conversationID,
                title: "Realtime Summary Limit",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeerUserID: nil,
                directPeerEmail: nil,
                notice: nil,
                avatarPreset: nil,
                memberUserIDs: memberUserIDs,
                lastMessage: nil,
                lastReadSequence: 0,
                unreadCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_412_100),
                updatedAt: Date(timeIntervalSince1970: 1_710_412_100),
                isRemoved: false
            )
            try await summary.create(on: app.imSummaryDB)

            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .membershipAdded,
                aggregateSequence: 1,
                payload: .memberAdded(memberUserIDs: [thirdMemberID], recipientUserIDs: [ownerID]),
                createdAt: Date(timeIntervalSince1970: 1_710_412_101)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            let batches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope)

            #expect(batches.count == 1)
            let payload = try #require(batches.first?.payload)
            let conversationSummary = try #require(payload.conversation)
            #expect(conversationSummary.memberCount == 3)
            #expect(conversationSummary.memberUserIDs.isEmpty)

            var metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimePayloadBuiltCount == 0)
            await app.gatewaySessionService.sendDomainEventPayloadBatches(
                batches.map {
                    IMGatewayDomainEventPayloadBatch(
                        payload: $0.payload,
                        recipientUserIDs: $0.recipientUserIDs,
                        fanoutIntent: $0.fanoutIntent
                    )
                },
                requestID: event.id
            )

            metrics = await app.routingMetrics.currentSnapshot()
            #expect(metrics.realtimePayloadBuiltCount == 1)
            #expect(metrics.realtimePayloadRecipientDeliveryCount == 1)
            #expect(metrics.realtimePayloadWithConversationSummaryCount == 1)
            #expect(metrics.realtimePayloadConversationSummaryMemberIDsOmittedCount == 1)
            #expect(metrics.realtimePayloadConversationSummaryMemberIDsOmittedTotalMembers == 3)
        }
    }

    @Test("Large-group realtime lightweight payload uses embedded message preview")
    func largeGroupRealtimeLightweightPayloadUsesEmbeddedMessagePreview() async throws {
        let key = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let conversationID = UUID()
            let messageID = UUID()
            let senderID = UUID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 11,
                payload: .messageCreated(
                    messageID: messageID,
                    recipientUserIDs: recipientUserIDs,
                    preview: ConversationMessageCreatedPreview(
                        senderUserID: senderID,
                        serverSequence: 11,
                        timelineSequence: 11,
                        previewText: "embedded preview without message row",
                        createdAt: Date(timeIntervalSince1970: 1_710_412_111)
                    )
                ),
                createdAt: Date(timeIntervalSince1970: 1_710_412_112)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            let batches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope, detail: .lightweightMessageCreatedIfLarge)

            #expect(batches.count == 1)
            #expect(batches.first?.recipientUserIDs == recipientUserIDs.sorted { $0.uuidString < $1.uuidString })
            let payload = try #require(batches.first?.payload)
            #expect(payload.eventType == .conversationActivityHint)
            #expect(payload.conversation == nil)
            guard case .conversationActivityHint(let hint) = payload.body else {
                Issue.record("Expected conversationActivityHint payload body.")
                return
            }
            #expect(hint.messageID == messageID)
            #expect(hint.senderUserID == senderID)
            #expect(hint.serverSequence == 11)
            #expect(hint.timelineSequence == 11)
            #expect(hint.previewText == "embedded preview without message row")
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedPreviewEmbeddedCount == 1)
            #expect(metrics.messageCreatedPreviewMessageLookupCount == 0)
            #expect(metrics.messageCreatedPreviewMissingCount == 0)
        }
    }

    @Test("Large-group active compact payload can use bounded activity hint preview")
    func largeGroupActiveCompactPayloadCanUseBoundedActivityHintPreview() async throws {
        let values = [
            "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "3",
            "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS": "12"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let conversationID = UUID()
            let messageID = UUID()
            let senderID = UUID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 12,
                payload: .messageCreated(
                    messageID: messageID,
                    recipientUserIDs: recipientUserIDs,
                    preview: ConversationMessageCreatedPreview(
                        senderUserID: senderID,
                        serverSequence: 12,
                        timelineSequence: 12,
                        previewText: "active compact preview body",
                        createdAt: Date(timeIntervalSince1970: 1_710_412_121)
                    )
                ),
                createdAt: Date(timeIntervalSince1970: 1_710_412_122)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            let batches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope, detail: .activeCompactMessageCreatedIfLarge)

            #expect(batches.count == 1)
            let payload = try #require(batches.first?.payload)
            #expect(payload.eventType == .conversationActivityHint)
            #expect(payload.conversation == nil)
            guard case .conversationActivityHint(let hint) = payload.body else {
                Issue.record("Expected active compact conversationActivityHint payload body.")
                return
            }
            #expect(hint.messageID == messageID)
            #expect(hint.senderUserID == senderID)
            #expect(hint.serverSequence == 12)
            #expect(hint.timelineSequence == 12)
            #expect(hint.previewText == "active compa")
            #expect(hint.messageCreatedAt == Date(timeIntervalSince1970: 1_710_412_121))
        }
    }

    @Test("Large-group realtime missing preview avoids message lookup when disabled")
    func largeGroupRealtimeMissingPreviewAvoidsMessageLookupWhenDisabled() async throws {
        let thresholdKey = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
        let lookupKey = "IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED"
        let originalThresholdValue = Environment.get(thresholdKey)
        let originalLookupValue = Environment.get(lookupKey)
        defer {
            restoreEnvironment(thresholdKey, to: originalThresholdValue)
            restoreEnvironment(lookupKey, to: originalLookupValue)
        }
        setenv(thresholdKey, "3", 1)
        setenv(lookupKey, "false", 1)

        try await withApp(configure: configure) { app in
            let conversationID = UUID()
            let messageID = UUID()
            let senderID = UUID()
            let recipientUserIDs = [senderID, UUID(), UUID()]
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                aggregateSequence: 13,
                actorUserID: senderID,
                payload: .messageCreated(
                    messageID: messageID,
                    recipientUserIDs: recipientUserIDs
                ),
                createdAt: Date(timeIntervalSince1970: 1_710_412_113)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            let batches = try await ConversationRealtimeConsumer(app: app, sourceDB: app.db)
                .domainEventPayloadBatches(for: envelope, detail: .lightweightMessageCreatedIfLarge)

            #expect(batches.count == 1)
            #expect(batches.first?.recipientUserIDs == recipientUserIDs.sorted { $0.uuidString < $1.uuidString })
            let payload = try #require(batches.first?.payload)
            #expect(payload.eventType == .conversationActivityHint)
            guard case .conversationActivityHint(let hint) = payload.body else {
                Issue.record("Expected conversationActivityHint payload body.")
                return
            }
            #expect(hint.messageID == messageID)
            #expect(hint.senderUserID == senderID)
            #expect(hint.serverSequence == 13)
            #expect(hint.timelineSequence == 13)
            #expect(hint.previewText == "")
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedPreviewEmbeddedCount == 0)
            #expect(metrics.messageCreatedPreviewMessageLookupCount == 0)
            #expect(metrics.messageCreatedPreviewMissingCount == 1)
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
                timelineSequence: 3,
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
                timelineSequence: 10,
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
                payload: .readAdvanced(ownerUserID: readerID),
                createdAt: Date(timeIntervalSince1970: 1_710_300_010)
            )
            let envelope = try ConversationEventEnvelope(
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

    @Test("Read-advanced projection uses conversation activity sequence for activity-only large groups")
    func readAdvancedProjectionUsesConversationActivitySequenceForActivityOnlyLargeGroups() async throws {
        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let reader = try await makeUser(email: "activity-read-reader@example.com", on: app)
            let readerID = try reader.requireID()
            let conversation = Conversation(
                title: "Activity Read",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_413_000),
                lastMessageSequence: 5
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(conversationID: conversationID, userID: senderID, role: .owner)
                .create(on: app.db)
            try await ConversationMember(
                conversationID: conversationID,
                userID: readerID,
                role: .member,
                lastReadSequence: 3
            ).create(on: app.db)

            let staleSummary = try ConversationUserSummary(
                ownerUserID: readerID,
                conversationID: conversationID,
                title: "Activity Read",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeerUserID: nil,
                directPeerEmail: nil,
                memberUserIDs: [senderID, readerID],
                lastMessage: IMMessagePreviewResponse(
                    id: UUID(),
                    senderUserID: senderID,
                    serverSequence: 1,
                    timelineSequence: 1,
                    content: .richText(.plain("old message")),
                    createdAt: Date(timeIntervalSince1970: 1_710_413_001)
                ),
                lastReadSequence: 0,
                unreadCount: 1,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_413_001),
                updatedAt: Date(timeIntervalSince1970: 1_710_413_001),
                isRemoved: false
            )
            try await staleSummary.create(on: app.imSummaryDB)
            let activityMessage = IMMessagePreviewResponse(
                id: UUID(),
                senderUserID: senderID,
                serverSequence: 5,
                timelineSequence: 5,
                content: .richText(.plain("activity latest")),
                createdAt: Date(timeIntervalSince1970: 1_710_413_005)
            )
            try await ConversationActivitySummary(
                conversationID: conversationID,
                lastMessage: activityMessage,
                lastMessageServerSequence: 5,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_413_005),
                updatedAt: Date(timeIntervalSince1970: 1_710_413_005)
            ).create(on: app.imSummaryDB)

            try await IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: app.imSummaryDB
            ).applyReadAdvanced(
                conversationID: conversationID,
                recipientUserID: readerID,
                on: app.db,
                writeChangeLog: true
            )

            let recordID = ConversationUserSummary.recordID(ownerUserID: readerID, conversationID: conversationID)
            let summary = try #require(try await ConversationUserSummary.find(recordID, on: app.imSummaryDB))
            #expect(summary.lastReadSequence == 3)
            #expect(summary.unreadCount == 2)
            let changes = try await IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: app.imSummaryDB
            ).listConversationChanges(
                for: readerID,
                afterToken: IMConversationSummaryProjectionService.encodeChangeToken(
                    IMConversationSummaryProjectionService.ChangeToken(updatedAt: .distantPast, recordID: "")
                ),
                cursor: nil,
                limit: 10
            )
            #expect(changes.upserts.first?.lastMessage?.serverSequence == 5)
            #expect(changes.upserts.first?.unreadCount == 2)
        }
    }

    @Test("Single summary read overlays conversation activity summary")
    func singleSummaryReadOverlaysConversationActivitySummary() async throws {
        try await withApp(configure: configure) { app in
            let ownerID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000201")!
            let peerID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000202")!
            let conversationID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000203")!
            let latestMessageID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000205")!
            let summary = try ConversationUserSummary(
                ownerUserID: ownerID,
                conversationID: conversationID,
                title: "Activity Overlay",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeerUserID: nil,
                directPeerEmail: nil,
                memberUserIDs: [ownerID, peerID],
                lastMessage: IMMessagePreviewResponse(
                    id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000204")!,
                    senderUserID: peerID,
                    serverSequence: 2,
                    timelineSequence: 2,
                    content: .richText(.plain("old summary")),
                    createdAt: Date(timeIntervalSince1970: 1_710_414_002)
                ),
                lastReadSequence: 2,
                unreadCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_414_002),
                updatedAt: Date(timeIntervalSince1970: 1_710_414_002),
                isRemoved: false
            )
            try await summary.create(on: app.imSummaryDB)
            try await ConversationActivitySummary(
                conversationID: conversationID,
                lastMessage: IMMessagePreviewResponse(
                    id: latestMessageID,
                    senderUserID: peerID,
                    serverSequence: 5,
                    timelineSequence: 5,
                    content: .richText(.plain("latest activity")),
                    createdAt: Date(timeIntervalSince1970: 1_710_414_005)
                ),
                lastMessageServerSequence: 5,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_414_005),
                updatedAt: Date(timeIntervalSince1970: 1_710_414_005)
            ).create(on: app.imSummaryDB)

            let response = try await DatabaseSummaryReadModelStore(summaryDB: app.imSummaryDB)
                .conversationSummary(conversationID: conversationID, for: ownerID)

            #expect(response.lastMessage?.id == latestMessageID)
            #expect(response.lastMessage?.serverSequence == 5)
            #expect(response.lastMessage?.body["text"] == "latest activity")
            #expect(response.unreadCount == 3)
            #expect(response.updatedAt == Date(timeIntervalSince1970: 1_710_414_005))
        }
    }

    @Test("Cached command summary read overlays conversation activity summary")
    func cachedCommandSummaryReadOverlaysConversationActivitySummary() async throws {
        try await withApp(configure: configure) { app in
            let owner = try await makeUser(email: "activity-overlay-owner@example.com", on: app)
            let peer = try await makeUser(email: "activity-overlay-peer@example.com", on: app)
            let ownerID = try owner.requireID()
            let peerID = try peer.requireID()
            let membershipRevision = Date(timeIntervalSince1970: 1_710_414_100)
            let conversation = Conversation(
                title: "Cached Activity Overlay",
                kind: .group,
                updatedAt: membershipRevision,
                lastMessageSequence: 8,
                membershipRevision: membershipRevision
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(conversationID: conversationID, userID: ownerID, role: .member)
                .create(on: app.db)
            try await ConversationMember(conversationID: conversationID, userID: peerID, role: .member)
                .create(on: app.db)
            let staleSummary = try ConversationUserSummary(
                ownerUserID: ownerID,
                conversationID: conversationID,
                title: "Cached Activity Overlay",
                kind: IMConversationKind.group.rawValue,
                directMessagingState: nil,
                directPeerUserID: nil,
                directPeerEmail: nil,
                memberUserIDs: [ownerID, peerID],
                lastMessage: IMMessagePreviewResponse(
                    id: UUID(),
                    senderUserID: peerID,
                    serverSequence: 4,
                    timelineSequence: 4,
                    content: .richText(.plain("cached old")),
                    createdAt: Date(timeIntervalSince1970: 1_710_414_104)
                ),
                lastReadSequence: 4,
                unreadCount: 0,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_414_104),
                updatedAt: Date(timeIntervalSince1970: 1_710_414_104),
                isRemoved: false,
                membershipRevision: membershipRevision
            )
            try await staleSummary.create(on: app.db)
            try await ConversationActivitySummary(
                conversationID: conversationID,
                lastMessage: IMMessagePreviewResponse(
                    id: UUID(),
                    senderUserID: peerID,
                    serverSequence: 8,
                    timelineSequence: 8,
                    content: .richText(.plain("cached latest")),
                    createdAt: Date(timeIntervalSince1970: 1_710_414_108)
                ),
                lastMessageServerSequence: 8,
                lastActivityAt: Date(timeIntervalSince1970: 1_710_414_108),
                updatedAt: Date(timeIntervalSince1970: 1_710_414_108)
            ).create(on: app.db)

            let response = try await ConversationSummaryReadSupport(db: app.db)
                .conversationSummary(conversationID: conversationID, for: ownerID)

            #expect(response.lastMessage?.serverSequence == 8)
            #expect(response.lastMessage?.body["text"] == "cached latest")
            #expect(response.unreadCount == 4)
            #expect(response.updatedAt == Date(timeIntervalSince1970: 1_710_414_108))
        }
    }

    @Test("Activity summary coalescer keeps independent read-model keys")
    func activitySummaryCoalescerKeepsIndependentReadModelKeys() async throws {
        let values = [
            "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD": "3",
            "IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS": "50"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            let conversation = Conversation(
                title: "Coalescer Shards",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_414_200),
                lastMessageSequence: 2
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            try await ConversationMember(conversationID: conversationID, userID: senderID, role: .owner)
                .create(on: app.db)

            var messageIDs: [UUID] = []
            for sequence in 1...2 {
                let message = try ConversationMessage(
                    conversationID: conversationID,
                    senderUserID: senderID,
                    serverSequence: sequence,
                    timelineSequence: sequence,
                    clientMessageID: "coalescer-key-\(sequence)",
                    content: .richText(.plain("coalescer key \(sequence)"))
                )
                try await message.create(on: app.db)
                messageIDs.append(try message.requireID())
            }

            let service = IMConversationSummaryProjectionService(
                sourceDB: app.db,
                readModelDB: app.imSummaryDB,
                streamConsumerConfiguration: app.streamConsumerConfiguration,
                domainEventMetrics: app.conversationDomainEventMetrics,
                activitySummaryCoalescer: app.conversationActivitySummaryCoalescer
            )
            try await service.applyMessageCreatedActivityOnly(
                conversationID: conversationID,
                messageID: messageIDs[0],
                recipientCount: 3,
                on: app.db,
                readModelKey: "summary-a"
            )
            try await service.applyMessageCreatedActivityOnly(
                conversationID: conversationID,
                messageID: messageIDs[1],
                recipientCount: 3,
                on: app.db,
                readModelKey: "summary-b"
            )
            try await Task.sleep(nanoseconds: 200_000_000)

            let activity = try #require(
                try await ConversationActivitySummary.find(conversationID, on: app.imSummaryDB)
            )
            #expect(activity.lastMessageServerSequence == 2)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.summaryActivityCoalescedReplacementCount == 0)
            #expect(metrics.summaryActivityCoalescedFlushCount == 2)
            #expect(metrics.summaryActivityCoalescedFlushRequestCount == 2)
            #expect(metrics.summaryActivityCoalescedFlushFailureCount == 0)
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
                timelineSequence: 8,
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
                timelineSequence: 4,
                clientMessageID: "media-reference-message",
                content: .file(asset)
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let createdEvent = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: [senderID, peerID])
            )
            let createdEnvelope = try ConversationEventEnvelope(
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

            try message.replaceDerivedState(.init(recallState: .recalled))
            try await message.update(on: app.db)
            let recalledEvent = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageRecalled,
                payload: .messageRecalled(messageID: messageID, recipientUserIDs: [senderID, peerID])
            )
            let recalledEnvelope = try ConversationEventEnvelope(
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
                payload: .metadataUpdated(recipientUserIDs: [UUID()])
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

    @Test("Unknown outbox event type fails instead of falling back")
    func unknownOutboxEventTypeFailsInsteadOfFallingBack() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            let event = try ConversationDomainEvent(
                conversationID: UUID(),
                eventType: .metadataUpdated,
                payload: .metadataUpdated(recipientUserIDs: [UUID()])
            )
            try await event.create(on: app.db)
            let eventID = try event.requireID()

            try await sql.raw("""
                UPDATE conversation_domain_events
                SET event_type = 'unknown_event_type'
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

            let reloaded = try #require(try await ConversationDomainEvent.find(eventID, on: app.db))
            #expect(reloaded.statusEnum == .failed)
            #expect(reloaded.errorMessage?.contains("unknown_event_type") == true)
        }
    }

    @Test("Corrupt timeline notice payload throws instead of returning empty values")
    func corruptTimelineNoticePayloadThrowsInsteadOfReturningEmptyValues() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            let eventID = UUID()
            let notice = try ConversationTimelineNotice(
                eventID: eventID,
                conversationID: UUID(),
                timelineSequence: 1,
                eventType: ConversationDomainEventType.membershipAdded.rawValue,
                actorUserID: UUID(),
                targetUserIDs: [UUID()],
                noticeKind: "member_added",
                params: ["actor": "demo"],
                fallbackText: "member added",
                createdAt: Date()
            )
            try await notice.create(on: app.db)

            try await sql.raw("""
                UPDATE conversation_timeline_notices
                SET target_user_ids_json = '["not-a-uuid"]',
                    params_json = '{"unterminated":'
                WHERE event_id = \(bind: eventID)
                """).run()

            let reloaded = try #require(try await ConversationTimelineNotice.find(eventID, on: app.db))
            var targetDecodeFailed = false
            do {
                _ = try reloaded.targetUserIDs
            } catch {
                targetDecodeFailed = true
            }
            var paramsDecodeFailed = false
            do {
                _ = try reloaded.params
            } catch {
                paramsDecodeFailed = true
            }

            #expect(targetDecodeFailed)
            #expect(paramsDecodeFailed)
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
                timelineSequence: 1,
                clientMessageID: "side-effect-message",
                content: .richText(.plain("critical path should finish"))
            )
            try await message.create(on: app.db)
            let messageID = try message.requireID()
            let event = try ConversationDomainEvent(
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: [senderID, peerID])
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
                payload: .metadataUpdated(recipientUserIDs: [UUID()]),
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
                payload: .metadataUpdated(recipientUserIDs: [UUID()])
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
                payload: .metadataUpdated(recipientUserIDs: [UUID()])
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
                payload: .metadataUpdated(recipientUserIDs: [UUID()])
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
            let messageID = UUID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: UUID(),
                eventType: .messageUpdated,
                payload: .messageUpdated(messageID: messageID, recipientUserIDs: [recipientUserID]),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let envelope = try ConversationEventEnvelope(event: event, payload: try event.decodedPayload(), deliveryContext: nil)

            try await ConversationNotificationConsumer(app: app).consume(envelope)

            let recordID = ConversationNotificationEntry.recordID(ownerUserID: recipientUserID, eventID: try #require(event.id))
            let stored = try await ConversationNotificationEntry.find(recordID, on: app.imSummaryDB)
            #expect(stored?.ownerUserID == recipientUserID)
            #expect(stored?.conversationID == event.conversationID)
            #expect(stored?.eventType == ConversationDomainEventType.messageUpdated.rawValue)
        }
    }

    @Test("Large-group messageCreated notification consumer skips by recipient threshold")
    func largeGroupMessageCreatedNotificationConsumerSkipsByRecipientThreshold() async throws {
        let key = "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "notification-skip-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Notification Skip",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_420_000),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let messageID = UUID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_420_001)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationNotificationConsumer(app: app).consume(envelope)

            let notificationCount = try await ConversationNotificationEntry.query(on: app.imSummaryDB).count()
            #expect(notificationCount == 0)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedOwnerNotificationSkippedCount == 1)
            #expect(metrics.messageCreatedOwnerNotificationSkippedRecipientCount == memberUserIDs.count)
            #expect(metrics.messageCreatedOwnerNotificationSkippedMaxRecipients == memberUserIDs.count)
        }
    }

    @Test("Large-group messageCreated notification run writer skips by recipient threshold")
    func largeGroupMessageCreatedNotificationRunWriterSkipsByRecipientThreshold() async throws {
        let key = "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "3", 1)

        try await withApp(configure: configure) { app in
            let sender = try await user(email: "demo@example.com", on: app)
            let senderID = try sender.requireID()
            var memberUserIDs = [senderID]
            for index in 0..<2 {
                let member = try await makeUser(email: "notification-run-skip-\(index)@example.com", on: app)
                memberUserIDs.append(try member.requireID())
            }

            let conversation = Conversation(
                title: "Notification Run Skip",
                kind: .group,
                updatedAt: Date(timeIntervalSince1970: 1_710_420_100),
                lastMessageSequence: 1
            )
            try await conversation.create(on: app.db)
            let conversationID = try conversation.requireID()
            for userID in memberUserIDs {
                try await ConversationMember(
                    conversationID: conversationID,
                    userID: userID,
                    role: userID == senderID ? .owner : .member
                ).create(on: app.db)
            }

            let messageID = UUID()
            let event = try ConversationDomainEvent(
                id: UUID(),
                conversationID: conversationID,
                eventType: .messageCreated,
                payload: .messageCreated(messageID: messageID, recipientUserIDs: memberUserIDs),
                createdAt: Date(timeIntervalSince1970: 1_710_420_101)
            )
            let envelope = try ConversationEventEnvelope(
                event: event,
                payload: try event.decodedPayload(),
                deliveryContext: nil
            )

            try await ConversationNotificationRunWriter(app: app).consume([envelope])

            let notificationCount = try await ConversationNotificationEntry.query(on: app.imSummaryDB).count()
            #expect(notificationCount == 0)
            let metrics = await app.conversationDomainEventMetrics.currentSnapshot()
            #expect(metrics.messageCreatedOwnerNotificationSkippedCount == 1)
            #expect(metrics.messageCreatedOwnerNotificationSkippedRecipientCount == memberUserIDs.count)
            #expect(metrics.messageCreatedOwnerNotificationSkippedMaxRecipients == memberUserIDs.count)
        }
    }

    @Test("Repair replay consumer stores dead-letter envelopes for later replay")
    func repairReplayConsumerStoresDeadLetterEnvelopes() async throws {
        try await withApp(configure: configure) { app in
            let eventID = UUID()
            let conversationID = UUID()
            let envelope = try ConversationEventEnvelope(
                event: try ConversationDomainEvent(
                    id: eventID,
                    conversationID: conversationID,
                    eventType: .metadataUpdated,
                    payload: .metadataUpdated(recipientUserIDs: [UUID()]),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                payload: .metadataUpdated(recipientUserIDs: [UUID()]),
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

    @Test("Conversation outbox enqueueOnce is idempotent by side-effect key")
    func conversationOutboxEnqueueOnceIsIdempotentBySideEffectKey() async throws {
        try await withApp(configure: configure) { app in
            let conversationID = UUID()
            let recipientUserID = UUID()
            let key = "contact:\(UUID().uuidString.lowercased()):direct-peer:\(conversationID.uuidString.lowercased())"
            let service = ConversationOutboxService(db: app.imWriteDB)

            let first = try await service.enqueueOnce(
                sideEffectKey: key,
                type: .directPeerUpdated,
                conversationID: conversationID,
                actorUserID: recipientUserID,
                payload: .directPeerUpdated(recipientUserIDs: [recipientUserID])
            )
            let second = try await service.enqueueOnce(
                sideEffectKey: key,
                type: .directPeerUpdated,
                conversationID: conversationID,
                actorUserID: recipientUserID,
                payload: .directPeerUpdated(recipientUserIDs: [recipientUserID])
            )

            #expect(try first.requireID() == second.requireID())
            #expect(first.aggregateSequence == second.aggregateSequence)
            let count = try await ConversationDomainEvent.query(on: app.imWriteDB)
                .filter(\.$sideEffectKey == key)
                .count()
            #expect(count == 1)
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

private actor MessageCreatedRunProbe {
    private(set) var singleEventIDs: [UUID] = []
    private(set) var runEventIDs: [UUID] = []

    func recordSingle(_ envelope: ConversationEventEnvelope) {
        if let eventID = envelope.eventID {
            singleEventIDs.append(eventID)
        }
    }

    func recordRun(_ envelopes: [ConversationEventEnvelope]) {
        runEventIDs.append(contentsOf: envelopes.compactMap(\.eventID))
    }

    func snapshot() -> (singleEventIDs: [UUID], runEventIDs: [UUID]) {
        (singleEventIDs, runEventIDs)
    }
}

private struct ProbeMessageCreatedRunConsumer: ConversationEventConsumer {
    let probe: MessageCreatedRunProbe

    var supportedEventTypes: Set<ConversationDomainEventType> {
        [.messageCreated]
    }

    func consume(_ envelope: ConversationEventEnvelope) async throws {
        await probe.recordSingle(envelope)
    }

    func consumeMessageCreatedRun(_ envelopes: [ConversationEventEnvelope]) async throws {
        await probe.recordRun(envelopes)
    }
}

private func streamMetadata(
    topic: String,
    partition: Int,
    offset: Int,
    conversationID: UUID,
    eventType: ConversationDomainEventType = .messageCreated,
    payload: ConversationDomainEventPayload,
    producerShard: String = "conversation-shard-0"
) -> ConversationEventStreamMessageRunGrouper.Metadata {
    ConversationEventStreamMessageRunGrouper.Metadata(
        topic: topic,
        partition: partition,
        offset: offset,
        envelope: ConversationEventStreamEnvelope(
            eventID: UUID(),
            conversationID: conversationID,
            aggregateSequence: offset + 1,
            eventType: eventType.rawValue,
            payload: payload,
            occurredAt: Date(timeIntervalSince1970: 1_710_410_000 + TimeInterval(offset)),
            producerShard: producerShard
        )
    )
}

private func testStreamEnvelope(
    conversationID: UUID,
    eventType: ConversationDomainEventType,
    payload: ConversationDomainEventPayload
) -> ConversationEventStreamEnvelope {
    ConversationEventStreamEnvelope(
        eventID: UUID(),
        conversationID: conversationID,
        aggregateSequence: 1,
        eventType: eventType.rawValue,
        payload: payload,
        occurredAt: Date(timeIntervalSince1970: 1_710_410_000),
        producerShard: "conversation-shard-0"
    )
}

private struct FailingConversationSearchIndexWriter: ConversationSearchIndexWriter {
    func reindexMessage(messageID: UUID, on database: any Database) async throws {
        throw Abort(.internalServerError, reason: "search index unavailable")
    }
}

private func ownerDeliveryTestPayload(
    eventID: UUID,
    conversationID: UUID,
    senderUserID: UUID,
    sequence: UInt64,
    text: String
) -> IMTCPChatDomainEventPayload {
    IMTCPChatDomainEventPayload(
        eventID: eventID,
        eventType: .messageCreated,
        aggregateType: "conversation",
        aggregateID: conversationID,
        aggregateSequence: sequence,
        occurredAt: Date(),
        actorUserID: senderUserID,
        conversation: nil,
        ownerCursor: nil,
        ownerAggregateSequence: nil,
        body: .messageCreated(
            message: IMMessageResponse(
                id: UUID(),
                conversationID: conversationID,
                senderUserID: senderUserID,
                clientMessageID: "owner-batch-\(sequence)",
                serverSequence: sequence,
                timelineSequence: sequence,
                content: .richText(.plain(text)),
                derivedState: MessageDerivedState(),
                createdAt: Date()
            ),
            clientMessageID: "owner-batch-\(sequence)"
        )
    )
}

private actor FailingConversationEventStreamProducer: ConversationEventStreamProducer {
    let driverName = "failing-test"

    func publish(_ envelope: ConversationEventStreamEnvelope) async throws {
        throw Abort(.serviceUnavailable, reason: "stream unavailable")
    }
}

private func kafkaTestHeader(key: String, value: String) -> KafkaHeader {
    var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
    buffer.writeString(value)
    return KafkaHeader(key: key, value: buffer)
}

private func kafkaHeaderValue(_ key: String, in headers: [KafkaHeader]) -> String? {
    guard let header = headers.first(where: { $0.key == key }),
          var value = header.value else {
        return nil
    }
    return value.readString(length: value.readableBytes)
}
