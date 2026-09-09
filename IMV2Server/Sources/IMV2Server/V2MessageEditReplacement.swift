import Foundation
import IMV2Core

/// An authorized complete edit value. The enclosing room event still owns
/// mutation ordering; this value retains the immutable acceptance identity.
struct V2MessageEditReplacement: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let acceptedEventID: UUID
    let acceptedMembershipRevision: Int64
    let state: V2MessageProjectionState

    init(state: V2MessageProjectionState, delivery: V2MessageAcceptedDelivery) throws {
        guard state.messageRevision > 1, !state.isWithdrawn,
              state.acceptedRoomSequence == delivery.roomSequence,
              delivery.membershipRevision >= 0
        else { throw V2MessageProjectionStateError.invalidPayload }
        schemaVersion = 1
        acceptedEventID = delivery.eventID
        acceptedMembershipRevision = delivery.membershipRevision
        self.state = state
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Presence is authoritative: a malformed value must never become a delta.
    static func decodeIfPresent(in object: [String: Any]) throws -> Self? {
        guard let raw = object["replacement"] else { return nil }
        do {
            struct Header: Decodable {
                let message_id: String; let room_id: String; let message_revision: UInt64
                let room_sequence: UInt64; let text: String; let entities: [V2MessageEntity]
            }
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: JSONSerialization.data(withJSONObject: object))
            let value = try decoder.decode(Self.self, from: JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]))
            guard value.schemaVersion == 1, value.acceptedMembershipRevision >= 0,
                  !value.state.isWithdrawn, value.state.messageRevision > 1,
                  value.state.messageID == (try MessageID(header.message_id)),
                  value.state.roomID == (try RoomID(header.room_id)),
                  header.message_revision == value.state.messageRevision,
                  header.room_sequence > value.state.acceptedRoomSequence,
                  header.text == value.state.text, header.entities == value.state.entities
            else { throw V2MessageProjectionStateError.invalidPayload }
            return value
        } catch { throw V2MessageProjectionStateError.invalidPayload }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        acceptedEventID = try c.decode(UUID.self, forKey: .acceptedEventID)
        acceptedMembershipRevision = try c.decode(Int64.self, forKey: .acceptedMembershipRevision)
        let stateDecoder = try c.superDecoder(forKey: .state)
        enum ReferenceKeys: String, CodingKey, CaseIterable {
            case reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id
        }
        let fields = try stateDecoder.container(keyedBy: ReferenceKeys.self)
        guard ReferenceKeys.allCases.allSatisfy(fields.contains) else { throw V2MessageProjectionStateError.invalidPayload }
        state = try V2MessageProjectionState(from: stateDecoder)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", acceptedEventID = "accepted_event_id"
        case acceptedMembershipRevision = "accepted_membership_revision", state
    }
}
