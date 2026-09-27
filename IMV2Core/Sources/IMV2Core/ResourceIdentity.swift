import Foundation

/// 资源的逻辑归属；物理数据库和对象存储地址不属于该身份。
public enum V2ResourceHome: Hashable, Codable, Sendable {
    case account(UserID)
    case room(RoomID)
}

/// 上传用途决定归属，账号身份始终取自经过认证的请求。
public enum V2ResourceUsage: Hashable, Codable, Sendable {
    case messageAttachment(RoomID)
    case userAvatar
    case groupAvatar(RoomID)

    public func home(actorUserID: UserID) -> V2ResourceHome {
        switch self {
        case .messageAttachment(let roomID), .groupAvatar(let roomID): .room(roomID)
        case .userAvatar: .account(actorUserID)
        }
    }
}

/// 可持久化的会话定位信息，只提供路由，不授予访问权限。
public struct V2ResourceUploadLocator: Hashable, Codable, Sendable {
    public let home: V2ResourceHome
    public let sessionID: MediaUploadSessionID

    public init(home: V2ResourceHome, sessionID: MediaUploadSessionID) {
        self.home = home
        self.sessionID = sessionID
    }
}

public enum ResourceBlobIDTag: V2IdentifierTag {}
public enum ResourceVariantIDTag: V2IdentifierTag {}
public typealias ResourceBlobID = V2Identifier<ResourceBlobIDTag>
public typealias ResourceVariantID = V2Identifier<ResourceVariantIDTag>

public enum V2ResourceValidationError: Error, Equatable, Sendable {
    case invalidChecksum
    case invalidByteRange
    case invalidTransferHeader
    case invalidTransferPlan
    case invalidUploadRequest
    case invalidUploadSession
    case invalidPart
    case invalidDescriptor
    case invalidTimestamp
    case invalidPresentationLease
}

/// 本系统的全文摘要；不接受供应商 ETag 或分片组合摘要冒充全文摘要。
public struct V2ResourceChecksum: Hashable, Codable, Sendable {
    public enum Algorithm: String, Codable, Sendable { case sha256 }
    public let algorithm: Algorithm
    public let value: String

    public init(algorithm: Algorithm = .sha256, value: String) throws {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw V2ResourceValidationError.invalidChecksum }
        self.algorithm = algorithm
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case algorithm, value }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(algorithm: values.decode(Algorithm.self, forKey: .algorithm), value: values.decode(String.self, forKey: .value))
    }
}

/// 闭区间；长度计算不会溢出。用途和原始文件大小在调用边界进一步检查。
public struct V2ResourceByteRange: Hashable, Codable, Sendable {
    public let lowerBound: Int64
    public let upperBound: Int64
    public var byteCount: Int64 { upperBound - lowerBound + 1 }

    public init(lowerBound: Int64, upperBound: Int64) throws {
        guard lowerBound >= 0, upperBound >= lowerBound, upperBound - lowerBound < Int64.max
        else { throw V2ResourceValidationError.invalidByteRange }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    private enum CodingKeys: String, CodingKey { case lowerBound, upperBound }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(lowerBound: values.decode(Int64.self, forKey: .lowerBound), upperBound: values.decode(Int64.self, forKey: .upperBound))
    }
}

enum V2ResourceTime {
    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard value.isFinite, let result = Int64(exactly: value)
        else { throw V2ResourceValidationError.invalidTimestamp }
        return result
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

enum V2ResourceMetadataValidation {
    static func contentType(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return value.utf8.count <= 127 && components.count == 2
            && components.allSatisfy { component in
                !component.isEmpty && component.utf8.allSatisfy {
                    (97...122).contains($0) || (48...57).contains($0) || [33,35,36,38,45,46,94,95,43].contains($0)
                }
            }
    }
}
