import Foundation
import IMV2Core

/// Values rejected before they can enter the runtime or a wire request.
public enum V2ActorContractError: Error, Equatable, Sendable {
    case invalidEpoch
    case invalidShardID
    case invalidDuration
    case invalidLeaseTimestamp
    case invalidConfiguration(String)
}

/// A positive epoch that can be stored without truncation in PostgreSQL bigint.
public struct V2ActorEpoch: Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue > 0 else { throw V2ActorContractError.invalidEpoch }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Int64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Database placement is independent of the process hosting a room.
public struct V2RoomDataOwner: Hashable, Codable, Sendable {
    public let shardID: String
    /// Existing room-owner epochs include zero; activation epochs start at one.
    public let epoch: Int64

    public init(shardID: String, epoch: Int64) throws {
        let normalized = shardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw V2ActorContractError.invalidShardID }
        guard epoch >= 0 else { throw V2ActorContractError.invalidEpoch }
        self.shardID = normalized
        self.epoch = epoch
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            shardID: values.decode(String.self, forKey: .shardID),
            epoch: values.decode(Int64.self, forKey: .epoch)
        )
    }

    private enum CodingKeys: String, CodingKey { case shardID, epoch }
}

public enum V2ActorHostIDTag: V2IdentifierTag {}
public typealias V2ActorHostID = V2Identifier<V2ActorHostIDTag>

/// A stable host label plus a fresh identity for every process start.
///
/// A reused address or label never gives the restarted process its old lease.
public struct V2ActorHostIdentity: Hashable, Codable, Sendable {
    public let hostID: V2ActorHostID
    public let incarnationID: UUID

    public init(hostID: V2ActorHostID, incarnationID: UUID) {
        self.hostID = hostID
        self.incarnationID = incarnationID
    }
}

/// The entire value is compared when renewing, releasing, or fencing a write.
///
/// Constructing this value does not grant authority. The room database must
/// validate it while holding the transaction fence through commit.
public struct V2RoomActivationToken: Hashable, Codable, Sendable {
    public let roomID: RoomID
    public let owner: V2RoomDataOwner
    public let activationEpoch: V2ActorEpoch
    public let host: V2ActorHostIdentity

    public init(
        roomID: RoomID,
        owner: V2RoomDataOwner,
        activationEpoch: V2ActorEpoch,
        host: V2ActorHostIdentity
    ) {
        self.roomID = roomID
        self.owner = owner
        self.activationEpoch = activationEpoch
        self.host = host
    }

    /// Only compares generations for the same logical room.
    ///
    /// Equal epochs with another host identity are not "newer"; they indicate
    /// conflicting observations that the resolver must settle against the DB.
    public func isNewer(than other: Self) -> Bool {
        guard roomID == other.roomID else { return false }
        if owner.epoch != other.owner.epoch { return owner.epoch > other.owner.epoch }
        guard owner.shardID == other.owner.shardID else { return false }
        return activationEpoch > other.activationEpoch
    }
}

/// A database observation, not a client-clock authorization check.
public struct V2RoomActivationLease: Equatable, Codable, Sendable {
    public let token: V2RoomActivationToken
    public let databaseObservedAt: Date
    public let expiresAt: Date

    public init(token: V2RoomActivationToken, databaseObservedAt: Date, expiresAt: Date) throws {
        guard databaseObservedAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > databaseObservedAt,
              expiresAt.timeIntervalSince(databaseObservedAt)
                <= Double(V2ActorMilliseconds.maximum) / 1_000
        else { throw V2ActorContractError.invalidLeaseTimestamp }
        self.token = token
        self.databaseObservedAt = databaseObservedAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            token: values.decode(V2RoomActivationToken.self, forKey: .token),
            databaseObservedAt: values.decode(Date.self, forKey: .databaseObservedAt),
            expiresAt: values.decode(Date.self, forKey: .expiresAt)
        )
    }

    private enum CodingKeys: String, CodingKey { case token, databaseObservedAt, expiresAt }
}

/// A strictly positive bounded duration suitable for wire and configuration use.
public struct V2ActorMilliseconds: Hashable, Comparable, Codable, Sendable {
    public static let maximum: Int64 = 3_600_000
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard (1...Self.maximum).contains(rawValue) else {
            throw V2ActorContractError.invalidDuration
        }
        self.rawValue = rawValue
    }

    public var duration: Duration { .milliseconds(rawValue) }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Int64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
