import Foundation
import IMV2Core

/// Sent only through the fixed-placement bootstrap port, never an unknown RoomRef.
public struct V2ProvenGroupBootstrap: Codable, Equatable, Sendable {
    public let intent: V2GroupCreationIntent
    public let placement: V2ActorGroupCreationIntentWire
    public init(intent: V2GroupCreationIntent, placement: V2ActorGroupCreationIntentWire) {
        self.intent = intent; self.placement = placement
    }
}
