import Foundation

public struct V2MessageOperationAcceptance: Equatable, Codable, Sendable {
    public let messageID: MessageID
    public let roomSequence: UInt64
    public init(messageID: MessageID, roomSequence: UInt64) throws {
        guard roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2CoreError.invalidPositiveValue }
        self.messageID = messageID; self.roomSequence = roomSequence
    }
    private enum CodingKeys: String, CodingKey { case messageID, roomSequence }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: values.decode(MessageID.self, forKey: .messageID), roomSequence: values.decode(UInt64.self, forKey: .roomSequence))
    }
}
