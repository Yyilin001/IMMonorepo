import Fluent
import Vapor

struct IMMessagePersistencePipeline {
    let service: IMRealtimeMessageService
    let conversationID: UUID
    let preparedMessages: [IMPreparedIncomingMessage]

    func run() async throws -> [IMRealtimeMessagePersistenceResult] {
        guard !preparedMessages.isEmpty else {
            return []
        }
        let diagnostics = IMMessagePersistenceDiagnostics()
        let trace = IMDeliveryTrace(
            conversationID: conversationID,
            clientMessageID: preparedMessages.count == 1
                ? preparedMessages[0].normalizedClientMessageID
                : nil,
            runtimeRole: service.app?.imRuntimeRole.rawValue
        )
        defer {
            diagnostics.logIfSlow(
                app: service.app,
                trace: trace,
                messageCount: preparedMessages.count
            )
        }

        let routedDatabase = try await diagnostics.measure("databaseRoute", operation: {
            try await service.database(forConversationID: conversationID)
        })
        let preallocatedServerSequences = try await diagnostics.measure("serverSequencePreallocate", operation: {
            try await service.preallocateServerSequencesIfNeeded(
                count: preparedMessages.count,
                conversationID: conversationID,
                updatedAt: preparedMessages.last?.serverTimestamp ?? Date(),
                on: routedDatabase
            )
        })

        let results = try await diagnostics.measure("transaction", operation: {
            try await routedDatabase.transaction { database in
                try await ConversationWriteFenceService.requireWritesAllowed(conversationID: conversationID, on: database)
                let membershipContext = try await diagnostics.measure("membershipContext", operation: {
                    try await service.requireConversationMembershipContext(
                        conversationID: conversationID,
                        senderUserID: preparedMessages[0].senderUserID,
                        on: database
                    )
                })
            let recipientUserIDs = membershipContext.memberUserIDs
            diagnostics.recordRecipientCount(recipientUserIDs.count)
            let recipientUserIDSet = Set(recipientUserIDs)
            var directPolicyContext = DirectPolicyBatchContext(
                conversationID: conversationID,
                conversationKind: membershipContext.conversationKind,
                directMessagingState: membershipContext.directMessagingState,
                memberUserIDs: recipientUserIDs
            )
            var resultsByIndex: [Int: IMRealtimeMessagePersistenceResult] = [:]
            resultsByIndex.reserveCapacity(preparedMessages.count)
            var creations: [(index: Int, prepared: IMPreparedIncomingMessage, serverSequence: Int)] = []
            creations.reserveCapacity(preparedMessages.count)
            var outboxItems: [ConversationMessageCreatedOutboxItem] = []
            outboxItems.reserveCapacity(preparedMessages.count)

            for (index, prepared) in preparedMessages.enumerated() {
                guard prepared.conversationID == conversationID,
                      recipientUserIDSet.contains(prepared.senderUserID)
                else {
                    throw IMRealtimeMessageError.conversationUnavailable
                }

                if let result = try await diagnostics.measure("existingLookup", operation: {
                    try await existingResult(
                        prepared: prepared,
                        recipientUserIDs: recipientUserIDs,
                        on: database
                    )
                }) {
                    resultsByIndex[index] = result
                    continue
                }

                try await diagnostics.measure("directPolicy", operation: {
                    try await directPolicyContext.enforceBeforeCreate(
                        senderUserID: prepared.senderUserID,
                        service: service,
                        on: database
                    )
                })
                try service.validateMentionTargets(
                    in: prepared.normalizedContent,
                    memberUserIDs: recipientUserIDSet
                )

                let serverSequence: Int
                if let preallocatedServerSequences {
                    serverSequence = preallocatedServerSequences[index]
                } else {
                    serverSequence = try await diagnostics.measure("serverSequenceAllocate", operation: {
                        try await service.allocateNextServerSequence(
                            conversationID: conversationID,
                            updatedAt: prepared.serverTimestamp,
                            on: database
                        )
                    })
                }

                directPolicyContext.recordCreated(senderUserID: prepared.senderUserID)
                creations.append((index: index, prepared: prepared, serverSequence: serverSequence))
            }

            let aggregateSequences = try await diagnostics.measure("aggregateSequencePreallocate", operation: {
                try await ConversationDomainEventSequenceAllocator(db: database).allocateRange(
                    count: creations.count,
                    conversationID: conversationID,
                    on: database
                )
            })
            guard aggregateSequences.count == creations.count else {
                throw Abort(.internalServerError, reason: "消息领域事件 sequence 批量分配返回了不完整结果。")
            }

            for (creation, aggregateSequence) in zip(creations, aggregateSequences) {
                let aggregateSequenceValue = try imIntSequence(
                    aggregateSequence.rawValue,
                    field: "aggregate_sequence"
                )
                let message = try await createMessage(
                    prepared: creation.prepared,
                    serverSequence: creation.serverSequence,
                    aggregateSequence: aggregateSequenceValue,
                    on: database
                )
                resultsByIndex[creation.index] = try service.makePersistenceResult(
                    conversationID: conversationID,
                    message: message,
                    recipientUserIDs: recipientUserIDs,
                    didCreateMessage: true,
                    fallbackTimestamp: creation.prepared.serverTimestamp
                )
                outboxItems.append(
                    ConversationMessageCreatedOutboxItem(
                        actorUserID: creation.prepared.senderUserID,
                        messageID: try message.requireID(),
                        aggregateSequence: message.timelineSequence,
                        preview: try ConversationMessageCreatedPreview(
                            senderUserID: message.$sender.id,
                            serverSequence: imPositiveUInt64Sequence(message.serverSequence, field: "server_sequence"),
                            timelineSequence: imPositiveUInt64Sequence(message.timelineSequence, field: "timeline_sequence"),
                            previewText: message.decodedContent().previewText,
                            createdAt: message.createdAt
                        )
                    )
                )
            }
            if !outboxItems.isEmpty {
                _ = try await diagnostics.measure("outboxEnqueue", operation: {
                    try await ConversationOutboxService(
                        db: database,
                        domainEventMetrics: service.app?.conversationDomainEventMetrics
                    ).enqueueMessageCreatedBatch(
                        conversationID: conversationID,
                        recipientUserIDs: recipientUserIDs,
                        items: outboxItems,
                        recipientSnapshotDeduplicationThreshold: service.app?
                            .domainEventRecipientSnapshotConfiguration
                            .deduplicationThreshold ?? 0,
                        on: database
                    )
                })
            }
            return try preparedMessages.indices.map { index in
                guard let result = resultsByIndex[index] else {
                    throw Abort(.internalServerError, reason: "消息批量持久化缺少结果。")
                }
                return result
            }
            }
        })
        if results.contains(where: \.didCreateMessage) {
            service.app?.invalidateTimelineSinceHotCache(conversationID: conversationID)
        }
        await service.app?.messageWriteMetrics.recordPersistencePipeline(
            messageCount: preparedMessages.count,
            recipientCount: diagnostics.capturedRecipientCount(),
            totalMillis: diagnostics.totalMilliseconds(),
            stageMillis: diagnostics.capturedMarks()
        )
        return results
    }

    private func existingResult(
        prepared: IMPreparedIncomingMessage,
        recipientUserIDs: [UUID],
        on database: any Database
    ) async throws -> IMRealtimeMessagePersistenceResult? {
        guard let existingMessage = try await service.existingMessage(
            conversationID: conversationID,
            senderUserID: prepared.senderUserID,
            clientMessageID: prepared.normalizedClientMessageID,
            on: database
        ) else {
            return nil
        }

        return try service.makePersistenceResult(
            conversationID: conversationID,
            message: existingMessage,
            recipientUserIDs: recipientUserIDs,
            didCreateMessage: false
        )
    }

    private func createMessage(
        prepared: IMPreparedIncomingMessage,
        serverSequence: Int,
        aggregateSequence: Int,
        on database: any Database
    ) async throws -> ConversationMessage {
        let canonicalContent = try await service.canonicalizeReplyReferenceIfNeeded(
            prepared.normalizedContent,
            conversationID: conversationID,
            on: database
        )
        let message = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: prepared.senderUserID,
            serverSequence: serverSequence,
            timelineSequence: aggregateSequence,
            clientMessageID: prepared.normalizedClientMessageID,
            content: canonicalContent
        )
        try await message.create(on: database)
        try await service.advanceReadSequence(
            conversationID: conversationID,
            userID: prepared.senderUserID,
            readSequence: serverSequence,
            on: database
        )
        return message
    }
}
