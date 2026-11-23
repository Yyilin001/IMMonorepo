import IMV2ActorContracts
import IMV2Core

/// A committed ordinary message can still advance its authorized subscription
/// stream when the bounded mailbox has no space for another live body.
public struct V2CommittedRoomMessageHeader: Equatable, Sendable {
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let sourceEventID: EventID
    public let membershipRevision: UInt64

    public init?(_ message: V2AcceptedMessage) {
        guard let sourceEventID = message.sourceEventID, let revision = message.acceptedMembershipRevision,
              revision <= UInt64(Int64.max), message.media.isEmpty, message.mediaPresentations.isEmpty,
              message.mentions.isEmpty, message.entities.isEmpty, message.replyTo == nil else { return nil }
        roomID = message.roomID
        roomSequence = message.roomSequence
        self.sourceEventID = sourceEventID
        membershipRevision = revision
    }
}

public enum V2CommittedRoomMessageFact: Equatable, Sendable {
    case body(V2AcceptedMessage)
    case header(V2CommittedRoomMessageHeader)

    public var roomID: RoomID {
        switch self {
        case .body(let message): message.roomID
        case .header(let header): header.roomID
        }
    }

    public var roomSequence: UInt64 {
        switch self {
        case .body(let message): message.roomSequence
        case .header(let header): header.roomSequence
        }
    }
}

public struct V2RoomCommittedFactsBatch: Equatable, Sendable {
    public let activation: V2RoomActivationToken
    public let facts: [V2CommittedRoomMessageFact]
    public let dirtyHighWatermark: UInt64?

    public init(activation: V2RoomActivationToken, facts: [V2CommittedRoomMessageFact], dirtyHighWatermark: UInt64?) {
        self.activation = activation
        self.facts = facts
        self.dirtyHighWatermark = dirtyHighWatermark
    }
}
