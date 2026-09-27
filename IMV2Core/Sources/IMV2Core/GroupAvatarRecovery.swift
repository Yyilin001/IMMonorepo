import Foundation

public struct V2GroupAvatarRecoveryRequest: Equatable, Codable, Sendable {
    public enum Action: String, Codable, Sendable { case query, closeIfAbsent }
    public let command: V2GroupAvatarCommand
    public let action: Action
    public init(command: V2GroupAvatarCommand, action: Action) { self.command = command; self.action = action }
}

public enum V2GroupAvatarRecoveryResult: Equatable, Codable, Sendable {
    case committed(V2GroupAvatarChange)
    case closed
    case unresolved
    case idempotencyConflict
}

/// A negative result is bound to the original command, just like its positive receipt.
public struct V2GroupAvatarRecoveryResponse: Equatable, Codable, Sendable {
    public let actorUserID: UserID
    public let deviceID: DeviceID
    public let request: V2GroupAvatarRecoveryRequest
    public let result: V2GroupAvatarRecoveryResult
    public init(actorUserID: UserID, deviceID: DeviceID, request: V2GroupAvatarRecoveryRequest, result: V2GroupAvatarRecoveryResult) throws {
        guard actorUserID.uuidValue != nil, deviceID.uuidValue != nil else { throw V2CoreError.invalidIdentifier }
        if case .committed(let change) = result {
            _ = try V2GroupAvatarCommandResponse(actorUserID: actorUserID, deviceID: deviceID, command: request.command, outcome: .committed(change))
        }
        guard request.action != .closeIfAbsent || result != .unresolved else { throw V2RevisionValidationError.outOfRange }
        self.actorUserID = actorUserID; self.deviceID = deviceID; self.request = request; self.result = result
    }
    private enum CodingKeys: String, CodingKey { case actorUserID, deviceID, request, result }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actorUserID: values.decode(UserID.self, forKey: .actorUserID),
                      deviceID: values.decode(DeviceID.self, forKey: .deviceID),
                      request: values.decode(V2GroupAvatarRecoveryRequest.self, forKey: .request),
                      result: values.decode(V2GroupAvatarRecoveryResult.self, forKey: .result))
    }
}
