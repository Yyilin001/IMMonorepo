import Foundation

/// Ephemeral, viewer/device/room-scoped presentation. Never persist the embedded byte capability.
/// Clients additionally bind it to their local account epoch and visible page lifetime.
public struct V2GroupAvatarPresentation: Equatable, Codable, Sendable {
    public let actorUserID: UserID
    public let deviceID: DeviceID
    public let state: V2GroupAvatarState
    public let membershipRevision: UInt64
    public let resourceGeneration: Int64?
    public let canManage: Bool
    public let avatar: V2ResourceAvatarAccess?
    public let observedAtUnixMilliseconds: Int64
    public let validUntilUnixMilliseconds: Int64
    public let serverNowUnixMilliseconds: Int64
    public var validUntil: Date { V2ResourceTime.date(validUntilUnixMilliseconds) }

    public init(actorUserID: UserID, deviceID: DeviceID, state: V2GroupAvatarState,
                membershipRevision: UInt64, resourceGeneration: Int64?, canManage: Bool,
                avatar: V2ResourceAvatarAccess?, observedAt: Date, validUntil: Date, serverNow: Date) throws {
        try self.init(actorUserID: actorUserID, deviceID: deviceID, state: state,
            membershipRevision: membershipRevision, resourceGeneration: resourceGeneration, canManage: canManage,
            avatar: avatar, observedAtUnixMilliseconds: V2ResourceTime.milliseconds(observedAt),
            validUntilUnixMilliseconds: V2ResourceTime.milliseconds(validUntil),
            serverNowUnixMilliseconds: V2ResourceTime.milliseconds(serverNow))
    }

    private init(actorUserID: UserID, deviceID: DeviceID, state: V2GroupAvatarState,
                 membershipRevision: UInt64, resourceGeneration: Int64?, canManage: Bool,
                 avatar: V2ResourceAvatarAccess?, observedAtUnixMilliseconds: Int64,
                 validUntilUnixMilliseconds: Int64, serverNowUnixMilliseconds: Int64) throws {
        let duration = validUntilUnixMilliseconds.subtractingReportingOverflow(observedAtUnixMilliseconds)
        guard actorUserID.uuidValue != nil, deviceID.uuidValue != nil,
              membershipRevision <= UInt64(Int64.max), !duration.overflow,
              duration.partialValue > 0, duration.partialValue <= 300_000,
              observedAtUnixMilliseconds <= serverNowUnixMilliseconds,
              serverNowUnixMilliseconds < validUntilUnixMilliseconds else {
            throw V2ResourceValidationError.invalidPresentationLease
        }
        if let media = state.mediaID {
            guard let avatar, avatar.mediaID == media, (resourceGeneration ?? 0) > 0,
                  avatar.plan.expiresAtUnixMilliseconds > serverNowUnixMilliseconds,
                  avatar.plan.expiresAtUnixMilliseconds <= validUntilUnixMilliseconds else {
                throw V2ResourceValidationError.invalidPresentationLease
            }
            let byteLifetime = avatar.plan.expiresAtUnixMilliseconds.subtractingReportingOverflow(observedAtUnixMilliseconds)
            guard !byteLifetime.overflow, byteLifetime.partialValue > 0, byteLifetime.partialValue <= 120_000 else {
                throw V2ResourceValidationError.invalidPresentationLease
            }
        } else {
            guard avatar == nil, resourceGeneration == nil else { throw V2ResourceValidationError.invalidPresentationLease }
        }
        self.actorUserID = actorUserID; self.deviceID = deviceID; self.state = state
        self.membershipRevision = membershipRevision; self.resourceGeneration = resourceGeneration
        self.canManage = canManage; self.avatar = avatar
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
        self.validUntilUnixMilliseconds = validUntilUnixMilliseconds
        self.serverNowUnixMilliseconds = serverNowUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case actorUserID, deviceID, state, membershipRevision, resourceGeneration, canManage, avatar
        case observedAtUnixMilliseconds, validUntilUnixMilliseconds, serverNowUnixMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actorUserID: values.decode(UserID.self, forKey: .actorUserID),
            deviceID: values.decode(DeviceID.self, forKey: .deviceID), state: values.decode(V2GroupAvatarState.self, forKey: .state),
            membershipRevision: values.decode(UInt64.self, forKey: .membershipRevision),
            resourceGeneration: values.decodeIfPresent(Int64.self, forKey: .resourceGeneration),
            canManage: values.decode(Bool.self, forKey: .canManage), avatar: values.decodeIfPresent(V2ResourceAvatarAccess.self, forKey: .avatar),
            observedAtUnixMilliseconds: values.decode(Int64.self, forKey: .observedAtUnixMilliseconds),
            validUntilUnixMilliseconds: values.decode(Int64.self, forKey: .validUntilUnixMilliseconds),
            serverNowUnixMilliseconds: values.decode(Int64.self, forKey: .serverNowUnixMilliseconds))
    }
}
