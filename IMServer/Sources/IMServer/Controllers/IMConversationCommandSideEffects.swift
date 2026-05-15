import Vapor

struct IMConversationCommandSideEffects {
    let app: Application
    private let eventService: IMConversationEventService

    init(app: Application, eventService: IMConversationEventService? = nil) {
        self.app = app
        self.eventService = eventService ?? IMConversationEventService(app: app)
    }

    func projectInlineOutboxIfAllowed() async throws {
        try await InlineOutboxProjectionRuntime(app: app).flushIfAllowed()
    }

    func publish(
        eventType: IMTCPConversationEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID],
        message: IMMessageResponse? = nil,
        actorUserID: UUID? = nil
    ) async {
        await eventService.publish(
            eventType: eventType,
            conversationID: conversationID,
            recipientUserIDs: recipientUserIDs,
            message: message,
            actorUserID: actorUserID
        )
    }

    func publishRemovedForSelf(
        conversation: IMConversationResponse,
        recipientUserID: UUID,
        actorUserID: UUID? = nil
    ) async {
        await eventService.publishRemovedForSelf(
            conversation: conversation,
            recipientUserID: recipientUserID,
            actorUserID: actorUserID
        )
    }

    func sendLatestSystemMessageIfNeeded(
        in conversationID: UUID,
        recipientUserIDs: [UUID]
    ) async {
        guard !recipientUserIDs.isEmpty else {
            return
        }

        do {
            guard let latestMessage = try await QueryReadModelFacade(app: app).latestMessage(in: conversationID) else {
                return
            }

            guard case .system = latestMessage.content else {
                return
            }

            await app.gatewaySessionService.sendMessage(
                IMTCPMessagePayload(
                    clientMessageID: latestMessage.clientMessageID,
                    messageID: latestMessage.id.uuidString,
                    conversationID: conversationID.uuidString,
                    senderUserID: latestMessage.senderUserID,
                    serverSequence: UInt64(latestMessage.serverSequence),
                    serverTimestamp: latestMessage.createdAt,
                    content: latestMessage.content,
                    derivedState: latestMessage.content.aggregate.derivedState
                ),
                toUserIDs: recipientUserIDs
            )
        } catch {
            app.logger.warning(
                "Failed to send latest IM system message",
                metadata: [
                    "conversationID": .string(conversationID.uuidString),
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    func invalidateMemberCacheEverywhere(conversationID: UUID) async {
        await app.conversationMemberCache.invalidate(conversationID: conversationID)
        await app.directConversationPairCache.invalidate(conversationID: conversationID)
        await app.conversationMediaAccessCache.invalidate(conversationID: conversationID)

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
