import Foundation
import IMV2Core

/// A durable, viewer-private timeline entry. It is intentionally not a
/// message: it cannot be replied to, read-receipted, edited, reacted to or
/// forwarded. The server stores only product-safe reason codes here.
public struct V2ClientTimelineActivityProjection: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case directMessageRestricted = "direct_message_restricted"
        case systemAccountReadOnly = "system_account_read_only"
    }

    public let sourceEventID: EventID
    public let roomID: RoomID
    public let timelineSequence: UInt64
    public let kind: Kind
    public let createdAt: Date

    public var id: String { sourceEventID.rawValue }

    public init(sourceEventID: EventID, roomID: RoomID, timelineSequence: UInt64, kind: Kind, createdAt: Date) {
        precondition(timelineSequence > 0)
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.timelineSequence = timelineSequence
        self.kind = kind
        self.createdAt = createdAt
    }

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let timelineSequence: UInt64
            let serverCreatedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"
                case roomID = "room_id"
                case timelineSequence = "timeline_sequence"
                case serverCreatedAtMilliseconds = "server_created_at_ms"
            }
        }
        guard record.projectionKind == "timeline_activity",
              let wire = try? JSONDecoder().decode(Wire.self, from: record.payload),
              wire.timelineSequence > 0,
              wire.serverCreatedAtMilliseconds >= 0,
              let kind = Kind(rawValue: wire.eventType)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            self.init(
                sourceEventID: record.sourceEventID,
                roomID: try .init(wire.roomID),
                timelineSequence: wire.timelineSequence,
                kind: kind,
                createdAt: Date(timeIntervalSince1970: TimeInterval(wire.serverCreatedAtMilliseconds) / 1_000)
            )
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}

/// A server-authoritative composer capability. It is a private projection so
/// it never leaks a counterpart's block or privacy configuration.
public struct V2ClientDirectSendingCapability: Equatable, Sendable {
    public let roomID: RoomID
    public let canSend: Bool
    public let updatedAt: Date

    public init(roomID: RoomID, canSend: Bool, updatedAt: Date) {
        self.roomID = roomID
        self.canSend = canSend
        self.updatedAt = updatedAt
    }

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let roomID: String
            let canSend: Bool
            let updatedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id"
                case canSend = "can_send"
                case updatedAtMilliseconds = "updated_at_ms"
            }
        }
        guard record.projectionKind == "direct_sending_capability",
              let wire = try? JSONDecoder().decode(Wire.self, from: record.payload),
              wire.updatedAtMilliseconds >= 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            self.init(roomID: try .init(wire.roomID), canSend: wire.canSend, updatedAt: Date(timeIntervalSince1970: TimeInterval(wire.updatedAtMilliseconds) / 1_000))
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}
