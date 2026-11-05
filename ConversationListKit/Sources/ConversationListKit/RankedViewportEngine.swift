import Foundation

/// 面向稳定标识、秩频繁变化集合的 actor 隔离排序与视口引擎。
///
/// 引擎故意不包含任何 UI、持久化或领域模型类型。调用方仅在罕见的结构替换时提供不可变值；稳态工作只使用小规模的层级移动和有界位置切片。
public actor RankedViewportEngine<Key: Hashable & Sendable> {
    public struct Entry: Sendable {
        public let position: Int
        public let key: Key

        public init(position: Int, key: Key) {
            self.position = position
            self.key = key
        }
    }

    public struct Move: Sendable {
        public let key: Key
        public let position: Int

        public init(key: Key, position: Int) {
            self.key = key
            self.position = position
        }
    }

    public struct Insertion: Sendable {
        public let key: Key
        public let position: Int

        public init(key: Key, position: Int) {
            self.key = key
            self.position = position
        }
    }

    public struct StructuralResult: Sendable {
        public let accepted: Bool
        public let missingRemovalKeys: Set<Key>
        public let duplicateInsertionKeys: Set<Key>
        public let mutationNanoseconds: UInt64
        public let count: Int
    }

    /// 仅用于罕见的结构投影。帧更新应使用 `applyFrame`，以便调用方仅接收其请求的视口范围。
    public struct ReplacementResult: Sendable {
        public let accepted: Bool
        public let orderedKeys: [Key]
        public let sortNanoseconds: UInt64
    }

    public struct FrameResult: Sendable {
        public let accepted: Bool
        public let entries: [Entry]
        public let missingKeys: Set<Key>
        public let moveNanoseconds: UInt64
        public let sliceNanoseconds: UInt64
    }

    private let index = KeyedOrderTree<Key, Key>()
    private var structuralGeneration = 0

    public init() {}

    /// 替换已排序序列。适用于具有外部权威顺序的测试夹具和调用者。
    ///
    /// - 复杂度：期望时间 O(n log n)，存储 O(n)
    public func replace(with keys: [Key]) {
        index.rebuild(keys, key: { $0 })
    }

    /// 原子性地安装一个已经排序的序列，前提是它的生成时间不早于当前接受的结构生成时间。
    ///
    /// - 复杂度：期望时间 O(n log n)，存储 O(n)
    public func replace(with keys: [Key], generation: Int) -> Bool {
        guard generation >= structuralGeneration else { return false }
        structuralGeneration = generation
        index.rebuild(keys, key: { $0 })
        return true
    }

    /// 在 actor 隔离内对不可变值进行排序，然后原子地替换 `generation` 的索引。
    ///
    /// - 复杂度：O(n log n) 时间和 O(n) 临时空间。`key` 和
    /// `areInIncreasingOrder` 必须是纯 Sendable 闭包。
    public func replace<Value: Sendable>(
        with values: [Value],
        generation: Int,
        key: @Sendable (Value) -> Key,
        areInIncreasingOrder: @Sendable (Value, Value) -> Bool
    ) -> ReplacementResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard generation >= structuralGeneration else {
            return ReplacementResult(
                accepted: false,
                orderedKeys: [],
                sortNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt
            )
        }
        let orderedValues = values.sorted(by: areInIncreasingOrder)
        let orderedKeys = orderedValues.map(key)
        structuralGeneration = generation
        index.rebuild(orderedKeys, key: { $0 })
        return ReplacementResult(
            accepted: true,
            orderedKeys: orderedKeys,
            sortNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt
        )
    }

    /// 失效待处理的结构帧工作并清空完整顺序。
    public func invalidateAndRemoveAll(generation: Int) {
        guard generation >= structuralGeneration else { return }
        structuralGeneration = generation
        index.rebuild([], key: { $0 })
    }

    /// 应用小的插入/删除增量而不重建完整顺序。
    ///
    /// - 复杂度：期望时间为 O((r + i) log n)；结果存储为 O(r + i)。
    public func applyStructuralChange(
        removing keys: [Key],
        inserting insertions: [Insertion],
        expectedGeneration: Int? = nil
    ) -> StructuralResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard expectedGeneration.map({ $0 == structuralGeneration }) ?? true else {
            return StructuralResult(
                accepted: false,
                missingRemovalKeys: [],
                duplicateInsertionKeys: [],
                mutationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt,
                count: index.count
            )
        }
        var missingRemovalKeys = Set<Key>()
        var duplicateInsertionKeys = Set<Key>()
        for key in keys where index.removeElement(forKey: key) == nil {
            missingRemovalKeys.insert(key)
        }
        for insertion in insertions {
            guard !index.contains(insertion.key) else {
                duplicateInsertionKeys.insert(insertion.key)
                continue
            }
            index.insertAtFront(insertion.key, forKey: insertion.key)
            if insertion.position != 0 {
                _ = index.move(forKey: insertion.key, to: insertion.position)
            }
        }
        return StructuralResult(
            accepted: true,
            missingRemovalKeys: missingRemovalKeys,
            duplicateInsertionKeys: duplicateInsertionKeys,
            mutationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt,
            count: index.count
        )
    }

    /// 合并秩移动，并一次性读取请求的视口范围。
    /// actor turn.
    ///
    /// - 复杂度：O(m log n + log n + k)，其中 `m` 是移动次数，`k` 是
    /// 返回的位置总数。
    public func applyFrame(
        moves: [Move],
        reading ranges: [Range<Int>],
        expectedGeneration: Int? = nil
    ) -> FrameResult {
        let moveStartedAt = DispatchTime.now().uptimeNanoseconds
        guard expectedGeneration.map({ $0 == structuralGeneration }) ?? true else {
            return FrameResult(
                accepted: false,
                entries: [],
                missingKeys: [],
                moveNanoseconds: DispatchTime.now().uptimeNanoseconds - moveStartedAt,
                sliceNanoseconds: 0
            )
        }
        var missingKeys = Set<Key>()
        for move in moves where !index.move(forKey: move.key, to: move.position) {
            missingKeys.insert(move.key)
        }
        let sliceStartedAt = DispatchTime.now().uptimeNanoseconds
        let entries = ranges.flatMap { range in
            index.elements(in: range).map { Entry(position: $0.position, key: $0.element) }
        }
        let endedAt = DispatchTime.now().uptimeNanoseconds
        return FrameResult(
            accepted: true,
            entries: entries,
            missingKeys: missingKeys,
            moveNanoseconds: sliceStartedAt - moveStartedAt,
            sliceNanoseconds: endedAt - sliceStartedAt
        )
    }

    /// - 复杂度：O(log n + k)，其中 `k` 是返回切片的长度。
    public func entries(in positions: Range<Int>) -> [Entry] {
        index.elements(in: positions).map { Entry(position: $0.position, key: $0.element) }
    }

    /// - 复杂度：O(区间数量 × log n + k)
    public func entries(in ranges: [Range<Int>]) -> [Entry] {
        ranges.flatMap { range in
            index.elements(in: range).map { Entry(position: $0.position, key: $0.element) }
        }
    }

    public func count() -> Int {
        index.count
    }
}
