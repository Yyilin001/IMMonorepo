import Foundation

/// A single exact-handle discovery result. This permission is independent of
/// relationship/room presentation leases and never authorizes avatar access.
/// Keep it in memory for the active discovery page only.
public struct V2PublicIdentityResolution: Equatable, Codable, Sendable {
    public static let maximumLifetimeMilliseconds: Int64 = 60_000
    public let identity: V2PublicIdentity
    public let actorUserID: UserID
    public let deviceID: DeviceID
    public let observedAtUnixMilliseconds: Int64
    public let validUntilUnixMilliseconds: Int64
    public let serverNowUnixMilliseconds: Int64

    public init(identity: V2PublicIdentity, actorUserID: UserID, deviceID: DeviceID,
                observedAt: Date, validUntil: Date, serverNow: Date) throws {
        try self.init(identity: identity, actorUserID: actorUserID, deviceID: deviceID,
            observedAtUnixMilliseconds: V2ResourceTime.milliseconds(observedAt),
            validUntilUnixMilliseconds: V2ResourceTime.milliseconds(validUntil),
            serverNowUnixMilliseconds: V2ResourceTime.milliseconds(serverNow))
    }

    private init(identity: V2PublicIdentity, actorUserID: UserID, deviceID: DeviceID,
                 observedAtUnixMilliseconds: Int64, validUntilUnixMilliseconds: Int64,
                 serverNowUnixMilliseconds: Int64) throws {
        let lifetime = validUntilUnixMilliseconds.subtractingReportingOverflow(observedAtUnixMilliseconds)
        guard !lifetime.overflow, lifetime.partialValue > 0,
              lifetime.partialValue <= Self.maximumLifetimeMilliseconds,
              observedAtUnixMilliseconds <= serverNowUnixMilliseconds,
              serverNowUnixMilliseconds < validUntilUnixMilliseconds,
              try V2PublicHandle(identity.handle.rawValue) == identity.handle
        else { throw V2ResourceValidationError.invalidPresentationLease }
        self.identity = try .init(userID: identity.userID, handle: identity.handle,
            displayName: identity.displayName, accountKind: identity.accountKind)
        self.actorUserID = actorUserID
        self.deviceID = deviceID
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
        self.validUntilUnixMilliseconds = validUntilUnixMilliseconds
        self.serverNowUnixMilliseconds = serverNowUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case identity, actorUserID, deviceID, observedAtUnixMilliseconds, validUntilUnixMilliseconds, serverNowUnixMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: values.decode(V2PublicIdentity.self, forKey: .identity),
            actorUserID: values.decode(UserID.self, forKey: .actorUserID),
            deviceID: values.decode(DeviceID.self, forKey: .deviceID),
            observedAtUnixMilliseconds: values.decode(Int64.self, forKey: .observedAtUnixMilliseconds),
            validUntilUnixMilliseconds: values.decode(Int64.self, forKey: .validUntilUnixMilliseconds),
            serverNowUnixMilliseconds: values.decode(Int64.self, forKey: .serverNowUnixMilliseconds))
    }
}
