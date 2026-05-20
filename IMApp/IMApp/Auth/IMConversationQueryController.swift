import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func reloadIMConversations(force: Bool = true, kind: IMConversationKind? = nil) async {
        await conversationRuntimeController.reloadConversations(force: force, kind: kind)
    }

    func loadMoreIMConversationSummariesIfNeeded(
        anchorConversationID: String?,
        kind: IMConversationKind? = nil
    ) async {
        await conversationRuntimeController.loadMoreConversationSummariesIfNeeded(
            anchorConversationID: anchorConversationID,
            kind: kind
        )
    }

    func jumpToReferencedIMMessage(_ messageID: String, in conversationID: String) async {
        await conversationRuntimeController.jumpToReferencedMessage(messageID, in: conversationID)
    }

    func jumpToIMMessage(_ messageID: String, in conversationID: String) async {
        await conversationRuntimeController.jumpToReferencedMessage(messageID, in: conversationID)
    }

    func searchIMConversationMessages(
        in conversationID: String,
        query: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> IMConversationMessageSearchPageResponseBody? {
        await conversationRuntimeController.searchConversationMessages(
            in: conversationID,
            query: query,
            cursor: cursor,
            limit: limit
        )
    }

    func fetchIMFavorites(
        conversationID: UUID? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> IMFavoritePageResponseBody? {
        do {
            let page = try await sessionClient.fetchIMFavorites(
                conversationID: conversationID,
                cursor: cursor,
                limit: limit
            )
            markServerOnline()
            return page
        } catch {
            await handleIMDataRequestError(error)
            return nil
        }
    }

    func openIMConversation(_ conversationID: String) async {
        guard currentUser != nil else {
            return
        }

        imConversationStore.openConversation(id: conversationID)
        scheduleIMConversationCachePersist()
        await conversationRuntimeController.loadConversationMembers(for: conversationID)
        await conversationRuntimeController.loadMessagesIfNeeded(for: conversationID)
        await conversationRuntimeController.loadReceiptSummary(for: conversationID)
        await conversationRuntimeController.syncConversationAfterOpen(conversationID)
    }

    func loadIMConversationMembers(conversationID: String, query: String = "") async {
        await conversationRuntimeController.loadConversationMembers(
            for: conversationID,
            query: query,
            reset: true
        )
    }

    func loadMoreIMConversationMembers(conversationID: String) async {
        await conversationRuntimeController.loadMoreConversationMembers(for: conversationID)
    }

    func loadIMReceiptSummary(conversationID: String) async {
        await conversationRuntimeController.loadReceiptSummary(for: conversationID)
    }


    func refreshIMConversationSummaryReadModelIfNeeded() async {
        await conversationRuntimeController.refreshConversationSummaryReadModelIfNeeded()
    }

    func loadOlderIMMessages() async {
        await conversationRuntimeController.loadOlderMessages()
    }
}
