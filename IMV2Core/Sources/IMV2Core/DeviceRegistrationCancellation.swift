import Foundation

/// Client-held authority to cancel one registration. It cannot authenticate,
/// refresh, or cancel a different registration, and is saved before issuance.
public struct V2DeviceRegistrationCancellationProof: Equatable, Sendable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let rawValue: String
    private static let prefix = "imv2-cancel-registration-v1."

    public init(rawValue: String) throws {
        guard rawValue.hasPrefix(Self.prefix) else { throw ValidationError.invalidProof }
        let suffix = String(rawValue.dropFirst(Self.prefix.count))
        // Reuse the canonical 256-bit encoding validator, with a distinct
        // purpose prefix so these values cannot be used as session capability.
        guard (try? V2DeviceRevocationCredential(rawValue: "imv2-revoke-v1." + suffix)) != nil else {
            throw ValidationError.invalidProof
        }
        self.rawValue = rawValue
    }

    public static func generate() -> Self {
        let suffix = V2DeviceRevocationCredential.generate().rawValue.dropFirst("imv2-revoke-v1.".count)
        return Self(validatedValue: prefix + suffix)
    }

    private init(validatedValue: String) { rawValue = validatedValue }
    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
    public var description: String { "V2DeviceRegistrationCancellationProof(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public enum ValidationError: Error, Equatable, Sendable { case invalidProof }
}

/// Immutable identity of the cancellation authority. Every retry must retain
/// all four fields. The server additionally bounds the future issue deadline.
public struct V2DeviceRegistrationCancellation: Equatable, Sendable, Codable {
    public let deviceID: DeviceID
    public let operationID: UUID
    public let proof: V2DeviceRegistrationCancellationProof
    public let issueBeforeMilliseconds: Int64

    public init(deviceID: DeviceID, operationID: UUID, proof: V2DeviceRegistrationCancellationProof,
                issueBeforeMilliseconds: Int64) throws {
        guard let device = UUID(uuidString: deviceID.rawValue),
              (1...253_402_300_799_000).contains(issueBeforeMilliseconds) else { throw ValidationError.invalidRequest }
        self.deviceID = try DeviceID(device.uuidString)
        self.operationID = operationID
        self.proof = proof
        self.issueBeforeMilliseconds = issueBeforeMilliseconds
    }

    public var issueBefore: Date { Date(timeIntervalSince1970: Double(issueBeforeMilliseconds) / 1_000) }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(deviceID: values.decode(DeviceID.self, forKey: .deviceID),
            operationID: values.decode(UUID.self, forKey: .operationID),
            proof: values.decode(V2DeviceRegistrationCancellationProof.self, forKey: .proof),
            issueBeforeMilliseconds: values.decode(Int64.self, forKey: .issueBeforeMilliseconds))
    }
    private enum CodingKeys: CodingKey { case deviceID, operationID, proof, issueBeforeMilliseconds }
    public enum ValidationError: Error, Equatable, Sendable { case invalidRequest }
}
