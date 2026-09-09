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
    /// The already-validated UUID representation when this identifier came
    /// from a UUID-shaped boundary. Persistence adapters can bind these 16
    /// bytes directly instead of reparsing `rawValue` for every operation.
    /// Opaque, non-UUID identifiers deliberately keep this value nil.
    public let uuidValue: UUID?

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
        if let uuid = UUID(uuidString: rawValue) {
            self.rawValue = uuid.uuidString
            self.uuidValue = uuid
        } else {
            self.rawValue = rawValue
            self.uuidValue = nil
        }
    }

    /// Constructs a canonical identifier from a value that is already a
    /// strongly typed UUID. Unlike the string boundary above, this path does
    /// not need to rescan URL safety or parse the same UUID a second time.
    /// The resulting spelling is still exactly Foundation's canonical UUID
    /// representation, so persistence and wire equality remain unchanged.
    public init(uuid: UUID) {
        self.rawValue = uuid.uuidString
        self.uuidValue = uuid
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

    /// Identity semantics remain the canonical opaque spelling. The cached
    /// UUID is an implementation representation, not another equality axis.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        if let uuidValue {
            // UUID-backed identifiers dominate server routing dictionaries.
            // Hash their already-parsed 16 bytes instead of rescanning the
            // canonical 36-byte spelling on every lookup. Equality remains
            // the canonical opaque string above, so public identity semantics
            // and Codable output are unchanged.
            hasher.combine(uuidValue)
        } else {
            hasher.combine(rawValue)
        }
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
public enum UserAddPreferenceOperationIDTag: V2IdentifierTag {}
public enum ReadReceiptPreferenceOperationIDTag: V2IdentifierTag {}
public enum LiveActivityPreferenceOperationIDTag: V2IdentifierTag {}
public enum RelationshipOperationIDTag: V2IdentifierTag {}
public enum UserBlockOperationIDTag: V2IdentifierTag {}
public enum ConversationPreferenceOperationIDTag: V2IdentifierTag {}
public enum MessageFavoriteOperationIDTag: V2IdentifierTag {}
public enum PinnedMessageOperationIDTag: V2IdentifierTag {}
public enum GroupAnnouncementOperationIDTag: V2IdentifierTag {}
public enum GroupPermissionOperationIDTag: V2IdentifierTag {}
public enum GroupRoleOperationIDTag: V2IdentifierTag {}
public enum MessageForwardOperationIDTag: V2IdentifierTag {}
public enum MediaIDTag: V2IdentifierTag {}
public enum MediaUploadOperationIDTag: V2IdentifierTag {}
public enum ProfileUpdateOperationIDTag: V2IdentifierTag {}
public enum ContactAliasOperationIDTag: V2IdentifierTag {}
public enum GroupNicknameOperationIDTag: V2IdentifierTag {}
public enum MediaUploadSessionIDTag: V2IdentifierTag {}
public enum MediaDownloadSessionIDTag: V2IdentifierTag {}
public enum GroupInviteIDTag: V2IdentifierTag {}
public enum GroupInviteOperationIDTag: V2IdentifierTag {}
public enum GroupJoinRequestIDTag: V2IdentifierTag {}
public enum GroupJoinRequestOperationIDTag: V2IdentifierTag {}
public enum GroupJoinDecisionOperationIDTag: V2IdentifierTag {}

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
public typealias UserAddPreferenceOperationID = V2Identifier<UserAddPreferenceOperationIDTag>
public typealias ReadReceiptPreferenceOperationID = V2Identifier<ReadReceiptPreferenceOperationIDTag>
public typealias LiveActivityPreferenceOperationID = V2Identifier<LiveActivityPreferenceOperationIDTag>
public typealias RelationshipOperationID = V2Identifier<RelationshipOperationIDTag>
public typealias UserBlockOperationID = V2Identifier<UserBlockOperationIDTag>
public typealias ConversationPreferenceOperationID = V2Identifier<ConversationPreferenceOperationIDTag>
public typealias MessageFavoriteOperationID = V2Identifier<MessageFavoriteOperationIDTag>
public typealias PinnedMessageOperationID = V2Identifier<PinnedMessageOperationIDTag>
public typealias GroupAnnouncementOperationID = V2Identifier<GroupAnnouncementOperationIDTag>
public typealias GroupPermissionOperationID = V2Identifier<GroupPermissionOperationIDTag>
public typealias GroupRoleOperationID = V2Identifier<GroupRoleOperationIDTag>
public typealias MessageForwardOperationID = V2Identifier<MessageForwardOperationIDTag>
public typealias MediaID = V2Identifier<MediaIDTag>
public typealias MediaUploadOperationID = V2Identifier<MediaUploadOperationIDTag>
public typealias ProfileUpdateOperationID = V2Identifier<ProfileUpdateOperationIDTag>
public typealias ContactAliasOperationID = V2Identifier<ContactAliasOperationIDTag>
public typealias GroupNicknameOperationID = V2Identifier<GroupNicknameOperationIDTag>
public typealias MediaUploadSessionID = V2Identifier<MediaUploadSessionIDTag>
public typealias MediaDownloadSessionID = V2Identifier<MediaDownloadSessionIDTag>
public typealias GroupInviteID = V2Identifier<GroupInviteIDTag>
public typealias GroupInviteOperationID = V2Identifier<GroupInviteOperationIDTag>
public typealias GroupJoinRequestID = V2Identifier<GroupJoinRequestIDTag>
public typealias GroupJoinRequestOperationID = V2Identifier<GroupJoinRequestOperationIDTag>
public typealias GroupJoinDecisionOperationID = V2Identifier<GroupJoinDecisionOperationIDTag>
