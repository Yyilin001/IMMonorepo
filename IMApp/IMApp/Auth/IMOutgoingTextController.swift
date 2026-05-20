import Foundation
import IMClientKit

extension ConversationRuntimeController {
    func sendText(_ text: String, to conversationID: String) async -> Bool {
        guard let user = currentUserProvider() else {
            return false
        }

        guard let connection = imConnection else {
            let didQueue = imConversationStore.queueOutgoingText(
                text,
                conversationID: conversationID,
                senderUserID: user.id
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        }

        guard let request = imConversationStore.prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: user.id
        ) else {
            return false
        }
        scheduleConversationCachePersist()

        let generation = imConnectionGeneration

        do {
            try await connection.sendMessage(request.payload, requestID: request.requestID)
            return true
        } catch {
            await handleIMConnectionFailure(error, generation: generation)
            return false
        }
    }

    func sendReply(
        reference: IMReplyReference,
        text: String,
        to conversationID: String
    ) async -> Bool {
        guard let user = currentUserProvider() else {
            return false
        }

        guard let connection = imConnection else {
            let didQueue = imConversationStore.queueOutgoingReply(
                reference: reference,
                text: text,
                conversationID: conversationID,
                senderUserID: user.id
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        }

        guard let request = imConversationStore.prepareOutgoingReply(
            reference: reference,
            text: text,
            conversationID: conversationID,
            senderUserID: user.id
        ) else {
            return false
        }
        scheduleConversationCachePersist()

        let generation = imConnectionGeneration

        do {
            try await connection.sendMessage(request.payload, requestID: request.requestID)
            return true
        } catch {
            await handleIMConnectionFailure(error, generation: generation)
            return false
        }
    }

    func retryTextMessage(localMessageID: String, in conversationID: String) async -> Bool {
        guard currentUserProvider() != nil else {
            return false
        }

        guard let connection = imConnection else {
            let didQueue = imConversationStore.queueRetryableOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        }

        guard let request = imConversationStore.retryOutgoingMessage(
            localMessageID: localMessageID,
            conversationID: conversationID
        ) else {
            scheduleConversationCachePersist()
            return false
        }
        scheduleConversationCachePersist()

        let generation = imConnectionGeneration

        do {
            try await connection.sendMessage(request.payload, requestID: request.requestID)
            return true
        } catch {
            await handleIMConnectionFailure(error, generation: generation)
            return false
        }
    }
}
