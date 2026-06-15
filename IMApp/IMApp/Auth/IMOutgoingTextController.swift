import Foundation
import IMClientKit
import OSLog

extension ConversationRuntimeController {
    func sendText(_ text: String, to conversationID: String) async -> Bool {
        IMAppLog.imRuntime.debug(
            "sendText requested conversationID=\(conversationID, privacy: .public) textLength=\(text.count, privacy: .public)"
        )

        guard let user = currentUserProvider() else {
            IMAppLog.imRuntime.warning(
                "sendText aborted: missing current user conversationID=\(conversationID, privacy: .public)"
            )
            return false
        }

        guard let connection = imConnection else {
            let didQueue = await imConversationStore.queueOutgoingTextAsync(
                text,
                conversationID: conversationID,
                senderUserID: user.id
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            IMAppLog.imRuntime.debug(
                "sendText queued because TCP unavailable conversationID=\(conversationID, privacy: .public) didQueue=\(didQueue, privacy: .public)"
            )
            return didQueue
        }

        guard let request = await imConversationStore.prepareOutgoingTextAsync(
            text,
            conversationID: conversationID,
            senderUserID: user.id
        ) else {
            IMAppLog.imRuntime.warning(
                "sendText aborted: prepareOutgoingText failed conversationID=\(conversationID, privacy: .public)"
            )
            return false
        }
        IMAppLog.imRuntime.debug(
            "sendText prepared TCP packet conversationID=\(conversationID, privacy: .public) requestID=\(request.requestID.uuidString, privacy: .public) localMessageID=\(request.localMessageID, privacy: .public) clientMessageID=\(request.payload.clientMessageID ?? "nil", privacy: .public)"
        )
        scheduleConversationCachePersist()

        let generation = imConnectionGeneration

        do {
            try await connection.sendMessage(request.payload, requestID: request.requestID)
            IMAppLog.imRuntime.debug(
                "sendText TCP sendMessage returned conversationID=\(conversationID, privacy: .public) requestID=\(request.requestID.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
            )
            return true
        } catch {
            IMAppLog.imRuntime.error(
                "sendText TCP sendMessage failed conversationID=\(conversationID, privacy: .public) requestID=\(request.requestID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
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
            let didQueue = await imConversationStore.queueOutgoingReplyAsync(
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

        guard let request = await imConversationStore.prepareOutgoingReplyAsync(
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
            let didQueue = await imConversationStore.queueRetryableOutgoingMessageAsync(
                localMessageID: localMessageID,
                conversationID: conversationID
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        }

        guard let request = await imConversationStore.retryOutgoingMessageAsync(
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
