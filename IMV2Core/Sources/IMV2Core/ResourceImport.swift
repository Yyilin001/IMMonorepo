import Foundation

public enum ResourceImportOperationIDTag: V2IdentifierTag {}
public typealias ResourceImportOperationID = V2Identifier<ResourceImportOperationIDTag>

/// 源定位只声明需要重新授权的业务上下文，不携带可复用下载凭证。
public enum V2ResourceImportSource: Equatable, Codable, Sendable {
    case message(location: V2MediaMessageLocation, mediaID: MediaID, variantID: ResourceVariantID?)
    case avatar(key: V2ProfileViewLookupKey, mediaID: MediaID, variantID: ResourceVariantID)

    public var mediaID: MediaID {
        switch self {
        case .message(_, let mediaID, _), .avatar(_, let mediaID, _): mediaID
        }
    }
}

/// 目标始终获得新的媒体身份；同一数据库中的两个房间仍是不同 home。
public struct V2ResourceImportRequest: Equatable, Codable, Sendable {
    public let operationID: ResourceImportOperationID
    public let source: V2ResourceImportSource
    public let targetUsage: V2ResourceUsage
    public let targetMediaID: MediaID

    public init(operationID: ResourceImportOperationID, source: V2ResourceImportSource,
                targetUsage: V2ResourceUsage, targetMediaID: MediaID) throws {
        guard source.mediaID != targetMediaID else { throw V2ResourceValidationError.invalidDescriptor }
        self.operationID = operationID; self.source = source
        self.targetUsage = targetUsage; self.targetMediaID = targetMediaID
    }

    private enum CodingKeys: String, CodingKey { case operationID, source, targetUsage, targetMediaID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operationID: values.decode(ResourceImportOperationID.self, forKey: .operationID),
                      source: values.decode(V2ResourceImportSource.self, forKey: .source),
                      targetUsage: values.decode(V2ResourceUsage.self, forKey: .targetUsage),
                      targetMediaID: values.decode(MediaID.self, forKey: .targetMediaID))
    }
}

public struct V2ResourceImportLocator: Hashable, Codable, Sendable {
    public let home: V2ResourceHome
    public let operationID: ResourceImportOperationID
    public init(home: V2ResourceHome, operationID: ResourceImportOperationID) {
        self.home = home; self.operationID = operationID
    }
}

public enum V2ResourceImportState: String, Codable, Sendable {
    case pending, copying, processing, ready, cancelled, failed
}

/// 可持久化的导入进度；没有 URL、对象存储 key 或供应商回执。
public struct V2ResourceImportStatus: Equatable, Codable, Sendable {
    public let locator: V2ResourceImportLocator
    public let mediaID: MediaID
    public let state: V2ResourceImportState
    public let bindableUntilUnixMilliseconds: Int64?

    public init(locator: V2ResourceImportLocator, mediaID: MediaID, state: V2ResourceImportState,
                bindableUntil: Date?) throws {
        try self.init(locator: locator, mediaID: mediaID, state: state,
                      bindableUntilUnixMilliseconds: bindableUntil.map(V2ResourceTime.milliseconds))
    }
    private init(locator: V2ResourceImportLocator, mediaID: MediaID, state: V2ResourceImportState,
                 bindableUntilUnixMilliseconds: Int64?) throws {
        guard (state == .ready) == (bindableUntilUnixMilliseconds != nil)
        else { throw V2ResourceValidationError.invalidDescriptor }
        self.locator = locator; self.mediaID = mediaID; self.state = state
        self.bindableUntilUnixMilliseconds = bindableUntilUnixMilliseconds
    }
    private enum CodingKeys: String, CodingKey { case locator, mediaID, state, bindableUntilUnixMilliseconds }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(locator: values.decode(V2ResourceImportLocator.self, forKey: .locator),
                      mediaID: values.decode(MediaID.self, forKey: .mediaID), state: values.decode(V2ResourceImportState.self, forKey: .state),
                      bindableUntilUnixMilliseconds: values.decodeIfPresent(Int64.self, forKey: .bindableUntilUnixMilliseconds))
    }
}
