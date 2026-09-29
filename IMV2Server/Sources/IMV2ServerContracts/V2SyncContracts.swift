import Foundation
import IMV2Core

/// 单条同步记录。
public struct V2SyncRecord: Equatable, Sendable {
    /// 该记录在用户同步流中的序号。
    public let sequence: UInt64
    /// 产生该记录的来源事件。
    public let sourceEventID: EventID
    /// 投影类型标识。
    public let projectionKind: String
    /// 由持久化投影提供的规范 JSON 载荷。
    ///
    /// 协议适配器只把它编码为字节，不重新解释其中的消息语义。
    public let payloadJSON: String

    /// 校验并保存同步记录。
    ///
    /// - Parameters:
    ///   - sequence: 同步序号，需大于零且可写入 `Int64`。
    ///   - sourceEventID: 来源事件标识。
    ///   - projectionKind: 投影类型标识。
    ///   - payloadJSON: 规范 JSON 载荷。
    /// - Throws: 序号为零或超出有符号 64 位范围时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public init(sequence: UInt64, sourceEventID: EventID, projectionKind: String, payloadJSON: String) throws {
        guard sequence > 0, Int64(exactly: sequence) != nil else { throw V2RoomWriteStoreError.corruptPersistenceState }
        self.sequence = sequence
        self.sourceEventID = sourceEventID
        self.projectionKind = projectionKind
        self.payloadJSON = payloadJSON
    }
}

/// 一次同步拉取的结果。
public enum V2SyncPullResult: Equatable, Sendable {
    /// 可正常返回增量记录。
    case ready(generation: UInt64, records: [V2SyncRecord], nextSyncToken: V2SyncToken, receipt: V2SyncReceipt, hasMore: Bool)
    /// 快照正在准备，需稍后按建议间隔重试。
    case resetPreparing(snapshotID: SnapshotID, generation: UInt64, retryAfter: TimeInterval)
    /// 必须重置本地投影并从指定快照重建。
    case resetRequired(snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, expiresAt: Date)
}

/// 快照清单。
public struct V2SnapshotManifest: Equatable, Sendable {
    /// 快照标识。
    public let snapshotID: SnapshotID
    /// 同步代次。
    public let generation: UInt64
    /// 快照基准序号。
    public let baseSequence: UInt64
    /// 全部页面的根摘要。
    public let rootDigest: String
    /// 快照载荷的 schema 版本。
    public let schemaVersion: UInt32
    /// 能力档位标识。
    public let capabilityProfile: String
    /// 页面数量。
    public let pageCount: UInt32
    /// 条目总数。
    public let totalItems: UInt64
    /// 字节总数。
    public let totalBytes: UInt64
    /// 下次增量同步使用的令牌。
    public let nextSyncToken: V2SyncToken
    /// 快照回执。
    public let receipt: V2SyncReceipt
    /// 快照到期时刻。
    public let expiresAt: Date

    package init(snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, rootDigest: String, schemaVersion: UInt32, capabilityProfile: String, pageCount: UInt32, totalItems: UInt64, totalBytes: UInt64, nextSyncToken: V2SyncToken, receipt: V2SyncReceipt, expiresAt: Date) {
        self.snapshotID = snapshotID
        self.generation = generation
        self.baseSequence = baseSequence
        self.rootDigest = rootDigest
        self.schemaVersion = schemaVersion
        self.capabilityProfile = capabilityProfile
        self.pageCount = pageCount
        self.totalItems = totalItems
        self.totalBytes = totalBytes
        self.nextSyncToken = nextSyncToken
        self.receipt = receipt
        self.expiresAt = expiresAt
    }
}

/// 快照中的一页。
public struct V2SnapshotPage: Equatable, Sendable {
    /// 快照标识。
    public let snapshotID: SnapshotID
    /// 同步代次。
    public let generation: UInt64
    /// 全部页面的根摘要。
    public let rootDigest: String
    /// 页序号。
    public let index: UInt32
    /// 本页第一条投影键。
    public let firstKey: V2SnapshotProjectionKey
    /// 本页最后一条投影键。
    public let lastKey: V2SnapshotProjectionKey
    /// 本页条目数。
    public let itemCount: UInt32
    /// 本页载荷摘要。
    public let digest: String
    /// 本页载荷字节。
    public let payload: Data

    package init(snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, firstKey: V2SnapshotProjectionKey, lastKey: V2SnapshotProjectionKey, itemCount: UInt32, digest: String, payload: Data) {
        self.snapshotID = snapshotID
        self.generation = generation
        self.rootDigest = rootDigest
        self.index = index
        self.firstKey = firstKey
        self.lastKey = lastKey
        self.itemCount = itemCount
        self.digest = digest
        self.payload = payload
    }
}

/// 用户同步的持久化能力。
public protocol V2SyncStore: Sendable {
    /// 拉取增量记录或在需要时要求重置。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - syncToken: 上次同步令牌；为空表示首次同步。
    ///   - maxRecords: 本次最多返回的记录数。
    ///   - requireSnapshot: 是否要求以快照方式同步。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 拉取结果。
    /// - Throws: 持久化失败或同步状态损坏时抛出。
    func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool, now: Date) async throws -> V2SyncPullResult

    /// 确认已连续处理的最高序号。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - generation: 同步代次。
    ///   - highestContiguousSequence: 已连续处理的最高序号。
    ///   - receipt: 本次确认回执。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 持久化失败时抛出。
    func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws

    /// 读取快照清单。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 快照清单。
    /// - Throws: 快照不存在、代次不符或持久化失败时抛出。
    func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest

    /// 读取快照分页。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - rootDigest: 期望的根摘要，用于确认请求的是同一份快照。
    ///   - index: 页序号。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 快照分页。
    /// - Throws: 页面不存在、摘要不符或持久化失败时抛出。
    func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage

    /// 确认快照已接收完成。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - baseSequence: 快照基准序号。
    ///   - receipt: 本次确认回执。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 持久化失败时抛出。
    func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws
}

public extension V2SyncStore {
    /// 以非快照方式拉取增量记录。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - syncToken: 上次同步令牌。
    ///   - maxRecords: 本次最多返回的记录数。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 拉取结果。
    /// - Throws: 存储实现抛出的错误。
    func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, now: Date) async throws -> V2SyncPullResult {
        try await pull(userID: userID, deviceID: deviceID, syncToken: syncToken, maxRecords: maxRecords, requireSnapshot: false, now: now)
    }
}

/// 同步服务错误。
public enum V2SyncServiceError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
}
