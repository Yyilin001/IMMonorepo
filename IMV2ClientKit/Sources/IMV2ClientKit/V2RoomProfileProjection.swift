import Foundation
import IMV2Core

/// Compact group identity and the latest membership revision observed by this
/// device. It deliberately contains no member list: fan-out never replicates
/// a large roster into every recipient's sync history.
public struct V2ClientRoomProfileProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let title: String
    public let ownerUserID: UserID
    public let deliveryMode: V2GroupDeliveryMode?
    public let membershipRevision: UInt64
    public let createdAt: Date

    init(
        sourceEventID: EventID, roomID: RoomID, title: String,
        ownerUserID: UserID, deliveryMode: V2GroupDeliveryMode?,
        membershipRevision: UInt64, createdAt: Date
    ) {
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.title = title
        self.ownerUserID = ownerUserID
        self.deliveryMode = deliveryMode
        self.membershipRevision = membershipRevision
        self.createdAt = createdAt
    }

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let title: String
            let ownerUserID: String
            let membershipRevision: UInt64
            let deliveryMode: String?
            let createdAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type"; case roomID = "room_id"; case title
                case ownerUserID = "owner_user_id"; case membershipRevision = "membership_revision"; case deliveryMode = "delivery_mode"; case createdAtMilliseconds = "created_at_ms"
            }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        let normalizedTitle = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (record.projectionKind == "room" && payload.eventType == "room.created")
                || (record.projectionKind == "membership" && payload.eventType == "membership_changed"),
              !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= V2CreateGroupRoomCommand.maximumTitleUTF8Bytes,
              !normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              payload.membershipRevision > 0,
              payload.createdAtMilliseconds >= 0
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            sourceEventID = record.sourceEventID
            roomID = try .init(payload.roomID)
            title = normalizedTitle
            ownerUserID = try .init(payload.ownerUserID)
            deliveryMode = try payload.deliveryMode.map {
                guard let mode = V2GroupDeliveryMode(rawValue: $0) else { throw V2ClientProjectionError.invalidMessagePayload }
                return mode
            }
            membershipRevision = payload.membershipRevision
            createdAt = Date(timeIntervalSince1970: TimeInterval(payload.createdAtMilliseconds) / 1_000)
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
