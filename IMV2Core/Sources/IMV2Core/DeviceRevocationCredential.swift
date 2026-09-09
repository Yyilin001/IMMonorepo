import Foundation

/// Possession authorizes only revoking the session to which the server bound
/// this value. It is never an access token or a refresh credential.
public struct V2DeviceRevocationCredential: Equatable, Sendable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let rawValue: String
    private static let prefix = "imv2-revoke-v1."

    public init(rawValue: String) throws {
        guard rawValue.utf8.count == Self.prefix.utf8.count + 43,
              rawValue.hasPrefix(Self.prefix) else { throw ValidationError.invalidCredential }
        let suffix = String(rawValue.dropFirst(Self.prefix.count))
        guard suffix.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), let bytes = Data(base64Encoded: suffix.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32, Self.encode(bytes) == suffix
        else { throw ValidationError.invalidCredential }
        self.rawValue = rawValue
    }

    public static func generate() -> Self {
        var random = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        return Self(generatedValue: prefix + encode(bytes))
    }

    private init(generatedValue: String) { rawValue = generatedValue }

    private static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { "V2DeviceRevocationCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public enum ValidationError: Error, Equatable, Sendable { case invalidCredential }
}
