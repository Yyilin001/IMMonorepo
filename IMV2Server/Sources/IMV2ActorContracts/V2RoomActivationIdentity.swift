import Foundation
import IMV2Core

/// 在进入运行时或线路请求前即被拒绝的值。
public enum V2ActorContractError: Error, Equatable, Sendable {
    case invalidEpoch
    case invalidShardID
    case invalidDuration
    case invalidConfiguration(String)
}

/// 可无截断地存入 PostgreSQL bigint 的正纪元值。
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

/// 数据库位置与宿主房间的进程相互独立。
public struct V2RoomDataOwner: Hashable, Codable, Sendable {
    public let shardID: String
    /// 既有房间所有者纪元允许零；激活纪元从一开始。
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

/// 稳定的宿主标签，加上每次进程启动生成的新身份。
///
/// 复用地址或标签不会让重启后的进程继承旧 Actor 实例的执行权限。
public struct V2ActorHostIdentity: Hashable, Codable, Sendable {
    public let hostID: V2ActorHostID
    public let incarnationID: UUID

    public init(hostID: V2ActorHostID, incarnationID: UUID) {
        self.hostID = hostID
        self.incarnationID = incarnationID
    }
}

/// 标识一个房间的精确物理实例。Host 按整个值校验调用和生命周期。
///
/// 构造此值不会授予执行权限；分区归属由控制日志确定，原生 Host
/// 管理激活与排空。业务数据库只校验 owner 表示的数据分片及归属纪元。
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

    /// 只比较同一逻辑房间的代次。
    ///
    /// 纪元相同但宿主身份不同，不表示“更新”；
    /// 这代表互相冲突的观测，解析器须依据已提交的 Actor 分区归属裁定。
    public func isNewer(than other: Self) -> Bool {
        guard roomID == other.roomID else { return false }
        if owner.epoch != other.owner.epoch { return owner.epoch > other.owner.epoch }
        guard owner.shardID == other.owner.shardID else { return false }
        return activationEpoch > other.activationEpoch
    }
}

/// 严格为正且有界的时长，可用于线路协议与配置。
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
