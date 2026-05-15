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
        let routedDatabase = try await service.database(forConversationID: conversationID)
        let preallocatedServerSequences = try await service.preallocateServerSequencesIfNeeded(
            count: preparedMessages.count,
            conversationID: conversationID,
            updatedAt: preparedMessages.last?.serverTimestamp ?? Date(),
            on: routedDatabase
        )

        return try await routedDatabase.transaction { database in
            let membershipContext = try await service.requireConversationMembershipContext(
                conversationID: conversationID,
                senderUserID: preparedMessages[0].senderUserID,
                on: database
            )
            let recipientUserIDs = membershipContext.memberUserIDs
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

                if let result = try await existingResult(
                    prepared: prepared,
                    recipientUserIDs: recipientUserIDs,
                    on: database
                ) {
                    results.append(result)
                    continue
                }

                try await directPolicyContext.enforceBeforeCreate(
                    senderUserID: prepared.senderUserID,
                    service: service,
                    on: database
                )

                let serverSequence: Int
                if let preallocatedServerSequences {
                    serverSequence = preallocatedServerSequences[index]
                } else {
                    serverSequence = try await service.allocateNextServerSequence(
                        conversationID: conversationID,
                        updatedAt: prepared.serverTimestamp,
                        on: database
                    )
                }

                let message = try await createMessage(
                    prepared: prepared,
                    serverSequence: serverSequence,
                    recipientUserIDs: recipientUserIDs,
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
        try await ConversationOutboxService(db: database).enqueue(
            type: .messageCreated,
            conversationID: conversationID,
            payload: ConversationDomainEventPayload(
                recipientUserIDs: recipientUserIDs,
                messageID: try message.requireID()
            )
        )
        return message
    }
}
