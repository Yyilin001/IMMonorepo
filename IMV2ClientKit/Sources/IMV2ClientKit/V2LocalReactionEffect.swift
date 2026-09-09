import Crypto
import Foundation
import IMV2Core

/// Room sequence is the shared ordering authority. Personal-stream sequence
/// numbers are unrelated and must never be substituted for a missing version.
struct V2LocalReactionEffect {
    let sourceEventID: EventID
    let reaction: V2ClientMessageReaction
    let action: V2MessageReactionAction
    let roomSequence: Int64
    let digest: Data

    init(record: V2ClientSyncRecord) throws {
        struct Version: Decodable { let room_sequence: UInt64 }
        guard let version = try? JSONDecoder().decode(Version.self, from: record.payload),
              let sequence = Int64(exactly: version.room_sequence), sequence > 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        reaction = try .init(record: record)
        action = try reaction.action(record: record)
        sourceEventID = record.sourceEventID
        roomSequence = sequence
        struct Canonical: Encodable {
            let version = 1
            let room: String; let message: String; let actor: String
            let reaction: String; let action: String; let sequence: Int64
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        digest = Data(SHA256.hash(data: try encoder.encode(Canonical(room: reaction.roomID.rawValue, message: reaction.messageID.rawValue, actor: reaction.actorUserID.rawValue, reaction: reaction.reaction, action: action.rawValue, sequence: sequence))))
    }
}
