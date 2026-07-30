import Foundation

public enum V2CoreError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidNonNegativeValue
    case invalidPositiveValue
    case invalidGeneration
}

public protocol V2IdentifierTag: Sendable {}

/// A deliberately opaque, URL-path-safe identifier. Its tag prevents
/// accidental cross-domain use while its small RFC 3986 unreserved encoding
/// keeps an ID safe for database keys, logs, URLs, and cache filenames without
/// every boundary having to reinterpret or escape a raw value.
public struct V2Identifier<Tag: V2IdentifierTag>: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public static var maximumUTF8Bytes: Int { 128 }

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Bytes,
              rawValue.utf8.allSatisfy(Self.isUnreservedASCII)
        else {
            throw V2CoreError.invalidIdentifier
        }
        // UUID-backed IDs are emitted by PostgreSQL, HTTP, and protobuf
        // boundaries. Those boundaries are allowed to differ only in UUID
        // letter casing, never in identity. Persist one canonical spelling so
        // projections from independent endpoints still join on the same local
        // SQLite key. Foundation's UUID spelling is also the one used by the
        // server's room-event payloads, so every layer shares one lexical key.
        // Non-UUID opaque identifiers deliberately retain their exact
        // URL-safe spelling.
        self.rawValue = UUID(uuidString: rawValue)?.uuidString ?? rawValue
    }

    public var description: String { rawValue }

    /// Keep decoding on the same validation and canonicalization boundary as
    /// every other external identifier input. Synthesis would write directly
    /// into `rawValue`, allowing an invalid or differently cased UUID to
    /// bypass `init(_:)` when an identifier is embedded in a Codable model.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func isUnreservedASCII(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39, 0x2D, 0x2E, 0x5F, 0x7E:
            true
        default:
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }
}

public enum RoomIDTag: V2IdentifierTag {}
public enum UserIDTag: V2IdentifierTag {}
public enum DeviceIDTag: V2IdentifierTag {}
public enum MessageIDTag: V2IdentifierTag {}
public enum EventIDTag: V2IdentifierTag {}
public enum ClientMessageIDTag: V2IdentifierTag {}
public enum FanoutPlanIDTag: V2IdentifierTag {}
public enum CompletionUnitIDTag: V2IdentifierTag {}
public enum ShardAdmissionLeaseIDTag: V2IdentifierTag {}
public enum SnapshotIDTag: V2IdentifierTag {}
public enum MembershipOperationIDTag: V2IdentifierTag {}
public enum MessageWithdrawalOperationIDTag: V2IdentifierTag {}
public enum ModerationOperationIDTag: V2IdentifierTag {}
public enum MessageReactionOperationIDTag: V2IdentifierTag {}
public enum MessageEditOperationIDTag: V2IdentifierTag {}
public enum ReadReceiptOperationIDTag: V2IdentifierTag {}
public enum DirectRoomOperationIDTag: V2IdentifierTag {}
public enum GroupRoomOperationIDTag: V2IdentifierTag {}
public enum StrangerMessagePreferenceOperationIDTag: V2IdentifierTag {}
public enum RelationshipOperationIDTag: V2IdentifierTag {}
public enum UserBlockOperationIDTag: V2IdentifierTag {}
public enum MediaIDTag: V2IdentifierTag {}
public enum MediaUploadOperationIDTag: V2IdentifierTag {}
public enum ProfileUpdateOperationIDTag: V2IdentifierTag {}
public enum MediaUploadSessionIDTag: V2IdentifierTag {}
public enum MediaDownloadSessionIDTag: V2IdentifierTag {}

public typealias RoomID = V2Identifier<RoomIDTag>
public typealias UserID = V2Identifier<UserIDTag>
public typealias DeviceID = V2Identifier<DeviceIDTag>
public typealias MessageID = V2Identifier<MessageIDTag>
public typealias EventID = V2Identifier<EventIDTag>
public typealias ClientMessageID = V2Identifier<ClientMessageIDTag>
public typealias FanoutPlanID = V2Identifier<FanoutPlanIDTag>
public typealias CompletionUnitID = V2Identifier<CompletionUnitIDTag>
public typealias ShardAdmissionLeaseID = V2Identifier<ShardAdmissionLeaseIDTag>
public typealias SnapshotID = V2Identifier<SnapshotIDTag>
public typealias MembershipOperationID = V2Identifier<MembershipOperationIDTag>
public typealias MessageWithdrawalOperationID = V2Identifier<MessageWithdrawalOperationIDTag>
public typealias ModerationOperationID = V2Identifier<ModerationOperationIDTag>
public typealias MessageReactionOperationID = V2Identifier<MessageReactionOperationIDTag>
public typealias MessageEditOperationID = V2Identifier<MessageEditOperationIDTag>
public typealias ReadReceiptOperationID = V2Identifier<ReadReceiptOperationIDTag>
public typealias DirectRoomOperationID = V2Identifier<DirectRoomOperationIDTag>
public typealias GroupRoomOperationID = V2Identifier<GroupRoomOperationIDTag>
public typealias StrangerMessagePreferenceOperationID = V2Identifier<StrangerMessagePreferenceOperationIDTag>
public typealias RelationshipOperationID = V2Identifier<RelationshipOperationIDTag>
public typealias UserBlockOperationID = V2Identifier<UserBlockOperationIDTag>
public typealias MediaID = V2Identifier<MediaIDTag>
public typealias MediaUploadOperationID = V2Identifier<MediaUploadOperationIDTag>
public typealias ProfileUpdateOperationID = V2Identifier<ProfileUpdateOperationIDTag>
public typealias MediaUploadSessionID = V2Identifier<MediaUploadSessionIDTag>
public typealias MediaDownloadSessionID = V2Identifier<MediaDownloadSessionIDTag>
