// Shared by scalar and direct-room-log batch append on the Store's borrowed
// transaction. Cardinality checks remain with their respective write paths.
struct RoomLogMessageMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64
    let reviewCount: Int64
    let mediaCount: Int64
    let mentionCount: Int64
    let eventCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
        case reviewCount = "review_count"
        case mediaCount = "media_count"
        case mentionCount = "mention_count"
        case eventCount = "event_count"
    }
}
