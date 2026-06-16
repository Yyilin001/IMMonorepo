import Vapor

struct IMConversationCommandSideEffects {
    let app: Application

    init(app: Application) {
        self.app = app
    }

    func projectInlineOutboxIfAllowed() async throws {
        try await InlineOutboxProjectionRuntime(app: app).flushIfAllowed()
    }

    func invalidateMemberCacheEverywhere(conversationID: UUID) async {
        await app.conversationMemberCache.invalidate(conversationID: conversationID)
        await app.directConversationPairCache.invalidate(conversationID: conversationID)
        await app.conversationMediaAccessCache.invalidate(conversationID: conversationID)
        await ConversationRecipientSetExistenceCache.shared.invalidateConversation(conversationID)

        let configuration = app.commandOwnerRoutingConfiguration
        guard configuration.isEnabled,
              let sharedSecret = configuration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sharedSecret.isEmpty
        else {
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "X-IM-Internal-Secret", value: sharedSecret)

        for node in configuration.nodes where node.id != configuration.nodeID {
            do {
                _ = try await app.client.post(
                    URI(string: "\(node.baseURL)/internal/im/conversations/\(conversationID.uuidString)/member-cache/invalidate"),
                    headers: headers
                )
            } catch {
                app.logger.warning(
                    "Failed to invalidate remote IM conversation member cache",
                    metadata: [
                        "conversationID": .string(conversationID.uuidString),
                        "target_node_id": .string(node.id),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }
    }
}
