import Foundation

/// 当前批次仅包含同一已认证 viewer 的完整上下文键。
public struct V2ProfilePresentationBatchRequest: Equatable, Codable, Sendable {
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
              Set(keys).count == keys.count, rooms.count + directTargets.count <= 8
        else { throw V2ResourceValidationError.invalidPresentationLease }
        self.keys = keys
    }
    private enum CodingKeys: String, CodingKey { case keys }
    public init(from decoder: any Decoder) throws {
        try self.init(keys: decoder.container(keyedBy: CodingKeys.self).decode([V2ProfileViewLookupKey].self, forKey: .keys))
    }
}

/// 临时头像下载能力；客户端按精确版本共享已验证字节，不能将其写入资料表。
public struct V2ResourceAvatarAccess: Equatable, Codable, Sendable {
    public let mediaID: MediaID
    public let variantID: ResourceVariantID
    public let version: Int64
    public let checksum: V2ResourceChecksum
    public let plan: V2ResourceTransferPlan

    public init(mediaID: MediaID, variantID: ResourceVariantID, version: Int64,
                checksum: V2ResourceChecksum, plan: V2ResourceTransferPlan) throws {
        guard version > 0, plan.mode == .httpGet, plan.expectedByteCount > 0, plan.checksum == checksum
        else { throw V2ResourceValidationError.invalidDescriptor }
        self.mediaID = mediaID; self.variantID = variantID; self.version = version
        self.checksum = checksum; self.plan = plan
    }
    private enum CodingKeys: String, CodingKey { case mediaID, variantID, version, checksum, plan }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(mediaID: values.decode(MediaID.self, forKey: .mediaID), variantID: values.decode(ResourceVariantID.self, forKey: .variantID),
                      version: values.decode(Int64.self, forKey: .version), checksum: values.decode(V2ResourceChecksum.self, forKey: .checksum),
                      plan: values.decode(V2ResourceTransferPlan.self, forKey: .plan))
    }
}

/// 暂时故障与不可见分开，客户端不得将 retryable 写为 negative cache。
public enum V2ProfilePresentationBatchEntry: Equatable, Codable, Sendable {
    case presentation(V2AuthorizedProfilePresentation, avatar: V2ResourceAvatarAccess?)
    case unavailable(V2ProfileViewLookupKey)
    case retryable(V2ProfileViewLookupKey)

    public var key: V2ProfileViewLookupKey {
        switch self {
        case .presentation(let value, _): value.lease.key
        case .unavailable(let key), .retryable(let key): key
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
                          avatar.plan.expiresAtUnixMilliseconds <= value.lease.validUntilUnixMilliseconds,
                          avatar.plan.expiresAtUnixMilliseconds > serverNowUnixMilliseconds
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
