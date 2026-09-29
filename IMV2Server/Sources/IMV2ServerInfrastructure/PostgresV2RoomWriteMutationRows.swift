import IMV2ServerApplication
import IMV2ServerContracts
// 供 Store 借用事务上的逐条追加和私聊房间日志批量追加共用。
// 结果数量检查仍由各自的写入路径负责。
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
