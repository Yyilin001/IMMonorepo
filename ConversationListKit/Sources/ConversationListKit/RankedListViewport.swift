import Foundation

/// 维护固定位置列表使用的有界展示缓存。
///
/// 实时更新被有意地放入队列而不是立即发送给排序 actor。集合控制器每帧刷新时清空队列一次，给 actor 提供一个有序变更批次和一次变更后的视口读取。
@MainActor
public final class RankedListViewport<Row: Identifiable & Sendable>: FixedPositionViewportDataSource where Row.ID: Sendable {
    public init() {}

    public typealias OrderEngine = RankedViewportEngine<Row.ID>
    /// 首次显示从列表顶部开始；预绑定这一小段位置可让首个 UICollectionView
    /// 布局直接取得真实行数据，无需等待下一帧的 actor 读取再替换占位 cell。
    private static var initialLeadingBindingCount: Int { 64 }

    /// UIKit 负责实际条目数量变更。数量相同时不会触发集合重载：actor 顺序改变后，
    /// 只需刷新有界的可见绑定。
    private typealias StructureChange = FixedPositionViewportStructureChange

    public struct StructuralInsertion {
        public let row: Row
        public let position: Int

        public init(row: Row, position: Int) {
            self.row = row
            self.position = position
        }
    }

    public struct StructuralMutationResult {
        public let actorMutationNanoseconds: UInt64
        public let storeMutationNanoseconds: UInt64
        public let previousCount: Int
        public let currentCount: Int
        public let missingRemovalIDs: Set<Row.ID>
        public let duplicateInsertionIDs: Set<Row.ID>
    }

    /// 一个对话的最新展示事实。在重建过程中，它可以由旧的排序 actor 转移到替换的排序 actor。
    public struct RealtimeUpdate {
        public let row: Row
        public let targetPosition: Int?

        public init(row: Row, targetPosition: Int? = nil) {
            self.row = row
            self.targetPosition = targetPosition
        }
    }

    private struct PendingUpdate {
        let sequence: UInt64
        let update: RealtimeUpdate

        init(sequence: UInt64, update: RealtimeUpdate, previous: PendingUpdate?) {
            self.sequence = sequence
            // A later payload-only event retains the most recent ordering intent.
            self.update = .init(row: update.row, targetPosition: update.targetPosition ?? previous?.update.targetPosition)
        }
    }

    public private(set) var totalCount = 0
    /// 前 `pinnedCount` 个 actor 位置是置顶对话。控制器可能会隐藏该区域，但保留相同的 actor 顺序。
    public private(set) var pinnedCount = 0
    private var rowsByID: [Row.ID: Row] = [:]
    private var bindingsByPosition: [Int: Row.ID] = [:]
    private var engine: OrderEngine?
    /// 与 actor 的结构代次保持一致。每帧都携带此令牌，确保旧视口请求无法修改新安装的顺序。
    private var engineGeneration = 0
    private var revision = 0
    private var latestRequestID = 0
    private var frameTask: Task<Void, Never>?
    private var activeStructureID: UUID?
    private var frameRequestQueuedWhileInFlight = false
    private var lastResolvedRanges: [Range<Int>] = []
    private var lastResolvedRevision = -1

    /// 一个对话可能在一帧中收到多个消息。只保留最新的快照，并保留其最新的到达序列号以保证正确的顺序。
    private var pendingUpdatesByID: [Row.ID: PendingUpdate] = [:]
    /// 结构重建开始时，某个帧请求可能已经清空更新，但仍在等待旧 actor。
    private var inFlightPendingUpdates: [PendingUpdate] = []
    private var nextPendingSequence: UInt64 = 0

    /// 每个订阅者持有自己的令牌，并在销毁时移除。独立滚动的列表各自拥有视口缓存。
    private var viewportObservers: [UUID: FixedPositionViewportObserver<Row>] = [:]
    public var onOrderMutationRejected: ((Set<Row.ID>) -> Void)?

    public func addViewportObserver(
        _ observer: FixedPositionViewportObserver<Row>
    ) -> UUID {
        let id = UUID()
        viewportObservers[id] = observer
        return id
    }

    public func removeViewportObserver(id: UUID) {
        viewportObservers.removeValue(forKey: id)
    }

    private func publishStructureChange(_ change: StructureChange) {
        for observer in viewportObservers.values {
            observer.structureChanged(change)
        }
    }

    private func publishFrameWorkAvailable() {
        for observer in viewportObservers.values {
            observer.frameWorkAvailable()
        }
    }

    private func publishBindingsChanged(_ positions: Set<Int>) {
        for observer in viewportObservers.values {
            observer.bindingsChanged(positions)
        }
    }

    public func install(
        engine: OrderEngine,
        generation: Int = 0,
        totalCount: Int,
        pinnedCount: Int,
        rows: [Row],
        primesLeadingBindings: Bool = false
    ) {
        guard self.engine !== engine || generation >= engineGeneration else { return }
        activeStructureID = nil
        let previousCount = self.totalCount
        let previousPinnedCount = self.pinnedCount
        self.engine = engine
        engineGeneration = generation
        self.totalCount = totalCount
        self.pinnedCount = min(max(0, pinnedCount), totalCount)
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        bindingsByPosition.removeAll(keepingCapacity: true)
        if primesLeadingBindings {
            primeLeadingBindings(from: rows)
        }
        clearPendingUpdates()
        inFlightPendingUpdates.removeAll(keepingCapacity: true)
        lastResolvedRanges.removeAll(keepingCapacity: true)
        lastResolvedRevision = -1
        revision &+= 1
        latestRequestID &+= 1
        frameTask = nil
        frameRequestQueuedWhileInFlight = false
        // 更换结构排序 actor 并不意味着必须销毁原生单元格。稳定的位置映射会保留现有单元格；
        // 下一显示帧只重新绑定已实例化的位置。
        publishStructureChange(.snapshotReplaced(
            previous: previousCount,
            current: totalCount,
            mappingChanged: previousPinnedCount != self.pinnedCount
        ))
        publishFrameWorkAvailable()
    }

    private func primeLeadingBindings(from rows: [Row]) {
        for (position, row) in rows.prefix(Self.initialLeadingBindingCount).enumerated() {
            bindingsByPosition[position] = row.id
        }
    }

    public func removeAll() {
        activeStructureID = nil
        engine = nil
        engineGeneration = 0
        totalCount = 0
        pinnedCount = 0
        rowsByID.removeAll(keepingCapacity: true)
        bindingsByPosition.removeAll(keepingCapacity: true)
        clearPendingUpdates()
        inFlightPendingUpdates.removeAll(keepingCapacity: true)
        lastResolvedRanges.removeAll(keepingCapacity: true)
        lastResolvedRevision = -1
        revision &+= 1
        latestRequestID &+= 1
        frameTask = nil
        frameRequestQueuedWhileInFlight = false
        publishStructureChange(.reloadData)
    }

    /// 应用有界插入/删除事务，同时保留现有集合项。下一显示帧只将活动视口重新绑定到 actor 的新排序；
    /// 屏幕外位置仍按需处理。
    ///
    /// 结构事务按业务事件顺序逐个 await。另一事务仍在进行、输入包含重复 ID 或安装代次改变时返回 nil。
    /// - 复杂度：预期 actor 时间 O((r + i) log n)；MainActor 存储时间 O(r + i)。不会发生完整行投影或集合重载。
    public func applyStructuralChange(
        removing ids: [Row.ID],
        inserting insertions: [StructuralInsertion],
        pinnedCountAfterMutation: Int? = nil
    ) async -> StructuralMutationResult? {
        guard let engine, activeStructureID == nil,
              Set(ids).count == ids.count, Set(insertions.map { $0.row.id }).count == insertions.count else { return nil }
        let operation = UUID()
        activeStructureID = operation
        defer {
            if activeStructureID == operation {
                activeStructureID = nil
                publishFrameWorkAvailable()
            }
        }
        // A frame that already handed moves to the actor also owns their row payloads.
        // Let it publish both before inserting/removing keys in that order.
        await frameTask?.value
        guard activeStructureID == operation else { return nil }
        // Earlier queued moves refer to positions before this insertion/removal.
        if !pendingUpdatesByID.isEmpty, totalCount > 0 {
            startFrame(in: lastResolvedRanges.isEmpty ? [0..<1] : lastResolvedRanges)
            await frameTask?.value
            guard activeStructureID == operation else { return nil }
        }
        let previousCount = totalCount
        let actorInsertions = insertions.map {
            OrderEngine.Insertion(key: $0.row.id, position: $0.position)
        }
        let generation = engineGeneration
        let actorResult = await engine.applyStructuralChange(
            removing: ids,
            inserting: actorInsertions,
            expectedGeneration: engineGeneration
        )

        // 现在由更新的结构安装持有 actor。其 Store 安装过程将发布权威行，因此这个过时事务不得修改缓存或集合条目数量。
        guard actorResult.accepted, activeStructureID == operation, engineGeneration == generation else { return nil }

        let storeStartedAt = DispatchTime.now().uptimeNanoseconds
        // 忽略 actor 拒绝的键，这样在重复的 SDK 回调或过时的结构事件之后，行缓存和 actor 顺序不会不一致。
        let removedIDs = ids.filter { !actorResult.missingRemovalKeys.contains($0) }
        let insertedRows = insertions.filter {
            !actorResult.duplicateInsertionKeys.contains($0.row.id)
        }
        for id in removedIDs {
            rowsByID.removeValue(forKey: id)
            // 在删除操作之前入队的消息，在下一个显示帧刷新待呈现数据时，不能复活被孤儿化的行。
            pendingUpdatesByID.removeValue(forKey: id)
        }
        for insertion in insertedRows {
            rowsByID[insertion.row.id] = insertion.row
        }
        totalCount = actorResult.count
        pinnedCount = min(max(0, pinnedCountAfterMutation ?? pinnedCount), totalCount)

        // 使所有仍在执行的结构变更前视口响应失效。下一个显示链接请求会读取一致的变更后 actor 切片。
        revision &+= 1
        latestRequestID &+= 1
        frameTask = nil
        frameRequestQueuedWhileInFlight = false
        lastResolvedRanges.removeAll(keepingCapacity: true)
        lastResolvedRevision = -1

        let storeMutationNanoseconds = DispatchTime.now().uptimeNanoseconds - storeStartedAt
        if previousCount != totalCount {
            publishStructureChange(.itemCountChanged(previous: previousCount, current: totalCount))
        }
        publishFrameWorkAvailable()
        return StructuralMutationResult(
            actorMutationNanoseconds: actorResult.mutationNanoseconds,
            storeMutationNanoseconds: storeMutationNanoseconds,
            previousCount: previousCount,
            currentCount: totalCount,
            missingRemovalIDs: actorResult.missingRemovalKeys,
            duplicateInsertionIDs: actorResult.duplicateInsertionKeys
        )
    }

    /// 将单条实时展示数据排入队列。`targetPosition` 为 nil 表示仅更新内容，否则表示最终排序区间。
    /// 此处不会跳转到 actor，也不会修改集合视图。
    public func enqueueRealtimeUpdate(
        _ row: Row,
        targetPosition: Int?
    ) {
        enqueueRealtimeUpdates([.init(row: row, targetPosition: targetPosition)])
    }

    /// 恢复在构建替换排序 actor 期间捕获的事实。安装后，它们重新进入正常的每帧合并路径。
    public func enqueueRealtimeUpdates(_ updates: [RealtimeUpdate]) {
        guard !updates.isEmpty else { return }
        for realtimeUpdate in updates {
            let id = realtimeUpdate.row.id
            nextPendingSequence &+= 1
            pendingUpdatesByID[id] = .init(sequence: nextPendingSequence, update: realtimeUpdate,
                                           previous: pendingUpdatesByID[id])
        }
        publishFrameWorkAvailable()
    }

    /// 将队列中的事实和 actor 正在处理的事实转移到结构重建中。仅仅使旧请求失效是不够的：它会丢失 `commitFrame` 已经从其待处理字典中提取的批处理。
    public func takeRealtimeUpdatesForStructuralRebuild() -> [RealtimeUpdate] {
        for earlier in inFlightPendingUpdates {
            let id = earlier.update.row.id
            if let later = pendingUpdatesByID[id] {
                pendingUpdatesByID[id] = .init(sequence: later.sequence, update: later.update, previous: earlier)
            } else {
                pendingUpdatesByID[id] = earlier
            }
        }
        let updates = drainPendingUpdatesInArrivalOrder().map(\.update)
        inFlightPendingUpdates.removeAll(keepingCapacity: true)
        latestRequestID &+= 1
        frameTask = nil
        frameRequestQueuedWhileInFlight = false
        return updates
    }

    public func row(withID id: Row.ID) -> Row? { rowsByID[id] }

    public func row(at position: Int) -> Row? {
        guard let id = bindingsByPosition[position] else { return nil }
        return rowsByID[id]
    }

    /// 增量结构事务只有在行缓存覆盖完整 actor 顺序时才安全。受限投影必须退回到结构替换，以确保未见的行不会从树中消失。
    public func hasCompleteRowCache(containing id: Row.ID) -> Bool {
        rowsByID[id] != nil && rowsByID.count == totalCount
    }

    /// 用于增量插入之前。调用方持有新行，因此它只需要证明此缓存中不存在任何现有的 actor 项。
    public func hasCompleteRowCache() -> Bool {
        rowsByID.count == totalCount
    }

    /// 提交恰好一个显示帧事务。
    ///
    /// 它为每个对话获取最新的状态，按到达顺序应用所有等级移动，在同一 actor 执行周期内读取可见窗口，然后才将更改的单元格位置发布回 UIKit。
    public func commitFrame(in requestedRanges: [Range<Int>]) {
        guard activeStructureID == nil else { return }
        startFrame(in: requestedRanges)
    }

    private func startFrame(in requestedRanges: [Range<Int>]) {
        guard let engine, totalCount > 0 else { return }
        if frameTask != nil {
            // 滚动可能会在 actor 读取前一个窗口时改变请求的窗口。保留一个后续请求，而不是在应用正在进行的结果后将新单元格保留在占位符中。
            frameRequestQueuedWhileInFlight = true
            return
        }
        let ranges = normalizedRanges(requestedRanges)
        guard !ranges.isEmpty else { return }

        let pendingUpdates = drainPendingUpdatesInArrivalOrder()
        let needsViewportRead = ranges != lastResolvedRanges || revision != lastResolvedRevision
        guard needsViewportRead || !pendingUpdates.isEmpty else { return }

        latestRequestID &+= 1
        let requestID = latestRequestID
        let requestedRevision = revision
        let expectedGeneration = engineGeneration
        inFlightPendingUpdates = pendingUpdates
        let moves = pendingUpdates.compactMap { update -> OrderEngine.Move? in
            guard let targetPosition = update.update.targetPosition else { return nil }
            return .init(key: update.update.row.id, position: targetPosition)
        }

        frameTask = Task { [weak self, engine] in
            let result = await engine.applyFrame(
                moves: moves,
                reading: ranges,
                expectedGeneration: expectedGeneration
            )
            guard let self else { return }
            guard self.latestRequestID == requestID else { return }
            self.frameTask = nil
            self.inFlightPendingUpdates.removeAll(keepingCapacity: true)
            guard result.accepted else {
                // 一个新的结构化版本在 actor 暂停时无效化了此请求。不要发布它的旧行事实。
                if !self.pendingUpdatesByID.isEmpty || self.frameRequestQueuedWhileInFlight {
                    self.frameRequestQueuedWhileInFlight = false
                    self.publishFrameWorkAvailable()
                }
                return
            }

            var changedPositions = Set<Int>()
            for update in pendingUpdates where !result.missingKeys.contains(update.update.row.id) {
                self.rowsByID[update.update.row.id] = update.update.row
            }
            let updatedIDs = Set(pendingUpdates.map { $0.update.row.id })
            for (position, id) in self.bindingsByPosition where updatedIDs.contains(id) {
                changedPositions.insert(position)
            }
            var nextBindings: [Int: Row.ID] = [:]
            nextBindings.reserveCapacity(result.entries.count)
            for entry in result.entries {
                nextBindings[entry.position] = entry.key
            }
            for (position, previousID) in self.bindingsByPosition where nextBindings[position] != previousID {
                changedPositions.insert(position)
            }
            for (position, nextID) in nextBindings where self.bindingsByPosition[position] != nextID {
                changedPositions.insert(position)
            }

            self.bindingsByPosition = nextBindings
            if !pendingUpdates.isEmpty {
                self.revision &+= 1
            }
            self.lastResolvedRanges = ranges
            self.lastResolvedRevision = max(requestedRevision, self.revision)
            if !result.missingKeys.isEmpty {
                self.onOrderMutationRejected?(result.missingKeys)
            }
            if !changedPositions.isEmpty {
                self.publishBindingsChanged(changedPositions)
            }
            // 在 actor 执行此帧期间，可能会有事件到达。
            if !self.pendingUpdatesByID.isEmpty || self.frameRequestQueuedWhileInFlight {
                self.frameRequestQueuedWhileInFlight = false
                self.publishFrameWorkAvailable()
            }
        }
    }

    private func clearPendingUpdates() {
        pendingUpdatesByID.removeAll(keepingCapacity: true)
    }

    /// 每个 ID 只占一个待处理槽。恢复显示时按最后到达顺序提交。
    private func drainPendingUpdatesInArrivalOrder() -> [PendingUpdate] {
        let updates = pendingUpdatesByID.values.sorted { $0.sequence < $1.sequence }
        clearPendingUpdates()
        return updates
    }

    private func normalizedRanges(_ requestedRanges: [Range<Int>]) -> [Range<Int>] {
        let bounded = requestedRanges.compactMap { requestedRange -> Range<Int>? in
            let lower = max(0, requestedRange.lowerBound)
            let upper = min(totalCount, requestedRange.upperBound)
            return lower < upper ? lower..<upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = bounded.first else { return [] }
        var result: [Range<Int>] = []
        for range in bounded.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound ..< max(current.upperBound, range.upperBound)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }
}
