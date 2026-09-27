import Foundation

/// A reply to one frozen command. Only `committed` proves a durable result.
/// Other outcomes describe this attempt; they do not close an older in-flight attempt.
public struct V2GroupAvatarCommandResponse: Equatable, Codable, Sendable {
    public enum Outcome: Equatable, Codable, Sendable {
        case committed(V2GroupAvatarChange)
        case revisionConflict
        case idempotencyConflict
        case resourceUnavailable
        case forbidden
    }

    public let actorUserID: UserID
    public let deviceID: DeviceID
    public let command: V2GroupAvatarCommand
    public let outcome: Outcome

    public init(actorUserID: UserID, deviceID: DeviceID, command: V2GroupAvatarCommand, outcome: Outcome) throws {
        guard actorUserID.uuidValue != nil, deviceID.uuidValue != nil else { throw V2CoreError.invalidIdentifier }
        if case .committed(let change) = outcome {
            guard change.state.roomID == command.roomID, change.state.mediaID == command.mutation.mediaID,
                  change.state.revision == command.expectedRevision + 1 else { throw V2RevisionValidationError.outOfRange }
        }
        self.actorUserID = actorUserID; self.deviceID = deviceID
        self.command = command; self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey { case actorUserID, deviceID, command, outcome }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actorUserID: values.decode(UserID.self, forKey: .actorUserID),
                      deviceID: values.decode(DeviceID.self, forKey: .deviceID),
                      command: values.decode(V2GroupAvatarCommand.self, forKey: .command),
                      outcome: values.decode(Outcome.self, forKey: .outcome))
    }
}
