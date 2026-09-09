import Foundation

/// 基础领域输入不符合标识、数值或代次约束时的错误。
public enum V2CoreError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidNonNegativeValue
    case invalidPositiveValue
    case invalidGeneration
}

/// 标识用途的类型标签，使房间、用户、设备和操作 ID 在编译期不可混用。
public protocol V2IdentifierTag: Sendable {}

/// 不透明且可安全放入 URL 路径的领域标识。
///
/// Tag 区分身份用途；输入仅允许 RFC 3986 unreserved ASCII，最多 128 UTF-8 字节。
/// UUID 形式统一为 Foundation 规范表示，其他标识保留原拼写。
/// 标识有效不等于调用者有权限使用它，授权由业务边界负责。
public struct V2Identifier<Tag: V2IdentifierTag>: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// 验证并规范化后的标识文本；也是编码与相等比较使用的身份。
    public let rawValue: String
    /// 输入为 UUID 时缓存其强类型表示；其他不透明标识为 nil。
    ///
    /// 持久化适配器可直接使用此值绑定 UUID 列，避免重复解析。
    public let uuidValue: UUID?

    /// 原始标识允许的最大 UTF-8 字节数。
    public static var maximumUTF8Bytes: Int { 128 }

    /// 验证外部标识，并规范化 UUID 的大小写形式。
    ///
    /// - Parameter rawValue: 非空、至多 128 字节的 URL 路径安全文本。
    /// - Throws: 格式或长度不合规时抛出 ``V2CoreError/invalidIdentifier``。
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

    /// 由已解析的 UUID 构造标识，无需再次扫描字符或解析文本。
    ///
    /// - Parameter uuid: 由可信类型边界提供的 UUID；输出使用其规范字符串。
    public init(uuid: UUID) {
        self.rawValue = uuid.uuidString
        self.uuidValue = uuid
    }

    /// 标识的规范文本表示；不包含额外类型标签。
    public var description: String { rawValue }

    /// 按与直接构造相同的规则解码标识，避免 Codable 绕过验证。
    ///
    /// - Parameter decoder: 提供含 `rawValue` 字段的编码容器。
    /// - Throws: 字段解码错误，或 ``V2CoreError/invalidIdentifier``。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(String.self, forKey: .rawValue))
    }

    /// 将规范标识编码到 `rawValue` 字段；UUID 缓存不写入线格式。
    ///
    /// - Parameter encoder: 目标编码器。
    /// - Throws: 编码器拒绝字段或容器时返回其错误。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    /// 按规范文本的字典序排序，不表示事件发生顺序或业务优先级。
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 按规范标识文本比较身份；缓存的 UUID 不构成另一条相等条件。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    /// 将与规范身份一致的表示加入哈希；UUID 标识复用已解析字节。
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
