import Foundation

/// 固定位置视口使用的跨平台结构变更。
public enum FixedPositionViewportStructureChange: Sendable {
    case reloadData
    case itemCountChanged(previous: Int, current: Int)
    /// 一个完整的业务快照替换了之前的快照。如果其位置映射不变，渲染器可以保留现有的单元格，仅修改尾部槽；行标识将在下一帧重新绑定。
    case snapshotReplaced(previous: Int, current: Int, mappingChanged: Bool)
}

/// 渲染器通过这些回调订阅事件，而不是替换全局闭包。macOS 的多个窗口可以共享一个视口数据源，
/// 因此每个已挂载渲染器都需要独立的回调生命周期。
@MainActor
public struct FixedPositionViewportObserver<Row> {
    public let structureChanged: (FixedPositionViewportStructureChange) -> Void
    public let frameWorkAvailable: () -> Void
    public let bindingsChanged: (Set<Int>) -> Void

    public init(
        structureChanged: @escaping (FixedPositionViewportStructureChange) -> Void,
        frameWorkAvailable: @escaping () -> Void,
        bindingsChanged: @escaping (Set<Int>) -> Void
    ) {
        self.structureChanged = structureChanged
        self.frameWorkAvailable = frameWorkAvailable
        self.bindingsChanged = bindingsChanged
    }
}

/// 固定位置渲染器使用的数据源协议。
///
/// 数据源持有不可变行数据，并通过 actor 读取秩。平台渲染器只请求可见范围，再将最新行应用到复用原生条目。
/// 回调属于 UI 事件，因此该协议隔离到 MainActor。
@MainActor
public protocol FixedPositionViewportDataSource<Row>: AnyObject {
    associatedtype Row: Identifiable

    var totalCount: Int { get }
    var pinnedCount: Int { get }
    func row(at position: Int) -> Row?
    func row(withID id: Row.ID) -> Row?
    func commitFrame(in requestedRanges: [Range<Int>])

    func addViewportObserver(_ observer: FixedPositionViewportObserver<Row>) -> UUID
    func removeViewportObserver(id: UUID)
}

/// An already ordered, bounded window, such as a database page. Lookup is O(1).
/// Ranked sources can implement the same protocol and resolve only requested ranges.
@MainActor
public final class OrderedListWindow<Row: Identifiable>: FixedPositionViewportDataSource {
    private var rows: [Row]
    private var positionsByID: [Row.ID: Int]?
    private var observers: [UUID: FixedPositionViewportObserver<Row>] = [:]
    public var totalCount: Int { rows.count }
    public var pinnedCount: Int { 0 }

    public init(_ rows: [Row] = []) { self.rows = rows }

    public func replace(with rows: [Row]) {
        let previous = self.rows.count
        self.rows = rows
        positionsByID = nil
        for observer in observers.values {
            if rows.count != previous {
                observer.structureChanged(.itemCountChanged(previous: previous, current: rows.count))
            } else {
                observer.frameWorkAvailable()
            }
        }
    }

    public func row(at position: Int) -> Row? {
        rows.indices.contains(position) ? rows[position] : nil
    }

    public func row(withID id: Row.ID) -> Row? {
        // Most frames only use positions. Build this index once per snapshot
        // when an interaction actually needs to follow a row across a move.
        if positionsByID == nil {
            positionsByID = Dictionary(rows.indices.lazy.map { (self.rows[$0].id, $0) }, uniquingKeysWith: { _, _ in -1 })
        }
        return positionsByID?[id].flatMap(row(at:))
    }

    public func firstIndex(where matches: (Row) -> Bool) -> Int? { rows.firstIndex(where: matches) }

    public func commitFrame(in requestedRanges: [Range<Int>]) {}

    public func addViewportObserver(_ observer: FixedPositionViewportObserver<Row>) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeViewportObserver(id: UUID) { observers[id] = nil }
}
