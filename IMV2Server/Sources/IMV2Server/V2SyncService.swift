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

/// 用户同步的对外服务，负责参数限幅与返回值校验。
public struct V2SyncService: Sendable {
    private let store: any V2SyncStore
    private let maxRecordsLimit: Int
    private let now: @Sendable () -> Date

    /// 组合同步存储与限幅参数。
    ///
    /// - Parameters:
    ///   - store: 执行同步读取的持久化存储。
    ///   - maxRecordsLimit: 单次拉取允许的最大记录数，需大于零，默认 500。
    ///   - now: 可注入的当前时刻读取函数。
    ///
    /// 上限非正时直接失败，避免出现无界拉取。
    public init(store: any V2SyncStore, maxRecordsLimit: Int = 500, now: @escaping @Sendable () -> Date = Date.init) {
        precondition(maxRecordsLimit > 0)
        self.store = store
        self.maxRecordsLimit = maxRecordsLimit
        self.now = now
    }

    /// 拉取同步记录。
    ///
    /// 请求的记录数会被夹在 `1` 与 `maxRecordsLimit` 之间；返回值中的代次与序号
    /// 必须可写入持久化的有符号计数范围，否则视为持久化状态损坏。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - syncToken: 上次同步令牌。
    ///   - requestedMaxRecords: 期望的最大记录数。
    ///   - requireSnapshot: 是否要求以快照方式同步。
    /// - Returns: 拉取结果。
    /// - Throws: 代次或序号超出可编码范围时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``；其余错误来自存储实现。
    public func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, requestedMaxRecords: Int, requireSnapshot: Bool = false) async throws -> V2SyncPullResult {
        let limit = min(max(requestedMaxRecords, 1), maxRecordsLimit)
        let result = try await store.pull(userID: userID, deviceID: deviceID, syncToken: syncToken, maxRecords: limit, requireSnapshot: requireSnapshot, now: now())
        switch result {
        case .ready(let generation, let records, _, _, _):
            try validateReturnedPosition(generation: generation)
            guard records.allSatisfy({ $0.sequence > 0 && $0.sequence <= UInt64(Int64.max) }) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
        case .resetPreparing(_, let generation, _):
            try validateReturnedPosition(generation: generation)
        case .resetRequired(_, let generation, let baseSequence, _):
            try validateReturnedPosition(generation: generation, sequence: baseSequence)
        }
        return result
    }

    /// 确认已连续处理的最高序号。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - generation: 同步代次，需大于零。
    ///   - highestContiguousSequence: 已连续处理的最高序号。
    ///   - receipt: 本次确认回执。
    /// - Throws: 参数不可编码时抛出 ``V2SyncServiceError/invalidRequest``；
    ///   其余错误来自存储实现。
    public func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) async throws {
        try validate(generation: generation, sequence: highestContiguousSequence)
        try await store.acknowledge(userID: userID, deviceID: deviceID, generation: generation, highestContiguousSequence: highestContiguousSequence, receipt: receipt, now: now())
    }

    /// 读取快照清单并校验其自洽性。
    ///
    /// 除代次与基准序号外，还会校验页数、条目数与字节数落在编解码器上限内，
    /// 且三者之间的数量关系一致；任一项不符都视为持久化状态损坏。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    /// - Returns: 已校验的快照清单。
    /// - Throws: 参数不可编码时抛出 ``V2SyncServiceError/invalidRequest``；
    ///   清单与请求不符或数量关系异常时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64) async throws -> V2SnapshotManifest {
        try validate(generation: generation)
        let manifest = try await store.fetchSnapshotManifest(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, now: now())
        try validateReturnedPosition(generation: manifest.generation, sequence: manifest.baseSequence)
        guard manifest.snapshotID == snapshotID, manifest.generation == generation else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard manifest.pageCount <= V2SnapshotProjectionV3Codec.maximumPageCount,
              manifest.totalItems <= V2SnapshotProjectionV3Codec.maximumTotalItems,
              manifest.totalBytes <= V2SnapshotProjectionV3Codec.maximumTotalBytes,
              (manifest.pageCount == 0) == (manifest.totalItems == 0),
              (manifest.pageCount == 0) == (manifest.totalBytes == 0),
              manifest.totalItems >= UInt64(manifest.pageCount),
              manifest.totalItems <= UInt64(manifest.pageCount) * UInt64(V2SnapshotProjectionV3Codec.maximumPageItems),
              manifest.totalBytes >= UInt64(manifest.pageCount),
              manifest.totalBytes <= UInt64(manifest.pageCount) * UInt64(V2SnapshotProjectionV3Codec.maximumPageBytes) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return manifest
    }

    /// 读取快照分页并校验其与请求一致。
    ///
    /// 返回页的快照标识、代次、根摘要与页序号都必须与请求完全一致，
    /// 页内条目数与载荷长度需落在编解码器上限内且非空。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - rootDigest: 期望的根摘要。
    ///   - index: 页序号。
    /// - Returns: 已校验的快照分页。
    /// - Throws: 参数不可编码时抛出 ``V2SyncServiceError/invalidRequest``；
    ///   返回内容与请求不符或超出上限时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32) async throws -> V2SnapshotPage {
        try validate(generation: generation)
        let page = try await store.fetchSnapshotPage(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, rootDigest: rootDigest, index: index, now: now())
        try validateReturnedPosition(generation: page.generation)
        guard page.snapshotID == snapshotID, page.generation == generation,
              page.rootDigest == rootDigest, page.index == index else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard page.itemCount > 0, page.itemCount <= V2SnapshotProjectionV3Codec.maximumPageItems,
              !page.payload.isEmpty, page.payload.count <= V2SnapshotProjectionV3Codec.maximumPageBytes else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return page
    }

    /// 确认快照已接收完成。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次，需大于零。
    ///   - baseSequence: 快照基准序号，可为零。
    ///   - receipt: 本次确认回执。
    /// - Throws: 参数不可编码时抛出 ``V2SyncServiceError/invalidRequest``；
    ///   其余错误来自存储实现。
    public func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt) async throws {
        try validate(generation: generation, sequence: baseSequence)
        try await store.acknowledgeSnapshot(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, baseSequence: baseSequence, receipt: receipt, now: now())
    }

    /// 校验存储返回的代次与序号。
    ///
    /// - Parameters:
    ///   - generation: 返回的代次，需大于零。
    ///   - sequence: 返回的序号，默认为零。
    /// - Throws: 任一取值超界时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    private func validateReturnedPosition(generation: UInt64, sequence: UInt64 = 0) throws {
        guard generation > 0, generation <= UInt64(Int64.max), sequence <= UInt64(Int64.max) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// 校验调用方传入的代次与序号。
    ///
    /// 代次从不为零；序号为零对空账号是合法的，但两者都必须能写入持久化的有符号计数。
    ///
    /// - Parameters:
    ///   - generation: 同步代次。
    ///   - sequence: 同步序号，默认为零。
    /// - Throws: 代次为零或任一取值超出有符号 64 位范围时抛出
    ///   ``V2SyncServiceError/invalidRequest``。
    private func validate(generation: UInt64, sequence: UInt64 = 0) throws {
        // 不会签发代次零。空账户的序号可以为零；
        // 两个字段都必须能放入持久化的有符号计数器。
        guard generation > 0, Int64(exactly: generation) != nil,
              Int64(exactly: sequence) != nil else {
            throw V2SyncServiceError.invalidRequest
        }
    }
}
