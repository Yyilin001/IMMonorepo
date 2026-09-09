import Foundation
import IMV2Core

/// 单个同步周期的结果，区分增量完成与仍待快照恢复的状态。
public enum V2SyncCycleResult: Equatable, Sendable {
    /// 本地应用水位及服务端声明的更多记录标志；如游标含待确认回执，本周期已完成发送确认及本地确认记账。
    case synchronized(appliedThrough: UInt64, hasMore: Bool)
    /// 需要完成快照恢复；此结果不表示快照已经下载或激活。
    case resetPending(V2ClientResetRequired)
}

/// 有页数预算的增量同步汇总，不包含快照下载工作。
public struct V2IncrementalSyncResult: Equatable, Sendable {
    /// 停止原因：已追赶完成、达到页数预算，或遇到待恢复快照。
    public enum StopReason: Equatable, Sendable { case caughtUp, pageLimit, resetPending }
    /// 已经执行的同步周期数，遇到已有 reset 而未拉取页面的周期也计入此数。
    public let processedPageCount: Int
    /// 任一成功增量周期的应用水位是否高于周期开始时的值；不表示所有本地表都发生了变化。
    public let didCommitNewRecords: Bool
    /// 本次有界同步停止的原因。
    public let stopReason: StopReason
}

/// 客户端可靠同步状态机，协调增量批次与快照恢复。
///
/// 整项 pull／apply／ACK 通过 operation gate 串行化，不能只依赖 actor 跨 await 的隔离。
/// 增量先提交本地投影和待确认信息，再确认服务端；快照先完成 shadow 导入和服务端
/// 幂等确认，再激活本地投影。两者提交顺序不同，审核时不得混用。
public actor V2SyncEngine: V2SyncDriving {
    /// 拉取与确认同步数据的传输依赖。
    private let transport: any V2ClientSyncTransport
    /// 持久化投影、游标与可恢复快照状态的存储边界。
    private let store: any V2LocalSyncStore
    /// 每次增量拉取请求的最大记录数。
    private let maxRecords: Int
    /// 本客户端接受的投影能力配置，必须与批次和快照完全匹配。
    private let capabilityProfile: String
    /// 覆盖整项异步同步工作的共享独占许可。
    private let operationGate: V2SyncOperationGate
    /// 激活后尽力清理旧快照表的任务；替换或析构时请求取消，不等待其退出。
    private var retiredSnapshotCleanupTask: Task<Void, Never>?

    /// 创建同步引擎并配置持久化与传输依赖。
    ///
    /// - Parameters:
    ///   - transport: 增量和快照传输实现。
    ///   - store: 保存同步状态的本地存储。
    ///   - capabilityProfile: 非空能力配置；只检查去除首尾空白后是否为空，保存及比较仍使用原始字符串。
    ///   - maxRecords: 每次增量拉取的记录上限，必须大于零。
    ///   - operationGate: 写入同一存储的多个同步引擎应共享的操作门。
    ///
    /// 非法记录上限或空能力配置触发前置条件失败。初始化不发起网络或数据库工作。
    public init(
        transport: any V2ClientSyncTransport,
        store: any V2LocalSyncStore,
        capabilityProfile: String,
        maxRecords: Int = 500,
        operationGate: V2SyncOperationGate = .init()
    ) {
        precondition(maxRecords > 0 && !capabilityProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        self.transport = transport
        self.store = store
        self.capabilityProfile = capabilityProfile
        self.maxRecords = maxRecords
        self.operationGate = operationGate
    }

    deinit {
        retiredSnapshotCleanupTask?.cancel()
    }

    /// 执行一个增量同步周期，或报告已有／新发现的快照恢复需求。
    ///
    /// - Returns: 当前落盘水位和是否还有增量，或待处理 reset。
    /// - Throws: 取消、传输、批次验证或本地存储错误；失败不能被当作已确认批次。
    public func synchronizeOnce() async throws -> V2SyncCycleResult {
        try await operationGate.run { try await self.performSyncCycle() }
    }

    /// 处理最多指定页数的增量同步，适用于受预算约束的后台入口。
    ///
    /// 不下载快照；遇到 reset 时保存恢复需求并返回。总时间期限和取消由调用者持有。
    ///
    /// - Parameter maximumPages: 最大处理页数，必须大于零。
    /// - Returns: 处理页数、是否提交新记录及停止原因。
    /// - Throws: 取消、传输、验证或存储错误。
    public func synchronizeIncrementally(maximumPages: Int) async throws -> V2IncrementalSyncResult {
        precondition(maximumPages > 0)
        var committed = false
        for page in 1...maximumPages {
            try Task.checkCancellation()
            let (result, changed) = try await operationGate.run { try await self.performMeasuredSyncCycle() }
            committed = committed || changed
            switch result {
            case .resetPending:
                return .init(processedPageCount: page, didCommitNewRecords: committed, stopReason: .resetPending)
            case .synchronized(_, hasMore: false):
                return .init(processedPageCount: page, didCommitNewRecords: committed, stopReason: .caughtUp)
            case .synchronized(_, hasMore: true): break
            }
        }
        return .init(processedPageCount: maximumPages, didCommitNewRecords: committed, stopReason: .pageLimit)
    }

    /// 读取周期开始水位并执行同步，用成功增量结果的水位是否增加判断是否提交新记录；reset 结果不计为新增记录。
    private func performMeasuredSyncCycle() async throws -> (V2SyncCycleResult, Bool) {
        let previous = try await store.cursor()?.appliedSequence ?? 0
        let result = try await performSyncCycle()
        guard case .synchronized(let sequence, _) = result else { return (result, false) }
        return (result, sequence > previous)
    }

    /// 在已持有操作许可时执行拉取、落盘和确认。
    ///
    /// 已有 pending reset 时直接返回，避免重放服务端快照确认前的旧令牌。服务端明确拒绝同步令牌时，
    /// 按当前 generation 丢弃本地同步能力并仅重试一次无令牌拉取。
    ///
    /// 增量必须匹配能力配置，且不能替代已要求的快照重建。先原子应用批次，再发送游标保存的精确回执，
    /// 最后记录服务端确认。确认或记账失败不撤销已落盘投影，重试依靠持久化游标与回执。
    private func performSyncCycle() async throws -> V2SyncCycleResult {
        try Task.checkCancellation()
        let cursorBeforePull = try await store.cursor()
        // A restart may happen after the server committed the snapshot ACK but
        // before the local shadow projection was activated. Do not send the
        // old continuation token in that state; resume the durable import and
        // replay the idempotent snapshot ACK first.
        if let cursorBeforePull, let reset = cursorBeforePull.pendingReset {
            return .resetPending(reset)
        }
        let requireSnapshot = try await store.requiresSnapshotRebuild()
        let pull: V2ClientPullResult
        do {
            pull = try await transport.pull(
                syncToken: requireSnapshot ? nil : cursorBeforePull?.syncToken,
                maxRecords: maxRecords,
                requireSnapshot: requireSnapshot
            )
        } catch let error as V2RealtimeTransportError {
            guard case .server(code: "SYNC_TOKEN_INVALID", retryable: false, _, _) = error,
                  let cursorBeforePull
            else { throw error }
            try await store.discardSyncCapabilities(generation: cursorBeforePull.generation)
            pull = try await transport.pull(syncToken: nil, maxRecords: maxRecords, requireSnapshot: requireSnapshot)
        }
        try Task.checkCancellation()
        switch pull {
        case .ready(let batch):
            guard !requireSnapshot else { throw V2ClientSyncError.snapshotRebuildRequired }
            guard batch.capabilityProfile == capabilityProfile else { throw V2ClientSyncError.unsupportedCapabilityProfile }
            let cursor = try await store.apply(batch)
            guard cursor.state == .ready else { throw V2ClientSyncError.resetPending }
            if let receipt = cursor.pendingAcknowledgementReceipt,
               let sequence = cursor.pendingAcknowledgementSequence
            {
                try Task.checkCancellation()
                try await transport.acknowledge(generation: cursor.generation, highestContiguousSequence: sequence, receipt: receipt)
                try await store.markServerAcknowledged(generation: cursor.generation, sequence: sequence, receipt: receipt)
            }
            return .synchronized(appliedThrough: cursor.appliedSequence, hasMore: batch.hasMore)
        case .resetRequired(let reset):
            try await store.beginReset(reset)
            return .resetPending(reset)
        }
    }

    /// 逐批追赶至无更多增量，或遇到需要快照的状态。
    ///
    /// 此入口没有固定页数预算；后台有限执行应使用有界增量入口。
    ///
    /// - Returns: 最后一次同步周期结果。
    /// - Throws: 同步周期的传输、验证、持久化或取消错误。
    public func synchronizeUntilCaughtUp() async throws -> V2SyncCycleResult {
        while true {
            let result = try await synchronizeOnce()
            guard case .synchronized(_, let hasMore) = result, hasMore else { return result }
        }
    }

    /// 恢复已持久化的快照导入，并在服务端确认后原子激活本地投影。
    ///
    /// 分页写入 shadow 状态；进程在服务端 ACK 与本地激活之间中断后，可继续相同恢复。
    /// 旧就绪投影不能因仅下载了部分页面就被清空。
    ///
    /// - Throws: 无 pending reset、快照无效／过期、传输、存储或取消错误。
    public func completePendingReset() async throws {
        try await operationGate.run { try await self.performPendingReset() }
    }

    /// 在操作许可内恢复快照下载、验证、服务端确认与本地激活。
    ///
    /// 优先复用已导入的 manifest，从持久化的下一页继续；每页落入 shadow 状态。
    /// 激活准备完成后发送快照确认，再切换本地表与游标。确认成功后不额外插入取消检查，继续尝试本地激活，
    /// 减少两端已切换状态不同的窗口；激活失败仍由持久化导入状态支持恢复。
    ///
    /// 激活后启动可取消的旧表清理任务，其错误被忽略，清理不延长快照确认的关键事务。
    private func performPendingReset() async throws {
        guard let cursor = try await store.cursor(), let reset = cursor.pendingReset else {
            throw V2ClientSyncError.noResetPending
        }
        let manifest: V2ClientSnapshotManifest
        if let imported = try await store.importedSnapshotManifest(for: reset) {
            manifest = imported
        } else {
            do {
                manifest = try await transport.fetchSnapshotManifest(for: reset)
            } catch let error as V2RealtimeTransportError {
                try await cancelResetIfRejected(error, reset: reset)
                throw error
            }
        }
        guard manifest.reset == reset else { throw V2ClientSyncError.snapshotMismatch }
        guard manifest.capabilityProfile == capabilityProfile else { throw V2ClientSyncError.unsupportedCapabilityProfile }
        try await store.beginSnapshotImport(
            manifest,
            initialDigest: V2SnapshotV3Digest.initial(
                baseSequence: manifest.reset.baseSequence,
                capabilityProfile: manifest.capabilityProfile
            )
        )
        var index = try await store.nextSnapshotPageIndex(for: manifest)
        while index < manifest.pageCount {
            try Task.checkCancellation()
            let page: V2ClientSnapshotPage
            do {
                page = try await transport.fetchSnapshotPage(for: manifest, index: index)
            } catch let error as V2RealtimeTransportError {
                try await cancelResetIfRejected(error, reset: reset)
                throw error
            }
            try await store.applySnapshotPage(page, for: manifest)
            index += 1
        }
        try Task.checkCancellation()
        try await store.prepareSnapshotActivation(manifest)
        do {
            try await transport.acknowledgeSnapshot(manifest)
        } catch let error as V2RealtimeTransportError {
            try await cancelResetIfRejected(error, reset: reset)
            throw error
        }
        try await store.activateAcknowledgedSnapshot(manifest)
        // Reclaiming the old b-trees can touch every retired page. It is safe
        // to run after the cursor fence is visible and must never extend the
        // acknowledged-snapshot activation transaction. The engine owns this
        // best-effort task so replacement/deinitialization can cancel it; it
        // is not an orphaned task that silently outlives the sync lifecycle.
        retiredSnapshotCleanupTask?.cancel()
        retiredSnapshotCleanupTask = Task { [store] in
            guard !Task.isCancelled else { return }
            try? await store.cleanupRetiredSnapshotTables()
        }
    }

    /// 只在服务端对该 reset 返回不可重试的 RESET_REQUIRED 时取消本地恢复。
    ///
    /// - Parameters:
    ///   - error: 快照 manifest、分页或确认阶段收到的传输错误。
    ///   - reset: 本次处理的精确恢复标识。
    /// - Throws: 取消本地 reset 的存储错误；其他服务端错误不会改变恢复状态。
    ///
    /// 此时旧投影尚未激活替换，存储可以恢复旧游标。调用者仍会传播原传输错误，除非本地取消先失败。
    private func cancelResetIfRejected(
        _ error: V2RealtimeTransportError,
        reset: V2ClientResetRequired
    ) async throws {
        // RESET_REQUIRED is a terminal fence result for this exact reset: the
        // server either expired and rolled it back or superseded it. The live
        // projection was never replaced, so restoring the old cursor is safe.
        if case .server(code: "RESET_REQUIRED", retryable: false, _, _) = error {
            try await store.cancelReset(reset)
        }
    }

}
