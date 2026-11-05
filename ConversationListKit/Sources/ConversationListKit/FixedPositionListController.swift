#if canImport(UIKit)
import UIKit

/// A list slot is a screen position. Actions receive the value actually bound to the cell.
@MainActor
public final class FixedPositionListController<Row: Identifiable & Equatable>: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    public struct VisibleRow {
        public let row: Row
        public let frame: CGRect
    }

    public struct Configuration {
        public var configure: (UICollectionViewListCell, Row) -> Void
        public var leadingActions: (Row) -> UISwipeActionsConfiguration?
        public var trailingActions: (Row) -> UISwipeActionsConfiguration?
        public var visibleRowsChanged: ([VisibleRow], CGRect) -> Void
        public var didBeginDragging: () -> Void
        public var refresh: (() async -> Void)?

        public init(configure: @escaping (UICollectionViewListCell, Row) -> Void,
                    leadingActions: @escaping (Row) -> UISwipeActionsConfiguration? = { _ in nil },
                    trailingActions: @escaping (Row) -> UISwipeActionsConfiguration? = { _ in nil },
                    visibleRowsChanged: @escaping ([VisibleRow], CGRect) -> Void = { _, _ in },
                    didBeginDragging: @escaping () -> Void = {},
                    refresh: (() async -> Void)? = nil) {
            self.configure = configure
            self.leadingActions = leadingActions
            self.trailingActions = trailingActions
            self.visibleRowsChanged = visibleRowsChanged
            self.didBeginDragging = didBeginDragging
            self.refresh = refresh
        }
    }

    /// A position is only the native menu's on-screen anchor. Its owner is always an ID.
    private final class Reveal {
        let id: Row.ID
        let path: IndexPath
        weak var cell: Cell?
        var heldIDs: [Int: Row.ID]?
        var consumed = false

        init(row: Row, path: IndexPath, cell: Cell) {
            id = row.id
            self.path = path
            self.cell = cell
        }
    }

    private final class Cell: UICollectionViewListCell {
        var boundRow: Row?
        var contentGeneration: UInt = 0
        var offered: Reveal?
        var swipeChanged: ((Cell, Bool) -> Void)?

        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)
            swipeChanged?(self, state.isSwiped)
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            swipeChanged?(self, false)
            offered = nil
            boundRow = nil
        }
    }

    private var revealed: Reveal?
    private weak var orphanedSwipe: Cell?
    private let source: any FixedPositionViewportDataSource<Row>
    private var observerID: UUID?
    private var renderedCount: Int
    private let prefetchDistance: Int
    private var configuration: Configuration
    private var contentGeneration: UInt = 0
    private var list: UICollectionView!
    private var displayLink: CADisplayLink?
    private var refreshTask: Task<Void, Never>?

    public init(source: any FixedPositionViewportDataSource<Row>, configuration: Configuration, prefetchDistance: Int = 24) {
        self.source = source
        renderedCount = source.totalCount
        self.prefetchDistance = max(0, prefetchDistance)
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        var layout = UICollectionLayoutListConfiguration(appearance: .plain)
        layout.leadingSwipeActionsConfigurationProvider = { [weak self] path in
            self?.swipeActions(at: path, leading: true)
        }
        layout.trailingSwipeActionsConfigurationProvider = { [weak self] path in
            self?.swipeActions(at: path, leading: false)
        }
        list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: layout))
        list.backgroundColor = .systemBackground
        list.alwaysBounceVertical = true
        list.allowsSelection = false // The host supplies accessible controls in its row content.
        list.register(Cell.self, forCellWithReuseIdentifier: "slot")
        list.dataSource = self
        list.delegate = self
        view = list
        updateRefreshControl()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if observerID == nil {
            observerID = source.addViewportObserver(.init(
                structureChanged: { [weak self] _ in self?.scheduleFrame() },
                frameWorkAvailable: { [weak self] in self?.scheduleFrame() },
                bindingsChanged: { [weak self] _ in self?.scheduleFrame() }
            ))
        }
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(displayFrame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        scheduleFrame()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scheduleFrame()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    public func stop() {
        closeReveal()
        orphanedSwipe = nil
        for case let cell as Cell in list?.visibleCells ?? [] { cell.offered = nil }
        if let observerID { source.removeViewportObserver(id: observerID) }
        observerID = nil
        displayLink?.invalidate()
        displayLink = nil
        refreshTask?.cancel()
        refreshTask = nil
        list?.refreshControl?.endRefreshing()
        configuration.visibleRowsChanged([], .zero)
    }

    public func update(configuration: Configuration, invalidateContent: Bool = false) {
        self.configuration = configuration
        if invalidateContent { contentGeneration &+= 1 }
        if isViewLoaded { updateRefreshControl() }
        scheduleFrame()
    }

    public func scrollToItem(at index: Int) {
        guard isViewLoaded else { return }
        closeReveal()
        applyCountChange()
        guard (0..<renderedCount).contains(index) else { return }
        list.layoutIfNeeded()
        list.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
        list.layoutIfNeeded()
        reportVisibleRows()
        scheduleFrame()
    }

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { renderedCount }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "slot", for: indexPath) as! Cell
        cell.swipeChanged = { [weak self] cell, open in self?.swipeChanged(cell, open: open) }
        bind(cell, at: indexPath)
        return cell
    }

    public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let cell = cell as? Cell { bind(cell, at: indexPath) }
        scheduleFrame()
    }

    public func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? Cell else { return }
        swipeChanged(cell, open: false)
        cell.offered = nil
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) { scheduleFrame() }
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        closeReveal()
        configuration.didBeginDragging()
    }

    private func bind(_ cell: Cell, at path: IndexPath) {
        guard let row = presentedRow(at: path.item) else {
            // A ranked source can resolve a new viewport asynchronously. A reused slot
            // must release its old content and actions while the new binding is pending.
            if cell.boundRow != nil {
                cell.offered = nil
                cell.boundRow = nil
                cell.contentConfiguration = nil
            }
            return
        }
        guard cell.boundRow != row || cell.contentGeneration != contentGeneration else { return }
        if cell.offered?.id != row.id { cell.offered = nil }
        configuration.configure(cell, row)
        cell.boundRow = row
        cell.contentGeneration = contentGeneration
    }

    private func swipeActions(at path: IndexPath, leading: Bool) -> UISwipeActionsConfiguration? {
        guard let cell = list.cellForItem(at: path) as? Cell, let row = cell.boundRow,
              source.row(withID: row.id) != nil,
              let menu = (leading ? configuration.leadingActions : configuration.trailingActions)(row) else { return nil }
        let offer: Reveal
        if let existing = cell.offered, existing.id == row.id, existing.path == path, !existing.consumed {
            offer = existing
        } else {
            offer = Reveal(row: row, path: path, cell: cell)
            cell.offered = offer
        }
        if cell.configurationState.isSwiped { swipeChanged(cell, open: true) }
        let actions = menu.actions.map { original in
            let guarded = UIContextualAction(style: original.style, title: original.title) { [weak self] _, view, complete in
                guard let self, observerID != nil, let cell = offer.cell, cell.offered === offer, !offer.consumed,
                      cell.boundRow?.id == offer.id, list.indexPath(for: cell) == offer.path,
                      source.row(withID: offer.id) != nil else { complete(false); return }
                offer.consumed = true
                original.handler(original, view, complete)
            }
            guarded.image = original.image
            guarded.backgroundColor = original.backgroundColor
            return guarded
        }
        let guarded = UISwipeActionsConfiguration(actions: actions)
        guarded.performsFirstActionWithFullSwipe = menu.performsFirstActionWithFullSwipe
        return guarded
    }

    private func swipeChanged(_ cell: Cell, open: Bool) {
        if open, let offer = cell.offered, cell.boundRow?.id == offer.id {
            if revealed !== offer {
                revealed?.cell?.offered = nil
                revealed = offer
                scheduleFrame()
            }
        } else if open {
            // The slot may have rebound between UIKit requesting the actions and
            // reporting the open state. Retire that native menu on the next frame.
            orphanedSwipe = cell
            scheduleFrame()
        } else if let active = revealed, active.cell === cell {
            cell.offered = nil
            revealed = nil
            scheduleFrame()
        }
    }

    private func closeReveal() {
        guard let active = revealed else { return }
        revealed = nil
        active.cell?.offered = nil
        if let cell = active.cell, list.indexPath(for: cell) == active.path {
            // UICollectionView has no public close-swipe command. Retire just the
            // owning cell, after invalidating any action UIKit still retains.
            UIView.performWithoutAnimation { list.reloadItems(at: [active.path]) }
        }
        scheduleFrame()
    }

    private func presentedRow(at position: Int) -> Row? {
        guard let active = revealed else { return source.row(at: position) }
        if source.row(at: active.path.item)?.id == active.id {
            active.heldIDs = nil
            return source.row(at: position)
        }
        if active.heldIDs == nil {
            var ids = [active.path.item: active.id]
            for cell in list.visibleCells {
                if let cell = cell as? Cell, let row = cell.boundRow, let index = list.indexPath(for: cell) {
                    ids[index.item] = row.id
                }
            }
            active.heldIDs = ids
        }
        return active.heldIDs?[position].flatMap { source.row(withID: $0) }
    }

    private func scheduleFrame() { displayLink?.isPaused = false }

    @objc private func displayFrame() {
        displayLink?.isPaused = true
        if let active = revealed {
            let heldRowWasRemoved = active.heldIDs?.values.contains { source.row(withID: $0) == nil } == true
            if source.row(withID: active.id) == nil || active.path.item >= source.totalCount || heldRowWasRemoved {
                closeReveal()
            }
        }
        if let cell = orphanedSwipe {
            orphanedSwipe = nil
            if cell.configurationState.isSwiped, cell.offered == nil, let path = list.indexPath(for: cell) {
                UIView.performWithoutAnimation { list.reloadItems(at: [path]) }
            }
        }
        if revealed == nil { applyCountChange() }
        let positions = list.indexPathsForVisibleItems.map(\.item)
        let requestCount = min(source.totalCount, renderedCount)
        if requestCount > 0 {
            let first = min(positions.min() ?? 0, requestCount - 1)
            let last = min(positions.max() ?? first, requestCount - 1)
            let lower = first - min(first, prefetchDistance)
            let upper = last + 1 + min(requestCount - last - 1, prefetchDistance)
            source.commitFrame(in: [lower..<upper])
        }
        reportVisibleRows()
    }

    private func reportVisibleRows() {
        let bounds = list.bounds.inset(by: list.adjustedContentInset)
        let visible = list.indexPathsForVisibleItems.sorted().compactMap { path -> VisibleRow? in
            guard path.item < renderedCount, let cell = list.cellForItem(at: path) as? Cell else { return nil }
            bind(cell, at: path)
            guard cell.frame.intersects(bounds), let row = cell.boundRow else { return nil }
            return VisibleRow(row: row, frame: cell.frame)
        }
        configuration.visibleRowsChanged(visible, bounds)
    }

    private func applyCountChange() {
        let previousCount = renderedCount
        let currentCount = source.totalCount
        guard previousCount != currentCount else { return }
        // UIKit must see the old count until the update closure advances the data source.
        // All moves within the shared prefix are value rebindings, not structural edits.
        UIView.performWithoutAnimation {
            list.performBatchUpdates {
                renderedCount = currentCount
                if currentCount > previousCount {
                    list.insertItems(at: (previousCount..<currentCount).map { IndexPath(item: $0, section: 0) })
                } else {
                    list.deleteItems(at: (currentCount..<previousCount).map { IndexPath(item: $0, section: 0) })
                }
            }
        }
    }

    private func updateRefreshControl() {
        if configuration.refresh == nil { list.refreshControl = nil }
        else if list.refreshControl == nil {
            let refresh = UIRefreshControl()
            refresh.addTarget(self, action: #selector(beginRefresh), for: .valueChanged)
            list.refreshControl = refresh
        }
    }

    @objc private func beginRefresh() {
        guard refreshTask == nil, let refresh = configuration.refresh else { return }
        refreshTask = Task { [weak self] in
            await refresh()
            guard !Task.isCancelled else { return }
            self?.list.refreshControl?.endRefreshing()
            self?.refreshTask = nil
        }
    }
}
#endif
