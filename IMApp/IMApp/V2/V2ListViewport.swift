import Observation
import SwiftUI

/// 列表视口状态。
///
/// 行几何信息是临时的且受已发布窗口约束；对外观察到的只有顶部可见条目标识
/// 与显式的恢复请求。
@MainActor
@Observable
final class V2ListViewport {
    /// 一次滚动位置恢复请求。
    struct Restoration: Equatable {
        let id = UUID()
        let itemID: String
    }
    struct RowPosition: Equatable {
        let minY: CGFloat
        let maxY: CGFloat
    }
    enum ReadResolution {
        case ready(anchorID: String?)
        case reread
    }
    private(set) var anchorID: String?
    private(set) var restoration: Restoration?
    @ObservationIgnored private var rows: [String: RowPosition] = [:]
    @ObservationIgnored private var rowOwners: [String: UUID] = [:]
    @ObservationIgnored private var allowedIDs = Set<String>()
    @ObservationIgnored private var visibleBounds: CGRect = .zero

    func reconcile(ids: [String]) {
        allowedIDs = Set(ids)
        rows = rows.filter { allowedIDs.contains($0.key) }
        rowOwners = rowOwners.filter { allowedIDs.contains($0.key) }
        if let anchorID, !allowedIDs.contains(anchorID) { self.anchorID = nil }
        if let restoration, !allowedIDs.contains(restoration.itemID) { self.restoration = nil }
    }

    func resize(height: CGFloat) {
        visibleBounds = CGRect(x: 0, y: 0, width: 0, height: height)
        updateAnchor()
    }

    func resize(visibleBounds: CGRect) {
        self.visibleBounds = visibleBounds
        updateAnchor()
    }

    func record(id: String, position: RowPosition, ownerID: UUID? = nil) {
        guard allowedIDs.contains(id) else { return }
        rows[id] = position
        rowOwners[id] = ownerID
        updateAnchor()
    }

    func remove(id: String, ownerID: UUID? = nil) {
        guard ownerID == nil || rowOwners[id] == ownerID else { return }
        rows[id] = nil; rowOwners[id] = nil; updateAnchor()
    }

    func containsVisibleRow(_ id: String) -> Bool {
        guard visibleBounds.height > 0, let row = rows[id] else { return false }
        return row.maxY > visibleBounds.minY && row.minY < visibleBounds.maxY
    }

    /// 在发布前立即解析读取结果，调用方提交之前不得发生挂起。
    ///
    /// 读取方绝不允许恢复一个已经过时的滚动位置，因此这里在捕获锚点后同步判断：
    /// 锚点未变则沿用回退值，锚点仍在返回集合中则直接采用，否则要求重新读取。
    ///
    /// - Parameters:
    ///   - capturedAnchorID: 本次读取开始时捕获的锚点标识。
    ///   - returnedIDs: 本次读取返回的条目标识列表。
    ///   - fallback: 锚点未变化时使用的回退标识。
    /// - Returns: 读取结果（就绪或需要重新读取）。
    func resolveRead(capturedAnchorID: String?, returnedIDs: [String], fallback: String?) -> ReadResolution {
        guard anchorID != capturedAnchorID else { return .ready(anchorID: fallback) }
        guard let anchorID else { return .ready(anchorID: nil) }
        return returnedIDs.contains(anchorID) ? .ready(anchorID: anchorID) : .reread
    }

    #if DEBUG
    func layoutDescription(for id: String) -> String {
        "visibleBounds=\(visibleBounds), row=\(String(describing: rows[id])), cachedRows=\(rows.count)"
    }
    #endif

    func restore(to id: String?) {
        guard let id, allowedIDs.contains(id), restoration?.itemID != id else { return }
        anchorID = id
        restoration = .init(itemID: id)
    }

    func userDidBeginScrolling() {
        restoration = nil
        updateAnchor()
    }

    /// 执行一次滚动位置恢复。
    ///
    /// 列表可能按估算行高钳制首次滚动，因此允许若干次布局重试，随后即使视图消失也要释放所有权。
    /// 取消由页面任务负责，本方法不会留下任何计时器。
    ///
    /// - Parameters:
    ///   - request: 待执行的恢复请求。
    ///   - scrollTo: 实际的滚动回调。
    func performRestoration(_ request: Restoration, scrollTo: (String) -> Void) async {
        await Task.yield()
        for _ in 0..<8 {
            guard !Task.isCancelled, restoration?.id == request.id else { return }
            scrollTo(request.itemID)
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return }
            guard !Task.isCancelled, restoration?.id == request.id else { return }
            if containsVisibleRow(request.itemID) { break }
        }
        didRequestRestoration(request)
    }

    func didRequestRestoration(_ request: Restoration) {
        if restoration?.id == request.id { restoration = nil }
    }

    func reset() { rows.removeAll(); rowOwners.removeAll(); allowedIDs.removeAll(); anchorID = nil; restoration = nil }

    private func updateAnchor() {
        guard restoration == nil, visibleBounds.height > 0 else { return }
        let top = rows.filter { $0.value.maxY > visibleBounds.minY && $0.value.minY < visibleBounds.maxY }
            .min { lhs, rhs in lhs.value.minY == rhs.value.minY ? lhs.key < rhs.key : lhs.value.minY < rhs.value.minY }
        if let top { anchorID = top.key }
    }
}

struct V2ListViewportRow: ViewModifier {
    @State private var ownerID = UUID()
    let viewport: V2ListViewport
    let itemID: String
    let coordinateSpace: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: V2ListViewport.RowPosition.self) { proxy in
                let frame = proxy.frame(in: .global)
                return .init(minY: frame.minY, maxY: frame.maxY)
            } action: { viewport.record(id: itemID, position: $0, ownerID: ownerID) }
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        // A reused List row may reappear at the same geometry,
                        // so onGeometryChange alone need not emit again.
                        let frame = proxy.frame(in: .global)
                        viewport.record(id: itemID, position: .init(minY: frame.minY, maxY: frame.maxY), ownerID: ownerID)
                    }
                }
            }
            .onDisappear { viewport.remove(id: itemID, ownerID: ownerID) }
    }
}

struct V2ListViewportContainer: ViewModifier {
    let viewport: V2ListViewport
    let coordinateSpace: String

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .coordinateSpace(name: coordinateSpace)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport.resize(visibleBounds: $0) }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { viewport.userDidBeginScrolling() }
                }
                .task(id: viewport.restoration?.id) {
                    guard let request = viewport.restoration else { return }
                    await viewport.performRestoration(request) { proxy.scrollTo($0, anchor: .top) }
                }
        }
    }
}
