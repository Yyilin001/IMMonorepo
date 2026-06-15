import Crypto
import Foundation

func imLightweightMessageCreatedHintEventID(for eventID: UUID) -> UUID {
    let input = Data("im.realtime.message-created-hint:\(eventID.uuidString.lowercased())".utf8)
    let digest = SHA256.hash(data: input)
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
