import Foundation
import IMV2Core

/// 按用户同步序列排序的一条投影记录。
///
/// 构造时只验证序列范围与非零要求；投影类型、载荷和跨记录连续性由应用批次的存储实现检查。
public struct V2ClientSyncRecord: Equatable, Sendable {
    /// 本用户同步序列，范围为 1 到 Int64.max。
    public let sequence: UInt64
    /// 产生此投影的源事件身份。
    public let sourceEventID: EventID
    /// 投影类型名称，由应用层解释。
    public let projectionKind: String
    /// 投影原始载荷。
    public let payload: Data

    /// 创建一条待应用的投影记录。
    ///
    /// - Parameters:
    ///   - sequence: 非零且不超过 Int64.max 的序列。
    ///   - sourceEventID: 源事件身份。
    ///   - projectionKind: 投影类型名称。
    ///   - payload: 原始投影载荷。
    /// - Throws: 超范围或零序列错误；此处不解析载荷。
    public init(sequence: UInt64, sourceEventID: EventID, projectionKind: String, payload: Data) throws {
        guard sequence <= UInt64(Int64.max) else { throw V2ClientSyncError.storageRangeExceeded }
        guard sequence > 0 else { throw V2ClientSyncError.invalidRecordOrdering }
        self.sequence = sequence
        self.sourceEventID = sourceEventID
        self.projectionKind = projectionKind
        self.payload = payload
    }
}

/// 服务端返回的一批增量记录及其继续拉取令牌和确认回执；构造成功不代表记录已应用。
public struct V2ClientSyncBatch: Equatable, Sendable {
    /// 非零同步代际，必须可持久化为有符号整数。
    public let generation: UInt64
    /// 服务端提供的有序记录，顺序由存储应用时验证。
    public let records: [V2ClientSyncRecord]
    /// 与本次应用水位一起落盘的后续拉取能力。
    public let nextSyncToken: V2SyncToken
    /// 确认本批连续范围所用的服务端回执。
    public let receipt: V2SyncReceipt
    /// 服务端是否声明仍有后续记录。
    public let hasMore: Bool
    /// 本批投影采用的能力配置。
    public let capabilityProfile: String

    /// 保存增量批次，检查代际的整数范围与非零要求。
    ///
    /// - Parameters:
    ///   - generation: 服务端同步代际。
    ///   - records: 待验证应用的记录序列。
    ///   - nextSyncToken: 下一次拉取能力。
    ///   - receipt: 本批确认回执。
    ///   - hasMore: 是否有后续批次。
    ///   - capabilityProfile: 投影能力配置。
    /// - Throws: 代际超出持久化范围或为零时抛出错误。
    ///
    /// 此处不校验跨记录顺序、能力配置或回执与记录的对应关系。
    public init(generation: UInt64, records: [V2ClientSyncRecord], nextSyncToken: V2SyncToken, receipt: V2SyncReceipt, hasMore: Bool, capabilityProfile: String) throws {
        guard generation <= UInt64(Int64.max) else { throw V2ClientSyncError.storageRangeExceeded }
        guard generation > 0 else { throw V2ClientSyncError.generationMismatch }
        self.generation = generation
        self.records = records
        self.nextSyncToken = nextSyncToken
        self.receipt = receipt
        self.hasMore = hasMore
        self.capabilityProfile = capabilityProfile
    }
}

/// 快照恢复所需的身份、代际、基准水位和服务端期限。
public struct V2ClientResetRequired: Equatable, Sendable {
    /// 本次恢复对应的快照身份。
    public let snapshotID: SnapshotID
    /// 恢复绑定的同步代际，必须大于零。
    public let generation: UInt64
    /// 快照的基准水位，允许零。
    public let baseSequence: UInt64
    /// 服务端声明的恢复期限；构造只要求时间有限，不检查是否已到期。
    public let expiresAt: Date

    /// 创建可持久化的快照恢复信息。
    ///
    /// - Parameters:
    ///   - snapshotID: 快照身份。
    ///   - generation: 非零代际。
    ///   - baseSequence: 允许为零的基准水位。
    ///   - expiresAt: 有限的到期时间。
    /// - Throws: 整数超范围、零代际或非有限到期时间错误。
    ///
    /// 不读取当前时钟，因此已过期但有限的日期仍可构造。
    public init(snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, expiresAt: Date) throws {
        guard generation <= UInt64(Int64.max), baseSequence <= UInt64(Int64.max) else { throw V2ClientSyncError.storageRangeExceeded }
        guard generation > 0 else { throw V2ClientSyncError.generationMismatch }
        guard expiresAt.timeIntervalSince1970.isFinite else { throw V2ClientSyncError.snapshotMismatch }
        self.snapshotID = snapshotID
        self.generation = generation
        self.baseSequence = baseSequence
        self.expiresAt = expiresAt
    }

    /// 检查代际非零且代际与基准水位均可放入 SQLite 有符号整数。
    var hasPersistableIntegers: Bool {
        generation > 0 && generation <= UInt64(Int64.max) && baseSequence <= UInt64(Int64.max)
    }
}

/// 增量拉取结果：可应用批次或必须进入快照恢复。
public enum V2ClientPullResult: Equatable, Sendable {
    /// 获得可供存储验证与应用的增量批次。
    case ready(V2ClientSyncBatch)
    /// 服务端要求按指定恢复信息切换到快照流程。
    case resetRequired(V2ClientResetRequired)
}

/// 描述一次快照的完整性、规模与激活后同步能力。
///
/// 构造时校验页数、总条数与总字节的预算及相互关系；摘要真实性、页面内容和能力配置匹配由导入流程进一步验证。
public struct V2ClientSnapshotManifest: Equatable, Sendable {
    /// manifest 所属的精确恢复信息。
    public let reset: V2ClientResetRequired
    /// 快照根摘要；格式与内容验证由导入流程负责。
    public let rootDigest: String
    /// 快照页数，空快照为零。
    public let pageCount: Int
    /// 所有页面投影条数总和。
    public let totalItems: UInt64
    /// 所有页面载荷字节总和。
    public let totalBytes: UInt64
    /// 快照激活后继续同步的能力。
    public let nextSyncToken: V2SyncToken
    /// 向服务端确认此快照的回执。
    public let receipt: V2SyncReceipt
    /// 快照投影能力配置。
    public let capabilityProfile: String

    /// 验证快照规模关系并保存恢复所需的元数据。
    ///
    /// - Parameters:
    ///   - reset: 可持久化的恢复信息。
    ///   - rootDigest: 声明的根摘要。
    ///   - pageCount: 不超过协议上限的页数。
    ///   - totalItems: 总条数，需与页数及每页上限相容。
    ///   - totalBytes: 总字节数，需与页数及每页字节上限相容。
    ///   - nextSyncToken: 激活后的拉取能力。
    ///   - receipt: 快照确认回执。
    ///   - capabilityProfile: 投影能力配置。
    /// - Throws: 规模或恢复整数关系无效时抛出快照不匹配错误。
    ///
    /// 页数为零当且仅当总条数和总字节数均为零；非空快照每页至少贡献一条和一个字节。
    /// 构造不验证摘要、能力配置或实际页面内容。
    public init(reset: V2ClientResetRequired, rootDigest: String, pageCount: Int, totalItems: UInt64, totalBytes: UInt64, nextSyncToken: V2SyncToken, receipt: V2SyncReceipt, capabilityProfile: String) throws {
        guard reset.hasPersistableIntegers,
              (0 ... V2SnapshotProjectionV3Codec.maximumPageCount).contains(pageCount),
              totalItems <= V2SnapshotProjectionV3Codec.maximumTotalItems,
              totalBytes <= V2SnapshotProjectionV3Codec.maximumTotalBytes,
              (pageCount == 0) == (totalItems == 0),
              (pageCount == 0) == (totalBytes == 0),
              pageCount == 0 || (
                  totalItems >= UInt64(pageCount)
                  && totalItems <= UInt64(pageCount * V2SnapshotProjectionV3Codec.maximumPageItems)
                  && totalBytes >= UInt64(pageCount)
                  && totalBytes <= UInt64(pageCount) * UInt64(V2SnapshotProjectionV3Codec.maximumPageBytes)
              )
        else { throw V2ClientSyncError.snapshotMismatch }
        self.reset = reset
        self.rootDigest = rootDigest
        self.pageCount = pageCount
        self.totalItems = totalItems
        self.totalBytes = totalBytes
        self.nextSyncToken = nextSyncToken
        self.receipt = receipt
        self.capabilityProfile = capabilityProfile
    }
}

/// 单页快照投影及其排序范围和摘要，导入时仍需验证实际载荷与 manifest。
public struct V2ClientSnapshotPage: Equatable, Sendable {
    /// 从零开始的页面下标。
    public let index: Int
    /// 该页声明的摘要，构造时不重新计算。
    public let digest: String
    /// 该页声明的首个投影排序键。
    public let firstKey: V2SnapshotProjectionKey
    /// 该页声明的最后投影排序键。
    public let lastKey: V2SnapshotProjectionKey
    /// 声明的投影条数，必须为正且不超过单页上限。
    public let itemCount: Int
    /// 编码后的页面投影载荷，实际字节预算由后续解码与导入验证。
    public let payload: Data

    /// 保存快照页面并检查下标与声明条数的范围。
    ///
    /// - Parameters:
    ///   - index: 从零开始且小于协议总页数上限的下标。
    ///   - digest: 声明的页面摘要。
    ///   - firstKey: 声明的首键。
    ///   - lastKey: 声明的末键。
    ///   - itemCount: 正且不超过单页上限的条数。
    ///   - payload: 页面载荷。
    /// - Throws: 下标无效时抛出快照不匹配错误，条数无效时抛出投影冲突错误。
    ///
    /// 此处不核对具体 manifest 页数、键顺序、摘要或载荷内容，导入边界需继续验证。
    public init(index: Int, digest: String, firstKey: V2SnapshotProjectionKey, lastKey: V2SnapshotProjectionKey, itemCount: Int, payload: Data) throws {
        guard (0..<V2SnapshotProjectionV3Codec.maximumPageCount).contains(index) else { throw V2ClientSyncError.snapshotMismatch }
        guard (1...V2SnapshotProjectionV3Codec.maximumPageItems).contains(itemCount) else { throw V2ClientSyncError.snapshotProjectionConflict }
        self.index = index
        self.digest = digest
        self.firstKey = firstKey
        self.lastKey = lastKey
        self.itemCount = itemCount
        self.payload = payload
    }
}

/// 客户端同步模型与本地持久化边界的合同错误。
public enum V2ClientSyncError: Error, Equatable, Sendable {
    /// 协议无符号整数超出 SQLite 有符号 INTEGER 可保存的范围。
    case storageRangeExceeded
    /// 记录序列为零，或批次应用发现顺序不符合要求。
    case invalidRecordOrdering
    /// 本地要求完整快照重建，当前增量批次不能满足该要求。
    case snapshotRebuildRequired
    /// 同步代际或同代水位关系不符合约束。
    case generationMismatch
    /// 当前处于快照恢复状态，不能按就绪增量路径处理。
    case resetPending
    /// 调用快照恢复操作时没有待恢复状态。
    case noResetPending
    /// 恢复标识、代际或游标阶段不匹配。
    case resetFenceMismatch
    /// 快照身份、时间、规模或完整性数据不匹配。
    case snapshotMismatch
    /// 快照投影条数、排序或应用结果发生冲突。
    case snapshotProjectionConflict
    /// 确认回执与待确认水位不成对或不符合当前游标合同。
    case acknowledgementReceiptMismatch
    /// 同步数据的能力配置与当前客户端要求不匹配。
    case unsupportedCapabilityProfile
}

/// 本地投影、同步能力与恢复流程的持久化游标。
///
/// 应用水位与继续令牌需在同一事务保存；已应用但未获服务端确认的范围保留精确回执。
/// reset 状态必须携带同代恢复信息，不能同时保留待增量确认回执。
public struct V2LocalSyncCursor: Equatable, Sendable {
    /// 游标阶段：可继续增量同步，或等待快照恢复完成。
    public enum State: String, Equatable, Sendable { case ready, resetPending }
    /// 就绪或待恢复阶段。
    public let state: State
    /// 当前本地同步代际。
    public let generation: UInt64
    /// 已原子应用到投影的最高连续水位。
    public let appliedSequence: UInt64
    /// 已记录服务端确认的水位，不能超过应用水位。
    public let serverAcknowledgedSequence: UInt64
    /// 与应用水位在同一 SQLite 事务保存的继续拉取能力。
    public let syncToken: V2SyncToken?
    /// 已落盘但仍待确认的精确回执，可在进程重启后重试。
    public let pendingAcknowledgementReceipt: V2SyncReceipt?
    /// 与待确认回执成对的水位，严格高于已确认水位且不超过应用水位。
    public let pendingAcknowledgementSequence: UInt64?
    /// 仅在待恢复阶段存在的同代快照恢复信息。
    public let pendingReset: V2ClientResetRequired?

    /// 验证游标阶段、水位、回执与恢复信息的一致性。
    ///
    /// - Parameters:
    ///   - state: 就绪或待恢复阶段。
    ///   - generation: 非零本地代际。
    ///   - appliedSequence: 本地已应用水位。
    ///   - serverAcknowledgedSequence: 服务端已确认水位，不超过应用水位。
    ///   - syncToken: 可选继续拉取能力。
    ///   - pendingAcknowledgementReceipt: 与待确认水位成对出现的回执。
    ///   - pendingAcknowledgementSequence: 就绪阶段的待确认水位，位于已确认水位之后、应用水位以内。
    ///   - pendingReset: 待恢复阶段必须存在且代际匹配的恢复信息。
    /// - Throws: 整数超范围、代际、水位、回执或恢复阶段合同错误。
    ///
    /// 初始化只构造值，投影与此游标的原子保存由存储事务负责。
    public init(
        state: State,
        generation: UInt64,
        appliedSequence: UInt64,
        serverAcknowledgedSequence: UInt64,
        syncToken: V2SyncToken?,
        pendingAcknowledgementReceipt: V2SyncReceipt?,
        pendingAcknowledgementSequence: UInt64?,
        pendingReset: V2ClientResetRequired?
    ) throws {
        let maximum = UInt64(Int64.max)
        guard generation <= maximum, appliedSequence <= maximum,
              serverAcknowledgedSequence <= maximum,
              (pendingAcknowledgementSequence ?? 0) <= maximum,
              (pendingReset?.generation ?? 0) <= maximum,
              (pendingReset?.baseSequence ?? 0) <= maximum
        else { throw V2ClientSyncError.storageRangeExceeded }
        guard generation > 0, serverAcknowledgedSequence <= appliedSequence else {
            throw V2ClientSyncError.generationMismatch
        }
        let hasPendingAcknowledgement = pendingAcknowledgementReceipt != nil || pendingAcknowledgementSequence != nil
        let validPendingAcknowledgement: Bool
        if pendingAcknowledgementReceipt != nil, let pendingAcknowledgementSequence {
            validPendingAcknowledgement = state == .ready &&
                pendingAcknowledgementSequence <= appliedSequence &&
                pendingAcknowledgementSequence > serverAcknowledgedSequence
        } else {
            validPendingAcknowledgement = false
        }
        guard !hasPendingAcknowledgement || validPendingAcknowledgement else {
            throw V2ClientSyncError.acknowledgementReceiptMismatch
        }
        guard (state == .ready) == (pendingReset == nil),
              pendingReset.map({ $0.generation == generation }) ?? true else {
            throw V2ClientSyncError.resetFenceMismatch
        }
        self.state = state
        self.generation = generation
        self.appliedSequence = appliedSequence
        self.serverAcknowledgedSequence = serverAcknowledgedSequence
        self.syncToken = syncToken
        self.pendingAcknowledgementReceipt = pendingAcknowledgementReceipt
        self.pendingAcknowledgementSequence = pendingAcknowledgementSequence
        self.pendingReset = pendingReset
    }
}

/// 提供同步拉取与幂等确认的传输边界，不负责本地投影持久化。
public protocol V2ClientSyncTransport: Sendable {
    /// 拉取下一批同步数据或申请快照恢复。
    ///
    /// - Parameters:
    ///   - syncToken: 本地已落盘的继续能力，无令牌时交由服务端决定起点或恢复。
    ///   - maxRecords: 请求的单批记录预算。
    ///   - requireSnapshot: 本地要求重建时为 `true`，不能以普通增量代替。
    /// - Returns: 增量批次或恢复信息。
    /// - Throws: 取消、传输或服务端拒绝错误。
    func pull(syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool) async throws -> V2ClientPullResult
    /// 确认已原子落盘的连续增量范围。
    ///
    /// - Parameters:
    ///   - generation: 本地游标保存的代际。
    ///   - highestContiguousSequence: 与回执对应的最高连续水位。
    ///   - receipt: 本地持久化的精确待确认回执。
    /// - Throws: 传输或服务端拒绝错误；失败后本地仍需保留可重试状态。
    ///
    /// 调用方必须在本地提交后调用，不能确认仅收到但尚未应用的记录。
    func acknowledge(generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) async throws
    /// 读取指定恢复的快照清单。
    ///
    /// - Parameter reset: 当前持久化恢复信息。
    /// - Returns: 供客户端继续验证身份、能力配置及规模的清单。
    /// - Throws: 传输、恢复过期或服务端拒绝错误。
    func fetchSnapshotManifest(for reset: V2ClientResetRequired) async throws -> V2ClientSnapshotManifest
    /// 读取指定快照页面。
    ///
    /// - Parameters:
    ///   - manifest: 当前恢复的清单。
    ///   - index: 待导入的从零开始页号。
    /// - Returns: 仍需由本地导入验证摘要与内容的页面。
    /// - Throws: 传输、页号或恢复状态错误。
    func fetchSnapshotPage(for manifest: V2ClientSnapshotManifest, index: Int) async throws -> V2ClientSnapshotPage
    /// 向服务端确认已经完整下载并完成本地激活准备的快照。
    ///
    /// - Parameter manifest: 当前导入并验证完成的精确清单。
    /// - Throws: 传输或服务端拒绝错误。
    ///
    /// 调用方在成功返回后才激活本地投影；重启后可能重放同一次确认，服务端应保持幂等语义。
    func acknowledgeSnapshot(_ manifest: V2ClientSnapshotManifest) async throws
}

public extension V2ClientSyncTransport {
    /// 使用普通增量模式拉取，委托完整接口并把 `requireSnapshot` 设为 `false`。
    ///
    /// - Parameters:
    ///   - syncToken: 已保存的继续拉取能力。
    ///   - maxRecords: 单批记录预算。
    /// - Returns: 完整拉取接口的结果，仍可能要求快照恢复。
    /// - Throws: 原样传播完整接口错误。
    func pull(syncToken: V2SyncToken?, maxRecords: Int) async throws -> V2ClientPullResult {
        try await pull(syncToken: syncToken, maxRecords: maxRecords, requireSnapshot: false)
    }
}

/// 客户端同步的事务与恢复状态存储合同。
///
/// 实现负责验证代际、连续水位、回执及快照完整性。增量应用原子保存投影和能力；快照通过私有表分阶段导入，
/// 服务端确认后才激活。共享此存储的同步引擎还需共用操作门，覆盖跨方法的异步流程。
public protocol V2LocalSyncStore: Sendable {
    /// 持久化完整快照重建请求，供后续同步周期读取；不在此下载快照。
    ///
    /// - Throws: 本地存储错误。
    func requestSnapshotRebuild() async throws
    /// 读取是否存在待处理的完整重建要求。
    ///
    /// - Returns: 后续拉取是否必须要求快照。
    /// - Throws: 本地读取错误。
    func requiresSnapshotRebuild() async throws -> Bool
    /// 读取当前持久化游标。
    ///
    /// - Returns: 已存在的游标，首次尚未建立同步状态时可为 `nil`。
    /// - Throws: 存储读取或游标一致性错误。
    func cursor() async throws -> V2LocalSyncCursor?
    /// 令牌被服务端明确拒绝后，按代际清除继续令牌与待确认能力。
    ///
    /// - Parameter generation: 必须与当前就绪游标匹配的代际。
    /// - Throws: 代际、阶段或存储错误。
    ///
    /// 保留已应用投影和水位，避免把能力失效误当作本地数据从未提交。
    func discardSyncCapabilities(generation: UInt64) async throws
    /// 验证并原子应用增量投影，同时保存水位、继续令牌和待确认回执。
    ///
    /// - Parameter batch: 传输返回的完整批次。
    /// - Returns: 提交后的游标，供引擎发送精确确认。
    /// - Throws: 记录顺序、代际、投影或存储错误。
    ///
    /// 不能先推进游标再另行写入投影，也不能在事务未提交时返回成功。
    func apply(_ batch: V2ClientSyncBatch) async throws -> V2LocalSyncCursor
    /// 服务端确认成功后推进本地确认水位并清除匹配的待确认信息。
    ///
    /// - Parameters:
    ///   - generation: 当前同步代际。
    ///   - sequence: 本次已确认的水位。
    ///   - receipt: 与该水位匹配的精确回执。
    /// - Throws: 游标、回执匹配或存储错误。
    func markServerAcknowledged(generation: UInt64, sequence: UInt64, receipt: V2SyncReceipt) async throws
    /// 记录精确恢复信息并进入待恢复阶段，保留旧投影及必要回滚状态。
    ///
    /// - Parameter reset: 服务端要求的恢复标识。
    /// - Throws: 代际、恢复状态或存储错误。
    func beginReset(_ reset: V2ClientResetRequired) async throws
    /// 取消匹配的未激活恢复并恢复旧游标状态。
    ///
    /// - Parameter reset: 必须与当前待恢复信息匹配的标识。
    /// - Throws: 恢复身份、回滚状态或存储错误。
    ///
    /// 由服务端明确拒绝该恢复时调用，不能用于撤销已经确认并激活的新投影。
    func cancelReset(_ reset: V2ClientResetRequired) async throws
    /// 读取已持久化、属于该恢复的导入清单，支持进程重启后继续。
    ///
    /// - Parameter reset: 当前恢复信息。
    /// - Returns: 可复用清单，尚未建立导入时为 `nil`。
    /// - Throws: 恢复状态或存储错误。
    func importedSnapshotManifest(for reset: V2ClientResetRequired) async throws -> V2ClientSnapshotManifest?
    /// 建立或恢复私有快照导入状态，保持当前可见投影完整。
    ///
    /// - Parameters:
    ///   - manifest: 与当前 reset 匹配的清单。
    ///   - initialDigest: 按快照基准水位和能力配置计算的初始摘要。
    /// - Throws: 清单、摘要、恢复身份或存储错误。
    func beginSnapshotImport(_ manifest: V2ClientSnapshotManifest, initialDigest: String) async throws
    /// 读取持久化导入进度。
    ///
    /// - Parameter manifest: 当前导入清单。
    /// - Returns: 下一页的零起始下标，等于页数时表示页面已导入完毕。
    /// - Throws: 清单、进度或存储错误。
    func nextSnapshotPageIndex(for manifest: V2ClientSnapshotManifest) async throws -> Int
    /// 验证并应用一页到私有投影，同时原子推进导入摘要与页号。
    ///
    /// - Parameters:
    ///   - page: 待验证的页面内容。
    ///   - manifest: 所属导入清单。
    /// - Throws: 页号、键顺序、内容、完整性或存储错误。
    ///
    /// 部分导入不能替换当前对业务可见的完整投影。
    func applySnapshotPage(_ page: V2ClientSnapshotPage, for manifest: V2ClientSnapshotManifest) async throws
    /// 在服务端仍认为旧代有效时完成与数据规模有关的激活准备。
    ///
    /// - Parameter manifest: 已完整导入的快照清单。
    /// - Throws: 完整性、恢复状态或存储错误。
    ///
    /// 返回后应阻止会使准备结果过时的投影写入，直到激活或取消恢复。
    func prepareSnapshotActivation(_ manifest: V2ClientSnapshotManifest) async throws
    /// 在有界 schema 事务中切换表名并推进本地代际。
    ///
    /// - Parameter manifest: 已准备完成且已获服务端持久化确认的精确快照。
    /// - Throws: 准备状态、恢复身份或激活事务错误。
    ///
    /// 调用者负责保证服务端确认先于此操作；不能仅因下载完成就切换可见投影。
    func activateAcknowledgedSnapshot(_ manifest: V2ClientSnapshotManifest) async throws
    /// 激活之后回收退役表组。
    ///
    /// - Throws: 清理存储错误，由调用方决定重试或尽力处理。
    ///
    /// 释放大规模 SQLite 树与数据量成比例，必须与激活事务及确认关键路径分离。
    func cleanupRetiredSnapshotTables() async throws
}
