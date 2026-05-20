import Foundation
import IMClientKit

extension ConversationRuntimeController {
    func recallMessage(messageID: String, in conversationID: String) async -> Bool {
        guard let currentUserID = currentUserProvider()?.id else {
            return false
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            return false
        }

        do {
            let response = try await sessionClient.recallIMMessage(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID
            )
            markServerOnline()
            imConversationStore.applyRecalledMessage(response, currentUserID: currentUserID)
            _ = await reconcileConversationSummaryReadModel(force: true)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func editMessage(messageID: String, text: String, in conversationID: String) async -> Bool {
        guard let currentUserID = currentUserProvider()?.id else {
            return false
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty, !trimmedText.isEmpty else {
            return false
        }

        do {
            let response = try await sessionClient.editIMMessage(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID,
                text: trimmedText
            )
            markServerOnline()
            imConversationStore.applyUpdatedMessage(response, currentUserID: currentUserID)
            _ = await reconcileConversationSummaryReadModel(force: true)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func toggleMessageReaction(messageID: String, emoji: String, in conversationID: String) async -> Bool {
        guard let currentUserID = currentUserProvider()?.id else {
            return false
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty, !trimmedEmoji.isEmpty else {
            return false
        }

        do {
            let response = try await sessionClient.toggleIMMessageReaction(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID,
                emoji: trimmedEmoji
            )
            markServerOnline()
            imConversationStore.applyUpdatedMessage(response, currentUserID: currentUserID)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func favoriteMessage(messageID: String, in conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.favoriteIMMessage(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID
            )
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func unfavoriteMessage(messageID: String, in conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.unfavoriteIMMessage(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID
            )
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func deleteMessagesForSelf(messageIDs: [String], in conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = messageIDs.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !trimmedConversationID.isEmpty, !ids.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.deleteIMMessagesForSelf(
                conversationID: trimmedConversationID,
                messageIDs: ids
            )
            markServerOnline()
            imConversationStore.removeMessages(
                ids: Set(ids.map(\.uuidString) + messageIDs),
                from: trimmedConversationID
            )
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func clearConversationForSelf(_ conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.clearIMConversationForSelf(conversationID: trimmedConversationID)
            markServerOnline()
            if let conversation = imConversationStore.conversations.first(where: { $0.id == trimmedConversationID }) {
                let ids = Set(conversation.messages.map(\.id) + conversation.messages.compactMap(\.serverMessageID))
                imConversationStore.removeMessages(ids: ids, from: trimmedConversationID)
            }
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func deleteConversationForSelf(_ conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.deleteIMConversationForSelf(conversationID: trimmedConversationID)
            markServerOnline()
            imConversationStore.removeConversation(id: trimmedConversationID)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func forwardMessages(messageIDs: [String], from conversationID: String, to targetConversationIDs: [String]) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIDs = messageIDs.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let targetIDs = targetConversationIDs.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !trimmedConversationID.isEmpty, !sourceIDs.isEmpty, !targetIDs.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.forwardIMMessages(
                conversationID: trimmedConversationID,
                messageIDs: sourceIDs,
                targetConversationIDs: targetIDs
            )
            markServerOnline()
            _ = await reconcileConversationSummaryReadModel(force: true)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }
}
