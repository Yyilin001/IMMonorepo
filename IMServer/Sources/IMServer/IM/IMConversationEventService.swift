import Fluent
import Foundation
import Vapor

struct IMConversationEventService {
    let app: Application
    let db: any Database

    func publish(
        eventType: IMTCPConversationEventType,
        conversationID: UUID,
        recipientUserIDs: [UUID],
        actorUserID: UUID? = nil
    ) async {
        let uniqueRecipientUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueRecipientUserIDs.isEmpty else {
            return
        }

        let timestamp = Date()
        let service = IMConversationService(db: db)

        for recipientUserID in uniqueRecipientUserIDs {
            do {
                let conversation = try await service.conversationSummary(
                    conversationID: conversationID,
                    for: recipientUserID
                )
                await app.imConnectionRegistry.sendConversationEvent(
                    IMTCPConversationEventPayload(
                        eventType: eventType,
                        conversation: conversation,
                        actorUserID: actorUserID,
                        serverTimestamp: timestamp
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
        await app.imConnectionRegistry.sendConversationEvent(
            IMTCPConversationEventPayload(
                eventType: .conversationRemovedForSelf,
                conversation: conversation,
                actorUserID: actorUserID,
                serverTimestamp: Date()
            ),
            toUserID: recipientUserID
        )
    }
}
