import Fluent
import Foundation
import Kafka
import NIOCore
import Vapor

struct KafkaConversationEventStreamConsumerRunner {
    struct DecodedStreamMessage: Sendable {
        let metadata: ConversationEventStreamMessageRunGrouper.Metadata
        let streamEnvelope: ConversationEventStreamEnvelope
        let eventEnvelope: ConversationEventEnvelope
        let producerShard: String
    }

    private struct QueuedDecodedStreamMessage: Sendable {
        let raw: KafkaConsumerMessage
        let decoded: DecodedStreamMessage
    }

    private struct QueuedMessageResult: Sendable {
        let didSend: Bool
        let didWaitForCapacity: Bool
        let depth: Int
        let revision: Int
    }

    let app: Application
    let groupID: String
    let clientSuffix: String
    let topics: [String]
    let replayRecordsEnabled: Bool
    let autoOffsetReset: KafkaConsumerConfiguration.AutoOffsetReset
    let coalesceInterleavedMessageCreatedBatches: Bool
    let consumerFactory: @Sendable (String) -> [any ConversationEventConsumer]

    init(
        app: Application,
        groupID: String,
        clientSuffix: String,
        topics: [String],
        replayRecordsEnabled: Bool = true,
        autoOffsetReset: KafkaConsumerConfiguration.AutoOffsetReset = .earliest,
        coalesceInterleavedMessageCreatedBatches: Bool = false,
        consumerFactory: @escaping @Sendable (String) -> [any ConversationEventConsumer]
    ) {
        self.app = app
        self.groupID = groupID
        self.clientSuffix = clientSuffix
        self.topics = topics
        self.replayRecordsEnabled = replayRecordsEnabled
        self.autoOffsetReset = autoOffsetReset
        self.coalesceInterleavedMessageCreatedBatches = coalesceInterleavedMessageCreatedBatches
        self.consumerFactory = consumerFactory
    }

    func run() async throws {
        guard app.eventStreamConfiguration.driver == .kafka else {
            throw Abort(.internalServerError, reason: "stream-consumer requires IM_EVENT_STREAM_DRIVER=kafka.")
        }

        let configuration = try app.eventStreamConfiguration.makeConsumerConfiguration(
            consumerGroupID: groupID,
            clientSuffix: clientSuffix,
            topics: topics,
            autoOffsetReset: autoOffsetReset
        )
        let (consumer, events) = try KafkaConsumer.makeConsumerWithEvents(
            configuration: configuration,
            logger: app.logger
        )
        let deadLetterProducer = KafkaConversationEventStreamProducer(
            logger: app.logger,
            configuration: app.eventStreamConfiguration,
            nodeID: "\(app.imNodeID)-\(clientSuffix)-dead-letter"
        )

        let runTask = Task {
            try await consumer.run()
        }
        let eventsTask = Task {
            for await event in events {
                app.logger.debug(
                    "Kafka stream consumer event received",
                    metadata: [
                        "group_id": .string(groupID),
                        "event": .string(String(describing: event))
                    ]
                )
            }
        }

        let messageQueue = AsyncBoundedQueue<KafkaConsumerMessage>(
            capacity: app.streamConsumerConfiguration.streamConsumerQueueCapacity
        )
        let readerTask = Task {
            do {
                for try await message in consumer.messages {
                    let result = await sendQueuedMessage(message, to: messageQueue)
                    guard result.didSend else {
                        break
                    }
                }
                await messageQueue.finish()
            } catch {
                await messageQueue.finish(error)
            }
        }

        defer {
            consumer.triggerGracefulShutdown()
            runTask.cancel()
            eventsTask.cancel()
            readerTask.cancel()
            Task {
                await messageQueue.finish()
            }
            Task {
                await deadLetterProducer.shutdown()
            }
        }

        do {
            try await processQueuedMessages(
                from: messageQueue,
                consumer: consumer,
                deadLetterProducer: deadLetterProducer
            )
        } catch {
            await deadLetterProducer.shutdown()
            throw error
        }

        await deadLetterProducer.shutdown()
    }

    private func decodeEnvelope(from message: KafkaConsumerMessage) throws -> ConversationEventStreamEnvelope {
        let data = Data(Array(message.value.readableBytesView))
        return try JSONDecoder().decode(ConversationEventStreamEnvelope.self, from: data)
    }

    private func sendQueuedMessage(
        _ message: KafkaConsumerMessage,
        to queue: AsyncBoundedQueue<KafkaConsumerMessage>
    ) async -> QueuedMessageResult {
        let result = await queue.send(message)
        guard result.didSend else {
            return QueuedMessageResult(
                didSend: false,
                didWaitForCapacity: result.didWaitForCapacity,
                depth: result.depth,
                revision: result.revision
            )
        }
        await app.streamMetrics.recordQueueDepth(groupID: groupID, depth: result.depth, revision: result.revision)
        if result.didWaitForCapacity {
            await app.streamMetrics.recordQueueProducerWait(groupID: groupID)
        }
        return QueuedMessageResult(
            didSend: true,
            didWaitForCapacity: result.didWaitForCapacity,
            depth: result.depth,
            revision: result.revision
        )
    }

    private func processQueuedMessages(
        from queue: AsyncBoundedQueue<KafkaConsumerMessage>,
        consumer: KafkaConsumer,
        deadLetterProducer: KafkaConversationEventStreamProducer
    ) async throws {
        let maxBatchSize = app.streamConsumerConfiguration.streamConsumerRunBatchSize
        let batchFillWaitMilliseconds = app.streamConsumerConfiguration.streamConsumerBatchFillWaitMilliseconds
        while let first = try await queue.next() {
            let drained = await queue.drainAvailable(limit: max(0, maxBatchSize - 1))
            let remainingCapacity = max(0, maxBatchSize - 1 - drained.count)
            let fillDrained: [KafkaConsumerMessage]
            let didWaitForBatchFill: Bool
            let didSkipBatchFill: Bool
            let isBatchFillCandidate = batchFillWaitMilliseconds > 0 && remainingCapacity > 0
            let isBatchFillEligible = isBatchFillCandidate && shouldWaitForBatchFill(after: first)
            if isBatchFillEligible {
                try await Task.sleep(nanoseconds: UInt64(batchFillWaitMilliseconds) * 1_000_000)
                fillDrained = await queue.drainAvailable(limit: remainingCapacity)
                didWaitForBatchFill = true
                didSkipBatchFill = false
            } else {
                fillDrained = []
                didWaitForBatchFill = false
                didSkipBatchFill = isBatchFillCandidate
            }
            await app.streamMetrics.recordProcessingBatch(
                groupID: groupID,
                eventCount: 1 + drained.count + fillDrained.count,
                batchFillWaitMillis: didWaitForBatchFill ? batchFillWaitMilliseconds : 0,
                batchFillEventCount: fillDrained.count,
                batchFillSkipped: didSkipBatchFill
            )
            let stats = await queue.stats()
            await app.streamMetrics.recordQueueDepth(groupID: groupID, depth: stats.depth, revision: stats.revision)
            try await processKafkaMessages(
                [first] + drained + fillDrained,
                consumer: consumer,
                deadLetterProducer: deadLetterProducer
            )
        }
        let finalStats = await queue.stats()
        await app.streamMetrics.recordQueueDepth(
            groupID: groupID,
            depth: finalStats.depth,
            revision: finalStats.revision
        )
    }

    private func shouldWaitForBatchFill(after message: KafkaConsumerMessage) -> Bool {
        let eventTypeHeader = headerValue(named: "event-type", in: message.headers)
        guard ConversationEventStreamBatchFillPolicy.shouldDecodeEnvelope(headerEventType: eventTypeHeader) else {
            return false
        }
        guard let envelope = try? decodeEnvelope(from: message) else {
            return false
        }
        return ConversationEventStreamBatchFillPolicy.isEligible(envelope)
    }

    private func processKafkaMessages(
        _ messages: [KafkaConsumerMessage],
        consumer: KafkaConsumer,
        deadLetterProducer: KafkaConversationEventStreamProducer
    ) async throws {
        if coalesceInterleavedMessageCreatedBatches,
           try await processInterleavedMessageCreatedBatchIfEligible(
               messages,
               consumer: consumer,
               deadLetterProducer: deadLetterProducer
           ) {
            return
        }

        var currentRun: [QueuedDecodedStreamMessage] = []

        for message in messages {
            do {
                let streamEnvelope = try decodeEnvelope(from: message)
                if replayRecordsEnabled, try await hasAlreadyProcessed(streamEnvelope.eventID) {
                    try await flushDecodedRun(
                        &currentRun,
                        consumer: consumer,
                        deadLetterProducer: deadLetterProducer
                    )
                    await app.streamMetrics.recordDuplicate(groupID: groupID)
                    try await consumer.commit(message)
                    continue
                }
                let decoded = try decodedMessage(
                    from: streamEnvelope,
                    sourceTopic: message.topic,
                    partition: message.partition.rawValue,
                    offset: message.offset.rawValue,
                    deadLetterError: headerValue(
                        named: "dead-letter-error",
                        in: message.headers
                    )
                )
                let queued = QueuedDecodedStreamMessage(raw: message, decoded: decoded)
                if let previous = currentRun.last,
                   !ConversationEventStreamMessageRunGrouper.canAppend(
                       queued.decoded.metadata,
                       after: previous.decoded.metadata
                   ) {
                    try await flushDecodedRun(
                        &currentRun,
                        consumer: consumer,
                        deadLetterProducer: deadLetterProducer
                    )
                }
                currentRun.append(queued)
            } catch {
                try await flushDecodedRun(
                    &currentRun,
                    consumer: consumer,
                    deadLetterProducer: deadLetterProducer
                )
                try await processKafkaMessage(message, consumer: consumer, deadLetterProducer: deadLetterProducer)
            }
        }

        try await flushDecodedRun(
            &currentRun,
            consumer: consumer,
            deadLetterProducer: deadLetterProducer
        )
    }

    /// Kafka preserves partition order, but independent conversations in a partition do not
    /// require each other to be delivered serially. Re-grouping a homogeneous message-created
    /// batch restores the existing bulk fanout path without changing ordering within a
    /// conversation. The final offset is committed only after every re-grouped run succeeds.
    private func processInterleavedMessageCreatedBatchIfEligible(
        _ messages: [KafkaConsumerMessage],
        consumer: KafkaConsumer,
        deadLetterProducer: KafkaConversationEventStreamProducer
    ) async throws -> Bool {
        guard messages.count > 1 else {
            return false
        }

        var decodedMessages: [QueuedDecodedStreamMessage] = []
        decodedMessages.reserveCapacity(messages.count)
        for message in messages {
            let streamEnvelope: ConversationEventStreamEnvelope
            do {
                streamEnvelope = try decodeEnvelope(from: message)
            } catch {
                return false
            }
            if replayRecordsEnabled,
               try await hasAlreadyProcessed(streamEnvelope.eventID) {
                return false
            }
            let decoded: DecodedStreamMessage
            do {
                decoded = try decodedMessage(
                    from: streamEnvelope,
                    sourceTopic: message.topic,
                    partition: message.partition.rawValue,
                    offset: message.offset.rawValue,
                    deadLetterError: headerValue(
                        named: "dead-letter-error",
                        in: message.headers
                    )
                )
            } catch {
                return false
            }
            decodedMessages.append(QueuedDecodedStreamMessage(raw: message, decoded: decoded))
        }

        guard ConversationEventStreamMessageRunGrouper.isInterleavedMessageCreatedBatchEligible(
            decodedMessages.map(\.decoded.metadata)
        ) else {
            return false
        }

        struct RunKey: Hashable {
            let conversationID: UUID
            let producerShard: String
        }
        var orderedKeys: [RunKey] = []
        var runs: [RunKey: [QueuedDecodedStreamMessage]] = [:]
        for message in decodedMessages {
            let key = RunKey(
                conversationID: message.decoded.streamEnvelope.conversationID,
                producerShard: message.decoded.producerShard
            )
            if runs[key] == nil {
                orderedKeys.append(key)
                runs[key] = []
            }
            runs[key]?.append(message)
        }

        guard orderedKeys.count > 1 else {
            return false
        }

        for key in orderedKeys {
            guard let run = runs[key] else {
                continue
            }
            try await processDecodedRun(
                run,
                consumer: consumer,
                deadLetterProducer: deadLetterProducer,
                commitAfterProcessing: false
            )
            try Task.checkCancellation()
        }
        if let last = messages.last {
            try Task.checkCancellation()
            try await consumer.commit(last)
        }
        return true
    }

    private func flushDecodedRun(
        _ run: inout [QueuedDecodedStreamMessage],
        consumer: KafkaConsumer,
        deadLetterProducer: KafkaConversationEventStreamProducer
    ) async throws {
        guard !run.isEmpty else {
            return
        }
        let current = run
        run.removeAll()
        try await processDecodedRun(current, consumer: consumer, deadLetterProducer: deadLetterProducer)
    }

    private func processDecodedRun(
        _ run: [QueuedDecodedStreamMessage],
        consumer: KafkaConsumer,
        deadLetterProducer: KafkaConversationEventStreamProducer,
        commitAfterProcessing: Bool = true
    ) async throws {
        guard !run.isEmpty else {
            return
        }
        guard run.count > 1 else {
            try await processKafkaMessage(
                run[0].raw,
                consumer: consumer,
                deadLetterProducer: deadLetterProducer,
                commitAfterProcessing: commitAfterProcessing
            )
            return
        }

        var transientAttempt = 0
        while !Task.isCancelled {
            do {
                let startedAt = Date()
                let isMessageCreatedRun = ConversationEventStreamMessageRunGrouper
                    .isMessageCreatedRun(run.map(\.decoded.metadata))
                let eventLagMilliseconds = maxEventLagMilliseconds(in: run, at: startedAt)
                try await consumeDecodedMessages(run.map(\.decoded))
                let processingMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
                await app.streamMetrics.recordRun(
                    groupID: groupID,
                    eventCount: run.count,
                    isMessageCreatedRun: isMessageCreatedRun,
                    durationMillis: processingMilliseconds,
                    eventLagMillis: eventLagMilliseconds,
                    slowThresholdMillis: app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
                )
                logSlowDecodedRunIfNeeded(
                    run,
                    processingMilliseconds: processingMilliseconds,
                    eventLagMilliseconds: eventLagMilliseconds,
                    isMessageCreatedRun: isMessageCreatedRun
                )
                if replayRecordsEnabled {
                    for message in run {
                        try await recordProcessed(message.decoded.streamEnvelope)
                    }
                }
                for _ in run {
                    await app.streamMetrics.recordConsumed(groupID: groupID)
                }
                if commitAfterProcessing, let last = run.last {
                    try await consumer.commit(last.raw)
                }
                return
            } catch let transientError as ConversationEventTransientProcessingError {
                transientAttempt += 1
                let maxTransientAttempts = app.streamConsumerConfiguration.domainDeliveryTransientMaxAttempts
                if transientAttempt >= maxTransientAttempts {
                    app.logger.warning(
                        "Kafka stream consumer run transient processing exhausted; falling back to single-message processing",
                        metadata: [
                            "group_id": .string(groupID),
                            "run_count": .stringConvertible(run.count),
                            "attempt": .stringConvertible(transientAttempt),
                            "max_attempts": .stringConvertible(maxTransientAttempts),
                            "error": .string(String(describing: transientError))
                        ]
                    )
                    try await processDecodedRunIndividually(
                        run,
                        consumer: consumer,
                        deadLetterProducer: deadLetterProducer,
                        commitAfterProcessing: commitAfterProcessing
                    )
                    return
                }
                app.logger.warning(
                    "Kafka stream consumer run transient processing failed; retrying run without commit",
                    metadata: [
                        "group_id": .string(groupID),
                        "run_count": .stringConvertible(run.count),
                        "attempt": .stringConvertible(transientAttempt),
                        "max_attempts": .stringConvertible(maxTransientAttempts),
                        "error": .string(String(describing: transientError))
                    ]
                )
                let retryDelay = UInt64(app.streamConsumerConfiguration.domainDeliveryTimelineNoticeRetryDelayMilliseconds) * 1_000_000
                try? await Task.sleep(nanoseconds: retryDelay)
            } catch {
                app.logger.warning(
                    "Kafka stream consumer run processing failed; falling back to single-message processing",
                    metadata: [
                        "group_id": .string(groupID),
                        "run_count": .stringConvertible(run.count),
                        "error": .string(String(describing: error))
                    ]
                )
                try await processDecodedRunIndividually(
                    run,
                    consumer: consumer,
                    deadLetterProducer: deadLetterProducer,
                    commitAfterProcessing: commitAfterProcessing
                )
                return
            }
        }
    }

    private func logSlowDecodedRunIfNeeded(
        _ run: [QueuedDecodedStreamMessage],
        processingMilliseconds: Int,
        eventLagMilliseconds: Int,
        isMessageCreatedRun: Bool
    ) {
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        guard slowLogMilliseconds > 0,
              (processingMilliseconds >= slowLogMilliseconds || eventLagMilliseconds >= slowLogMilliseconds),
              let first = run.first,
              let last = run.last
        else {
            return
        }

        let firstEnvelope = first.decoded.streamEnvelope
        app.logger.info("Kafka stream consumer run slow.", metadata: [
            "group_id": .string(groupID),
            "run_count": .stringConvertible(run.count),
            "is_message_created_run": .stringConvertible(isMessageCreatedRun),
            "conversation_id": .string(firstEnvelope.conversationID.uuidString),
            "event_type": .string(firstEnvelope.eventType),
            "producer_shard": .string(first.decoded.producerShard),
            "topic": .string(first.decoded.metadata.topic),
            "partition": .stringConvertible(first.decoded.metadata.partition),
            "first_offset": .stringConvertible(first.decoded.metadata.offset),
            "last_offset": .stringConvertible(last.decoded.metadata.offset),
            "processing_ms": .stringConvertible(processingMilliseconds),
            "event_lag_ms": .stringConvertible(eventLagMilliseconds),
            "slow_log_ms": .stringConvertible(slowLogMilliseconds)
        ])
    }

    private func maxEventLagMilliseconds(in run: [QueuedDecodedStreamMessage], at now: Date) -> Int {
        run.map {
            IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(
                from: $0.decoded.streamEnvelope.occurredAt,
                to: now
            )
        }.max() ?? 0
    }

    private func processDecodedRunIndividually(
        _ run: [QueuedDecodedStreamMessage],
        consumer: KafkaConsumer,
        deadLetterProducer: KafkaConversationEventStreamProducer,
        commitAfterProcessing: Bool
    ) async throws {
        for message in run {
            try await processKafkaMessage(
                message.raw,
                consumer: consumer,
                deadLetterProducer: deadLetterProducer,
                commitAfterProcessing: commitAfterProcessing
            )
        }
    }

    private func processKafkaMessage(
        _ message: KafkaConsumerMessage,
        consumer: KafkaConsumer,
        deadLetterProducer: KafkaConversationEventStreamProducer,
        commitAfterProcessing: Bool = true
    ) async throws {
        var transientAttempt = 0
        while !Task.isCancelled {
            do {
                let streamEnvelope = try decodeEnvelope(from: message)
                if replayRecordsEnabled, try await hasAlreadyProcessed(streamEnvelope.eventID) {
                    await app.streamMetrics.recordDuplicate(groupID: groupID)
                    if commitAfterProcessing {
                        try await consumer.commit(message)
                    }
                    return
                }
                let decoded = try decodedMessage(
                    from: streamEnvelope,
                    sourceTopic: message.topic,
                    partition: message.partition.rawValue,
                    offset: message.offset.rawValue,
                    deadLetterError: headerValue(
                        named: "dead-letter-error",
                        in: message.headers
                    )
                )
                let startedAt = Date()
                let isMessageCreatedRun = ConversationEventStreamMessageRunGrouper
                    .isMessageCreatedRun([decoded.metadata])
                let eventLagMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(
                    from: streamEnvelope.occurredAt,
                    to: startedAt
                )
                try await consumeDecodedMessages([decoded])
                let processingMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
                await app.streamMetrics.recordRun(
                    groupID: groupID,
                    eventCount: 1,
                    isMessageCreatedRun: isMessageCreatedRun,
                    durationMillis: processingMilliseconds,
                    eventLagMillis: eventLagMilliseconds,
                    slowThresholdMillis: app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
                )
                logSlowDecodedRunIfNeeded(
                    [QueuedDecodedStreamMessage(raw: message, decoded: decoded)],
                    processingMilliseconds: processingMilliseconds,
                    eventLagMilliseconds: eventLagMilliseconds,
                    isMessageCreatedRun: isMessageCreatedRun
                )
                if replayRecordsEnabled {
                    try await recordProcessed(streamEnvelope)
                }
                await app.streamMetrics.recordConsumed(groupID: groupID)
                if commitAfterProcessing {
                    try await consumer.commit(message)
                }
                return
            } catch let transientError as ConversationEventTransientProcessingError {
                transientAttempt += 1
                let maxTransientAttempts = app.streamConsumerConfiguration.domainDeliveryTransientMaxAttempts
                if transientAttempt >= maxTransientAttempts {
                    await app.streamMetrics.recordFailed(groupID: groupID)
                    app.logger.warning(
                        "Kafka stream consumer transient processing exhausted; publishing to dead letter",
                        metadata: [
                            "group_id": .string(groupID),
                            "attempt": .stringConvertible(transientAttempt),
                            "max_attempts": .stringConvertible(maxTransientAttempts),
                            "error": .string(String(describing: transientError))
                        ]
                    )
                    if await publishDeadLetter(for: message, error: transientError, producer: deadLetterProducer) {
                        if commitAfterProcessing {
                            try? await consumer.commit(message)
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                app.logger.warning(
                    "Kafka stream consumer transient processing failed; retrying without commit",
                    metadata: [
                        "group_id": .string(groupID),
                        "attempt": .stringConvertible(transientAttempt),
                        "max_attempts": .stringConvertible(maxTransientAttempts),
                        "error": .string(String(describing: transientError))
                    ]
                )
                let retryDelay = UInt64(app.streamConsumerConfiguration.domainDeliveryTimelineNoticeRetryDelayMilliseconds) * 1_000_000
                try? await Task.sleep(nanoseconds: retryDelay)
            } catch {
                // Most dependency failures are surfaced as generic errors by the
                // underlying client libraries. Do not turn a transient outage into
                // a permanent delivery loss just because it lacks our marker type.
                transientAttempt += 1
                let maxTransientAttempts = app.streamConsumerConfiguration.domainDeliveryTransientMaxAttempts
                if transientAttempt < maxTransientAttempts {
                    app.logger.warning(
                        "Kafka stream consumer unclassified processing failed; retrying without commit",
                        metadata: [
                            "group_id": .string(groupID),
                            "attempt": .stringConvertible(transientAttempt),
                            "max_attempts": .stringConvertible(maxTransientAttempts),
                            "error": .string(String(describing: error))
                        ]
                    )
                    let retryDelay = UInt64(app.streamConsumerConfiguration.domainDeliveryTimelineNoticeRetryDelayMilliseconds) * 1_000_000
                    try? await Task.sleep(nanoseconds: retryDelay)
                    continue
                }

                await app.streamMetrics.recordFailed(groupID: groupID)
                app.logger.warning(
                    "Kafka stream consumer unclassified processing exhausted; publishing to dead letter",
                    metadata: [
                        "group_id": .string(groupID),
                        "attempt": .stringConvertible(transientAttempt),
                        "max_attempts": .stringConvertible(maxTransientAttempts),
                        "error": .string(String(describing: error))
                    ]
                )

                if !(await publishDeadLetter(for: message, error: error, producer: deadLetterProducer)) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                if commitAfterProcessing {
                    try? await consumer.commit(message)
                }
                return
            }
        }
    }

    private func decodedMessage(
        from streamEnvelope: ConversationEventStreamEnvelope,
        sourceTopic: String,
        partition: Int,
        offset: Int,
        deadLetterError: String?
    ) throws -> DecodedStreamMessage {
        guard let eventType = ConversationDomainEventType(rawValue: streamEnvelope.eventType) else {
            throw Abort(.unprocessableEntity, reason: "未知 conversation stream event 类型：\(streamEnvelope.eventType)。")
        }
        let syntheticEvent = try ConversationDomainEvent(
            id: streamEnvelope.eventID,
            conversationID: streamEnvelope.conversationID,
            eventType: eventType,
            aggregateSequence: streamEnvelope.aggregateSequence,
            actorUserID: streamEnvelope.actorUserID,
            payload: streamEnvelope.payload,
            status: .pending,
            createdAt: streamEnvelope.occurredAt
        )
        return try DecodedStreamMessage(
            metadata: ConversationEventStreamMessageRunGrouper.Metadata(
                topic: sourceTopic,
                partition: partition,
                offset: offset,
                envelope: streamEnvelope
            ),
            streamEnvelope: streamEnvelope,
            eventEnvelope: ConversationEventEnvelope(
                event: syntheticEvent,
                payload: streamEnvelope.payload,
                deliveryContext: .init(
                    sourceTopic: sourceTopic,
                    consumerGroupID: groupID,
                    producerShard: streamEnvelope.producerShard,
                    deadLetterError: deadLetterError
                )
            ),
            producerShard: streamEnvelope.producerShard
        )
    }

    private func consumeDecodedMessages(_ messages: [DecodedStreamMessage]) async throws {
        guard !messages.isEmpty else {
            return
        }
        if ConversationEventStreamMessageRunGrouper.isMessageCreatedRun(messages.map(\.metadata)) {
            let registry = ConversationEventConsumerRegistry(
                consumers: consumerFactory(messages[0].producerShard)
            )
            try await registry.consumeMessageCreatedRun(messages.map(\.eventEnvelope))
            return
        }
        if ConversationEventStreamMessageRunGrouper.isMembershipAddedRun(messages.map(\.metadata)) {
            let registry = ConversationEventConsumerRegistry(
                consumers: consumerFactory(messages[0].producerShard)
            )
            try await registry.consumeMembershipAddedRun(messages.map(\.eventEnvelope))
            return
        }

        for message in messages {
            let registry = ConversationEventConsumerRegistry(
                consumers: consumerFactory(message.producerShard)
            )
            try await registry.consume(message.eventEnvelope)
        }
    }

    private func publishDeadLetter(
        for message: KafkaConsumerMessage,
        error: any Error,
        producer: KafkaConversationEventStreamProducer
    ) async -> Bool {
        guard let envelope = try? decodeEnvelope(from: message) else {
            return true
        }
        let deadLetterHeader = kafkaHeader(
            key: "dead-letter-error",
            value: String(describing: error)
        )
        do {
            try await producer.publish(
                envelope,
                topicOverride: app.eventStreamConfiguration.deadLetterTopic,
                additionalHeaders: [deadLetterHeader]
            )
            await app.streamMetrics.recordDeadLetterPublished(groupID: groupID)
            return true
        } catch {
            app.logger.error(
                "Kafka stream consumer dead-letter publish failed; original message will not be committed",
                metadata: [
                    "group_id": .string(groupID),
                    "event_id": .string(envelope.eventID.uuidString),
                    "error": .string(String(describing: error))
                ]
            )
            return false
        }
    }

    private func headerValue(
        named key: String,
        in headers: [KafkaHeader]
    ) -> String? {
        guard let header = headers.first(where: { $0.key == key }),
              var value = header.value else {
            return nil
        }
        return value.readString(length: value.readableBytes)
    }

    private func kafkaHeader(key: String, value: String) -> KafkaHeader {
        var buffer = ByteBufferAllocator().buffer(capacity: value.utf8.count)
        buffer.writeString(value)
        return KafkaHeader(key: key, value: buffer)
    }

    private func hasAlreadyProcessed(_ eventID: UUID) async throws -> Bool {
        let recordID = ConversationReplayRecord.recordID(consumerGroupID: groupID, eventID: eventID)
        guard let record = try await ConversationReplayRecord.find(recordID, on: app.imWriteDB) else {
            return false
        }
        return record.statusEnum == .replayed
    }

    private func recordProcessed(_ envelope: ConversationEventStreamEnvelope) async throws {
        let recordID = ConversationReplayRecord.recordID(consumerGroupID: groupID, eventID: envelope.eventID)
        let now = Date()
        if let existing = try await ConversationReplayRecord.find(recordID, on: app.imWriteDB) {
            existing.statusEnum = .replayed
            existing.receiveCount += 1
            existing.lastError = nil
            existing.replayedAt = now
            existing.updatedAt = now
            try await existing.update(on: app.imWriteDB)
            return
        }

        let record = try ConversationReplayRecord(
            eventID: envelope.eventID,
            consumerGroupID: groupID,
            sourceTopic: topics.first ?? app.eventStreamConfiguration.topic,
            conversationID: envelope.conversationID,
            eventType: envelope.eventType,
            aggregateSequence: envelope.aggregateSequence,
            producerShard: envelope.producerShard,
            payload: envelope.payload,
            status: .replayed,
            lastError: nil,
            receiveCount: 1,
            replayedAt: now,
            createdAt: envelope.occurredAt,
            updatedAt: now
        )
        try await record.create(on: app.imWriteDB)
    }
}

struct ConversationEventStreamMessageRunGrouper {
    struct Metadata: Equatable, Sendable {
        let topic: String
        let partition: Int
        let offset: Int
        let envelope: ConversationEventStreamEnvelope
    }

    static func contiguousRuns(in messages: [Metadata]) -> [[Metadata]] {
        var runs: [[Metadata]] = []
        var current: [Metadata] = []

        for message in messages {
            if let previous = current.last, canAppend(message, after: previous) {
                current.append(message)
                continue
            }
            if !current.isEmpty {
                runs.append(current)
            }
            current = [message]
        }

        if !current.isEmpty {
            runs.append(current)
        }
        return runs
    }

    static func canAppend(_ message: Metadata, after previous: Metadata) -> Bool {
        previous.topic == message.topic
            && previous.partition == message.partition
            && previous.offset + 1 == message.offset
            && previous.envelope.conversationID == message.envelope.conversationID
            && previous.envelope.producerShard == message.envelope.producerShard
            && sameCoalescibleEventType(previous.envelope, message.envelope)
    }

    static func isMessageCreatedRun(_ envelopes: [ConversationEventStreamEnvelope]) -> Bool {
        guard let first = envelopes.first else {
            return false
        }
        return envelopes.allSatisfy {
            $0.conversationID == first.conversationID
                && $0.producerShard == first.producerShard
                && isMessageCreated($0)
        }
    }

    static func isMessageCreatedRun(_ messages: [Metadata]) -> Bool {
        guard let first = messages.first else {
            return false
        }
        var previous = first
        guard isMessageCreated(first.envelope) else {
            return false
        }
        for message in messages.dropFirst() {
            guard canAppend(message, after: previous) else {
                return false
            }
            previous = message
        }
        return true
    }

    static func isInterleavedMessageCreatedBatchEligible(_ messages: [Metadata]) -> Bool {
        guard let first = messages.first,
              isMessageCreated(first.envelope)
        else {
            return false
        }
        return messages.allSatisfy {
            $0.topic == first.topic
                && $0.partition == first.partition
                && isMessageCreated($0.envelope)
        }
    }

    static func isMembershipAddedRun(_ messages: [Metadata]) -> Bool {
        guard let first = messages.first else {
            return false
        }
        var previous = first
        guard isMembershipAdded(first.envelope) else {
            return false
        }
        for message in messages.dropFirst() {
            guard canAppend(message, after: previous) else {
                return false
            }
            previous = message
        }
        return true
    }

    private static func sameCoalescibleEventType(
        _ lhs: ConversationEventStreamEnvelope,
        _ rhs: ConversationEventStreamEnvelope
    ) -> Bool {
        (isMessageCreated(lhs) && isMessageCreated(rhs))
            || (isMembershipAdded(lhs) && isMembershipAdded(rhs))
    }

    private static func isMessageCreated(_ envelope: ConversationEventStreamEnvelope) -> Bool {
        envelope.eventType == ConversationDomainEventType.messageCreated.rawValue
            && envelope.payload.messageID != nil
    }

    private static func isMembershipAdded(_ envelope: ConversationEventStreamEnvelope) -> Bool {
        envelope.eventType == ConversationDomainEventType.membershipAdded.rawValue
    }
}

enum ConversationEventStreamBatchFillPolicy {
    static func shouldDecodeEnvelope(headerEventType: String?) -> Bool {
        guard let headerEventType else {
            return true
        }
        return headerEventType == ConversationDomainEventType.messageCreated.rawValue
    }

    static func isEligible(_ envelope: ConversationEventStreamEnvelope) -> Bool {
        (envelope.eventType == ConversationDomainEventType.messageCreated.rawValue
            && envelope.payload.messageID != nil)
            || envelope.eventType == ConversationDomainEventType.membershipAdded.rawValue
    }
}

actor AsyncBoundedQueue<Element: Sendable> {
    struct SendResult: Sendable {
        let didSend: Bool
        let didWaitForCapacity: Bool
        let depth: Int
        let revision: Int
    }

    struct Stats: Sendable {
        let depth: Int
        let waitingProducerCount: Int
        let waitingConsumerCount: Int
        let capacity: Int
        let revision: Int
    }

    private let capacity: Int
    private var buffer: [Element] = []
    private var waitingConsumers: [CheckedContinuation<Element?, any Error>] = []
    private var waitingProducers: [CheckedContinuation<Void, Never>] = []
    private var terminalError: (any Error)?
    private var isFinished = false
    private var revision = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func send(_ element: Element) async -> SendResult {
        var didWaitForCapacity = false
        while buffer.count >= capacity && !isFinished && waitingConsumers.isEmpty {
            didWaitForCapacity = true
            await withCheckedContinuation { continuation in
                waitingProducers.append(continuation)
            }
        }
        guard !isFinished else {
            return SendResult(
                didSend: false,
                didWaitForCapacity: didWaitForCapacity,
                depth: buffer.count,
                revision: revision
            )
        }
        if let consumer = waitingConsumers.first {
            waitingConsumers.removeFirst()
            revision += 1
            consumer.resume(returning: element)
            return SendResult(
                didSend: true,
                didWaitForCapacity: didWaitForCapacity,
                depth: buffer.count,
                revision: revision
            )
        }
        buffer.append(element)
        revision += 1
        return SendResult(
            didSend: true,
            didWaitForCapacity: didWaitForCapacity,
            depth: buffer.count,
            revision: revision
        )
    }

    func next() async throws -> Element? {
        if !buffer.isEmpty {
            let element = buffer.removeFirst()
            revision += 1
            resumeProducerIfNeeded()
            return element
        }
        if isFinished {
            if let terminalError {
                throw terminalError
            }
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            waitingConsumers.append(continuation)
        }
    }

    func drainAvailable(limit: Int) -> [Element] {
        guard limit > 0, !buffer.isEmpty else {
            return []
        }
        let count = min(limit, buffer.count)
        let drained = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        revision += 1
        for _ in 0..<count {
            resumeProducerIfNeeded()
        }
        return drained
    }

    func finish(_ error: (any Error)? = nil) {
        guard !isFinished else {
            return
        }
        isFinished = true
        terminalError = error
        let consumers = waitingConsumers
        let producers = waitingProducers
        waitingConsumers.removeAll()
        waitingProducers.removeAll()
        for consumer in consumers {
            if let error {
                consumer.resume(throwing: error)
            } else {
                consumer.resume(returning: nil)
            }
        }
        for producer in producers {
            producer.resume()
        }
    }

    func stats() -> Stats {
        Stats(
            depth: buffer.count,
            waitingProducerCount: waitingProducers.count,
            waitingConsumerCount: waitingConsumers.count,
            capacity: capacity,
            revision: revision
        )
    }

    private func resumeProducerIfNeeded() {
        guard buffer.count < capacity, !waitingProducers.isEmpty else {
            return
        }
        let producer = waitingProducers.removeFirst()
        producer.resume()
    }
}
