import Foundation
import Vapor

struct IMConversationEventService {
    let app: Application
    let strongReadService: ConversationStrongReadService

    init(app: Application, strongReadService: ConversationStrongReadService? = nil) {
        self.app = app
        self.strongReadService = strongReadService ?? IMConversationService.strongRead(app: app)
    }

    func publish(
        eventType: IMTCPConversationEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID],
        message: IMMessageResponse? = nil,
        actorUserID: UUID? = nil,
        messageIDs: [UUID] = [],
        favoriteChangedMessageID: UUID? = nil,
        isFavorited: Bool? = nil,
        visibilityAction: ConversationVisibilityAction? = nil
    ) async {
        let uniqueRecipientUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueRecipientUserIDs.isEmpty else {
            return
        }

        let timestamp = Date()

        for recipientUserID in uniqueRecipientUserIDs {
            do {
                let conversation = try await strongReadService.conversationSummary(
                    conversationID: conversationID,
                    for: recipientUserID
                )
                await app.gatewaySessionService.sendConversationEvent(
                    IMTCPConversationEventPayload(
                        eventType: eventType,
                        conversation: conversation,
                        message: message,
                        actorUserID: actorUserID,
                        serverTimestamp: timestamp,
                        messageIDs: messageIDs,
                        favoriteChangedMessageID: favoriteChangedMessageID,
                        isFavorited: isFavorited,
                        visibilityAction: visibilityAction
                    ),
                    toUserID: recipientUserID
                )
            } catch let error as any AbortError where error.status == .notFound {
                continue
            } catch {
                app.logger.warning(
                    "Failed to publish IM conversation event",
                    metadata: [
                        "eventType": .string(eventType.rawValue),
                        "conversationID": .string(conversationID.uuidString),
                        "recipientUserID": .string(recipientUserID.uuidString),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }
    }

    func publishRemovedForSelf(
        conversation: IMConversationResponse,
        recipientUserID: UUID,
        actorUserID: UUID? = nil
    ) async {
        await app.gatewaySessionService.sendConversationEvent(
            IMTCPConversationEventPayload(
                eventType: .conversationRemovedForSelf,
                conversation: conversation,
                message: nil,
                actorUserID: actorUserID,
                serverTimestamp: Date()
            ),
            toUserID: recipientUserID
        )
    }
}
