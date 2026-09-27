import Foundation

/// 原操作的身份和不可变指纹；权限身份由认证会话取得。
public struct V2MessageOperationRecoveryRequest: Equatable, Codable, Sendable {
    public enum Action: String, Codable, Sendable { case query, closeIfAbsent }
    public let roomID: RoomID
    public let clientMessageID: ClientMessageID
    public let fingerprint: V2SendMessageFingerprint
    public let action: Action
    public init(roomID: RoomID, clientMessageID: ClientMessageID, fingerprint: V2SendMessageFingerprint, action: Action) {
        self.roomID = roomID; self.clientMessageID = clientMessageID; self.fingerprint = fingerprint; self.action = action
    }
}

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

/// unresolved 仅表示本次尚未找到；只有 closed 证明 owner 已永久禁止原操作未来接受。
public enum V2MessageOperationRecoveryResult: Equatable, Codable, Sendable {
    case accepted(V2MessageOperationAcceptance)
    case closed
    case unresolved
    case fingerprintConflict
}
