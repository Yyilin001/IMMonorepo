import Foundation
import IMV2ActorContracts
import IMV2Core

/// Immutable room turn submitted to a physical-owner preparation collector.
/// Construction conveys no authority; each turn is validated independently by
/// its store, with the absolute original deadline retained in the handle.
public struct V2MessageSendPreparationRequest: Sendable {
    public let commands: [V2MessageSendOperationCommand]
    public let token: V2RoomActivationToken
    public let deadline: ContinuousClock.Instant
    public init(commands: [V2MessageSendOperationCommand], token: V2RoomActivationToken,
                deadline: ContinuousClock.Instant) {
        self.commands = commands
        self.token = token
        self.deadline = deadline
    }
}
