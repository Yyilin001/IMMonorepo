import Foundation
import IMV2Core
@testable import IMV2ServerContracts

enum AuthorPresentationMessageFixtures {
    /// Uses the production full-replacement contract. The editing actor is
    /// deliberately different so a hint cannot substitute it for the sender.
    static func edited(room: RoomID, author: UserID) throws -> Data {
        let sourceID = UUID(), source = EventID(uuid: sourceID)
        let draft = V2AcceptedMessageDraft(messageID: .init(uuid: UUID()), roomID: room, roomSequence: 1,
            senderUserID: author, clientMessageID: .init(uuid: UUID()), text: "original", entities: [],
            createdAt: Date(timeIntervalSince1970: 1))
        let message = draft.materialized(mediaPresentations: [], sourceEventID: source,
            acceptedMembershipRevision: 1, directRecipientUserID: .init(uuid: UUID()),
            projectionCreatedAtUnixMilliseconds: 1_000)
        let state = try V2MessageProjectionState(accepted: message, forwardedFromMessageID: nil,
            forwardedFromUserID: nil).applyingEdit(revision: 2, text: "edited", entities: [])
        let replacement = try V2MessageEditReplacement(state: state,
            acceptance: .init(eventID: sourceID, membershipRevision: 1, roomSequence: 1))
        return try JSONSerialization.data(withJSONObject: [
            "event_type": "message.edited", "room_id": room.rawValue, "room_sequence": 2,
            "message_id": draft.messageID.rawValue, "message_revision": 2,
            "text": "edited", "entities": [], "actor_user_id": UUID().uuidString,
            "replacement": JSONSerialization.jsonObject(with: Data(replacement.encodedJSON().utf8))
        ])
    }
}
