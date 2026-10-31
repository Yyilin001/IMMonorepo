import Foundation

/// 当前批次仅包含同一已认证 viewer 的完整上下文键。
public struct V2ProfilePresentationBatchRequest: Equatable, Codable, Sendable {
    public static let maximumAuthorityContexts = 8
    public let keys: [V2ProfileViewLookupKey]
    public init(keys: [V2ProfileViewLookupKey]) throws {
        let rooms = Set(keys.compactMap { key -> V2ProfileViewContext? in
            key.context.authorizationRoomID == nil ? nil : key.context
        })
        let directTargets = Set(keys.compactMap { key -> UserID? in
            if case .directConversation = key.context { return key.userID }
            return nil
        })
        guard !keys.isEmpty, keys.count <= V2ProfileViewLookupLimits.maximumKeys,
              Set(keys).count == keys.count, rooms.count + directTargets.count <= Self.maximumAuthorityContexts
        else { throw V2ResourceValidationError.invalidPresentationLease }
        self.keys = keys
    }

    /// Select one bounded read from an ordered interest queue. The queue may
    /// span more contexts than one read permits. Keep complete key identity:
    /// review and member access to the same room are separate authorities,
    /// and each direct-conversation target consumes a distinct context.
    /// This only schedules reads; it never establishes permission.
    public static func selectKeys(from orderedKeys: [V2ProfileViewLookupKey],
                                  maximumKeys: Int = V2ProfileViewLookupLimits.maximumKeys) -> [V2ProfileViewLookupKey] {
        let limit = min(max(0, maximumKeys), V2ProfileViewLookupLimits.maximumKeys)
        guard limit > 0 else { return [] }
        var rooms = Set<V2ProfileViewContext>(), directTargets = Set<UserID>()
        var selected: [V2ProfileViewLookupKey] = [], seen = Set<V2ProfileViewLookupKey>()
        for key in orderedKeys {
            guard seen.insert(key).inserted else { continue }
            if key.context.authorizationRoomID != nil {
                guard rooms.contains(key.context) || rooms.count + directTargets.count < maximumAuthorityContexts else { continue }
                rooms.insert(key.context)
            } else if key.context == .directConversation {
                guard directTargets.contains(key.userID) || rooms.count + directTargets.count < maximumAuthorityContexts else { continue }
                directTargets.insert(key.userID)
            }
            selected.append(key)
            if selected.count == limit { break }
        }
        return selected
    }
    private enum CodingKeys: String, CodingKey { case keys }
    public init(from decoder: any Decoder) throws {
        try self.init(keys: decoder.container(keyedBy: CodingKeys.self).decode([V2ProfileViewLookupKey].self, forKey: .keys))
    }
}

/// Stable avatar content plus an optional, temporary download plan. The
/// surrounding presentation authorizes display; this descriptor alone does not.
public struct V2ResourceAvatarAccess: Equatable, Codable, Sendable {
    public let mediaID: MediaID
    public let variantID: ResourceVariantID
    public let version: Int64
    public let checksum: V2ResourceChecksum
    public let byteCount: Int64
    public private(set) var plan: V2ResourceTransferPlan?

    public init(mediaID: MediaID, variantID: ResourceVariantID, version: Int64,
                checksum: V2ResourceChecksum, byteCount: Int64, plan: V2ResourceTransferPlan?) throws {
        guard version > 0, (1...2 * 1_024 * 1_024).contains(byteCount),
              plan.map({ $0.mode == .httpGet && $0.expectedByteCount == byteCount && $0.checksum == checksum }) ?? true
        else { throw V2ResourceValidationError.invalidDescriptor }
        self.mediaID = mediaID; self.variantID = variantID; self.version = version
        self.checksum = checksum; self.byteCount = byteCount; self.plan = plan
    }
    public func withoutDownloadPlan() -> Self { var value = self; value.plan = nil; return value }
    public func hasSameContent(as other: Self) -> Bool {
        mediaID == other.mediaID && variantID == other.variantID && version == other.version
            && checksum == other.checksum && byteCount == other.byteCount
    }
    private enum CodingKeys: String, CodingKey { case mediaID, variantID, version, checksum, byteCount, plan }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(mediaID: values.decode(MediaID.self, forKey: .mediaID), variantID: values.decode(ResourceVariantID.self, forKey: .variantID),
                      version: values.decode(Int64.self, forKey: .version), checksum: values.decode(V2ResourceChecksum.self, forKey: .checksum),
                      byteCount: values.decode(Int64.self, forKey: .byteCount),
                      plan: values.decodeIfPresent(V2ResourceTransferPlan.self, forKey: .plan))
    }
}

/// 暂时故障与不可见分开，客户端不得将 retryable 写为 negative cache。
public enum V2ProfilePresentationBatchEntry: Equatable, Codable, Sendable {
    case presentation(V2AuthorizedProfilePresentation, avatar: V2ResourceAvatarAccess?)
    case unavailable(V2PresentationDenial)
    case retryable(V2ProfileViewLookupKey)

    public var key: V2ProfileViewLookupKey {
        switch self {
        case .presentation(let value, _): value.lease.key
        case .unavailable(let denial): denial.key
        case .retryable(let key): key
        }
    }
}

/// 服务器当前时间用于将剩余展示期限映射到客户端单调时钟，避免客户端墙钟延长权限。
/// 包含临时 plan，整个响应都不得作为资料缓存或 journal 持久化。
public struct V2ProfilePresentationBatchResponse: Equatable, Codable, Sendable {
    public let serverNowUnixMilliseconds: Int64
    public let results: [V2ProfilePresentationBatchEntry]

    public init(serverNowUnixMilliseconds: Int64, results: [V2ProfilePresentationBatchEntry]) throws {
        guard results.count <= V2ProfileViewLookupLimits.maximumKeys, Set(results.map(\.key)).count == results.count
        else { throw V2ResourceValidationError.invalidPresentationLease }
        for result in results {
            if case .presentation(let value, let avatar) = result {
                guard value.lease.observedAtUnixMilliseconds <= serverNowUnixMilliseconds,
                      value.lease.validUntilUnixMilliseconds > serverNowUnixMilliseconds
                else { throw V2ResourceValidationError.invalidPresentationLease }
                if let avatar {
                    guard value.view.avatar?.mediaID == avatar.mediaID,
                          avatar.plan.map({ $0.expiresAtUnixMilliseconds <= value.lease.validUntilUnixMilliseconds
                              && $0.expiresAtUnixMilliseconds > serverNowUnixMilliseconds }) ?? true
                    else { throw V2ResourceValidationError.invalidPresentationLease }
                }
            }
        }
        self.serverNowUnixMilliseconds = serverNowUnixMilliseconds
        self.results = results
    }
    private enum CodingKeys: String, CodingKey { case serverNowUnixMilliseconds, results }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(serverNowUnixMilliseconds: values.decode(Int64.self, forKey: .serverNowUnixMilliseconds),
                      results: values.decode([V2ProfilePresentationBatchEntry].self, forKey: .results))
    }
}
