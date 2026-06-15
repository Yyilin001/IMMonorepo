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
        defer {
            diagnostics.logIfSlow(
                app: service.app,
                conversationID: conversationID,
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
            var results: [IMRealtimeMessagePersistenceResult] = []
            results.reserveCapacity(preparedMessages.count)

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
                    results.append(result)
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

                let message = try await createMessage(
                    prepared: prepared,
                    serverSequence: serverSequence,
                    recipientUserIDs: recipientUserIDs,
                    diagnostics: diagnostics,
                    on: database
                )
                directPolicyContext.recordCreated(senderUserID: prepared.senderUserID)
                results.append(
                    try service.makePersistenceResult(
                        conversationID: conversationID,
                        message: message,
                        recipientUserIDs: recipientUserIDs,
                        didCreateMessage: true,
                        fallbackTimestamp: prepared.serverTimestamp
                    )
                )
            }
            return results
            }
        })
        if results.contains(where: \.didCreateMessage) {
            service.app?.invalidateTimelineSinceHotCache(conversationID: conversationID)
        }
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
        recipientUserIDs: [UUID],
        diagnostics: IMMessagePersistenceDiagnostics,
        on database: any Database
    ) async throws -> ConversationMessage {
        let canonicalContent = try await diagnostics.measure("canonicalize", operation: {
            try await service.canonicalizeReplyReferenceIfNeeded(
                prepared.normalizedContent,
                conversationID: conversationID,
                on: database
            )
        })
        let aggregateSequence = try await diagnostics.measure("aggregateSequenceAllocate", operation: {
            let sequence = try await ConversationDomainEventSequenceAllocator(db: database).allocate(
                conversationID: conversationID,
                on: database
            )
            return try imIntSequence(sequence.rawValue, field: "aggregate_sequence")
        })
        let message = try ConversationMessage(
            conversationID: conversationID,
            senderUserID: prepared.senderUserID,
            serverSequence: serverSequence,
            timelineSequence: aggregateSequence,
            clientMessageID: prepared.normalizedClientMessageID,
            content: canonicalContent
        )
        try await diagnostics.measure("messageCreate", operation: {
            try await message.create(on: database)
        })
        try await diagnostics.measure("readAdvance", operation: {
            try await service.advanceReadSequence(
                conversationID: conversationID,
                userID: prepared.senderUserID,
                readSequence: serverSequence,
                on: database
            )
        })
        try await diagnostics.measure("outboxEnqueue", operation: {
            let shouldInlineRecipients = service.app?
                .messageCreatedRecipientInlineConfiguration
                .shouldInlineRecipients(recipientCount: recipientUserIDs.count) ?? true
            try await ConversationOutboxService(
                db: database,
                domainEventMetrics: service.app?.conversationDomainEventMetrics
            ).enqueue(
                type: .messageCreated,
                conversationID: conversationID,
                actorUserID: prepared.senderUserID,
                payload: .messageCreated(
                    messageID: try message.requireID(),
                    recipientUserIDs: shouldInlineRecipients ? recipientUserIDs : [],
                    preview: try ConversationMessageCreatedPreview(
                        senderUserID: message.$sender.id,
                        serverSequence: imPositiveUInt64Sequence(message.serverSequence, field: "server_sequence"),
                        timelineSequence: imPositiveUInt64Sequence(message.timelineSequence, field: "timeline_sequence"),
                        previewText: canonicalContent.previewText,
                        createdAt: message.createdAt
                    )
                ),
                recipientSnapshotUserIDs: shouldInlineRecipients ? nil : recipientUserIDs,
                recipientSnapshotDeduplicationThreshold: service.app?
                    .domainEventRecipientSnapshotConfiguration
                    .deduplicationThreshold ?? 0,
                preallocatedAggregateSequence: aggregateSequence,
                updatesMessageTimelineSequence: false
            )
        })
        return message
    }
}
