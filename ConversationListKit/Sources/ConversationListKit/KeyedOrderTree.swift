/// 基于隐式树堆的键控顺序统计索引。
///
/// 此索引适用于元素标识稳定但秩频繁变化的列表，例如会话移动到最新位置。
/// 它同时维护键到节点的查找表和子树大小，因此调用方可以更新秩并只读取可见切片，
/// 无需为整个集合重建 `id -> position` 表。
///
/// 该类型不是线程安全的。当它被并发任务共享时，保持一个实例在 actor、串行队列或单个执行器内。
public final class KeyedOrderTree<Key: Hashable, Element> {
    private final class Node {
        let key: Key
        let priority: UInt64
        var element: Element
        var left: Node?
        var right: Node?
        weak var parent: Node?
        var subtreeCount = 1

        init(key: Key, element: Element, priority: UInt64) {
            self.key = key
            self.element = element
            self.priority = priority
        }
    }

    private var root: Node?
    private var nodesByKey: [Key: Node] = [:]
    private var randomState: UInt64

    /// 创建空索引。确定性的种子使得测试可重复；生成的优先级仍然提供预期的平衡树。
    public init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        randomState = seed
    }

    /// 索引元素数量。
    ///
    /// - 复杂度：时间 O(1)，额外空间 O(1)。
    public var count: Int { nodesByKey.count }

    /// 返回 `key` 是否存在。
    ///
    /// - 复杂度：期望时间 O(1)，额外空间 O(1)。
    public func contains(_ key: Key) -> Bool {
        nodesByKey[key] != nil
    }

    /// 返回 `key` 对应的元素，不暴露可变树节点。
    ///
    /// - 复杂度：期望时间 O(1)，额外空间 O(1)。
    public func element(forKey key: Key) -> Element? {
        nodesByKey[key]?.element
    }

    /// 替换元素值，同时保持其秩不变。
    ///
    /// - 返回：当键存在时 `true`。
    /// - 复杂度：期望时间 O(1)，额外空间 O(1)。
    @discardableResult
    public func replaceElement(_ element: Element, forKey key: Key) -> Bool {
        guard let node = nodesByKey[key] else { return false }
        node.element = element
        return true
    }

    /// 从左到右重建完整的有序索引。
    ///
    /// 用于初始加载或真正的服务器重新同步。稳定运行期间的置顶更新应改用 `moveToFront(forKey:)`。
    ///
    /// - 复杂度：期望时间 O(n log n)，总存储 O(n)。
    public func rebuild(_ elements: [Element], key: (Element) -> Key) {
        root = nil
        nodesByKey.removeAll(keepingCapacity: true)
        nodesByKey.reserveCapacity(elements.count)

        for element in elements {
            let elementKey = key(element)
            precondition(nodesByKey[elementKey] == nil, "KeyedOrderTree requires unique keys")
            let node = Node(key: elementKey, element: element, priority: nextPriority())
            nodesByKey[elementKey] = node
            root = merge(root, node)
            root?.parent = nil
        }
    }

    /// 在零基秩 0 处插入新元素。
    ///
    /// - 复杂度：期望时间 O(log n)，额外空间 O(1)。
    public func insertAtFront(_ element: Element, forKey key: Key) {
        precondition(nodesByKey[key] == nil, "KeyedOrderTree requires unique keys")
        let node = Node(key: key, element: element, priority: nextPriority())
        nodesByKey[key] = node
        root = merge(node, root)
        root?.parent = nil
    }

    /// 在指定零基秩处插入尚不存在的元素。
    ///
    /// 请求的位置被限制在 `0...count` 范围内。这使得消息时间线可以在不实例化或移动后续每一行的情况下应用本地事务。
    ///
    /// - 复杂度：期望时间 O(log n)，额外空间 O(log n) 用于
    /// 分治递归。
    public func insert(_ element: Element, forKey key: Key, at requestedPosition: Int) {
        precondition(nodesByKey[key] == nil, "KeyedOrderTree requires unique keys")
        let position = min(max(0, requestedPosition), count)
        let node = Node(key: key, element: element, priority: nextPriority())
        let (prefix, suffix) = split(root, keepingFirst: position)
        nodesByKey[key] = node
        root = merge(prefix, merge(node, suffix))
        root?.parent = nil
    }

    /// 将现有键移动到零基秩 0。
    ///
    /// - 返回：当键存在时 `true`。
    /// - 复杂度：期望时间 O(log n)，额外空间 O(log n) 用于递归。
    @discardableResult
    public func moveToFront(forKey key: Key) -> Bool {
        move(forKey: key, to: 0)
    }

    /// 将现有元素移动到最终顺序中的指定零基秩。
    ///
    /// - 返回：当键存在时 `true`。
    /// - 复杂度：期望时间 O(log n)，额外空间 O(log n) 用于递归。
    @discardableResult
    public func move(forKey key: Key, to requestedPosition: Int) -> Bool {
        guard let node = nodesByKey[key] else { return false }
        let currentPosition = position(of: node)
        let targetPosition = min(max(0, requestedPosition), count - 1)
        guard currentPosition != targetPosition else { return true }

        let (prefix, includingNodeAndSuffix) = split(root, keepingFirst: currentPosition)
        let (target, suffix) = split(includingNodeAndSuffix, keepingFirst: 1)
        let remaining = merge(prefix, suffix)
        let (beforeTarget, afterTarget) = split(remaining, keepingFirst: targetPosition)
        root = merge(beforeTarget, merge(target, afterTarget))
        root?.parent = nil
        return true
    }

    /// 移除并返回 `key` 对应的元素。
    ///
    /// - 复杂度：期望时间 O(log n)，额外空间 O(log n) 用于递归。
    @discardableResult
    public func removeElement(forKey key: Key) -> Element? {
        guard let node = nodesByKey.removeValue(forKey: key) else { return nil }
        let rank = position(of: node)
        let (prefix, includingNodeAndSuffix) = split(root, keepingFirst: rank)
        let (_, suffix) = split(includingNodeAndSuffix, keepingFirst: 1)
        root = merge(prefix, suffix)
        root?.parent = nil
        node.parent = nil
        node.left = nil
        node.right = nil
        return node.element
    }

    /// 返回 `key` 对应的零基秩。
    ///
    /// - 复杂度：期望时间 O(log n)，额外空间 O(1)。
    public func position(ofKey key: Key) -> Int? {
        nodesByKey[key].map(position(of:))
    }

    /// 返回指定零基秩处的元素。
    ///
    /// - 复杂度：期望时间 O(log n)，额外空间 O(1)。
    public func element(at position: Int) -> Element? {
        guard position >= 0, position < count else { return nil }
        var node = root
        var remaining = position
        while let current = node {
            let leftCount = subtreeCount(of: current.left)
            if remaining < leftCount {
                node = current.left
            } else if remaining == leftCount {
                return current.element
            } else {
                remaining -= leftCount + 1
                node = current.right
            }
        }
        return nil
    }

    /// 返回一个连续的、以零为起始的范围及其原始秩。
    ///
    /// 遍历会修剪请求范围之外的完整子树。因此适合用于集合视图的可见区域加上预取窗口。
    ///
    /// - 复杂度：期望时间 O(log n + k)，其中 `k` 是结果数量；
    /// 额外空间复杂度 O(log n + k)。
    public func elements(in positions: Range<Int>) -> [(position: Int, element: Element)] {
        let lowerBound = max(0, positions.lowerBound)
        let upperBound = min(count, positions.upperBound)
        guard lowerBound < upperBound else { return [] }

        var result: [(position: Int, element: Element)] = []
        result.reserveCapacity(upperBound - lowerBound)
        collect(
            from: root,
            subtreeStart: 0,
            requestedRange: lowerBound ..< upperBound,
            result: &result
        )
        return result
    }

    private func nextPriority() -> UInt64 {
        randomState &+= 0x9E37_79B9_7F4A_7C15
        var value = randomState
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private func subtreeCount(of node: Node?) -> Int {
        node?.subtreeCount ?? 0
    }

    private func update(_ node: Node) {
        node.subtreeCount = 1 + subtreeCount(of: node.left) + subtreeCount(of: node.right)
        node.left?.parent = node
        node.right?.parent = node
    }

    private func merge(_ left: Node?, _ right: Node?) -> Node? {
        guard let left else { return right }
        guard let right else { return left }
        if left.priority > right.priority {
            left.right = merge(left.right, right)
            update(left)
            return left
        }
        right.left = merge(left, right.left)
        update(right)
        return right
    }

    /// 将 `node` 拆分为前 `count` 个秩和其余部分。
    private func split(_ node: Node?, keepingFirst count: Int) -> (Node?, Node?) {
        guard let node else { return (nil, nil) }
        let leftCount = subtreeCount(of: node.left)
        if count <= leftCount {
            let (prefix, suffix) = split(node.left, keepingFirst: count)
            node.left = suffix
            update(node)
            prefix?.parent = nil
            node.parent = nil
            return (prefix, node)
        }
        let (prefix, suffix) = split(node.right, keepingFirst: count - leftCount - 1)
        node.right = prefix
        update(node)
        suffix?.parent = nil
        node.parent = nil
        return (node, suffix)
    }

    private func position(of node: Node) -> Int {
        var rank = subtreeCount(of: node.left)
        var current: Node? = node
        while let parent = current?.parent {
            if parent.right === current {
                rank += subtreeCount(of: parent.left) + 1
            }
            current = parent
        }
        return rank
    }

    private func collect(
        from node: Node?,
        subtreeStart: Int,
        requestedRange: Range<Int>,
        result: inout [(position: Int, element: Element)]
    ) {
        guard let node else { return }
        let subtreeEnd = subtreeStart + node.subtreeCount
        guard subtreeEnd > requestedRange.lowerBound, subtreeStart < requestedRange.upperBound else { return }

        let nodePosition = subtreeStart + subtreeCount(of: node.left)
        collect(
            from: node.left,
            subtreeStart: subtreeStart,
            requestedRange: requestedRange,
            result: &result
        )
        if requestedRange.contains(nodePosition) {
            result.append((nodePosition, node.element))
        }
        collect(
            from: node.right,
            subtreeStart: nodePosition + 1,
            requestedRange: requestedRange,
            result: &result
        )
    }
}
