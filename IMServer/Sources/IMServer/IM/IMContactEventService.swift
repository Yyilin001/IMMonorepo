import Foundation
import Vapor

struct IMContactEventService {
    let app: Application

    func publishRequestEvent(
        eventType: IMTCPContactEventType,
        request: FriendRequestResponse,
        recipientUserIDs: [UUID],
        actorUserID: UUID? = nil
    ) async {
        let uniqueRecipientUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        let timestamp = Date()

        for recipientUserID in uniqueRecipientUserIDs {
            await app.gatewaySessionService.sendContactEvent(
                IMTCPContactEventPayload(
                    eventType: eventType,
                    request: request,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: actorUserID,
                    serverTimestamp: timestamp
                ),
                toUserID: recipientUserID
            )
        }
    }

    func publishAccepted(
        request: FriendRequestResponse,
        contactByRecipientUserID: [UUID: ContactResponse],
        actorUserID: UUID? = nil
    ) async {
        let timestamp = Date()

        for recipientUserID in contactByRecipientUserID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            await app.gatewaySessionService.sendContactEvent(
                IMTCPContactEventPayload(
                    eventType: .friendRequestAccepted,
                    request: request,
                    contact: contactByRecipientUserID[recipientUserID],
                    contactUserID: nil,
                    actorUserID: actorUserID,
                    serverTimestamp: timestamp
                ),
                toUserID: recipientUserID
            )
        }
    }

    func publishContactRemoved(
        recipientUserID: UUID,
        contactUserID: UUID,
        actorUserID: UUID? = nil
    ) async {
        await app.gatewaySessionService.sendContactEvent(
            IMTCPContactEventPayload(
                eventType: .contactRemoved,
                request: nil,
                contact: nil,
                contactUserID: contactUserID,
                actorUserID: actorUserID,
                serverTimestamp: Date()
            ),
            toUserID: recipientUserID
        )
    }
}
