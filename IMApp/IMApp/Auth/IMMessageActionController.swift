import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func favoriteIMMessage(_ messageID: String, in conversationID: String) async -> Bool {
        await conversationRuntimeController.favoriteMessage(messageID: messageID, in: conversationID)
    }

    func unfavoriteIMMessage(_ messageID: String, in conversationID: String) async -> Bool {
        await conversationRuntimeController.unfavoriteMessage(messageID: messageID, in: conversationID)
    }

    func deleteIMMessagesForSelf(_ messageIDs: [String], in conversationID: String) async -> Bool {
        await conversationRuntimeController.deleteMessagesForSelf(messageIDs: messageIDs, in: conversationID)
    }

    func clearIMConversationForSelf(_ conversationID: String) async -> Bool {
        await conversationRuntimeController.clearConversationForSelf(conversationID)
    }

    func deleteIMConversationForSelf(_ conversationID: String) async -> Bool {
        await conversationRuntimeController.deleteConversationForSelf(conversationID)
    }

    func forwardIMMessages(_ messageIDs: [String], from conversationID: String, to targetConversationIDs: [String]) async -> Bool {
        await conversationRuntimeController.forwardMessages(
            messageIDs: messageIDs,
            from: conversationID,
            to: targetConversationIDs
        )
    }

    func sendIMText(_ text: String, to conversationID: String) async -> Bool {
        guard currentUser != nil else {
            return false
        }

        return await conversationRuntimeController.sendText(text, to: conversationID)
    }

    func sendIMReply(
        reference: IMReplyReference,
        text: String,
        to conversationID: String
    ) async -> Bool {
        guard currentUser != nil else {
            return false
        }

        return await conversationRuntimeController.sendReply(reference: reference, text: text, to: conversationID)
    }


    func retryIMTextMessage(localMessageID: String, in conversationID: String) async -> Bool {
        guard currentUser != nil else {
            return false
        }

        return await conversationRuntimeController.retryTextMessage(
            localMessageID: localMessageID,
            in: conversationID
        )
    }

    func cancelQueuedIMTextMessage(localMessageID: String, in conversationID: String) -> Bool {
        guard currentUser != nil else {
            return false
        }

        let didCancel = imConversationStore.cancelQueuedOutgoingMessage(
            localMessageID: localMessageID,
            conversationID: conversationID
        )
        if didCancel {
            scheduleIMConversationCachePersist()
        }
        return didCancel
    }

    func recallIMMessage(messageID: String, in conversationID: String) async -> Bool {
        guard currentUser != nil else {
            return false
        }

        return await conversationRuntimeController.recallMessage(messageID: messageID, in: conversationID)
    }

    func editIMMessage(messageID: String, text: String, in conversationID: String) async -> Bool {
        guard currentUser != nil else {
            return false
        }

        return await conversationRuntimeController.editMessage(
            messageID: messageID,
            text: text,
            in: conversationID
        )
    }

    func toggleIMMessageReaction(messageID: String, emoji: String, in conversationID: String) async -> Bool {
        guard currentUser != nil else {
            return false
        }

        return await conversationRuntimeController.toggleMessageReaction(
            messageID: messageID,
            emoji: emoji,
            in: conversationID
        )
    }
}
