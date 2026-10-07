/// One node owns the demand, traversal links, scheduling membership and heap index.
/// The deadline heap contains only exact key/deadline entries, never stale copies.
struct V2RecoveryOrderedStore<Key: Hashable & Sendable, Value: Sendable>: Sendable, Sequence {
    enum SchedulingPlacement: Int, Sendable { case primary, queued, owned }
    struct SchedulingDescriptor: Sendable {
        let classIndex: Int
        let placement: SchedulingPlacement
        let readyAt: ContinuousClock.Instant
        let refreshAt: ContinuousClock.Instant?
        init(classIndex: Int, placement: SchedulingPlacement, readyAt: ContinuousClock.Instant,
             refreshAt: ContinuousClock.Instant? = nil) {
            precondition((0..<7).contains(classIndex))
            self.classIndex = classIndex; self.placement = placement
            self.readyAt = readyAt; self.refreshAt = refreshAt
        }
    }
    fileprivate struct Node: Sendable {
        var value: Value
        var scheduling: SchedulingDescriptor?
        var ready = false
        var previousAll: Key?
        var nextAll: Key?
        var previousReady: Key?
        var nextReady: Key?
        var heapIndex: Int?
    }
    private struct DeadlineEntry: Sendable { let key: Key; let deadline: ContinuousClock.Instant }
    private var nodes: [Key: Node] = [:]
    private var allHeads = [Key?](repeating: nil, count: 21)
    private var allTails = [Key?](repeating: nil, count: 21)
    private var readyHeads = [Key?](repeating: nil, count: 21)
    private var readyTails = [Key?](repeating: nil, count: 21)
    private var allCounts = [Int](repeating: 0, count: 21)
    private var readyCounts = [Int](repeating: 0, count: 21)
    private var placementCounts = [Int](repeating: 0, count: 3)
    private var placementReadyCounts = [Int](repeating: 0, count: 3)
    private var deadlines: [DeadlineEntry] = []
    init() {}
    var count: Int { nodes.count }
    var isEmpty: Bool { nodes.isEmpty }
    var keys: AnySequence<Key> { AnySequence(nodes.keys) }
    func keys(at placement: SchedulingPlacement) -> AnySequence<Key> {
        AnySequence(nodes.lazy.compactMap { key, node in node.scheduling?.placement == placement ? key : nil })
    }
    subscript(key: Key) -> Value? {
        get { nodes[key]?.value }
        set {
            guard let value = newValue else { _ = removeValue(forKey: key); return }
            if nodes[key] != nil { nodes[key]!.value = value; return }
            nodes[key] = Node(value: value)
        }
    }
    func contains(_ key: Key) -> Bool { nodes[key] != nil }
    func scheduling(for key: Key) -> SchedulingDescriptor? { nodes[key]?.scheduling }
    private func bucket(_ descriptor: SchedulingDescriptor) -> Int {
        descriptor.placement.rawValue * 7 + descriptor.classIndex
    }
    func schedulingCount(placement: SchedulingPlacement, classIndex: Int? = nil, eligibleOnly: Bool = false) -> Int {
        guard let classIndex else {
            return eligibleOnly ? placementReadyCounts[placement.rawValue] : placementCounts[placement.rawValue]
        }
        precondition((0..<7).contains(classIndex))
        let index = placement.rawValue * 7 + classIndex
        return eligibleOnly ? readyCounts[index] : allCounts[index]
    }
    func peekScheduled(classIndex: Int, placement: SchedulingPlacement,
                       eligibleOnly: Bool = true) -> (key: Key, value: Value)? {
        precondition((0..<7).contains(classIndex))
        guard placement != .owned else { return nil }
        let index = placement.rawValue * 7 + classIndex
        guard let key = eligibleOnly ? readyHeads[index] : allHeads[index], let node = nodes[key] else { return nil }
        return (key, node.value)
    }
    /// Only actual selection or an explicit victim choice rotates a class FIFO.
    @discardableResult mutating func rotateScheduled(classIndex: Int, placement: SchedulingPlacement,
                       eligibleOnly: Bool = true) -> (key: Key, value: Value)? {
        guard let result = peekScheduled(classIndex: classIndex, placement: placement, eligibleOnly: eligibleOnly),
              let descriptor = nodes[result.key]?.scheduling else { return nil }
        let index = bucket(descriptor), key = result.key
        unlinkAll(key, index: index); appendAll(key, index: index)
        if nodes[key]?.ready == true { unlinkReady(key, index: index); appendReady(key, index: index) }
        return result
    }
    mutating func setScheduling(_ descriptor: SchedulingDescriptor?, for key: Key, now: ContinuousClock.Instant) {
        guard let existing = nodes[key] else { return }
        let old = existing.scheduling
        let wasReady = existing.ready
        let ready = descriptor.map { $0.placement != .owned && $0.readyAt <= now } ?? false
        let sameBucket = old.map { lhs in descriptor.map { bucket(lhs) == bucket($0) } ?? false } ?? false
        if let old, !sameBucket {
            let index = bucket(old)
            if old.placement != .owned { unlinkAll(key, index: index) }
            allCounts[index] -= 1; placementCounts[old.placement.rawValue] -= 1
        }
        if let old, wasReady && (!sameBucket || !ready) {
            let index = bucket(old); unlinkReady(key, index: index)
            readyCounts[index] -= 1; placementReadyCounts[old.placement.rawValue] -= 1
        }
        nodes[key]!.scheduling = descriptor; nodes[key]!.ready = ready
        if let descriptor, !sameBucket {
            let index = bucket(descriptor)
            if descriptor.placement != .owned { appendAll(key, index: index) }
            allCounts[index] += 1; placementCounts[descriptor.placement.rawValue] += 1
        }
        if let descriptor, ready && (!sameBucket || !wasReady) {
            let index = bucket(descriptor); appendReady(key, index: index)
            readyCounts[index] += 1; placementReadyCounts[descriptor.placement.rawValue] += 1
        }
        // Preserve already due refreshes until the owner consumes and reclassifies
        // them. Otherwise an ordinary H update could silently discard expiry work.
        let deadline: ContinuousClock.Instant? = descriptor.flatMap { value in
            guard value.placement != .owned else { return nil }
            let retry = value.readyAt > now ? value.readyAt : nil
            if let refresh = value.refreshAt { return retry.map { Swift.min($0, refresh) } ?? refresh }
            return retry
        }
        updateDeadline(key, deadline: deadline)
    }
    var earliestSchedulingDeadline: ContinuousClock.Instant? { deadlines.first?.deadline }
    var schedulingDeadlineCount: Int { deadlines.count }
    /// Caller reclassifies returned exact keys before selecting another class.
    /// A pending due deadline is never represented by a new task or stale heap ID.
    mutating func popDueScheduling(now: ContinuousClock.Instant, limit: Int = 128) -> [Key] {
        var result: [Key] = []
        let budget = Swift.max(0, Swift.min(limit, 128))
        while result.count < budget, let entry = deadlines.first, entry.deadline <= now {
            result.append(entry.key); removeDeadline(at: 0)
        }
        return result
    }
    private mutating func appendAll(_ key: Key, index: Int) {
        let previous = allTails[index]
        nodes[key]!.previousAll = previous; nodes[key]!.nextAll = nil
        if let previous { nodes[previous]!.nextAll = key } else { allHeads[index] = key }
        allTails[index] = key
    }
    private mutating func unlinkAll(_ key: Key, index: Int) {
        guard let node = nodes[key] else { return }
        if let previous = node.previousAll { nodes[previous]!.nextAll = node.nextAll } else { allHeads[index] = node.nextAll }
        if let next = node.nextAll { nodes[next]!.previousAll = node.previousAll } else { allTails[index] = node.previousAll }
        nodes[key]!.previousAll = nil; nodes[key]!.nextAll = nil
    }
    private mutating func appendReady(_ key: Key, index: Int) {
        let previous = readyTails[index]
        nodes[key]!.previousReady = previous; nodes[key]!.nextReady = nil
        if let previous { nodes[previous]!.nextReady = key } else { readyHeads[index] = key }
        readyTails[index] = key
    }
    private mutating func unlinkReady(_ key: Key, index: Int) {
        guard let node = nodes[key] else { return }
        if let previous = node.previousReady { nodes[previous]!.nextReady = node.nextReady } else { readyHeads[index] = node.nextReady }
        if let next = node.nextReady { nodes[next]!.previousReady = node.previousReady } else { readyTails[index] = node.previousReady }
        nodes[key]!.previousReady = nil; nodes[key]!.nextReady = nil
    }
    private mutating func updateDeadline(_ key: Key, deadline: ContinuousClock.Instant?) {
        if let index = nodes[key]?.heapIndex {
            if let deadline {
                deadlines[index] = .init(key: key, deadline: deadline)
                siftUp(index); siftDown(nodes[key]!.heapIndex!)
            } else { removeDeadline(at: index) }
        } else if let deadline {
            let index = deadlines.count; deadlines.append(.init(key: key, deadline: deadline))
            nodes[key]!.heapIndex = index; siftUp(index)
        }
    }
    private mutating func swapDeadlines(_ a: Int, _ b: Int) {
        guard a != b else { return }
        deadlines.swapAt(a, b)
        nodes[deadlines[a].key]!.heapIndex = a; nodes[deadlines[b].key]!.heapIndex = b
    }
    private mutating func siftUp(_ initial: Int) {
        var index = initial
        while index > 0 {
            let parent = (index - 1) / 2
            guard deadlines[index].deadline < deadlines[parent].deadline else { break }
            swapDeadlines(index, parent); index = parent
        }
    }
    private mutating func siftDown(_ initial: Int) {
        var index = initial
        while index * 2 + 1 < deadlines.count {
            let left = index * 2 + 1, right = left + 1
            let child = right < deadlines.count && deadlines[right].deadline < deadlines[left].deadline ? right : left
            guard deadlines[child].deadline < deadlines[index].deadline else { break }
            swapDeadlines(index, child); index = child
        }
    }
    private mutating func removeDeadline(at index: Int) {
        let removed = deadlines[index].key
        swapDeadlines(index, deadlines.count - 1); deadlines.removeLast(); nodes[removed]!.heapIndex = nil
        if index < deadlines.count {
            let moved = deadlines[index].key; siftUp(index); siftDown(nodes[moved]!.heapIndex!)
        }
    }
    @discardableResult mutating func removeValue(forKey key: Key) -> Value? {
        guard let original = nodes[key] else { return nil }
        setScheduling(nil, for: key, now: .now)
        nodes.removeValue(forKey: key)
        return original.value
    }
    mutating func removeAll() { self = Self() }
    struct Iterator: IteratorProtocol {
        fileprivate var iterator: Dictionary<Key, Node>.Iterator
        mutating func next() -> (Key, Value)? {
            guard let (key, node) = iterator.next() else { return nil }; return (key, node.value)
        }
    }
    func makeIterator() -> Iterator { .init(iterator: nodes.makeIterator()) }
}
