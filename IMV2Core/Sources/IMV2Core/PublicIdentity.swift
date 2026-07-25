import Foundation

/// A public, user-chosen identifier. It is intentionally distinct from every
/// authentication credential: callers may use an optional leading `@` for
/// input ergonomics, while persistence and protocol values are canonical.
public struct V2PublicHandle: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ value: String) throws {
        let withoutPrefix = value.first == "@" ? String(value.dropFirst()) : value
        let canonical = withoutPrefix.lowercased()
        let scalars = canonical.unicodeScalars
        guard (3 ... 32).contains(scalars.count), scalars.allSatisfy({ scalar in
            (48 ... 57).contains(scalar.value) ||
            (97 ... 122).contains(scalar.value) ||
            scalar == "_"
        }) else {
            throw V2PublicIdentityValidationError.invalidHandle
        }
        rawValue = canonical
    }

    public var description: String { "@\(rawValue)" }
}

/// A profile fact allowed to leave the authenticated identity boundary. It
/// never carries an account handle, password factor, passkey, phone, or email.
public struct V2PublicIdentity: Codable, Equatable, Sendable {
    public let userID: UserID
    public let handle: V2PublicHandle
    public let displayName: String

    public init(userID: UserID, handle: V2PublicHandle, displayName: String) throws {
        let normalizedName = displayName.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= 80,
              normalizedName.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) && (!$0.properties.isWhitespace || $0 == " ")
              })
        else { throw V2PublicIdentityValidationError.invalidDisplayName }
        self.userID = userID
        self.handle = handle
        self.displayName = normalizedName
    }
}

public enum V2PublicIdentityValidationError: Error, Equatable, Sendable {
    case invalidHandle
    case invalidDisplayName
}
