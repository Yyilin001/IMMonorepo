/// A content revision is positive and representable by every persistence
/// adapter. Construct this value before a command can reach an idempotency
/// lookup, not only before writing a new operation.
public struct V2MessageRevision: Equatable, Hashable, Sendable {
    public let signedValue: Int64
    public var rawValue: UInt64 { UInt64(signedValue) }

    public init(_ rawValue: UInt64) throws {
        guard let value = Int64(exactly: rawValue), value > 0 else {
            throw V2RevisionValidationError.outOfRange
        }
        signedValue = value
    }
}

/// Membership fences may name the initial (zero) revision. They must still
/// fit in the signed storage domain; truncating or clamping changes intent.
public struct V2MembershipRevision: Equatable, Hashable, Sendable {
    public let signedValue: Int64
    public var rawValue: UInt64 { UInt64(signedValue) }

    public init(_ rawValue: UInt64) throws {
        guard let value = Int64(exactly: rawValue) else {
            throw V2RevisionValidationError.outOfRange
        }
        signedValue = value
    }
}

public enum V2RevisionValidationError: Error, Equatable, Sendable {
    case outOfRange
}

/// A durable room-log waterline. Zero denotes an empty or unread room.
public struct V2RoomCursor: Equatable, Hashable, Sendable {
    public let signedValue: Int64
    public var rawValue: UInt64 { UInt64(signedValue) }

    public init(_ rawValue: UInt64) throws {
        guard let value = Int64(exactly: rawValue) else {
            throw V2RevisionValidationError.outOfRange
        }
        signedValue = value
    }
}
