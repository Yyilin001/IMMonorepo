import Foundation

/// 消息写入执行路径所用的有界进程内分类缓存。
///
/// 该缓存刻意不承担授权、房间存在性或投递权威：它只在共享事务执行前把写入区分成私聊、
/// 混合大群与单条三类执行图。每条路径仍会在接受消息前用 PostgreSQL 校验房间与调用方，
/// 因此过期条目最多让请求走更慢的路径，或让原子路径安全地放弃合并。
actor V2RoomWriteBatchRouteCache {
    /// 房间写入路径分类。
    enum Route: Sendable, Equatable {
        /// 私聊房间写入。
        case direct
        /// 混合大群写入。
        case large
        /// 无法合并的单条写入。
        case individual
    }

    /// 缓存运行统计快照。
    struct Snapshot: Sendable, Equatable {
        /// 当前条目数。
        let entries: Int
        /// 命中次数。
        let lookupHits: UInt64
        /// 未命中次数。
        let lookupMisses: UInt64
        /// 插入次数。
        let insertions: UInt64
        /// 淘汰次数。
        let evictions: UInt64
    }

    /// 最近最少使用链表的节点。
    private final class Node {
        let roomID: UUID
        var route: Route
        weak var previous: Node?
        var next: Node?

        /// 以房间标识与路径构造节点。
        ///
        /// - Parameters:
        ///   - roomID: 房间标识。
        ///   - route: 写入路径分类。
        init(roomID: UUID, route: Route) {
            self.roomID = roomID
            self.route = route
        }
    }

    private let capacity: Int
    private var entries: [UUID: Node] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?
    private var lookupHits: UInt64 = 0
    private var lookupMisses: UInt64 = 0
    private var insertions: UInt64 = 0
    private var evictions: UInt64 = 0

    /// 创建容量有界的缓存。
    ///
    /// - Parameter capacity: 条目容量上限，小于一时按一处理。
    init(capacity: Int = 50_000) {
        self.capacity = max(1, capacity)
    }

    /// 批量查询房间的写入路径。
    ///
    /// 命中与未命中都会计数，命中项会被提升为最近使用。
    ///
    /// - Parameter roomIDs: 待查询的房间标识。
    /// - Returns: 与输入顺序一一对应的路径；未命中为 `nil`。
    func values(for roomIDs: [UUID]) -> [Route?] {
        roomIDs.map { roomID in
            guard let node = entries[roomID] else {
                lookupMisses &+= 1
                return nil
            }
            lookupHits &+= 1
            moveToMostRecent(node)
            return node.route
        }
    }

    /// 写入或更新房间的写入路径。
    ///
    /// 已存在的条目只更新路径并提升为最近使用；新条目在容量已满时淘汰最久未使用的一项。
    ///
    /// - Parameter routes: 待写入的房间与路径列表。
    func insert(_ routes: [(roomID: UUID, route: Route)]) {
        for value in routes {
            if let node = entries[value.roomID] {
                node.route = value.route
                moveToMostRecent(node)
                continue
            }
            if entries.count >= capacity, let leastRecent {
                remove(leastRecent)
                evictions &+= 1
            }
            let node = Node(roomID: value.roomID, route: value.route)
            entries[value.roomID] = node
            attachAsMostRecent(node)
            insertions &+= 1
        }
    }

    /// 读取当前缓存统计。
    ///
    /// - Returns: 条目数与各项计数快照。
    func snapshot() -> Snapshot {
        .init(
            entries: entries.count,
            lookupHits: lookupHits,
            lookupMisses: lookupMisses,
            insertions: insertions,
            evictions: evictions
        )
    }

    /// 把节点提升为最近使用。
    ///
    /// - Parameter node: 目标节点。
    private func moveToMostRecent(_ node: Node) {
        guard mostRecent !== node else { return }
        detach(node)
        attachAsMostRecent(node)
    }

    /// 把节点挂到最近使用端。
    ///
    /// - Parameter node: 目标节点。
    private func attachAsMostRecent(_ node: Node) {
        node.previous = nil
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil {
            leastRecent = node
        }
    }

    /// 把节点从链表中断开，不改变索引。
    ///
    /// - Parameter node: 目标节点。
    private func detach(_ node: Node) {
        if let previous = node.previous {
            previous.next = node.next
        } else {
            mostRecent = node.next
        }
        if let next = node.next {
            next.previous = node.previous
        } else {
            leastRecent = node.previous
        }
        node.previous = nil
        node.next = nil
    }

    /// 断开节点并从索引中移除。
    ///
    /// - Parameter node: 目标节点。
    private func remove(_ node: Node) {
        detach(node)
        entries.removeValue(forKey: node.roomID)
    }
}
