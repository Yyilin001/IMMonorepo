import Foundation
import IMV2Core

/// An immutable, privacy-safe moderation fact received through user sync. It
/// intentionally carries identifiers and a bounded action only: report text
/// and the audit reason remain in the protected server-side audit store.
public struct V2ClientModerationProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let actorUserID: UserID
    public let targetUserID: UserID
    public let muteUntil: Date
    public let createdAt: Date

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let roomSequence: UInt64
            let actorUserID: String
            let targetUserID: String
            let muteUntilMilliseconds: Int64
            let serverCreatedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
                case roomID = "room_id"
                case roomSequence = "room_sequence"
                case actorUserID = "actor_user_id"
                case targetUserID = "target_user_id"
                case muteUntilMilliseconds = "mute_until_ms"
                case serverCreatedAtMilliseconds = "server_created_at_ms"
            }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard record.projectionKind == "moderation", payload.eventType == "member.muted",
              payload.roomSequence > 0, payload.muteUntilMilliseconds > payload.serverCreatedAtMilliseconds,
              payload.serverCreatedAtMilliseconds >= 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            sourceEventID = record.sourceEventID
            roomID = try .init(payload.roomID)
            roomSequence = payload.roomSequence
            actorUserID = try .init(payload.actorUserID)
            targetUserID = try .init(payload.targetUserID)
            muteUntil = Date(timeIntervalSince1970: TimeInterval(payload.muteUntilMilliseconds) / 1_000)
            createdAt = Date(timeIntervalSince1970: TimeInterval(payload.serverCreatedAtMilliseconds) / 1_000)
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}
