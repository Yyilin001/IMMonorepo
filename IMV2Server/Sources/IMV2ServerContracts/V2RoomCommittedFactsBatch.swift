import IMV2ActorContracts
import IMV2Core

/// Optional in-process acceleration after durable transaction commitment.
/// Plain accepted values are immutable; body encoding and all actor/SQL work
/// belong to the consumer. dirtyHighWatermark requests independent durable
/// repair when a control, unsupported body, conflict or overflow lost facts.
public struct V2RoomCommittedFactsBatch: Equatable, Sendable {
    public let activation: V2RoomActivationToken
    public let messages: [V2AcceptedMessage]
    public let dirtyHighWatermark: UInt64?
    public init(activation: V2RoomActivationToken, messages: [V2AcceptedMessage], dirtyHighWatermark: UInt64?) {
        self.activation = activation; self.messages = messages; self.dirtyHighWatermark = dirtyHighWatermark
    }
}
